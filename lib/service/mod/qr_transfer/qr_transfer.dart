import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:onexray/core/tools/logger.dart';

/// Encrypted VNG1 QR profile transfer — the import side.
///
/// Mirrors the Android mod build's `QrTransfer`: the token is
/// `"VNG1:" + base64url(IV(12) || AES-256-GCM(JSON, tag 128))` and the AES
/// key is baked at build time through `--dart-define=MOD_QR_SECRET`
/// (Base32, key = SHA-256 of the decoded secret). Import-only by design;
/// the export UI lives in the admin Android build.
///
/// AES-GCM is unavailable in the Dart dependency tree, so the sealed box is
/// opened by CryptoKit through the `onexray/mod_qr` method channel (see
/// `ios/Runner/ModQr.swift`); every other platform fails closed and the
/// token stays unrecognized. Decoding is all-or-nothing: any tampered or
/// invalid entry rejects the whole token before a single write.
final class ModQrTransfer {
  static const String secretDefine = 'MOD_QR_SECRET';
  static const String tokenPrefix = 'VNG1:';
  static const int payloadVersion = 1;

  static const String _channelName = 'onexray/mod_qr';
  static const int _ivLengthBytes = 12;
  static const int _gcmTagBytes = 16;
  static const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// EConfigType values from the Android fork; only these travel in tokens.
  static const Map<String, int> _configTypes = {
    'VMESS': 1,
    'CUSTOM': 2,
    'SHADOWSOCKS': 3,
    'SOCKS': 4,
    'VLESS': 5,
    'TROJAN': 6,
    'WIREGUARD': 7,
    'HYSTERIA2': 9,
    'HTTP': 10,
    'POLICYGROUP': 101,
    'PROXYCHAIN': 102,
  };

  /// Share-link protocols the native libXray parser accepts.
  static const Map<int, String> _linkableTypes = {
    1: 'vmess://',
    3: 'ss://',
    4: 'socks://',
    5: 'vless://',
    6: 'trojan://',
  };

  static final ModQrTransfer _instance = ModQrTransfer._(
    const String.fromEnvironment(secretDefine),
    _decryptViaChannel,
  );

  factory ModQrTransfer() => _instance;

  @visibleForTesting
  ModQrTransfer.forTesting({
    String secret = '',
    Future<String?> Function(String dataBase64, List<int> key)? decrypt,
  }) : this._(secret, decrypt ?? _decryptViaChannel);

  ModQrTransfer._(this._secret, this._decrypt);

  final String _secret;
  final Future<String?> Function(String dataBase64, List<int> key) _decrypt;

  /// The import path only arms when a build-time secret is present.
  bool get enabled => _secret.isNotEmpty;

  /// Any import entry (scan, file, clipboard, paste) funnels through this
  /// check before regular link parsing.
  bool isToken(String input) =>
      enabled && input.trimLeft().startsWith(tokenPrefix);

  /// Decrypts a token and converts every profile into inputs for the
  /// regular import pipeline: one text of share links plus one raw JSON
  /// text per custom config. Unknown-but-valid entry types are skipped and
  /// counted; profile identities never travel in the token.
  Future<List<String>> expand(String input) async {
    if (!isToken(input)) {
      throw const FormatException('Not a QR transfer token');
    }
    final data = decodeBase64Url(
      input.trimLeft().substring(tokenPrefix.length).trim(),
    );
    if (data == null || data.length < _ivLengthBytes + _gcmTagBytes) {
      throw const FormatException('Invalid QR transfer token');
    }
    final key = deriveKey(_secret);
    if (key == null) {
      throw const FormatException('Invalid QR transfer secret');
    }
    final plain = await _decrypt(base64.encode(data), key);
    if (plain == null) {
      throw const FormatException('Invalid QR transfer token');
    }
    return convertPayload(plain);
  }

