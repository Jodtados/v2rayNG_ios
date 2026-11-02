import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:onexray/core/pigeon/flutter_api.dart';
import 'package:onexray/core/pigeon/host_api.dart';
import 'package:onexray/core/pigeon/messages.g.dart';
import 'package:onexray/core/tools/diag_trace.dart';
import 'package:onexray/core/tools/platform.dart';
import 'package:onexray/pages/main/router.dart';
import 'package:onexray/service/launch/app_startup.dart';
import 'package:onexray/service/mod/rotation/service.dart';
import 'package:onexray/service/mod/traffic/guard.dart';
import 'package:onexray/service/shared/menu/short_cut/service.dart';
import 'package:onexray/service/shared/menu/settings/service.dart';
import 'package:onexray/service/shared/menu/window/service.dart';
import 'package:onexray/service/shared/share/service.dart';
import 'package:onexray/service/shared/apple_widget/service.dart';

const _desktopWindowSize = Size(1160, 720);
const _minimumDesktopWindowSize = Size(480, 600);

String _flatStack(StackTrace? stack) =>
    stack?.toString().replaceAll('\n', ' | ') ?? '';

Future<void> main(List<String> _) async {
  diagTrace('STEP main-enter');
  FlutterError.onError = (details) {
    diagTrace(
      'FLUTTER_ERROR ${details.exception} | ${_flatStack(details.stack)}',
    );
  };
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        diagTrace('DISPATCHER_ERROR $error | ${_flatStack(stack)}');
        return true;
      };
      diagTrace('STEP binding-ready');

      await ShortCutService().initialize();
      diagTrace('STEP shortcut-init');
      ShareService().startAppLinks();
      await _initBridge();
      diagTrace('STEP bridge-init');
      await AppleWidgetService().initialize();
      diagTrace('STEP apple-widget-init');
      final appStartup = AppStartupService();
      await appStartup.prepare();
      diagTrace('STEP app-startup-prepare');
      await ModTrafficGuard().start();
      diagTrace('STEP traffic-guard-start');
      await ModRotationService().start();
      diagTrace('STEP rotation-start');

      if (AppPlatform.isDesktop) {
        await WindowService().prepare(
          size: _desktopWindowSize,
          minimumSize: _minimumDesktopWindowSize,
        );
      }

      MacOSSettingsMenuService().initialize();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => diagTrace('STEP first-frame-rendered'),
      );
      runApp(GoRouteApp());
      diagTrace('STEP run-app-called');
      Timer.periodic(const Duration(seconds: 2), (timer) {
        diagTrace('TICK ${timer.tick}');
        if (timer.tick >= 15) timer.cancel();
      });
      // Hidden windows may not render frames. Keep visibility independent from
      // first-frame callbacks and preserve the existing hidden-start policy.
      await appStartup.onWindowReady();
      diagTrace('STEP window-ready');
    },
    (error, stack) {
      diagTrace('ZONE_ERROR $error | ${_flatStack(stack)}');
    },
  );
}

Future<void> _initBridge() async {
  BridgeFlutterApi.setUp(AppFlutterApi());
  await AppHostApi().initTunFilesDir();
}
