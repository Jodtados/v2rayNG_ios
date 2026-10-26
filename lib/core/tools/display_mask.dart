/// Hides host-like display strings for the personal build.
///
/// Server tags usually look like `sub.example.com:443`. The mask keeps the
/// head, the tail and any trailing numeric port so rows stay recognizable
/// while the full address never appears on screen.
String maskDisplayName(String input) {
  if (input.isEmpty) return input;
  var host = input;
  var port = '';
  final portIndex = input.lastIndexOf(':');
  if (portIndex > 0 && portIndex + 1 < input.length) {
    final suffix = input.substring(portIndex + 1);
    final numeric = suffix.codeUnits.every(
      (code) => code >= 0x30 && code <= 0x39,
    );
    if (numeric) {
      host = input.substring(0, portIndex);
      port = input.substring(portIndex);
    }
  }
  return _maskHost(host) + port;
}

String _maskHost(String host) {
  if (host.length < 8) return host;
  return '${host.substring(0, 2)}***${host.substring(host.length - 5)}';
}
