// TrendScreen calls the real BackendService (no dependency-injection point
// to mock it), so in a test environment - no backend running on
// 127.0.0.1:8765 - the network call fails fast and the honest
// "can't reach the backend" error path is what actually renders. That is
// deliberately what these tests assert on, rather than mocking the network
// layer: it's real coverage of the failure path every CI run and every
// `flutter test` invocation without a live backend will actually exercise.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_coaching_app/screens/trend_screen.dart';

void main() {
  group('TrendScreen', () {
    testWidgets(
      'Given the screen has just been pushed, When it builds the very first '
      'frame, Then it starts in the loading state (isLoading defaults true)',
      (WidgetTester tester) async {
        // flutter_test's fake HttpClient fails requests near-instantly (see
        // the framework's own warning: real network calls are never made,
        // status 400 comes back almost immediately) - by the time even one
        // pump() returns, the fetch may have already resolved to the error
        // state. So this checks the state the widget is *constructed* with,
        // via pumpWidget's own initial frame, rather than racing the fetch.
        await tester.pumpWidget(
          const MaterialApp(home: TrendScreen(patientId: 'test-patient')),
        );

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
    );

    testWidgets(
      'Given no backend is reachable, When the fetch fails, Then it shows '
      'the honest "can\'t reach" message with a Retry button, not a crash',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: TrendScreen(patientId: 'test-patient')),
        );
        await tester.pumpAndSettle(const Duration(seconds: 10));

        expect(find.textContaining("Can't reach the local coaching service"), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets(
      'Given the Trends screen, When it builds, Then the app bar title reads "Trends"',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: TrendScreen(patientId: 'test-patient')),
        );
        await tester.pumpAndSettle(const Duration(seconds: 10));

        expect(find.text('Trends'), findsOneWidget);
      },
    );

    testWidgets(
      'Given Retry is tapped after a failed fetch, When it re-fetches, '
      'Then it settles back to the same honest error state without throwing',
      (WidgetTester tester) async {
        // Doesn't assert on the intermediate loading frame: flutter_test's
        // fake HttpClient (see the framework's own warning above) can
        // resolve within the same pump() that renders the post-tap
        // rebuild, making that frame's content a genuine race rather than
        // a reliably observable state - see the first test in this file
        // for the same issue on initial load, where it *is* observable
        // because pumpWidget's frame runs before the fetch is even started.
        await tester.pumpWidget(
          const MaterialApp(home: TrendScreen(patientId: 'test-patient')),
        );
        await tester.pumpAndSettle(const Duration(seconds: 10));

        await tester.tap(find.widgetWithText(TextButton, 'Retry'));
        await tester.pumpAndSettle(const Duration(seconds: 10));

        expect(find.textContaining("Can't reach the local coaching service"), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      },
    );
  });
}