  /// Payload validation and link conversion, isolated from the crypto path
  /// so tests can drive it directly with plaintext JSON.
  @visibleForTesting
  List<String> convertPayload(String plain) {
    final Object? json;
    try {
      json = jsonDecode(plain);
    } catch (_) {
      throw const FormatException('Invalid QR transfer payload');
    }
    if (json is! Map<String, dynamic> ||
        json['v'] != payloadVersion ||
        json['servers'] is! List ||
        (json['servers'] as List).isEmpty) {
      throw const FormatException('Invalid QR transfer payload');
    }
    final links = <String>[];
    final raws = <String>[];
    var skipped = 0;
    for (final entry in json['servers'] as List) {
      if (entry is! Map<String, dynamic> || entry['p'] is! Map) {
        throw const FormatException('Invalid QR transfer payload');
      }
      final profile = entry['p'] as Map;
      final type = _configTypeValue(profile['configType']);
      if (type == null || !_configTypes.containsValue(type)) {
        throw const FormatException('Invalid QR transfer payload');
      }
      final link = _linkableTypes[type] == null ? null : _toLink(type, profile);
      if (link != null) {
        links.add(link);
      } else if (type == 2) {
        final raw = entry['raw'];
        if (raw is String && raw.trim().startsWith('{')) {
          raws.add(raw);
        } else {
          skipped++;
        }
      } else {
        // WireGuard, Hysteria2, HTTP and policy entries have no share-link
        // form the native parser accepts; drop them instead of the token.
        skipped++;
      }
    }
    if (skipped > 0) {
      ygLogger('QR transfer skipped $skipped unsupported profile(s)');
    }
    if (links.isEmpty && raws.isEmpty) {
      throw const FormatException('No importable profiles in token');
    }
    return [
      // A single links text keeps the batch write all-or-nothing.
      if (links.isNotEmpty) links.join('\n'),
      ...raws,
    ];
  }

  // ---------------------------------------------------------------- links

  /// Ports the Android fmt/ share-link generators (FmtBase, VlessFmt,
  /// VmessFmt, TrojanFmt, ShadowsocksFmt, SocksFmt) so tokens exported by
  /// the mod build round-trip through the existing native link parser.
  /// IDN hosts are passed through unchanged; only connection data is
  /// expressed, Android-mod-only fields (policy groups, chains) never do.
  String? _toLink(int type, Map p) {
    final scheme = _linkableTypes[type]!;
    return switch (type) {
      1 => '$scheme${_vmessBody(p)}',
      3 => _baseUri(
        scheme,
        p,
        _encodeNoPad('${_nb(p['method']) ?? ''}:${p['password'] ?? ''}'),
        const {},
      ),
      4 => _baseUri(
        scheme,
        p,
        _encodeNoPad(
          _nb(p['username']) == null
              ? ':${p['password'] ?? ''}'
              : '${p['username']}:${p['password'] ?? ''}',
        ),
        const {},
      ),
      5 => _baseUri(scheme, p, p['password'] as String? ?? '', {
        ..._queryDic(p),
        'encryption': _nb(p['method']) ?? 'none',
      }),
      6 => _baseUri(scheme, p, p['password'] as String? ?? '', _queryDic(p)),
      _ => null,
    };
  }

