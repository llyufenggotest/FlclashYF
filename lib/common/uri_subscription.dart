import 'package:fl_clash/common/yaml.dart';
import 'package:yaml/yaml.dart';

bool isYamlProfile(String content) {
  try {
    final document = loadYaml(content);
    if (document is! YamlMap) return false;
    return document.containsKey('proxies') ||
        document.containsKey('proxy-providers') ||
        document.containsKey('rules') ||
        document.containsKey('proxy-groups');
  } on YamlException {
    return false;
  }
}

bool isFullYamlProfile(String content) {
  try {
    final document = loadYaml(content);
    if (document is! YamlMap) return false;
    return document.containsKey('proxy-groups') ||
        document.containsKey('rules') ||
        document.containsKey('proxy-providers') ||
        document.containsKey('rule-providers');
  } on YamlException {
    return false;
  }
}

bool _hasProxyProviders(String content) {
  try {
    final document = loadYaml(content);
    final providers = document is YamlMap ? document['proxy-providers'] : null;
    return providers != null && (providers is! YamlMap || providers.isNotEmpty);
  } on YamlException {
    return false;
  }
}

String applyGlobalProfileTemplate({
  required String content,
  required String template,
  required bool enabled,
}) {
  if (!enabled && isFullYamlProfile(content)) return content;
  final proxies = extractYamlProxies(content);
  if (proxies == null || _hasProxyProviders(content)) {
    if (isFullYamlProfile(content) && enabled) {
      throw const FormatException(
        'Cannot safely extract nodes from a complete YAML profile containing proxy-providers or unsupported proxies.',
      );
    }
    return content;
  }
  final sourceDocument = loadYaml(content);
  if (sourceDocument is! YamlMap) {
    throw const FormatException('Invalid YAML profile');
  }
  final result = injectSubscriptionProxies(
    template: template,
    proxies: proxies,
  );
  final config = _plainMap(loadYaml(result) as YamlMap);
  final source = _plainMap(sourceDocument);
  if (enabled) mergeSubscriptionDns(config, source);
  if (source.containsKey('overwrite')) {
    config['overwrite'] = source['overwrite'];
  }
  return yaml.encode(config);
}

/// Keep template-wide DNS settings; overlay only subscription resolution data.
/// Literal resolver/hosts scalars are never split, normalized or logged here.
void mergeSubscriptionDns(
  Map<String, dynamic> config,
  Map<String, dynamic> source,
) {
  if (source['hosts'] is Map) {
    config['hosts'] = {
      if (config['hosts'] is Map) ...config['hosts'] as Map,
      ...source['hosts'] as Map,
    };
  }
  final sourceDns = source['dns'] is Map
      ? source['dns'] as Map
      : const <String, dynamic>{};
  if (sourceDns.isEmpty && source['hosts'] is! Map) return;
  final dns = <String, dynamic>{
    if (config['dns'] is Map)
      ...Map<String, dynamic>.from(config['dns'] as Map),
  };
  config['dns'] = dns;
  for (final key in ['nameserver-policy', 'proxy-server-nameserver-policy']) {
    if (sourceDns[key] is Map) {
      dns[key] = {
        ...sourceDns[key] as Map,
        if (dns[key] is Map)
          for (final entry in (dns[key] as Map).entries)
            if (!(sourceDns[key] as Map).containsKey(entry.key))
              entry.key: entry.value,
      };
    }
  }
  for (final key in [
    'nameserver',
    'default-nameserver',
    'proxy-server-nameserver',
    'direct-nameserver',
    'fallback',
    'fake-ip-filter',
  ]) {
    if (!sourceDns.containsKey(key)) continue;
    final original = sourceDns[key];
    if (original is List) {
      // Resolver lists are concurrent pools, not ordered failover. A declared
      // source pool must not race the template's public defaults.
      if (key == 'fake-ip-filter') {
        final defaults = dns[key];
        dns[key] = [
          ...original,
          if (defaults is List)
            ...defaults.where((item) => !original.contains(item)),
        ];
      } else if (original.isNotEmpty) {
        dns[key] = List<dynamic>.from(original);
      }
    } else {
      dns[key] = original;
    }
  }
  for (final key in [
    'enable',
    'use-hosts',
    'use-system-hosts',
    'respect-rules',
    'direct-nameserver-follow-policy',
  ]) {
    if (sourceDns.containsKey(key)) dns[key] = sourceDns[key];
  }
  final sourceFilter = sourceDns['fallback-filter'];
  if (sourceFilter is Map) {
    final merged = <String, dynamic>{
      if (dns['fallback-filter'] is Map)
        ...Map<String, dynamic>.from(dns['fallback-filter'] as Map),
    };
    // Filter flags and lists together define when fallback may be consulted.
    // Source entries own the exact field; defaults fill undeclared fields.
    merged.addAll(Map<String, dynamic>.from(sourceFilter));
    if (merged.isNotEmpty) dns['fallback-filter'] = merged;
  }
  // A private hosts/policy domain must not accidentally become a fake IP
  // merely because the selected global template uses fake-ip mode.
  // Plain domain exclusions have blacklist semantics only. A whitelist/rule
  // template with imported private resolution data needs an explicit decision
  // rather than silently reversing its semantics.
  final filterMode = dns['fake-ip-filter-mode'];
  final activeFakeIp =
      dns['enable'] != false && dns['enhanced-mode'] == 'fake-ip';
  if (activeFakeIp &&
      filterMode != null &&
      filterMode != 'blacklist' &&
      (source['hosts'] is Map ||
          sourceDns['fake-ip-filter'] != null ||
          sourceDns['nameserver-policy'] != null ||
          sourceDns['proxy-server-nameserver-policy'] != null)) {
    throw const FormatException(
      'Private DNS/hosts need a blacklist fake-ip filter or an explicit template adaptation.',
    );
  }
  if (activeFakeIp && (filterMode == null || filterMode == 'blacklist')) {
    final exclusions = <dynamic>[...dns['fake-ip-filter'] as List? ?? const []];
    final domains = <Object?>[
      if (config['hosts'] is Map) ...(config['hosts'] as Map).keys,
      if (dns['nameserver-policy'] is Map)
        ...(dns['nameserver-policy'] as Map).keys,
      if (dns['proxy-server-nameserver-policy'] is Map)
        ...(dns['proxy-server-nameserver-policy'] as Map).keys,
    ];
    for (final domain in domains.whereType<String>()) {
      if (!domain.toLowerCase().startsWith('geosite:') &&
          !domain.toLowerCase().startsWith('rule-set:') &&
          !exclusions.contains(domain)) {
        exclusions.add(domain);
      }
    }
    if (exclusions.isNotEmpty) dns['fake-ip-filter'] = exclusions;
  }
  _closeDnsDependencies(config, source, dns);
}

