// Basic smoke test for the app shell. Rewritten because it was asserting
// text from an earlier UI redesign ("Today's Health", "Steps Today") that no
// longer exists anywhere in the app - it would have failed the moment
// anyone actually ran `flutter test`, which nobody had (flutter wasn't even
// installed in the dev environment until this was verified live).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_coaching_app/main.dart';

void main() {
  testWidgets(
    'Given the app launches, When it loads, Then it shows the Summary '
    'screen with today\'s health metric cards',
    (WidgetTester tester) async {
      await tester.pumpWidget(const HealthCoachingApp());
      // Health data load + a (failing, in a test environment with no
      // backend running) sync attempt both need to settle before assertions.
      await tester.pumpAndSettle(const Duration(seconds: 10));

      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Steps'), findsOneWidget);
      expect(find.text('Heart Rate'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsOneWidget);

      // "AI Coach" and "Calories" sit further down this scrollable list than
      // the default test viewport shows - CustomScrollView/SliverList only
      // materialize what's actually laid out, so scroll before asserting on
      // them (this isn't a real user-facing issue, just this test's
      // viewport being shorter than a real phone screen).
      await tester.scrollUntilVisible(find.text('AI Coach'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('AI Coach'), findsOneWidget);
      expect(find.text('Calories'), findsOneWidget);
    },
  );
}
