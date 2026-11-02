import 'dart:io';

/// TEMP device diagnostic for the iOS white-screen investigation (2026-11).
///
/// Appends step markers into `<tmp>/startup_trace.txt` inside the app data
/// container. Pull with:
/// `xcrun devicectl device copy from --domain-type appDataContainer`.
/// Remove once the device run is verified.
void diagTrace(String message) {
  try {
    final file = File('${Directory.systemTemp.path}/startup_trace.txt');
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $message\n',
      mode: FileMode.append,
    );
  } on Object {
    // Best-effort trace; never break startup over logging.
  }
}
