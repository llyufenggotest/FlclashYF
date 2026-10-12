import 'dart:convert';

import 'package:yaml_writer/yaml_writer.dart';

class Yaml {
  static Yaml? _instance;

  Yaml._internal();

  factory Yaml() {
    _instance ??= Yaml._internal();
    return _instance!;
  }

  String encode(Object? value) {
    // The upstream writer's block scalars lose leading whitespace and can
    // produce invalid indentation. Quote device context explicitly with JSON
    // escapes (also valid YAML), without changing any literal map keys.
    var prefix = 'FLCLASH_DEVICE_SCALAR_';
    final source = YamlWriter().convert(value);
    while (source.contains(prefix)) {
      prefix = '${prefix}_';
    }
    final scalars = <String, String>{};
    Object? protect(Object? node) {
      if (node is List) return node.map(protect).toList();
      if (node is Map) {
        return node.map((key, item) {
          if ((key == 'device_id' || key == 'device_name') && item is String) {
            final marker = '$prefix${scalars.length}_END';
            scalars[marker] = jsonEncode(item);
            return MapEntry(key, marker);
          }
          return MapEntry(key, protect(item));
        });
      }
      return node;
    }

    final protected = protect(value);
    if (scalars.isEmpty) return source;
    var result = YamlWriter().convert(protected);
    for (final entry in scalars.entries) {
      result = result
          .replaceAll('"${entry.key}"', entry.value)
          .replaceAll(entry.key, entry.value);
    }
    return result;
  }
}

final yaml = Yaml();
