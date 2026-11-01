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
  final matches = <InternetAddress>{};
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
      matches.add(endpoint.address);
    }
  }

  for (final key in _resolverFields) {
    visit(dns[key]);
  }
  if (matches.isEmpty) return null;
  if (!wildcard) return declared;
  // One listener cannot safely narrow to several distinct local interfaces.
  if (matches.length != 1) return null;
  final address = matches.single;
  final host = address.address;
  return address.type == InternetAddressType.IPv6
      ? '[$host]:${bind.port}'
      : '$host:${bind.port}';
}

/// Whether replacing a listener would break any of its surviving references.
/// Examine endpoints individually so a wildcard with several references cannot
/// hide a conflict merely because it cannot narrow to a single address.
bool dnsListenerDependenciesConflict(Map dns, String replacement) {
  bool conflicts(Object? value) {
    if (value is Map) return value.values.any(conflicts);
    if (value is List) return value.any(conflicts);
    if (value is! String) return false;
    final endpointDns = {
      'listen': dns['listen'],
      'nameserver': [value],
    };
    return referencedLoopbackDnsListener(endpointDns) != null &&
        referencedLoopbackDnsListener(endpointDns, listener: replacement) ==
            null;
  }

  return _resolverFields.any((key) => conflicts(dns[key]));
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
