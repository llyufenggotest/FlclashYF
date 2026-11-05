import Foundation
import Darwin
let mode = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2])
func check(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { print("FAIL CONFIG ACCESS \(mode): \(message)"); exit(1) } }
fixtureContainer = root
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let shared = Data(#"{"vpnOptions":{"port":7890,"ipv6":false,"captureDns":true,"systemProxy":false,"stack":"mixed"},"setupParams":{"synthetic":true}}"#.utf8)
let defaults = UserDefaults(suiteName:"group.test.attempt")!
defaults.removePersistentDomain(forName:"group.test.attempt")
try Data("synthetic: true".utf8).write(to:root.appendingPathComponent("config.yaml"))
check(ConfigAccess.written(path:root.appendingPathComponent("config.yaml").path),"actual app write")
SwitchDiagnostics.setTestDirectory(root,bundleIdentifier:"test.attempt")
SwitchDiagnostics.setIPadTestStorage(local:root,sharedUnavailable:true)
Task { @MainActor in
 let state = SharedStateStore();check(state.saveSharedState(shared),"shared options")
 let manager = NETunnelProviderManager()
 let proto = NETunnelProviderProtocol();proto.providerBundleIdentifier="test.attempt.NECore"
 manager.protocolConfiguration=proto;NETunnelProviderManager.managers=[manager]
 let store=TunnelManagerStore(sharedStateStore:state,networkExtensionIdentifier:"test.attempt.NECore",localizedDescription:"test")
 _ = try! await store.loadManager(createIfNeeded:false)
 let sent=try! store.prepareStartupEnvelope(for:manager)
 check(proto.providerConfiguration?[ConfigAccess.key] is Data,"official persisted challenge")
 if mode == "owner-cold" {
  let cold=try! StartupEnvelope.resolveStartup(manual:nil,persisted:proto.providerConfiguration)
  check(cold?.0.revision == sent.revision,"cold and OnDemand revision")
  check(ConfigAccess.challenge(root:root,expected:proto.providerConfiguration?[ConfigAccess.key],revision:cold?.0.revision)==1,"cold namespace")
  let before=try! Data(contentsOf:root.appendingPathComponent(ConfigAccess.marker))
  let foreign=NETunnelProviderManager();let foreignProto=NETunnelProviderProtocol();foreignProto.providerBundleIdentifier="foreign.NECore";foreign.protocolConfiguration=foreignProto
  do { _ = try store.prepareStartupEnvelope(for:foreign);check(false,"bad owner admitted") } catch {}
  let after=try! Data(contentsOf:root.appendingPathComponent(ConfigAccess.marker))
  check(before==after && foreignProto.providerConfiguration==nil,"bad owner mutated marker/configuration")
  print("PASS CONFIG ACCESS owner-cold");exit(0)
 }
 let provider=PacketTunnelProvider();provider.protocolConfiguration=proto
 provider.startTunnel(options:try! store.requireStartupEnvelope(sent,manager:manager)) { error in
  check(error != nil,"failure required")
  let archived=try! NSKeyedArchiver.archivedData(withRootObject:error! as NSError,requiringSecureCoding:true)
  let bridged=try! NSKeyedUnarchiver.unarchivedObject(ofClass:NSError.self,from:archived)!
  let fields=SwitchDiagnostics.iPadErrorFields(bridged)
  check(fields["core_stage"]=="4" && fields["core_errno"]=="2","original closed error lost")
  check(fields["pre_probe"]=="1" && fields["challenge_status"]=="1","actual preprobe/challenge lost")
  check(fields["setup_source"]=="1" && fields["setup_status"]=="2","setup availability lost")
  SwitchDiagnostics.exportIPadDiagnostics { text in
   check(text.contains("config_access") && text.contains("core_stage"),"Runner local export absent")
   check(!text.contains("synthetic: true") && !text.contains(root.path) && !text.contains("@CA1"),"privacy")
   print("PASS CONFIG ACCESS failure-export");exit(0)
  }
 }
 provider.heldSettings?(nil)
 DispatchQueue.main.async {
  check(NECoreBridge.heldSetup != nil,"original callback not reached")
  NECoreBridge.heldSetup?(Data("@CA1:4:2:13".utf8))
 }
}
RunLoop.main.run()
