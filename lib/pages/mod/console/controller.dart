import 'package:flutter/foundation.dart';
import 'package:onexray/l10n/localizations/app_localizations.dart';
import 'package:onexray/pages/shared/page_cubit.dart';
import 'package:onexray/service/mod/mgmt/api.dart';
import 'package:onexray/service/mod/mgmt/heartbeat.dart';

/// Device-console state: the fleet list plus one in-flight action at a
/// time (the dialog stays open until the server answers).
@immutable
class ModConsoleState {
  const ModConsoleState({
    this.loading = false,
    this.devices = const [],
    this.error,
    this.message,
    this.busy = false,
  });

  final bool loading;
  final List<MgmtDevice> devices;
  final Object? error;
  final String? message;
  final bool busy;

  ModConsoleState copyWith({
    bool? loading,
    List<MgmtDevice>? devices,
    Object? error,
    bool clearError = false,
    String? message,
    bool clearMessage = false,
    bool? busy,
  }) => ModConsoleState(
    loading: loading ?? this.loading,
    devices: devices ?? this.devices,
    error: clearError ? null : (error ?? this.error),
    message: clearMessage ? null : (message ?? this.message),
    busy: busy ?? this.busy,
  );
}

/// Fleet console for the admin build — the iOS mirror of the Android
/// DeviceConsole. Lists enrolled devices and queues the same commands;
/// pushing server profiles is Android-only (iOS imports them through the
/// heartbeat queue instead).
class ModConsoleController extends PageCubit<ModConsoleState> {
  ModConsoleController({ModMgmtApi? api, Future<String> Function()? url})
    : _api = api ?? ModMgmtApi.instance,
      _url = url ?? ModMgmtHeartbeat.instance.effectiveUrl,
      super(const ModConsoleState(loading: true));

  final ModMgmtApi _api;
  final Future<String> Function() _url;

  bool get enabled =>
      _api.consoleEnabled && _api.bakedAdminToken.isNotEmpty;

  /// The console follows a pinned mgmt_url re-point, not just the baked
  /// endpoint.
  Future<String> get _endpoint async {
    final url = await _url();
    return url.isNotEmpty ? url : _api.bakedUrl;
  }

  Future<void> refresh() => _run(
    (url) async => _api.devices(url, _api.bakedAdminToken),
    onResult: (devices) => state.copyWith(
      devices: devices,
      clearMessage: true,
    ),
  );

  Future<void> ban(MgmtDevice device) => _run(
    (url) async => _api.ban(url, _api.bakedAdminToken, device.device),
  );

  Future<void> unban(MgmtDevice device) => _run(
    (url) async => _api.unban(url, _api.bakedAdminToken, device.device),
  );

  /// Remote lock: queues a "lock" command the device applies on its next
  /// heartbeat.
  Future<void> lockDevice(MgmtDevice device) => _run(
    (url) async => _api.push(url, _api.bakedAdminToken, device.device, 'lock', ''),
  );

  Future<void> clearQueue(MgmtDevice device) => _run(
    (url) async => _api.clearQueue(url, _api.bakedAdminToken, device.device),
  );

  /// Android delete rules: a live device refuses deletion (its heartbeat
  /// would re-enroll it immediately); a locked device stops heartbeating
  /// past the gate and can be forgotten.
  Future<void> delete(MgmtDevice device, AppLocalizations l10n) {
    if (device.online && !device.locked) {
      emit(
        state.copyWith(
          error: l10n.modConsoleDeleteLive,
          clearMessage: true,
        ),
      );
      return Future.value();
    }
    return _run(
      (url) async => _api.remove(url, _api.bakedAdminToken, device.device),
    );
  }

  Future<void> sendMgmtUrl(MgmtDevice device, String rawUrl) => _run(
    (url) async => _api.push(
      url,
      _api.bakedAdminToken,
      device.device,
      'mgmt_url',
      rawUrl,
    ),
  );

  Future<void> sendMgmtUrlToAll(String rawUrl) => _run(
    (url) async => _api.push(url, _api.bakedAdminToken, 'all', 'mgmt_url', rawUrl),
  );

  void dismissError() => emit(state.copyWith(clearError: true));

  Future<void> _run(
    Future<Object?> Function(String url) body, {
    Object? Function(Object result)? onResult,
  }) async {
    if (!enabled || state.busy) return;
    emit(state.copyWith(busy: true, clearError: true, clearMessage: true));
    Object? result;
    try {
      result = await body(await _endpoint);
    } catch (error) {
      emit(state.copyWith(busy: false, error: error, clearMessage: true));
      return;
    }
    final queued = result is List<String> ? result.length : null;
    final next = state.copyWith(
      busy: false,
      message: queued == null ? '' : '$queued',
      clearError: true,
    );
    emit(onResult == null ? next : onResult(result));
    // Refresh the list after any mutating call, mirroring Android.
    if (onResult == null) {
      await refresh();
    }
  }
}
