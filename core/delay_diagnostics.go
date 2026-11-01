package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"sync"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/log"
)

// These indices and their labels are the entire diagnostic vocabulary. Never
// retain an error, URL, proxy name, request ID, or configuration in the batch.
type delayFailure uint8

const (
	delayOK delayFailure = iota
	delayUnknown
	delayMissingProxy
	delayQueueDeadline
	delayQueueUnknown
	delayZero
	delayCanceled
	delayDeadline
	delayDNS
	delayDNSTimeout
	delayDNSNotFound
	delayCertAuthority
	delayCertHostname
	delayCertInvalid
	delayTLSRecord
	delayTLSAlert
	delayRefused
	delayReset
	delaySyscall
	delayNetOp
	delayURLParse
	delayURLWrapper
	delayFailureCount
)

type delayBucket struct {
	Class string `json:"class"`
	Stage string `json:"stage"`
	Cause string `json:"cause"`
	Count uint64 `json:"count"`
}

var delayFailureLabels = [delayFailureCount]delayBucket{
	delayOK:            {Class: "success", Stage: "complete", Cause: "none"},
	delayUnknown:       {Class: "unknown", Stage: "unknown", Cause: "untyped"},
	delayMissingProxy:  {Class: "missing_proxy", Stage: "proxy_lookup", Cause: "wrapper_lookup"},
	delayQueueDeadline: {Class: "queue_deadline", Stage: "wrapper_admission", Cause: "context_deadline"},
	delayQueueUnknown:  {Class: "queue_rejected", Stage: "wrapper_admission", Cause: "wrapper_admission"},
	delayZero:          {Class: "zero_delay", Stage: "complete", Cause: "wrapper_zero_value"},
	delayCanceled:      {Class: "canceled", Stage: "unknown", Cause: "context_canceled"},
	delayDeadline:      {Class: "deadline", Stage: "unknown", Cause: "context_deadline"},
	delayDNS:           {Class: "dns", Stage: "dns_resolve", Cause: "net_dns"},
	delayDNSTimeout:    {Class: "dns_timeout", Stage: "dns_resolve", Cause: "net_dns"},
	delayDNSNotFound:   {Class: "dns_not_found", Stage: "dns_resolve", Cause: "net_dns"},
	delayCertAuthority: {Class: "certificate_authority", Stage: "certificate_verify", Cause: "x509_authority"},
	delayCertHostname:  {Class: "certificate_hostname", Stage: "certificate_verify", Cause: "x509_hostname"},
	delayCertInvalid:   {Class: "certificate_invalid", Stage: "certificate_verify", Cause: "x509_invalid"},
	delayTLSRecord:     {Class: "tls_record", Stage: "tls_record", Cause: "tls_record_header"},
	delayTLSAlert:      {Class: "tls_alert", Stage: "tls_alert", Cause: "tls_alert"},
	delayRefused:       {Class: "connection_refused", Stage: "unknown", Cause: "syscall_refused"},
	delayReset:         {Class: "connection_reset", Stage: "unknown", Cause: "syscall_reset"},
	delaySyscall:       {Class: "syscall", Stage: "unknown", Cause: "syscall_errno"},
	delayNetOp:         {Class: "network_op", Stage: "unknown", Cause: "net_op"},
	delayURLParse:      {Class: "url_parse", Stage: "url_parse", Cause: "url_parse_type"},
	delayURLWrapper:    {Class: "url_error", Stage: "unknown", Cause: "url_error"},
}

// Inspect only typed causes, never Error() strings. A net.OpError alone proves
// neither TCP nor TLS. Context and errno causes do not locate a failing stage.
func classifyDelayFailure(err error) delayFailure {
	if err == nil {
		return delayOK
	}
	if errors.Is(err, context.Canceled) {
		return delayCanceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return delayDeadline
	}
	var dns *net.DNSError
	if errors.As(err, &dns) {
		if dns.IsTimeout {
			return delayDNSTimeout
		}
		if dns.IsNotFound {
			return delayDNSNotFound
		}
		return delayDNS
	}
	var authority x509.UnknownAuthorityError
	if errors.As(err, &authority) {
		return delayCertAuthority
	}
	var hostname x509.HostnameError
	if errors.As(err, &hostname) {
		return delayCertHostname
	}
	var invalid x509.CertificateInvalidError
	if errors.As(err, &invalid) {
		return delayCertInvalid
	}
	var record tls.RecordHeaderError
	if errors.As(err, &record) {
		return delayTLSRecord
	}
	var alert tls.AlertError
	if errors.As(err, &alert) {
		return delayTLSAlert
	}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		switch errno {
		case syscall.ECONNREFUSED:
			return delayRefused
		case syscall.ECONNRESET:
			return delayReset
		default:
			return delaySyscall
		}
	}
	var op *net.OpError
	if errors.As(err, &op) {
		return delayNetOp
	}
	var escape url.EscapeError
	var host url.InvalidHostError
	if errors.As(err, &escape) || errors.As(err, &host) {
		return delayURLParse
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return delayURLWrapper
	}
	return delayUnknown
}

