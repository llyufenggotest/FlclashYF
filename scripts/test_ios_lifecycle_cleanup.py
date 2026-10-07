import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
NECORE = ROOT / "ios" / "NECore"


class IOSLifecycleCleanupTests(unittest.TestCase):
    def read(self, name: str) -> str:
        return (NECORE / name).read_text(encoding="utf-8")

    def test_start_failures_share_idempotent_resource_cleanup(self):
        provider = self.read("PacketTunnelProvider.swift")
        cleanup = self.read("PacketTunnelLifecycleCleanup.swift")
        self.assertIn("PacketTunnelLifecycleCleanup", provider)
        self.assertIn("if error != nil", provider)
        self.assertIn("cleanup.cleanup()", provider)
        self.assertIn("NSLock", cleanup)
        self.assertIn("guard !cleanedUp else", cleanup)
        for resource in (
            "stopMemoryPressureDiagnostics",
            "eventQueue.stop()",
            "resourceHeartbeat.stop()",
            "commandServer.stop()",
        ):
            self.assertIn(resource, provider)

    def test_event_queue_reactivates_after_overflow_or_restart(self):
        source = self.read("NECoreEventQueue.swift")
        self.assertIn("coreActive = true", source)
        self.assertIn("coreActive = false", source)
        self.assertIn("func start()", source)
        self.assertIn("func stop()", source)

    def test_command_server_expires_stuck_inflight_requests(self):
        source = self.read("PacketTunnelCommandServer.swift")
        for marker in (
            "inFlightTimeout",
            "expireInFlightRequests",
            "InFlightRequest",
            "timedOutResponse",
        ):
            self.assertIn(marker, source)
        self.assertIn("inFlight: [String: InFlightRequest]", source)


if __name__ == "__main__":
    unittest.main()