void _closeDnsDependencies(
  Map<String, dynamic> config,
  Map<String, dynamic> source,
  Map<String, dynamic> dns,
) {
  const error = FormatException(
    'DNS dependency cannot be preserved safely. Check resolver proxy references, group membership and DNS rule-set providers before applying the global template.',
  );
  final providers = <String>{};
  void selector(Object? value) {
    if (value is String && value.toLowerCase().startsWith('rule-set:')) {
      providers.addAll(value.substring(9).split(','));
    }
  }

  for (final key in ['nameserver-policy', 'proxy-server-nameserver-policy']) {
    if (dns[key] is Map) (dns[key] as Map).keys.forEach(selector);
  }
  for (final value in dns['fake-ip-filter'] as List? ?? const []) {
    selector(value);
  }
  final filter = dns['fallback-filter'];
  if (filter is Map) {
    for (final key in ['domain', 'ipcidr']) {
      for (final value in filter[key] as List? ?? const []) {
        selector(value);
      }
    }
  }
  final resultProviders = <String, dynamic>{
    if (config['rule-providers'] is Map)
      ...Map<String, dynamic>.from(config['rule-providers'] as Map),
  };
  final sourceProviders = source['rule-providers'] as Map? ?? const {};
  for (final name in providers) {
    if (sourceProviders.containsKey(name)) {
      if (resultProviders.containsKey(name) &&
          yaml.encode(resultProviders[name]) !=
              yaml.encode(sourceProviders[name])) {
        throw error;
      }
      resultProviders[name] = sourceProviders[name];
    } else if (!resultProviders.containsKey(name)) {
      throw error;
    }
  }
  if (resultProviders.isNotEmpty) config['rule-providers'] = resultProviders;

  final names = <String>{
    'DIRECT',
    'REJECT',
    'REJECT-DROP',
    'PASS',
    'COMPATIBLE',
  };
  final proxies = config['proxies'] as List? ?? const [];
  names.addAll(proxies.whereType<Map>().map((p) => p['name'].toString()));
  final groups = List<dynamic>.from(
    config['proxy-groups'] as List? ?? const [],
  );
  names.addAll(groups.whereType<Map>().map((g) => g['name'].toString()));
  final sourceGroups = {
    for (final group
        in (source['proxy-groups'] as List? ?? const []).whereType<Map>())
      group['name'].toString(): group,
  };
  final visiting = <String>{};
  void reference(String name) {
    if (names.contains(name)) {
      final sourceGroup = sourceGroups[name];
      if (sourceGroup != null) {
        final retained = groups.whereType<Map>().where(
          (g) => g['name'] == name,
        );
        if (retained.isEmpty ||
            yaml.encode(retained.first) != yaml.encode(sourceGroup)) {
          throw error;
        }
      }
      final sourceProxy = (source['proxies'] as List? ?? const [])
          .whereType<Map>()
          .where((p) => p['name'] == name);
      if (sourceProxy.isNotEmpty &&
          !proxies.whereType<Map>().any((p) => p['name'] == name)) {
        throw error;
      }
      return;
    }
    final group = sourceGroups[name];
    if (group == null ||
        !visiting.add(name) ||
        (group['use'] is List && (group['use'] as List).isNotEmpty) ||
        group['proxies'] is! List) {
      throw error;
    }
    for (final member in group['proxies'] as List) {
      if (member is! String) throw error;
      reference(member);
    }
    visiting.remove(name);
    groups.add(Map<String, dynamic>.from(group));
    names.add(name);
  }

  void resolver(Object? value) {
    if (value is Map) {
      value.values.forEach(resolver);
    } else if (value is List) {
      value.forEach(resolver);
    } else if (value is String) {
      final uri = Uri.tryParse(value.contains('://') ? value : 'udp://$value');
      if (uri == null) throw error;
      if (['ts', 'tailscale', 'et', 'easytier'].contains(uri.scheme)) {
        reference(uri.host);
      }
      // Core uses the last fragment token without '=' as its proxy selector.
      String? proxy;
      for (final token in Uri.decodeComponent(uri.fragment).split('&')) {
        if (!token.contains('=')) proxy = token;
      }
      if (proxy != null && proxy.isNotEmpty && proxy != 'RULES') {
        reference(proxy);
      }
    }
  }

  for (final key in [
    'nameserver',
    'default-nameserver',
    'proxy-server-nameserver',
    'direct-nameserver',
    'fallback',
    'nameserver-policy',
    'proxy-server-nameserver-policy',
  ]) {
    resolver(dns[key]);
  }
  final privateDomains = <String>{};
  final sourceDns = source['dns'] is Map
      ? source['dns'] as Map
      : const <String, dynamic>{};
  for (final map in [
    source['hosts'],
    sourceDns['nameserver-policy'],
    sourceDns['proxy-server-nameserver-policy'],
  ]) {
    if (map is Map) {
      for (final key in map.keys.whereType<String>()) {
        if (!key.contains(':') && !key.contains(',')) {
          final declaredHosts = sourceDns['use-hosts'];
          final effectiveHosts = declaredHosts ?? dns['use-hosts'] ?? true;
          if (map != source['hosts'] || effectiveHosts == true) {
            privateDomains.add(
              key.startsWith('+.') || key.startsWith('*.')
                  ? key.substring(2)
                  : key,
            );
          }
        }
      }
    }
  }
  final associatedRules = <String>[];
  for (final rule in source['rules'] as List? ?? const []) {
    if (rule is! String) continue;
    final fields = rule.split(',');
    if (fields.length < 3 || !['DOMAIN', 'DOMAIN-SUFFIX'].contains(fields[0])) {
      continue;
    }
    if (!privateDomains.contains(fields[1])) continue;
    reference(fields[2]);
    associatedRules.add(rule);
  }
  if (associatedRules.isNotEmpty) {
    final defaults = config['rules'] as List? ?? const [];
    config['rules'] = [
      ...associatedRules,
      ...defaults.where((rule) => !associatedRules.contains(rule)),
    ];
  }
  config['proxy-groups'] = groups;
}

