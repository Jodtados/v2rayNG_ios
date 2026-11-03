import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:onexray/core/tools/logger.dart';
import 'package:onexray/service/connect/coordinator.dart';
import 'package:onexray/service/mod/activation/service.dart';
import 'package:onexray/service/mod/mgmt/api.dart';
import 'package:onexray/service/mod/qr_transfer/qr_transfer.dart';
import 'package:onexray/service/servers/import.dart';
import 'package:onexray/service/servers/server.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Management heartbeat — port of the Android `MgmtHeartbeat`.
///
/// One pulse per app cold start and per foreground resume (iOS offers no
/// WorkManager; background heartbeats are not attempted — a documented
/// platform difference from the Android mod). A rejected heartbeat heals
/// through the public bootstrap endpoint throttled to one try per 15
/// minutes, exactly like Android, so a rotated token or a moved server
/// self-repairs.
final class ModMgmtHeartbeat {
  static const String versionPrefix = 'v2rayNG-ios';
  static const int _bootstrapMinIntervalMs = 15 * 60 * 1000;

  static const String _prefUrl = 'mod.mgmt.url';
  static const String _prefDeviceToken = 'mod.mgmt.deviceToken';
  static const String _prefUserName = 'mod.mgmt.userName';
  static const String _prefDeviceId = 'mod.mgmt.deviceId';

  static final ModMgmtHeartbeat instance = ModMgmtHeartbeat._(
    ModMgmtApi.instance,
    SharedPreferences.getInstance,
    _appVersion,
    _serverNames,
    ConnectionCoordinator.instance.disconnect,
    ModActivationService(),
    ModQrTransfer(),
    ServerImportService.new,
  );

  ModMgmtHeartbeat._(
    this._api,
    this._preferences,
    this._version,
    this._serverNames,
    this._disconnect,
    this._activation,
    this._qr,
    this._importServiceFactory,
  );

  @visibleForTesting
  ModMgmtHeartbeat.forTesting({
    ModMgmtApi? api,
    Future<SharedPreferences> Function()? preferences,
    Future<String> Function()? version,
    Future<List<String>> Function()? serverNames,
    Future<void> Function()? disconnect,
    ModActivationService? activation,
    ModQrTransfer? qr,
    ServerImportService Function()? importServiceFactory,
  }) : this._(
         api ?? ModMgmtApi.forTesting(),
         preferences ?? _unavailablePreferences,
         version ?? () async => '0.0.0',
         serverNames ?? () async => const [],
         disconnect ?? () async {},
         activation ?? ModActivationService.forTesting(),
         qr ?? ModQrTransfer.forTesting(),
         importServiceFactory ?? ServerImportService.new,
       );

  static Future<SharedPreferences> _unavailablePreferences() async {
    throw UnsupportedError('preferences unavailable in tests');
  }

  static Future<String> _appVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// Config display names only — never addresses (masking parity with the
  /// softether fleet and the Android mod).
  static Future<List<String>> _serverNames() async =>
      (await ServerAssetService().rows()).map((row) => row.name).toList();

  final ModMgmtApi _api;
  final Future<SharedPreferences> Function() _preferences;
  final Future<String> Function() _version;
  final Future<List<String>> Function() _serverNames;
  final Future<void> Function() _disconnect;
  final ModActivationService _activation;
  final ModQrTransfer _qr;
  final ServerImportService Function() _importServiceFactory;

  int _lastBootstrapAttempt = 0;
  Future<bool>? _inFlight;

  /// Heartbeats run only in builds with a baked endpoint and device token.
  bool get configured => _api.configured;

  /// Stable per-install id ("d-" + UUID), generated once and kept in
  /// preferences.
  Future<String> deviceId() async {
    final preferences = await _preferences();
    final stored = preferences.getString(_prefDeviceId) ?? '';
    if (stored.isNotEmpty) return stored;
    final id = 'd-${const Uuid().v4()}';
    await preferences.setString(_prefDeviceId, id);
    return id;
  }

  /// Pinned URL wins over the baked one so mgmt_url commands can re-point us.
  Future<String> effectiveUrl() async {
    final pinned = (await _preferences()).getString(_prefUrl) ?? '';
    if (pinned.isNotEmpty) return pinned;
    return _api.bakedUrl;
  }

  /// Personal per-device token once enrolled, shared build token before
  /// that.
  Future<String> effectiveDeviceToken() async {
    final pinned = (await _preferences()).getString(_prefDeviceToken) ?? '';
    if (pinned.isNotEmpty) return pinned;
    return _api.bakedDeviceToken;
  }

  /// Console role: the console build manages the fleet, the plain mod
  /// reports as a managed admin device. (Android additionally reports
  /// "user" for user builds; iOS ships no user variant.)
  String get role => _api.consoleEnabled ? 'console' : 'admin';

  /// Display name shown in the console: the [v2] prefix keeps v2rayNG
  /// installs visually separate from the softether fleet sharing the
  /// server.
  @visibleForTesting
  static String displayUser(String storedName, String selected, String device) {
    final base = storedName.trim().isNotEmpty
        ? storedName
        : (selected.trim().isNotEmpty ? selected : device);
    return '[v2] $base'.take(64);
  }

  /// Wire body of a heartbeat; pure so unit tests cover it without Flutter.
  @visibleForTesting
  static Map<String, dynamic> hbBody({
    required String user,
    required String device,
    required String version,
    required String server,
    required String model,
    required String login,
    required int servers,
    required String role,
    required bool locked,
  }) => <String, dynamic>{
    'user': user,
    'device': device,
    'version': version,
    // remarks/name only — never addresses (masking parity)
    'server': server,
    'model': model,
    'login': login,
    'servers': servers,
    'role': role,
    'locked': locked,
  };

