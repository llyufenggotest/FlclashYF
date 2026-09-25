//go:build !(ios && with_low_memory)

package main

// Upstream behaviour for every process that is not the iOS Network Extension.
// Desktop and Android have no jetsam budget in this range, and the app-side iOS
// core has a much larger allowance than the extension.
const delayBatchConcurrency = 50