type delayURLShape uint8

const (
	delayURLInvalid delayURLShape = iota
	delayURLHTTP
	delayURLHTTPS
)

func delayTestURLShape(raw string) (delayURLShape, bool) {
	u, err := url.Parse(raw)
	if err != nil {
		return delayURLInvalid, false
	}
	present := u.Hostname() != ""
	if present {
		switch u.Scheme {
		case "http":
			return delayURLHTTP, true
		case "https":
			return delayURLHTTPS, true
		}
	}
	return delayURLInvalid, present
}

const delayDiagnosticWindow = 250 * time.Millisecond
const delayDiagnosticCountCap uint64 = 1_000_000_000

type delaySummary struct {
	Completed     uint64        `json:"completed"`
	Positive      uint64        `json:"positive"`
	Negative      uint64        `json:"negative"`
	Null          uint64        `json:"null"`
	Coalesced     uint64        `json:"coalesced"`
	SchemeHTTP    uint64        `json:"scheme_http"`
	SchemeHTTPS   uint64        `json:"scheme_https"`
	SchemeInvalid uint64        `json:"scheme_invalid"`
	HostPresent   uint64        `json:"host_present"`
	ProxyPresent  uint64        `json:"proxy_present"`
	Saturated     bool          `json:"saturated"`
	Buckets       []delayBucket `json:"buckets"`
}

type delayDiagnosticBatch struct {
	mu sync.Mutex
	// active stays true during publication: a stalled log sink cannot spawn a
	// goroutine/timer per window. New completions aggregate in the same fixed state.
	active  bool
	timer   *time.Timer
	summary delaySummary
	counts  [delayFailureCount]uint64
}

var delayDiagnostics delayDiagnosticBatch

func (b *delayDiagnosticBatch) add(failure delayFailure, value int32, null bool, shape delayURLShape, host, proxy bool) {
	b.mu.Lock()
	inc := func(n *uint64) {
		if *n < delayDiagnosticCountCap {
			*n++
		} else {
			b.summary.Saturated = true
		}
	}
	inc(&b.summary.Completed)
	if null {
		inc(&b.summary.Null)
	} else if value > 0 {
		inc(&b.summary.Positive)
	} else {
		inc(&b.summary.Negative)
	}
	if shape == delayURLHTTP {
		inc(&b.summary.SchemeHTTP)
	} else if shape == delayURLHTTPS {
		inc(&b.summary.SchemeHTTPS)
	} else {
		inc(&b.summary.SchemeInvalid)
	}
	if host {
		inc(&b.summary.HostPresent)
	}
	if proxy {
		inc(&b.summary.ProxyPresent)
	}
	if failure >= delayFailureCount {
		failure = delayUnknown
	}
	inc(&b.counts[failure])
	if !b.active {
		b.active = true
		b.timer = time.AfterFunc(delayDiagnosticWindow, b.publish)
	}
	b.mu.Unlock()
}

func (b *delayDiagnosticBatch) snapshotLocked() delaySummary {
	s := b.summary
	if s.Completed > 0 {
		s.Coalesced = s.Completed - 1
	}
	for i, n := range b.counts {
		if n == 0 {
			continue
		}
		label := delayFailureLabels[i]
		label.Count = n
		s.Buckets = append(s.Buckets, label)
	}
	b.summary = delaySummary{}
	b.counts = [delayFailureCount]uint64{}
	return s
}

func (b *delayDiagnosticBatch) publish() {
	b.mu.Lock()
	s := b.snapshotLocked()
	b.timer = nil
	b.mu.Unlock()
	// This is asynchronous to the probe and outside its locks. A log delivery
	// failure must never change Delay, consume its budget, or hold its slot.
	func() {
		defer func() { _ = recover() }()
		payload, err := json.Marshal(s)
		if err == nil {
			log.Infoln("delay_test_summary %s", payload)
		}
	}()
	b.mu.Lock()
	if b.summary.Completed != 0 {
		b.timer = time.AfterFunc(delayDiagnosticWindow, b.publish)
	} else {
		b.active = false
	}
	b.mu.Unlock()
}