  /// vmess body: Base64 (padded, no line wraps) of the VmessQRCode JSON
  /// declared by the Android DTO, keys in declaration order.
  String _vmessBody(Map p) {
    final network = _networkType(p['network']);
    var type = _string(p['headerType']);
    var host = _string(p['host']);
    var path = _string(p['path']);
    if (network == 'kcp') {
      path = _string(p['seed']);
    } else if (network == 'grpc') {
      type = _string(p['mode']);
      path = _string(p['serviceName']);
      host = _string(p['authority']);
    }
    // Non-blank host/path fields override the per-network mapping above.
    final hostOverride = _nb(p['host']);
    if (hostOverride != null) host = hostOverride;
    final pathOverride = _nb(p['path']);
    if (pathOverride != null) path = pathOverride;
    final insecure = p['insecure'];
    final json = jsonEncode(<String, String>{
      'v': '2',
      'ps': _string(p['remarks']) ?? '',
      'add': _string(p['server']) ?? '',
      'port': _string(p['serverPort']) ?? '',
      'id': _string(p['password']) ?? '',
      'aid': '0',
      'scy': _string(p['method']) ?? '',
      'net': _string(p['network']) ?? '',
      'type': type ?? '',
      'host': host ?? '',
      'path': path ?? '',
      'tls': _string(p['security']) ?? '',
      'sni': _string(p['sni']) ?? '',
      'alpn': _string(p['alpn']) ?? '',
      'fp': _string(p['fingerPrint']) ?? '',
      'insecure': insecure == null ? '' : (insecure == true ? '1' : '0'),
      'vcn': _string(p['verifyPeerCertByName']) ?? '',
      'pcs': _string(p['pinnedCA256']) ?? '',
    });
    return base64.encode(utf8.encode(json));
  }

  /// FmtBase.toUri: `user@host:port?query#remarks`, IPv6 hosts bracketed.
  String _baseUri(
    String scheme,
    Map p,
    String userInfo,
    Map<String, String> query,
  ) {
    var host = _string(p['server']) ?? '';
    if (host.contains(':') && !host.startsWith('[')) {
      host = '[$host]';
    }
    final queryText = query.entries
        .map((entry) => '${entry.key}=${Uri.encodeComponent(entry.value)}')
        .join('&');
    return '$scheme${Uri.encodeComponent(userInfo)}@$host:${_string(p['serverPort']) ?? ''}'
        '${queryText.isEmpty ? '' : '?$queryText'}'
        '#${Uri.encodeComponent(_string(p['remarks']) ?? '')}';
  }

  /// FmtBase.getQueryDic: transport and security parameters in the exact
  /// shape the Android generator emits (empty security key, per-network
  /// transport fields, both insecure spellings under TLS).
  Map<String, String> _queryDic(Map p) {
    final query = <String, String>{};
    final security = _string(p['security']);
    query['security'] = security == null
        ? ''
        : (security.isEmpty ? 'none' : security);
    for (final entry in {
      'sni': _nb(p['sni']),
      'alpn': _nb(p['alpn']),
      'ech': _nb(p['echConfigList']),
      'vcn': _nb(p['verifyPeerCertByName']),
      'pcs': _nb(p['pinnedCA256']),
      'fp': _nb(p['fingerPrint']),
      'pbk': _nb(p['publicKey']),
      'sid': _nb(p['shortId']),
      'spx': _nb(p['spiderX']),
      'pqv': _nb(p['mldsa65Verify']),
      'flow': _nb(p['flow']),
      'fm': _nb(p['finalMask']),
    }.entries) {
      if (entry.value != null) {
        query[entry.key] = entry.value!;
      }
    }
    final kcpMtu = p['kcpMtu'];
    final kcpTti = p['kcpTti'];
    if (kcpMtu is int) query['mtu'] = kcpMtu.toString();
    if (kcpTti is int) query['tti'] = kcpTti.toString();
    if (query['security'] == 'tls') {
      final insecure = p['insecure'] == true ? '1' : '0';
      query['insecure'] = insecure;
      query['allowInsecure'] = insecure;
    }
    final network = _networkType(p['network']);
    query['type'] = network;
    switch (network) {
      case 'tcp':
      case 'kcp':
        final headerType = _string(p['headerType']);
        query['headerType'] = headerType == null
            ? ''
            : (headerType.isEmpty ? 'none' : headerType);
        final value = network == 'tcp' ? _nb(p['host']) : _nb(p['seed']);
        if (value != null) query[network == 'tcp' ? 'host' : 'seed'] = value;
      case 'ws':
      case 'httpupgrade':
        _putIfNotBlank(query, 'host', p['host']);
        _putIfNotBlank(query, 'path', p['path']);
      case 'xhttp':
        _putIfNotBlank(query, 'host', p['host']);
        _putIfNotBlank(query, 'path', p['path']);
        _putIfNotBlank(query, 'mode', p['xhttpMode']);
        _putIfNotBlank(query, 'extra', p['xhttpExtra']);
      case 'http':
      case 'h2':
        query['type'] = 'http';
        _putIfNotBlank(query, 'host', p['host']);
        _putIfNotBlank(query, 'path', p['path']);
      case 'grpc':
        _putIfNotBlank(query, 'mode', p['mode']);
        _putIfNotBlank(query, 'authority', p['authority']);
        _putIfNotBlank(query, 'serviceName', p['serviceName']);
    }
    return query;
  }