/// Validate after user scripts/overwrites so deleted DNS dependencies fail
/// before Core consumes a partially broken profile. Never include raw values.
void validateProfileDnsDependencies(Map<String, dynamic> config) {
  if (config['dns'] is! Map) return;
  final dns = Map<String, dynamic>.from(config['dns'] as Map);
  final groups = {
    for (final group
        in (config['proxy-groups'] as List? ?? const []).whereType<Map>())
      group['name'].toString(): group,
  };
  final names = {
    'DIRECT',
    'REJECT',
    'REJECT-DROP',
    'PASS',
    'COMPATIBLE',
    for (final proxy
        in (config['proxies'] as List? ?? const []).whereType<Map>())
      proxy['name'].toString(),
  };
  const error = FormatException(
    'DNS dependency is missing after profile overwrite. Restore the referenced proxy/group or DNS rule-set provider.',
  );
  final visiting = <String>{};
  void check(String name) {
    if (names.contains(name)) return;
    final group = groups[name];
    if (group == null || !visiting.add(name)) throw error;
    if (group['use'] is List && (group['use'] as List).isNotEmpty) {
      final providers = config['proxy-providers'] as Map? ?? const {};
      if (!(group['use'] as List).every(providers.containsKey)) throw error;
    }
    for (final member in group['proxies'] as List? ?? const []) {
      if (member is! String) throw error;
      check(member);
    }
    visiting.remove(name);
  }

  void resolver(Object? value) {
    if (value is Map) {
      value.values.forEach(resolver);
    } else if (value is List) {
      value.forEach(resolver);
    } else if (value is String) {
      final uri = Uri.tryParse(value.contains('://') ? value : 'udp://$value');
      if (uri == null) throw error;
      if (['ts', 'tailscale', 'et', 'easytier'].contains(uri.scheme)) {
        check(uri.host);
      }
      String? proxy;
      for (final token in Uri.decodeComponent(uri.fragment).split('&')) {
        if (!token.contains('=')) proxy = token;
      }
      if (proxy != null && proxy.isNotEmpty && proxy != 'RULES') check(proxy);
    }
  }

  for (final key in [
    'nameserver',
    'default-nameserver',
    'proxy-server-nameserver',
    'direct-nameserver',
    'fallback',
    'nameserver-policy',
    'proxy-server-nameserver-policy',
  ]) {
    resolver(dns[key]);
  }
  final copy = Map<String, dynamic>.from(config);
  _closeDnsDependencies(copy, config, dns);
}

