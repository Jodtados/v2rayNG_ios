import 'package:material_ui/material_ui.dart';
import 'package:onexray/pages/shared/page_cubit.dart';
import 'package:onexray/core/tools/diag_trace.dart';
import 'package:onexray/core/tools/logger.dart';
import 'package:onexray/pages/launch/route.dart';
import 'package:onexray/service/launch/bootstrap.dart';
import 'package:onexray/service/launch/app_startup.dart';

class SplashPageState {
  final String? route;
  final bool failed;
  final Object? error;

  const SplashPageState({this.route, this.failed = false, this.error});

  factory SplashPageState.initial() => const SplashPageState();

  SplashPageState navigate(String route) => SplashPageState(route: route);
}

class SplashController extends PageCubit<SplashPageState> {
  SplashController() : super(SplashPageState.initial()) {
    WidgetsBinding.instance.addPostFrameCallback((_) => retry());
  }

  Future<void> retry() async {
    emit(const SplashPageState());
    diagTrace('SPLASH retry-enter');
    try {
      final destination = await LaunchBootstrapService().resolveDestination();
      diagTrace('SPLASH resolved route=${destination.route}');
      if (isPageActive) {
        emit(state.navigate(destination.route));
      }
    } catch (e, stackTrace) {
      diagTrace(
        'SPLASH error $e | ${stackTrace.toString().replaceAll('\n', ' | ')}',
      );
      ygLogger("initRouter error: $e\n$stackTrace");
      try {
        await AppStartupService().showMainWindow();
      } catch (_) {
        // Keep the original preparation failure and its retry path.
      }
      if (isPageActive) {
        emit(SplashPageState(failed: true, error: e));
      }
    }
  }
}
