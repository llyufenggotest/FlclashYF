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
    // produce invalid indentation. Quote device context and private DNS/hosts
    // scalars with JSON escapes (also valid YAML), without changing map keys.
    var prefix = 'FLCLASH_DEVICE_SCALAR_';
    final source = YamlWriter().convert(value);
    while (source.contains(prefix)) {
      prefix = '${prefix}_';
    }
    final scalars = <String, String>{};
    Object? protect(Object? node, {bool literal = false}) {
      if (literal && node is String) {
        final marker = '$prefix${scalars.length}_END';
        scalars[marker] = jsonEncode(node);
        return marker;
      }
      if (node is List) {
        return node.map((item) => protect(item, literal: literal)).toList();
      }
      if (node is Map) {
        return node.map((key, item) {
          return MapEntry(
            key,
            protect(
              item,
              literal:
                  literal ||
                  key == 'hosts' ||
                  key == 'dns' ||
                  key == 'device_id' ||
                  key == 'device_name',
            ),
          );
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
