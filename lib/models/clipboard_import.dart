const clipboardImportKindLabels = {
  ClipboardImportKind.url: 'URL',
  ClipboardImportKind.yaml: 'YAML',
  ClipboardImportKind.uri: 'URI',
  ClipboardImportKind.base64: 'Base64',
  ClipboardImportKind.json: 'JSON',
};

enum ClipboardImportKind { url, yaml, uri, base64, json }

class ClipboardImportPreview {
  const ClipboardImportPreview({
    required this.kind,
    required this.source,
    required this.suggestedName,
    this.nodeCount,
  });

  final ClipboardImportKind kind;
  final String source;
  final int? nodeCount;
  final String suggestedName;
}
