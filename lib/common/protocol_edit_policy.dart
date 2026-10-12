import 'package:yaml/yaml.dart';

enum ProtocolEditPolicy { standard, readOnly }

ProtocolEditPolicy protocolEditPolicyForYaml(String source) {
  try {
    final document = loadYaml(source);
    if (document is! YamlMap) return ProtocolEditPolicy.standard;
    final proxies = document['proxies'];
    if (proxies is! YamlList) return ProtocolEditPolicy.standard;
    for (final proxy in proxies) {
      if (proxy is! YamlMap) continue;
      final type = proxy['type']?.toString().toLowerCase();
      final transport = proxy['network']?.toString().toLowerCase();
      final password = proxy['password']?.toString().toLowerCase() ?? '';
      // These private proxy types now have a lossless editable schema.
      // Keep the existing guard for standard XHTTP transport/wire markers.
      if (type == 'blackstone' || type == 'xhttp') continue;
      if (transport == 'xhttp' || password.contains('blackstone')) {
        return ProtocolEditPolicy.readOnly;
      }
    }
    return ProtocolEditPolicy.standard;
  } on Object {
    return ProtocolEditPolicy.standard;
  }
}
