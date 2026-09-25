/// iOS-only profile hardening applied just before the YAML is handed to the
/// core.
///
/// Two independent problems are solved here, both proven by device traces:
///
/// 1. Desktop-oriented global keys are meaningless or harmful inside a Network
///    Extension. Inbound listeners (`port`, `socks-port`, `redir-port`,
///    `tproxy-port`), `allow-lan`/`bind-address`, the `external-controller`
///    HTTP API with its plaintext `secret`, and the profile's own `dns.listen`
///    all open sockets nothing on iOS consumes. The DNS listener in particular
///    caused `bind: address already in use` between the app core and the
///    extension core.
///
/// 2. The extension lives inside a jetsam budget near 50 MB and was observed at
///    47 MB before being terminated. The dominant costs in the shipped profiles
///    are Oppa `pre-connect` fan-out (180 nodes x 8 connections), 60-second
///    `url-test` sweeps over 110-180 nodes, and up to 20 remote rule providers
///    refreshing daily.
///
/// Wire-level protocol fields are never touched: only scheduling, listener, and
/// fan-out knobs change, so `#VT`, `#x365`, `#fastup`, BLACKSTONE/XHTTP, and
/// Oppa keep the exact behaviour already verified on device.
library;

/// Keys removed outright. Each opens a listener or control surface that has no
/// consumer on iOS.
///
/// `mixed-port` is deliberately NOT in this set: `NEProxySettings` points the
/// system HTTP/HTTPS proxy at `127.0.0.1:<mixed-port>` inside the tunnel, and
/// the app's own IP check dials the same port. Removing it silently disables
/// system proxy and makes checkIp fail with "Connection refused".
const iosRemovedGlobalKeys = <String>{
  'port',
  'socks-port',
  'redir-port',
  'tproxy-port',
  'allow-lan',
  'bind-address',
  'external-controller',
  'external-controller-tls',
  'external-controller-unix',
  'external-controller-pipe',
  'secret',
  'lan-allowed-ips',
  'lan-disallowed-ips',
  'authentication',
  'skip-auth-prefixes',
  'inbound-tfo',
  'inbound-mptcp',
  'tuic-server',
  'ss-config',
  'vmess-config',
  'listeners',
};

/// The tunnel process owns DNS; the profile must not bind its own port.
const iosRemovedDnsKeys = <String>{'listen'};

/// `pre-connect` keeps N idle TLS sessions per node. At 180 nodes the shipped
/// value of 8 implies ~1440 live connections, which alone exceeds the budget.
const iosPreConnectCap = 2;

/// Latency sweeps are the largest recurring allocation spike. Five minutes
/// still tracks node health without a per-minute burst across 180 nodes.
const iosMinHealthCheckInterval = 300;

/// Remote rule lists are tens of thousands of lines each. Weekly refresh keeps
/// them current without repeated parse-and-hold cycles inside the extension.
const iosMinRuleProviderInterval = 604800;

/// Group types that perform periodic latency probes.
const _latencyTestGroupTypes = <String>{'url-test', 'fallback', 'load-balance'};

/// Returns a deep-copied, iOS-appropriate variant of [rawConfig].
///
/// The input map is never mutated: callers hold the user's parsed profile and a
/// mutation would silently rewrite what the UI displays and what gets exported.
Map<String, dynamic> sanitizeProfileForIOS(Map<String, dynamic> rawConfig) {
  final config = _deepCopyMap(rawConfig);

  for (final key in iosRemovedGlobalKeys) {
    config.remove(key);
  }

  final dns = config['dns'];
  if (dns is Map) {
    for (final key in iosRemovedDnsKeys) {
      dns.remove(key);
    }
  }

  // iOS cannot inspect other processes' sockets; leaving this on produces a
  // continuous stream of "find process error: operation not permitted".
  config['find-process-mode'] = 'off';

  // Concurrent dialing doubles in-flight connections and buffers per request.
  config['tcp-concurrent'] = false;

  final keepAlive = config['keep-alive-interval'];
  if (keepAlive is! int || keepAlive < 30) {
    config['keep-alive-interval'] = 30;
  }

  _capPreConnect(config['proxies']);
  _raiseGroupIntervals(config['proxy-groups']);
  _raiseRuleProviderIntervals(config['rule-providers']);

  return config;
}

void _capPreConnect(Object? proxies) {
  if (proxies is! List) return;
  for (final proxy in proxies) {
    if (proxy is! Map) continue;
    if (!proxy.containsKey('pre-connect')) continue;
    final value = proxy['pre-connect'];
    if (value is! int) continue;
    if (value <= iosPreConnectCap) continue;
    proxy['pre-connect'] = iosPreConnectCap;
  }
}

void _raiseGroupIntervals(Object? groups) {
  if (groups is! List) return;
  for (final group in groups) {
    if (group is! Map) continue;
    final type = group['type'];
    if (type is! String) continue;
    if (!_latencyTestGroupTypes.contains(type)) continue;
    final interval = group['interval'];
    if (interval is! int) continue;
    if (interval >= iosMinHealthCheckInterval) continue;
    group['interval'] = iosMinHealthCheckInterval;
  }
}

void _raiseRuleProviderIntervals(Object? providers) {
  if (providers is! Map) return;
  for (final provider in providers.values) {
    if (provider is! Map) continue;
    if (provider['type'] != 'http') continue;
    final interval = provider['interval'];
    if (interval is! int) continue;
    if (interval >= iosMinRuleProviderInterval) continue;
    provider['interval'] = iosMinRuleProviderInterval;
  }
}

Map<String, dynamic> _deepCopyMap(Map<dynamic, dynamic> source) {
  final result = <String, dynamic>{};
  for (final entry in source.entries) {
    result[entry.key.toString()] = _deepCopyValue(entry.value);
  }
  return result;
}

Object? _deepCopyValue(Object? value) {
  if (value is Map) return _deepCopyMap(value);
  if (value is List) return value.map(_deepCopyValue).toList();
  return value;
}