  /// "Apple iOS 17.4" style model label; dart:io exposes no iPhone model
  /// identifier, and the console only needs a recognizable platform tag.
  @visibleForTesting
  static String deviceModel(String osVersion) {
    var compact = osVersion.trim();
    final buildIndex = compact.indexOf('(');
    if (buildIndex > 0) compact = compact.substring(0, buildIndex).trim();
    compact = compact.replaceFirst(RegExp('^Version\\s*'), '');
    final label = compact.isEmpty ? Platform.operatingSystem : compact;
    return 'Apple ${Platform.operatingSystem} $label'.take(64);
  }

  /// Fire-and-forget pulse; concurrent callers share one request.
  Future<bool> pulse() {
    final running = _inFlight;
    if (running != null) return running;
    final future = _pulseOnce().whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  /// One heartbeat attempt; heals a moved server or rotated token through
  /// the public bootstrap endpoint before retrying once.
  Future<bool> _pulseOnce() async {
    if (!configured) return false;
    Object? firstError;
    try {
      return await _heartbeatOnce();
    } catch (error) {
      firstError = error;
      ygLogger('mgmt heartbeat rejected: $error');
    }
    if (!await _bootstrapAndPin()) return false;
    try {
      return await _heartbeatOnce();
    } catch (error) {
      ygLogger('mgmt heartbeat still failing after bootstrap heal: $error');
      // The first failure carries the original cause.
      throw firstError;
    }
  }

  Future<bool> _heartbeatOnce() async {
    final url = await effectiveUrl();
    final token = await effectiveDeviceToken();
    final reply = await _api.heartbeat(url, token, await _buildBody());

    // Pin the personal token BEFORE applying commands: once the server
    // enrolls us, the shared token stops identifying this device.
    final minted = reply.deviceToken;
    if (minted != null && minted.isNotEmpty && minted != token) {
      await (await _preferences()).setString(_prefDeviceToken, minted);
    }

    await applyCommands(reply.commands);
    return true;
  }

  Future<Map<String, dynamic>> _buildBody() async {
    final names = await _serverNames();
    final storedName = (await _preferences()).getString(_prefUserName) ?? '';
    final device = await deviceId();
    return hbBody(
      user: displayUser(storedName, names.isEmpty ? '' : names.first, device),
      device: device,
      version: '$versionPrefix ${await _version()}'.take(32),
      server: names.isEmpty ? '' : names.first,
      model: deviceModel(Platform.operatingSystemVersion),
      login: '',
      servers: names.length,
      role: role,
      locked: !await _activation.isActivated(),
    );
  }

  Future<bool> _bootstrapAndPin() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBootstrapAttempt < _bootstrapMinIntervalMs) return false;
    _lastBootstrapAttempt = now;

    try {
      final baked = _api.bakedUrl;
      final target = baked.isEmpty ? await effectiveUrl() : baked;
      final reply = await _api.bootstrap(target, await effectiveDeviceToken());
      if (reply.server.isNotEmpty) {
        await (await _preferences()).setString(_prefUrl, reply.server);
      }
      final token = reply.deviceToken;
      if (token != null && token.isNotEmpty) {
        await (await _preferences()).setString(_prefDeviceToken, token);
      }
      return true;
    } catch (error) {
      ygLogger('mgmt bootstrap retry skipped or failed: $error');
      return false;
    }
  }

  /// Applies queued commands in order. A failing command is logged and
  /// skipped so one bad payload cannot block the rest of the queue.
  @visibleForTesting
  Future<void> applyCommands(List<MgmtCommand> commands) async {
    for (final command in commands) {
      try {
        switch (command.type) {
          case 'servers':
            await importServersToken(command.payload);

          // Remote wipe needs the shared data-clear flow; stopping the
          // tunnel is the safe subset for now (iOS v1 deviation from
          // Android, which also removes every server profile).
          case 'clear_servers':
            await _disconnect();

          // Re-arm the TOTP gate and stop the tunnel; the gate shows on
          // the next cold start (a live process keeps running).
          case 'lock':
            await _disconnect();
            await _activation.deactivate();

          case 'disconnect':
            await _disconnect();

          case 'mgmt_url':
            await applyMgmtUrl(command.payload);

          default:
            ygLogger('unknown mgmt command: ${command.type}');
        }
      } catch (error) {
        ygLogger('failed to apply mgmt command ${command.type}: $error');
      }
    }
  }

  /// Re-point heartbeats; only absolute http(s) URLs are accepted.
  @visibleForTesting
  Future<bool> applyMgmtUrl(String raw) async {
    final url = sanitizeMgmtUrl(raw);
    if (url == null) return false;
    await (await _preferences()).setString(_prefUrl, url);
    return true;
  }

  @visibleForTesting
  static String? sanitizeMgmtUrl(String raw) {
    final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (!trimmed.startsWith('https://') && !trimmed.startsWith('http://')) {
      return null;
    }
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Pushed "servers" payloads are the same VNG1 tokens the QR import
  /// reads; each expands into share-link/raw texts that go through the
  /// regular headless import pipeline.
  @visibleForTesting
  Future<int> importServersToken(String payload) async {
    final parts = await _qr.expand(payload);
    final service = _importServiceFactory();
    var imported = 0;
    for (final part in parts) {
      final detection = service.detect(part);
      final preview = await service.previewDetected(detection);
      if (!preview.hasItems) {
        await preview.dispose();
        continue;
      }
      final result = await service.commit(preview);
      imported += result.count + result.rawCount + result.customCount;
    }
    return imported;
  }
}

extension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
