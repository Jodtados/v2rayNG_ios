import 'package:flutter/widgets.dart';
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
      find.text('Choose your country or region'),
    );

    // Choose the first supported region and confirm the selection.
    await _tapAndAwait(
      tester,
      find.text('Choose your country or region'),
      _regionTiles,
    );
    await _tapAndAwait(tester, _regionTiles.first, _selectedTiles);
    await _tapUntilGone(tester, find.text('Done'), find.text('Direct regions'));

    await _tapAndAwait(
      tester,
      find.text('Go to Home'),
      find.byType(ConnectPage),
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Finder get _regionTiles => find.byWidgetPredicate(
  (widget) =>
      widget is Semantics &&
      widget.properties.checked != null &&
      widget.properties.inMutuallyExclusiveGroup,
);

Finder get _selectedTiles => find.byWidgetPredicate(
  (widget) => widget is Semantics && widget.properties.checked == true,
);

/// Pumps frames until [finder] resolves. The app keeps animating during
/// startup and setup, so pumpAndSettle would never settle.
Future<void> _awaitFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for $finder');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Taps [tapFinder] until [expectFinder] shows up. Wizard buttons stay
/// disabled while their action is busy, so an early single tap may be lost.
Future<void> _tapAndAwait(
  WidgetTester tester,
  Finder tapFinder,
  Finder expectFinder, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  await _awaitFound(tester, tapFinder, timeout: timeout);
  final deadline = DateTime.now().add(timeout);
  var lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  while (expectFinder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after tapping $tapFinder, waiting for $expectFinder');
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
  Duration timeout = const Duration(seconds: 120),
}) async {
  await _awaitFound(tester, tapFinder, timeout: timeout);
  final deadline = DateTime.now().add(timeout);
  var lastTap = DateTime.fromMillisecondsSinceEpoch(0);
  while (goneFinder.evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after tapping $tapFinder, waiting for $goneFinder to go');
    }
    if (tapFinder.evaluate().isNotEmpty &&
        DateTime.now().isAfter(lastTap.add(const Duration(seconds: 2)))) {
      await tester.tap(tapFinder.first);
      lastTap = DateTime.now();
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}
