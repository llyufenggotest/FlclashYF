/// Presentation only: never rewrite stored proxy types or VLESS transport.
String proxyTypeLabel(String type) {
  return switch (type.toLowerCase()) {
    'blackstone' || 'xhttp' => 'Blackstone',
    _ => type,
  };
}
