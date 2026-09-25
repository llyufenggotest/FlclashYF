//go:build ios && with_low_memory

package main

// The Network Extension process runs inside a jetsam budget near 50 MB, and a
// packet tunnel is killed outright when phys_footprint crosses it. This knob
// trades latency for peak memory and does not touch wire protocol behaviour.
//
// delayBatchConcurrency caps how many delay probes run at once. Each probe is a
// full TLS handshake, so the default of 50 is the largest transient allocation
// in this process when a profile with 100+ nodes runs a group test.
const delayBatchConcurrency = 8