  static const Map<String, String> _networks = {
    'tcp': 'tcp',
    'kcp': 'kcp',
    'ws': 'ws',
    'httpupgrade': 'httpupgrade',
    'xhttp': 'xhttp',
    'http': 'http',
    'h2': 'h2',
    'grpc': 'grpc',
    'hysteria': 'hysteria',
  };

  /// NetworkType.fromString: unknown or missing networks become tcp.
  String _networkType(Object? value) =>
      value is String ? (_networks[value] ?? 'tcp') : 'tcp';

  int? _configTypeValue(Object? value) {
    if (value is int) return value;
    if (value is String) return _configTypes[value];
    return null;
  }

  static void _putIfNotBlank(Map<String, String> query, String key, Object? v) {
    final value = _nb(v);
    if (value != null) query[key] = value;
  }

  /// nullIfBlank: keeps the original spacing, drops blank values.
  static String? _nb(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

  static String? _string(Object? value) => value is String ? value : null;

  // ---------------------------------------------------------------- crypto

  /// Standard-alphabet Base64 without '=' padding (FmtBase userInfo parts).
  static String _encodeNoPad(String text) =>
      base64.encode(utf8.encode(text)).replaceAll('=', '');

  /// Base32 decoder with RFC 4648 final-group validation; the Android side
  /// rejects the same malformed secrets before deriving keys.
  @visibleForTesting
  static Uint8List? decodeBase32(String input) {
    // dart:core trimRight() takes no pattern; strip base32 padding.
    final clean = input.replaceAll(RegExp(r'=+$'), '');
    if (clean.length % 8 == 1 ||
        clean.length % 8 == 3 ||
        clean.length % 8 == 6) {
      return null;
    }
    var buffer = 0;
    var bits = 0;
    final out = BytesBuilder();
    for (final character in clean.codeUnits) {
      final digit = _base32Alphabet.indexOf(String.fromCharCode(character));
      if (digit < 0) return null;
      buffer = (buffer << 5) | digit;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.addByte((buffer >> bits) & 0xff);
      }
    }
    return out.toBytes();
  }

  @visibleForTesting
  static Uint8List? deriveKey(String secret) {
    if (!RegExp(r'^[A-Z2-7]{16,}$').hasMatch(secret)) return null;
    return Uint8List.fromList(
      sha256.convert(decodeBase32(secret) ?? Uint8List(0)).bytes,
    );
  }

  /// Base64url decoder tolerating (but never requiring) '=' padding.
  @visibleForTesting
  static Uint8List? decodeBase64Url(String input) {
    var clean = input.trim().replaceAll('=', '');
    if (clean.length % 4 == 1) return null;
    clean += '=' * ((4 - clean.length % 4) % 4);
    try {
      return base64Url.decode(clean);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _decryptViaChannel(
    String dataBase64,
    List<int> key,
  ) async {
    try {
      const channel = MethodChannel(_channelName);
      return await channel.invokeMethod<String>('decrypt', {
        'data': dataBase64,
        'key': base64.encode(key),
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
