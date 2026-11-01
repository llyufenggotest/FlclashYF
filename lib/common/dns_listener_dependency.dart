import 'dart:io';

/// Only actual UDP/TCP DNS endpoints can depend on dns.listen. Never resolve
/// hostnames or inspect policy keys, URL paths, queries or proxy fragments.
const _resolverFields = [
  'nameserver',
  'default-nameserver',
  'proxy-server-nameserver',
  'direct-nameserver',
  'fallback',
  'nameserver-policy',
  'proxy-server-nameserver-policy',
];

/// Returns a local-only listener iff a declared listener serves a referenced
/// loopback DNS endpoint. Wildcards are narrowed, never reopened on the LAN.
/// No listener is invented when the source omitted it.
String? referencedLoopbackDnsListener(Map dns, {Object? listener}) {
  final declared = listener ?? dns['listen'];
  if (declared is! String) return null;
  final bind = _endpoint(declared, listener: true);
  if (bind == null) return null;
  final wildcard = bind.address.rawAddress.every((byte) => byte == 0);
  if (!wildcard && !bind.address.isLoopback) return null;
  final matches = <String>{};
  void visit(Object? value) {
    if (value is Map) {
      value.values.forEach(visit);
    } else if (value is List) {
      value.forEach(visit);
    } else if (value is String) {
      final endpoint = _endpoint(value);
      if (endpoint == null ||
          !endpoint.address.isLoopback ||
          endpoint.port != bind.port ||
          endpoint.address.type != bind.address.type)
        return;
      if (!wildcard && endpoint.address != bind.address) return;
      final host = endpoint.address.address;
      matches.add(
        endpoint.address.type == InternetAddressType.IPv6
            ? '[$host]:${bind.port}'
            : '$host:${bind.port}',
      );
    }
  }

  for (final key in _resolverFields) {
    visit(dns[key]);
  }
  if (matches.isEmpty) return null;
  if (!wildcard) return declared;
  // One listener cannot safely narrow to several distinct local interfaces.
  return matches.length == 1 ? matches.single : null;
}

({InternetAddress address, int port})? _endpoint(
  String value, {
  bool listener = false,
}) {
  try {
    if (value.trim() != value || value.isEmpty) return null;
    final explicitScheme = value.contains('://');
    if (listener && explicitScheme) return null;
    final uri = Uri.tryParse(explicitScheme ? value : 'udp://$value');
    if (uri == null ||
        !['udp', 'tcp'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        (listener && (uri.hasQuery || uri.hasFragment)))
      return null;
    // UDP/TCP query/fragment options are not addresses. Keep the original
    // scalar untouched; only the parsed authority participates in matching.
    final address = InternetAddress.tryParse(uri.host);
    final port = uri.hasPort ? uri.port : (listener ? 0 : 53);
    if (address == null || port < 1 || port > 65535) return null;
    return (address: address, port: port);
  } on FormatException {
    return null;
  }
}
