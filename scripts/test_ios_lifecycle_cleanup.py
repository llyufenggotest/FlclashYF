"""Source integration gates; Swift behavioral harness is a separate gate.

Run: python scripts/test_ios_lifecycle_cleanup.py
Run behavior (macOS Swift): python scripts/test_ios_lifecycle_behavior.py
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
NECORE = ROOT / "ios" / "NECore"

class IOSLifecycleCleanupTests(unittest.TestCase):
    def read(self, name):
        return (NECORE / name).read_text(encoding="utf-8")

    def test_start_failures_share_idempotent_resource_cleanup(self):
        provider = self.read("PacketTunnelProvider.swift")
        self.assertIn("guard self.activeCleanup === cleanup else", provider)
        self.assertNotIn("self.commandServerStarted = true\n          self.activeCleanup = nil", provider)
        self.assertNotIn("cleanup.cleanup()\n          self.activeCleanup = nil", provider)
        for resource in ("stopMemoryPressureDiagnostics", "eventQueue.stop()",
                         "resourceHeartbeat.stop()", "commandServer.stop()"):
            self.assertIn(resource, provider)

    def test_provider_callbacks_are_serialized(self):
        provider = self.read("PacketTunnelProvider.swift")
        self.assertIn("self.coreSetupOwner = nil", provider)
        self.assertIn("activeCleanup == nil, coreSetupOwner == nil", provider)
        self.assertIn("self.lifecycleGeneration == generation", provider)
        self.assertEqual(provider.count("startupCompletion?(PacketTunnelProviderError.couldNotStartCoreTun)"), 1)
        self.assertGreaterEqual(provider.count("DispatchQueue.main.async"), 6)
        self.assertGreaterEqual(provider.count("guard self.activeCleanup === cleanup else"), 3)

    def test_event_queue_is_serialized_and_generation_owned(self):
        source = self.read("NECoreEventQueue.swift")
        self.assertIn("private let queue = DispatchQueue", source)
        self.assertIn("self.generation == generation", source)
        self.assertIn("guard self.running else", source)

    def test_no_server_deadline_shorter_than_configuration_client(self):
        source = self.read("PacketTunnelCommandServer.swift")
        client = (ROOT / "ios/Runner/Tunnel/TunnelController.swift").read_text()
        self.assertIn("configurationTimeout: TimeInterval = 120", client)
        self.assertNotIn("inFlightTimeout", source)
        self.assertNotIn("timedOutResponse", source)
        self.assertIn("self.inFlight[id] == token", source)
        self.assertIn("self.running", source)
        self.assertIn("self.inFlight.removeAll()", source)

    def test_cleanup_has_real_synchronized_target_membership(self):
        project = (ROOT / "ios/Runner.xcodeproj/project.pbxproj").read_text()
        group = re.search(r'059852A72FF20A1200620D82 /\* NECore \*/ = \{(.*?)\n\t\t\};', project, re.S).group(1)
        target = re.search(r'059852A32FF20A1200620D82 /\* NECore \*/ = \{(.*?)\n\t\t\};', project, re.S).group(1)
        exceptions = re.search(r'059852AF2FF20A1200620D82 /\*.*?\*/ = \{(.*?)\n\t\t\};', project, re.S).group(1)
        self.assertIn("PBXFileSystemSynchronizedRootGroup", group)
        self.assertIn("path = NECore;", group)
        self.assertIn("fileSystemSynchronizedGroups", target)
        self.assertIn("059852A72FF20A1200620D82", target)
        self.assertNotIn("PacketTunnelLifecycleCleanup.swift", exceptions)
        self.assertTrue((NECORE / "PacketTunnelLifecycleCleanup.swift").is_file())

if __name__ == "__main__":
    unittest.main(verbosity=2)
