#!/usr/bin/env python3
"""Verify iOS provider retry and config acknowledgement behavior."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ProviderRetryWiring(unittest.TestCase):
    def source(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8")

    def test_service_init_waits_for_tunnel_route(self):
        channel = self.source("ios/Runner/ServiceChannel.swift")
        router = self.source("ios/Runner/Core/CoreMessageRouter.swift")
        init_body = channel.split('case "init":', 1)[1].split('case "syncState":', 1)[0]
        self.assertIn("await coreMessageRouter.refreshTunnelState()", init_body)
        self.assertLess(
            init_body.index("await coreMessageRouter.refreshTunnelState()"),
            init_body.index('result("")'),
        )
        self.assertIn("func refreshTunnelState() async", router)

    def test_configuration_messages_are_not_blindly_replayed(self):
        controller = self.source("ios/Runner/Tunnel/TunnelController.swift")
        router = self.source("ios/Runner/Core/CoreMessageRouter.swift")
        self.assertIn("ProviderReadRetry", controller)
        self.assertIn("ProviderReadRetry.isReadOnlyMethod(method)", controller)
        self.assertIn("attempts = retryRead ? ProviderReadRetry.maxAttempts : 1", controller)
        self.assertIn("configurationTimeout", controller)
        self.assertIn("providerReadTimeout", controller)
        self.assertIn("beginConfigurationApply", router)
        self.assertIn("finishConfigurationApply", router)

    def test_lost_configuration_reply_uses_exact_request_ack(self):
        controller = self.source("ios/Runner/Tunnel/TunnelController.swift")
        runner_store = self.source("ios/Runner/Storage/SharedStateStore.swift")
        provider = self.source("ios/NECore/PacketTunnelProvider.swift")
        packet_store = self.source("ios/NECore/PacketTunnelSharedStateStore.swift")
        self.assertIn("waitForAppliedConfiguration", controller)
        self.assertIn("SwitchDiagnostics.requestID(data)", controller)
        self.assertIn("isConfigurationRequestApplied", runner_store)
        self.assertIn("clearConfigurationRequestApplied", runner_store)
        self.assertIn("markConfigurationRequestApplied", packet_store)
        self.assertIn("clearConfigurationRequestApplied", packet_store)
        self.assertIn("markConfigurationRequestApplied", provider)
        self.assertIn("methodResponseHasEmptyStringResult", provider)


class ProviderReadRetryNative(unittest.TestCase):
    def test_policy_executes_with_swift(self):
        if not shutil.which("xcrun"):
            self.skipTest("native Swift test requires macOS and xcrun")
        source = ROOT / "ios/Shared/ProviderReadRetry.swift"
        harness = ROOT / "scripts/fixtures/provider_read_retry_main.swift"
        with tempfile.TemporaryDirectory(prefix="provider-read-retry-") as directory:
            binary = Path(directory) / "provider-read-retry"
            subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-swift-version",
                    "5",
                    "-warnings-as-errors",
                    str(source),
                    str(harness),
                    "-o",
                    str(binary),
                ],
                check=True,
                timeout=120,
            )
            subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == "__main__":
    unittest.main()
