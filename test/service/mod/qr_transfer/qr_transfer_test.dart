import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:onexray/service/mod/qr_transfer/qr_transfer.dart';

/// Vectors mirror the Android fork's QrTransferTest so both sides accept
/// exactly the same token and secret shapes.
void main() {
  const secret = 'JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP';

  group('base32/base64url codecs', () {
    test('decodes valid groups', () {
      expect(utf8.decode(ModQrTransfer._decodeBase32('MY======')!), 'f');
      expect(utf8.decode(ModQrTransfer._decodeBase32('MZXQ====')!), 'fo');
      expect(utf8.decode(ModQrTransfer._decodeBase32('MZXW6===')!), 'foo');
      expect(utf8.decode(ModQrTransfer._decodeBase32('MZXW6YQ=')!), 'foob');
      expect(utf8.decode(ModQrTransfer._decodeBase32('MZXW6YTB')!), 'fooba');
      expect(
        utf8.decode(ModQrTransfer._decodeBase32('MZXW6YTBOI======')!),
        'foobar',
      );
      expect(ModQrTransfer._decodeBase32(''), isEmpty);
    });

    test('rejects malformed groups and characters', () {
      expect(ModQrTransfer._decodeBase32('M1======'), isNull);
      expect(ModQrTransfer._decodeBase32('ABC'), isNull);
      expect(ModQrTransfer._decodeBase32('A'), isNull);
    });

    test('base64url rejects bad length and characters', () {
      expect(ModQrTransfer._decodeBase64Url('A'), isNull);
      expect(ModQrTransfer._decodeBase64Url('A?B'), isNull);
      expect(
        utf8.decode(ModQrTransfer._decodeBase64Url('Zm9vYmFy')!),
        'foobar',
      );
      // Padding is tolerated.
      expect(
        utf8.decode(ModQrTransfer._decodeBase64Url('Zm9vYmFy==')!),
        'foobar',
      );
    });

    test('derives the key only for valid Base32 secrets', () {
      expect(ModQrTransfer._deriveKey(secret), isNotNull);
      expect(ModQrTransfer._deriveKey(secret)?.length, 32);
      expect(ModQrTransfer._deriveKey('short'), isNull);
      expect(ModQrTransfer._deriveKey('abc1234567890123'), isNull);
    });
  });

  group('convertPayload', () {
    test('rejects tampered payloads', () {
      final transfer = ModQrTransfer.forTesting();
      expect(() => transfer.convertPayload('not json'), throwsFormatException);
      expect(
        () => transfer.convertPayload('{"v":2,"servers":[{"p":{}}]}'),
        throwsFormatException,
      );
      expect(
        () => transfer.convertPayload('{"v":1,"servers":[]}'),
        throwsFormatException,
      );
      expect(
        () => transfer.convertPayload(
          '{"v":1,"servers":[{"p":{"configType":"BROKEN"}}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => transfer.convertPayload(
          '{"v":1,"servers":[{"p":{"configType":"WIREGUARD"}}]}',
        ),
        throwsFormatException, // nothing importable left
      );
    });

    test('splits links and raw custom configs, skipping unsupported types', () {
      final transfer = ModQrTransfer.forTesting();
      final payload = jsonEncode({
        'v': 1,
        'servers': [
          {
            'p': {
              'configType': 'VLESS',
              'remarks': 'vless-srv',
              'server': 'example.com',
              'serverPort': '443',
              'password': 'uuid-1',
              'security': 'reality',
            },
            'raw': null,
          },
          {
            'p': {'configType': 'CUSTOM'},
            'raw': '{"outbounds":[{"tag":"proxy","protocol":"freedom"}]}',
          },
          {
            'p': {'configType': 'WIREGUARD'},
            'raw': null,
          },
        ],
      });
      final parts = transfer.convertPayload(payload);
      expect(parts, hasLength(2));
      expect(parts.first, startsWith('vless://uuid-1@example.com:443'));
      expect(parts.first, endsWith('#vless-srv'));
      expect(parts.last, startsWith('{"outbounds"'));
    });
  });

  group('link generation', () {
    ModQrTransfer transfer() => ModQrTransfer.forTesting();

    String payloadFor(Map profile, {String? raw}) => jsonEncode({
      'v': 1,
      'servers': [
        {'p': profile, 'raw': raw},
      ],
    });

    test('vless reality emits the Android share-link shape', () {
      final link = transfer()
          .convertPayload(
            payloadFor({
              'configType': 'VLESS',
              'remarks': 'srv1',
              'server': 'example.com',
              'serverPort': '443',
              'password': 'uuid-1',
              'security': 'reality',
              'sni': 'www.ya.ru',
              'fingerPrint': 'chrome',
              'publicKey': 'PUBKEY',
              'shortId': 'ab12',
              'spiderX': '/',
              'flow': 'xtls-rprx-vision',
              'network': 'tcp',
              'headerType': 'none',
            }),
          )
          .single;
      expect(
        link,
        'vless://uuid-1@example.com:443'
        '?security=reality&sni=www.ya.ru&fp=chrome&pbk=PUBKEY&sid=ab12'
        '&spx=%2F&flow=xtls-rprx-vision&type=tcp&headerType=none'
        '&encryption=none#srv1',
      );
    });

    test('vmess emits the padded VmessQRCode base64 body', () {
      final link = transfer()
          .convertPayload(
            payloadFor({
              'configType': 'VMESS',
              'remarks': 'vm1',
              'server': 'a.com',
              'serverPort': '443',
              'password': 'uuid-2',
              'method': 'auto',
              'network': 'ws',
              'host': 'cdn.a.com',
              'path': '/ws',
              'security': 'tls',
              'sni': 'a.com',
              'alpn': 'h2,http/1.1',
              'fingerPrint': 'chrome',
              'insecure': true,
            }),
          )
          .single;
      expect(link, startsWith('vmess://'));
      final decoded = jsonDecode(
        utf8.decode(base64.decode(link.substring('vmess://'.length))),
      );
      expect(decoded, {
        'v': '2',
        'ps': 'vm1',
        'add': 'a.com',
        'port': '443',
        'id': 'uuid-2',
        'aid': '0',
        'scy': 'auto',
        'net': 'ws',
        'type': '',
        'host': 'cdn.a.com',
        'path': '/ws',
        'tls': 'tls',
        'sni': 'a.com',
        'alpn': 'h2,http/1.1',
        'fp': 'chrome',
        'insecure': '1',
        'vcn': '',
        'pcs': '',
      });
    });

    test('vmess grpc fields map and host/path override them', () {
      final link = transfer()
          .convertPayload(
            payloadFor({
              'configType': 'VMESS',
              'server': 'g.com',
              'serverPort': '1',
              'password': 'id3',
              'network': 'grpc',
              'mode': 'gun',
              'serviceName': 'svc',
              'authority': 'auth.example',
              'host': 'override.example',
            }),
          )
          .single;
      final decoded = jsonDecode(
        utf8.decode(base64.decode(link.substring('vmess://'.length))),
      );
      expect(decoded['host'], 'override.example');
      expect(decoded['path'], 'svc');
      expect(decoded['type'], 'gun');
    });

    test('shadowsocks and socks carry encoded userinfo', () {
      final links = transfer()
          .convertPayload(
            jsonEncode({
              'v': 1,
              'servers': [
                {
                  'p': {
                    'configType': 'SHADOWSOCKS',
                    'remarks': 'ss1',
                    'server': 's.com',
                    'serverPort': '8388',
                    'method': 'aes-256-gcm',
                    'password': 'p:ass word',
                  },
                },
                {
                  'p': {
                    'configType': 'SOCKS',
                    'remarks': 'sx1',
                    'server': 'x.com',
                    'serverPort': '1080',
                    'username': 'user',
                    'password': 'pw',
                  },
                },
              ],
            }),
          )
          .single
          .split('\n');
      final ss = links[0];
      final ssUser = ss.substring('ss://'.length, ss.indexOf('@'));
      expect(ssUser.contains('='), isFalse);
      expect(
        utf8.decode(
          base64.decode(ssUser + '=' * ((4 - ssUser.length % 4) % 4)),
        ),
        'aes-256-gcm:p:ass word',
      );
      expect(ss, endsWith('@s.com:8388#ss1'));
      final socks = links[1];
      final socksUser = socks.substring('socks://'.length, socks.indexOf('@'));
      expect(
        utf8.decode(
          base64.decode(socksUser + '=' * ((4 - socksUser.length % 4) % 4)),
        ),
        'user:pw',
      );
    });

    test('trojan passes empty security through and brackets IPv6 hosts', () {
      final link = transfer()
          .convertPayload(
            payloadFor({
              'configType': 'TROJAN',
              'remarks': 'tj',
              'server': '2001:db8::1',
              'serverPort': '443',
              'password': 'secret',
            }),
          )
          .single;
      // FmtBase emits the security key even when the profile has none.
      expect(link, 'trojan://secret@[2001:db8::1]:443?security=#tj');
    });
  });

  group('expand', () {
    test('opens a token through the injected decryptor', () async {
      final transfer = ModQrTransfer.forTesting(
        secret: secret,
        decrypt: (data, key) async =>
            '{"v":1,"servers":['
            '{"p":{"configType":"SOCKS","server":"x.com","serverPort":"1080",'
            '"remarks":"ok"}}]}',
      );
      final body = ModQrTransfer._decodeBase64Url(
        base64Url.encode(utf8.encode('x' * 30)).replaceAll('=', ''),
      );
      final parts = await transfer.expand(
        'VNG1:${base64Url.encode(body!).replaceAll('=', '')}',
      );
      expect(parts.single, startsWith('socks://'));
    });

    test('disabled build leaves tokens unrecognized', () {
      final transfer = ModQrTransfer.forTesting();
      expect(transfer.enabled, isFalse);
      expect(transfer.isToken('VNG1:whatever'), isFalse);
    });

    test('short or undecryptable tokens reject without importing', () async {
      final transfer = ModQrTransfer.forTesting(
        secret: secret,
        decrypt: (data, key) async => null,
      );
      expect(() => transfer.expand('VNG1:AAAA'), throwsFormatException);
      final token =
          'VNG1:${base64Url.encode(utf8.encode('y' * 40)).replaceAll('=', '')}';
      expect(() => transfer.expand(token), throwsFormatException);
    });
  });
}
