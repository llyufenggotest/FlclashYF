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

    def test_live_extension_update_is_not_blocked_by_unconfigured_app_core(self):
        router = self.source("ios/Runner/Core/CoreMessageRouter.swift")
        body = router.split("private func sendConfigurationMessage(", 1)[1].split(
            "private func sendConfigurationPhase(", 1
        )[0]
        self.assertIn("if networkExtensionActive && method == .updateConfig", body)
        branch = body.split(
            "if networkExtensionActive && method == .updateConfig", 1
        )[1].split("let appResponse", 1)[0]
        self.assertIn("route: .networkExtension", branch)
        self.assertNotIn("route: .app", branch)

    def test_nil_provider_reply_refreshes_manager_before_retry(self):
        controller = self.source("ios/Runner/Tunnel/TunnelController.swift")
        store = self.source("ios/Runner/Tunnel/TunnelManagerStore.swift")
        self.assertIn("refreshManagerAfterNilResponse", controller)
        self.assertIn("func refreshLoadedManager() async throws", store)
        self.assertIn("selectManagedManager", store)

    def test_reads_leave_one_message_slot_for_configuration(self):
        controller = self.source("ios/Runner/Tunnel/TunnelController.swift")
        self.assertIn(
            "acquireProviderMessageSlot(reserveForConfiguration: retryRead)",
            controller,
        )
        self.assertIn("maxInFlightProviderMessages - 1", controller)

    def test_successful_live_setup_releases_app_core_runtime(self):
        router = self.source("ios/Runner/Core/CoreMessageRouter.swift")
        core = self.source("core/method.go")
        self.assertIn("releaseAppCoreConfiguration()", router)
        self.assertIn('releaseConfigMethod:', core)

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


class CommandBridgeWiring(unittest.TestCase):
    def source(self, path: str) -> str:
        return (ROOT / path).read_text(encoding="utf-8")

    def test_app_sends_control_requests_over_file_bridge(self):
        controller = self.source("ios/Runner/Tunnel/TunnelController.swift")
        # The dead sendProviderMessage transport must be gone from the attempt.
        self.assertNotIn("session.sendProviderMessage(", controller)
        self.assertIn("private let providerBridge: ProviderMessageBridge", controller)
        self.assertIn("try await providerBridge.send(data, timeout: timeout)", controller)
        self.assertIn("actor ProviderMessageBridge", controller)
        self.assertIn("core-rpc", controller)

    def test_extension_serves_requests_and_records_rpc(self):
        server = self.source("ios/NECore/PacketTunnelCommandServer.swift")
        provider = self.source("ios/NECore/PacketTunnelProvider.swift")
        self.assertIn("rpc_received", server)
        self.assertIn("rpc_reply", server)
        self.assertIn("NECoreBridge.invokeMethod", provider)
        self.assertIn("commandServer.start()", provider)
        self.assertIn("commandServer.stop()", provider)

    def test_command_notification_names_match_across_processes(self):
        controller = self.source("ios/Runner/Tunnel/TunnelController.swift")
        packet_store = self.source("ios/NECore/PacketTunnelSharedStateStore.swift")
        # App derives "<bundle>.NECore.command"; NE derives
        # "<extensionBundle>.command" where extensionBundle == "<bundle>.NECore".
        self.assertIn('"\\(networkExtensionIdentifier).command"', controller)
        self.assertIn('"\\(extensionBundleIdentifier).command"', packet_store)

    def test_bridge_uses_atomic_request_and_response_files(self):
        controller = self.source("ios/Runner/Tunnel/TunnelController.swift")
        server = self.source("ios/NECore/PacketTunnelCommandServer.swift")
        # Writers stage to a temp file then move it into place so the reader
        # never observes a partially written request/response.
        self.assertIn("moveItem(at: temporary, to: destination)", controller)
        self.assertIn("moveItem(at: temporary, to: destination)", server)
        # The server consumes each request before answering it.
        self.assertIn("try? FileManager.default.removeItem(at: fileURL)", server)


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
