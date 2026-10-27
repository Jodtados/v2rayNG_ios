import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onexray/main.dart' as app;
import 'package:onexray/pages/connect/page.dart';

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

    // A fresh simulator may preload the region from the device region, in
    // which case the step is ready immediately and the picker never opens.
    await _awaitRegionReady(tester);
    if (find.text('Choose your country or region').evaluate().isNotEmpty) {
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

/// Resolves as soon as the configuration step either became ready (the
/// "Go to Home" button enabled) or still waits for a region choice.
Future<void> _awaitRegionReady(WidgetTester tester) async {
  final button = find.ancestor(
    of: find.text('Go to Home'),
    matching: find.byType(FilledButton),
  );
  final deadline = DateTime.now().add(const Duration(seconds: 180));
  while (button.evaluate().isEmpty ||
      !tester.widget<FilledButton>(button).enabled) {
    if (find.text('Choose your country or region').evaluate().isNotEmpty) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('Setup step never became ready. On screen: ${_screenTexts(tester)}');
    }
    await tester.pump(const Duration(milliseconds: 200));
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
