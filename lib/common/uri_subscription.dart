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
  final source = sourceDocument;
  if (!source.containsKey('overwrite')) return result;
  final config = _plainMap(loadYaml(result) as YamlMap);
  config['overwrite'] = _plainMap(source)['overwrite'];
  return yaml.encode(config);
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
      return {
        for (final entry in value.entries)
          entry.key.toString(): plain(entry.value),
      };
    }
    if (value is YamlList) {
      return value.map(plain).toList();
    }
    return value;
  }

  return Map<String, dynamic>.from(plain(source)! as Map);
}
