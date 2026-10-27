import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onexray/main.dart' as app;
import 'package:onexray/pages/connect/page.dart';
import 'package:onexray/pages/launch/setup/view.dart';

/// First-run smoke flow on a real iOS simulator: launch, walk the setup
/// wizard (privacy, region) and land on the connect page. Guards against
/// regressions in startup, the native bridge and the mod gates.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first run setup completes and opens the connect page', (
    tester,
  ) async {
    app.main(const []);

    await _awaitFound(tester, find.text('Agree and continue'));
    await _tapAndAwait(
      tester,
      find.text('Agree and continue'),
      find.text('Get ready to connect'),
    );

    // The device region may be preloaded a few seconds after the step
    // renders, enabling "Go to Home" without any manual choice; give that
    // preload a window before falling back to picking a region by hand.
    if (await _awaitRegionReady(tester)) {
      // Choose the first supported region and confirm the selection.
      await _tapAndAwait(
        tester,
        find.text('Choose your country or region'),
        _regionTiles,
      );
      await _tapAndAwait(tester, _regionTiles.first, _selectedTiles);
      await _tapUntilGone(
        tester,
        find.text('Done'),
        find.text('Direct regions'),
      );
    }

    await _tapAndAwait(
      tester,
      find.text('Go to Home'),
      find.byType(ConnectPage),
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// Waits for the region preload; returns true when a manual region choice
/// is still required after the preload window elapsed. Tapping the region
/// row while the preload swaps its label silently does nothing, so the
/// manual path only starts once the row has stayed pending for a while.
Future<bool> _awaitRegionReady(WidgetTester tester) async {
  final button = find.ancestor(
    of: find.text('Go to Home'),
    matching: find.byType(FilledButton),
  );
  final preloadWindow = DateTime.now().add(const Duration(seconds: 45));
  final deadline = DateTime.now().add(const Duration(seconds: 240));
  while (true) {
    final enabled =
        button.evaluate().isNotEmpty &&
        tester.widget<FilledButton>(button).enabled;
    if (enabled) return false;
    if (find.text('Choose your country or region').evaluate().isNotEmpty &&
        DateTime.now().isAfter(preloadWindow)) {
      return true;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Setup step never became ready. '
        '${_setupDump(tester)} On screen: ${_screenTexts(tester)}',
      );
    }
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Finder get _regionTiles => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics &&
      widget.properties.checked != null &&
      widget.properties.inMutuallyExclusiveGroup == true,
);

Finder get _selectedTiles => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.checked == true,
);

/// Pumps frames until [finder] resolves. The app keeps animating during
/// startup and setup, so pumpAndSettle would never settle.
Future<void> _awaitFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 180),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $finder. On screen: ${_screenTexts(tester)}');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// All rendered text labels, for failure messages: integration runs have no
/// screenshots, so this is the only way to see which screen stalled.
String _screenTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data)
    .whereType<String>()
    .join(' | ');

/// Setup wizard internals, to tell a stalled prepare from a stuck button.
String _setupDump(WidgetTester tester) {
  final views = tester.widgetList<SetupView>(find.byType(SetupView)).toList();
  if (views.isEmpty) return 'no SetupView';
  final view = views
      .map(
        (view) =>
            'step=${view.state.step.name} busy=${view.state.busy} '
            'localReady=${view.state.localReady} regions=${view.state.regions} '
            'active=${view.state.activeAction} failure=${view.state.failure}',
      )
      .join(' ; ');
  final progress = find.byType(LinearProgressIndicator).evaluate().length;
  return '[$view] progressBars=$progress';
}

/// Taps [tapFinder] until [expectFinder] shows up. Wizard buttons stay
/// disabled while their action is busy, so an early single tap may be lost.
Future<void> _tapAndAwait(
  WidgetTester tester,
  Finder tapFinder,
  Finder expectFinder, {
  Duration timeout = const Duration(seconds: 180),
}) async {
  await _awaitFound(tester, tapFinder, timeout: timeout);
  final deadline = DateTime.now().add(timeout);
  var lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  while (expectFinder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Timed out after tapping $tapFinder, waiting for $expectFinder. '
        'On screen: ${_screenTexts(tester)}',
      );
    }
    if (tapFinder.evaluate().isNotEmpty &&
        DateTime.now().isAfter(lastTap.add(const Duration(seconds: 2)))) {
      await tester.tap(tapFinder.first);
      lastTap = DateTime.now();
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Taps [tapFinder] until [goneFinder] disappears from the tree.
Future<void> _tapUntilGone(
  WidgetTester tester,
  Finder tapFinder,
  Finder goneFinder, {
  Duration timeout = const Duration(seconds: 180),
}) async {
  await _awaitFound(tester, tapFinder, timeout: timeout);
  final deadline = DateTime.now().add(timeout);
  var lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  while (goneFinder.evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'Timed out after tapping $tapFinder, waiting for $goneFinder to go. '
        'On screen: ${_screenTexts(tester)}',
      );
    }
    if (tapFinder.evaluate().isNotEmpty &&
        DateTime.now().isAfter(lastTap.add(const Duration(seconds: 2)))) {
      await tester.tap(tapFinder.first);
      lastTap = DateTime.now();
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}
