import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// RFC 6238 TOTP verification with the HMAC-SHA1 algorithm.
///
/// The shared secret arrives at build time through `--dart-define`
/// MOD_TOTP_SECRET as a base32 string; verification stays inside the app
/// without network calls or extra dependencies.
class Totp {
  static const int _stepSeconds = 30;
  static const int _digits = 6;
  static const int _codeModulo = 1000000;
  static const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// Decodes a base32 string; returns null for invalid characters.
  static Uint8List? decodeBase32(String input) {
    final normalized = input.toUpperCase().replaceAll(RegExp(r'[=\s]'), '');
    if (normalized.isEmpty) return null;
    var bits = 0;
    var value = 0;
    final bytes = <int>[];
    for (final character in normalized.codeUnits) {
      final digit = _base32Alphabet.indexOf(String.fromCharCode(character));
      if (digit < 0) return null;
      value = (value << 5) | digit;
      bits += 5;
      if (bits >= 8) {
        bytes.add((value >> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return Uint8List.fromList(bytes);
  }

  static String _hotp(List<int> key, int counter) {
    final block = ByteData(8)..setUint64(0, counter);
    final digest = Hmac(sha1, key).convert(block.buffer.asUint8List()).bytes;
    final offset = digest[digest.length - 1] & 0x0f;
    final code =
        ((digest[offset] & 0x7f) << 24) |
        ((digest[offset + 1] & 0xff) << 16) |
        ((digest[offset + 2] & 0xff) << 8) |
        (digest[offset + 3] & 0xff);
    return (code % _codeModulo).toString().padLeft(_digits, '0');
  }

  /// Verifies a 6-digit code against the base32 secret. A ±`window` step
  /// drift is accepted to tolerate clock skew between devices.
  static bool verify(
    String base32Secret,
    String code, {
    int window = 1,
    int? nowMs,
  }) {
    final normalizedCode = code.trim();
    if (normalizedCode.length != _digits) return false;
    final key = decodeBase32(base32Secret);
    if (key == null || key.isEmpty) return false;
    final moment =
        (nowMs ?? DateTime.now().millisecondsSinceEpoch) ~/
        1000 ~/
        _stepSeconds;
    for (var drift = -window; drift <= window; drift++) {
      final expected = _hotp(key, moment + drift);
      // Constant-time style comparison length difference never leaks here
      // because both strings are fixed-length digits.
      var difference = 0;
      for (var index = 0; index < _digits; index++) {
        difference |=
            normalizedCode.codeUnitAt(index) ^ expected.codeUnitAt(index);
      }
      if (difference == 0) return true;
    }
    return false;
  }
}
