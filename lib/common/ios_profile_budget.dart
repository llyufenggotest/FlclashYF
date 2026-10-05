library;

// Keep mixed-port: system proxy and app-local requests still consume it.
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

const iosRemovedDnsKeys = <String>{'listen'};
const iosPreConnectCap = 2;
const iosMinHealthCheckInterval = 300;
const iosMinRuleProviderInterval = 604800;
const _latencyTestGroupTypes = <String>{'url-test', 'fallback', 'load-balance'};

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

  config['find-process-mode'] = 'off';
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
