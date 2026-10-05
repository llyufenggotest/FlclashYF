//go:build ios && with_low_memory

package main

// Bound concurrent TLS probes separately for the packet-tunnel build.
const delayBatchConcurrency = 8
const coreBuildVariant = "FLCLASH_CORE_VARIANT_LOWMEM"