List<Map<String, dynamic>>? extractYamlProxies(String content) {
  try {
    final document = loadYaml(content);
    if (document is! YamlMap || document['proxies'] is! YamlList) {
      return null;
    }
    final proxies = document['proxies'] as YamlList;
    if (proxies.any((proxy) => proxy is! YamlMap)) {
      throw const FormatException('Invalid proxy entry in YAML');
    }
    return proxies.cast<YamlMap>().map(_plainMap).toList();
  } on YamlException {
    return null;
  }
}

String injectSubscriptionProxies({
  required String template,
  required List<Map<String, dynamic>> proxies,
}) {
  if (proxies.isEmpty) {
    throw const FormatException('No supported proxy links found');
  }
  final document = loadYaml(template);
  if (document is! YamlMap) {
    throw const FormatException('Invalid built-in profile template');
  }
  final config = _plainMap(document);
  final groups = config['proxy-groups'];
  final reservedNames = groups is List
      ? groups
            .whereType<Map>()
            .map((group) => group['name']?.toString().trim() ?? '')
            .where((name) => name.isNotEmpty)
            .toSet()
      : <String>{};
  final names = <String>[];
  final usedNames = <String>{...reservedNames};
  final normalized = <Map<String, dynamic>>[];
  for (final proxy in proxies) {
    final rawName = proxy['name']?.toString().trim() ?? '';
    if (rawName.isEmpty) {
      throw const FormatException('Proxy name is empty');
    }
    var name = rawName;
    var index = 2;
    while (!usedNames.add(name)) {
      name = '$rawName ($index)';
      index++;
    }
    names.add(name);
    normalized.add({...proxy, 'name': name});
  }
  config['proxies'] = normalized;
  if (groups is List) {
    for (final group in groups.whereType<Map>()) {
      switch (group['name']) {
        case '🚀 节点选择':
          final refs = List<Object?>.from(
            group['proxies'] as List? ?? const [],
          );
          final insertion = refs.indexOf('⚡ 自动优选');
          refs.insertAll(insertion < 0 ? refs.length : insertion, names);
          group['proxies'] = refs;
        case '⚡ 自动优选':
          group['proxies'] = names;
      }
    }
  }
  return yaml.encode(config);
}

Map<String, dynamic> _plainMap(YamlMap source) {
  Object? plain(Object? value) {
    if (value is YamlMap) {
      final result = <String, dynamic>{};
      final merges = value['<<'];
      final maps = merges is YamlList ? merges : [?merges];
      // YAML merge sequences: earlier maps win; explicit keys always win.
      for (final merged in maps) {
        if (merged is! YamlMap) {
          throw const FormatException('Invalid YAML merge mapping');
        }
        final map = plain(merged) as Map<String, dynamic>;
        for (final entry in map.entries) {
          result.putIfAbsent(entry.key, () => entry.value);
        }
      }
      for (final entry in value.entries) {
        if (entry.key != '<<') {
          result[entry.key.toString()] = plain(entry.value);
        }
      }
      return result;
    }
    if (value is YamlList) {
      return value.map(plain).toList();
    }
    return value;
  }

  return Map<String, dynamic>.from(plain(source)! as Map);
}
