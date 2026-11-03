import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Management-server client for the mod builds — port of the Android
/// `MgmtApi` (server/mgmt.py wire format).
///
/// The endpoint, shared device token, admin token and TLS SPKI pin arrive as
/// build-time dart-defines (MOD_MGMT_URL, MOD_MGMT_DEVICE_TOKEN,
/// MOD_MGMT_ADMIN_TOKEN, MOD_MGMT_SPKI_PIN) and only arm the client when
/// both URL and device token are present; the console additionally needs the
/// admin token (MOD_ADMIN_CONSOLE=true selects the console role).
///
/// HTTPS runs through the `onexray/mod_mgmt` method channel
/// (`ios/Runner/ModMgmt.swift`) because dart:io exposes no certificate bytes
/// for pinning; every other platform fails closed and requests throw.
class ModMgmtApi {
  static const String urlDefine = 'MOD_MGMT_URL';
  static const String deviceTokenDefine = 'MOD_MGMT_DEVICE_TOKEN';
  static const String adminTokenDefine = 'MOD_MGMT_ADMIN_TOKEN';
  static const String spkiPinDefine = 'MOD_MGMT_SPKI_PIN';
  static const String consoleDefine = 'MOD_ADMIN_CONSOLE';

  static const String _channelName = 'onexray/mod_mgmt';

  static final ModMgmtApi instance = ModMgmtApi._(
    const String.fromEnvironment(urlDefine),
    const String.fromEnvironment(deviceTokenDefine),
    const String.fromEnvironment(adminTokenDefine),
    const String.fromEnvironment(spkiPinDefine),
    const String.fromEnvironment(consoleDefine),
    _requestViaChannel,
  );

  ModMgmtApi._(
    this.bakedUrl,
    this.bakedDeviceToken,
    this.bakedAdminToken,
    this.spkiPin,
    String consoleFlag,
    this.transport,
  ) : consoleEnabled = consoleFlag == 'true';

  @visibleForTesting
  ModMgmtApi.forTesting({
    String url = '',
    String deviceToken = '',
    String adminToken = '',
    String pin = '',
    String consoleFlag = '',
    MgmtTransport? transport,
  }) : this._(
         url,
         deviceToken,
         adminToken,
         pin,
         consoleFlag,
         transport ?? _requestViaChannel,
       );

  final String bakedUrl;
  final String bakedDeviceToken;
  final String bakedAdminToken;
  final String spkiPin;
  final bool consoleEnabled;
  final MgmtTransport transport;

  /// Heartbeats run only when the endpoint and a device token are baked in.
  bool get configured =>
      bakedUrl.isNotEmpty && bakedDeviceToken.isNotEmpty;

  /// Normalizes like the Android client: trimmed, no trailing slash, an
  /// explicit http scheme added when missing.
  @visibleForTesting
  static String normalizeUrl(String raw) {
    final trimmed = raw.trim();
    final bare = trimmed.endsWith('/')
        ? trimmed.replaceAll(RegExp(r'/+$'), '')
        : trimmed;
    if (bare.isEmpty) return '';
    return bare.startsWith('http') ? bare : 'http://$bare';
  }

  Future<Map<String, dynamic>> request(
    String url,
    String method, {
    String adminToken = '',
    String deviceToken = '',
    Map<String, dynamic>? body,
  }) async {
    final response = await transport(
      MgmtRequest(
        url: '${normalizeUrl(url)}',
        method: method,
        headers: {
          if (adminToken.isNotEmpty) 'X-Admin-Token': adminToken,
          if (deviceToken.isNotEmpty) 'X-Device-Token': deviceToken,
          if (body != null) 'Content-Type': 'application/json; charset=utf-8',
        },
        body: body == null ? null : jsonEncode(body),
        pin: spkiPin,
      ),
    );
    if (response.status < 200 || response.status > 299) {
      String detail = '';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          detail = decoded['error'] as String;
        }
      } catch (_) {}
      throw MgmtApiException(
        'HTTP ${response.status}${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    if (response.body.trim().isEmpty) return {};
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const MgmtApiException('invalid JSON response');
    }
    return decoded;
  }

  Future<List<MgmtDevice>> devices(String url, String adminToken) async {
    final response = await request(
      '$url/api/devices',
      'GET',
      adminToken: adminToken,
    );
    final list = response['devices'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) MgmtDevice.fromJson(item),
    ];
  }

  /// Returns the devices the command was queued for.
  Future<List<String>> push(
    String url,
    String adminToken,
    String target,
    String type,
    String payload,
  ) async {
    final response = await request(
      '$url/api/push',
      'POST',
      adminToken: adminToken,
      body: {'target': target, 'type': type, 'payload': payload},
    );
    return _stringList(response['queued']);
  }

  Future<List<MgmtCommand>> queue(String url, String adminToken, String device) async {
    final response = await request(
      '$url/api/queue?device=${Uri.encodeQueryComponent(device)}',
      'GET',
      adminToken: adminToken,
    );
    final list = response['queue'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) MgmtCommand.fromJson(item),
    ];
  }

  Future<void> clearQueue(String url, String adminToken, String device) async {
    await request(
      '$url/api/queue?device=${Uri.encodeQueryComponent(device)}',
      'DELETE',
      adminToken: adminToken,
    );
  }

  /// Server-side block: banned devices get 403 on heartbeat and are skipped
  /// by push.
  Future<List<String>> ban(String url, String adminToken, String target) async {
    final response = await request(
      '$url/api/ban',
      'POST',
      adminToken: adminToken,
      body: {'target': target},
    );
    return _stringList(response['banned']);
  }

  Future<void> unban(String url, String adminToken, String device) async {
    await request(
      '$url/api/ban?device=${Uri.encodeQueryComponent(device)}',
      'DELETE',
      adminToken: adminToken,
    );
  }

  /// Forget a device: drops its record, queued commands and ban state.
  Future<List<String>> remove(String url, String adminToken, String target) async {
    final response = await request(
      '$url/api/delete',
      'POST',
      adminToken: adminToken,
      body: {'target': target},
    );
    return _stringList(response['removed']);
  }

  /// Device heartbeat; returns queued commands plus the enrollment result,
  /// if any.
  Future<HeartbeatReply> heartbeat(
    String url,
    String deviceToken,
    Map<String, dynamic> body,
  ) async {
    final response = await request(
      '$url/api/hb',
      'POST',
      deviceToken: deviceToken,
      body: body,
    );
    return HeartbeatReply.fromJson(response);
  }

  /// Where the live management server lives now, plus (to a caller holding a
  /// valid device token) the current device token.
  Future<MgmtBootstrap> bootstrap(String url, String deviceToken) async {
    final response = await request('$url/api/bootstrap', 'GET', deviceToken: deviceToken);
    return MgmtBootstrap.fromJson(response);
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return [for (final item in value) if (item is String) item];
  }

  static Future<MgmtResponse> _requestViaChannel(MgmtRequest request) async {
    try {
      const channel = MethodChannel(_channelName);
      final result = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'request',
        {
          'url': request.url,
          'method': request.method,
          'headers': request.headers,
          if (request.body != null) 'body': request.body,
          'pin': request.pin,
        },
      );
      if (result == null) {
        throw const MgmtApiException('empty transport response');
      }
      return MgmtResponse(
        status: (result['status'] as num?)?.toInt() ?? 0,
        body: (result['body'] as String?) ?? '',
      );
    } on PlatformException catch (error) {
      throw MgmtApiException('${error.code}: ${error.message}');
    } on MissingPluginException {
      throw const MgmtApiException('mgmt transport unavailable');
    }
  }
}

typedef MgmtTransport = Future<MgmtResponse> Function(MgmtRequest request);

final class MgmtRequest {
  const MgmtRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.body,
    required this.pin,
  });

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final String pin;
}

final class MgmtResponse {
  const MgmtResponse({required this.status, required this.body});

  final int status;
  final String body;
}

class MgmtApiException implements Exception {
  const MgmtApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class MgmtDevice {
  const MgmtDevice({
    required this.user,
    required this.device,
    required this.version,
    required this.server,
    required this.model,
    required this.login,
    required this.serversCount,
    required this.firstSeen,
    required this.lastSeen,
    required this.online,
    required this.isNew,
    required this.pending,
    required this.role,
    required this.banned,
    required this.locked,
  });

  factory MgmtDevice.fromJson(Map<String, dynamic> json) {
    return MgmtDevice(
      user: _str(json['user']),
      device: _str(json['device']),
      version: _str(json['version']),
      server: _str(json['server']),
      model: _str(json['model']),
      login: _str(json['login']),
      serversCount: _int(json['servers']),
      firstSeen: _long(json['first_seen']),
      lastSeen: _long(json['last_seen']),
      online: json['online'] == true,
      isNew: json['new'] == true,
      pending: _int(json['pending']),
      role: _str(json['role']),
      banned: json['banned'] == true,
      locked: json['locked'] == true,
    );
  }

  final String user;
  final String device;
  final String version;
  final String server;
  final String model;
  final String login;
  final int serversCount;
  final int firstSeen;
  final int lastSeen;
  final bool online;
  final bool isNew;
  final int pending;
  final String role;
  final bool banned;
  final bool locked;

  static String _str(Object? value) => value is String ? value : '';
  static int _int(Object? value) =>
      value is num ? value.toInt() : (value is String ? int.tryParse(value) ?? 0 : 0);
  static int _long(Object? value) =>
      value is num ? value.toInt() : (value is String ? int.tryParse(value) ?? 0 : 0);
}

final class MgmtCommand {
  const MgmtCommand({required this.type, required this.payload});

  factory MgmtCommand.fromJson(Map<String, dynamic> json) => MgmtCommand(
    type: json['type'] is String ? json['type'] as String : '',
    payload: json['payload'] is String ? json['payload'] as String : '',
  );

  final String type;
  final String payload;
}

final class HeartbeatReply {
  const HeartbeatReply({required this.commands, this.deviceToken});

  factory HeartbeatReply.fromJson(Map<String, dynamic> json) {
    final list = json['commands'];
    return HeartbeatReply(
      commands: [
        if (list is List)
          for (final item in list)
            if (item is Map<String, dynamic>) MgmtCommand.fromJson(item),
      ],
      deviceToken: json['deviceToken'] is String &&
              (json['deviceToken'] as String).isNotEmpty
          ? json['deviceToken'] as String
          : null,
    );
  }

  final List<MgmtCommand> commands;

  /// Set when the server enrolled this device / reconfirmed its personal
  /// token.
  final String? deviceToken;
}

final class MgmtBootstrap {
  const MgmtBootstrap({required this.server, this.deviceToken});

  factory MgmtBootstrap.fromJson(Map<String, dynamic> json) =>
      MgmtBootstrap(
        server: json['server'] is String ? json['server'] as String : '',
        deviceToken: json['deviceToken'] is String &&
                (json['deviceToken'] as String).isNotEmpty
            ? json['deviceToken'] as String
            : null,
      );

  final String server;
  final String? deviceToken;
}
