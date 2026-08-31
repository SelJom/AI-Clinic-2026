// Regression coverage for the responsive shell added to fix two real UX
// complaints from running the app on a wide viewport: opening the AI coach
// meant losing sight of the rest of the app, and a single narrow column
// left most of a wide window looking empty. Verifies both breakpoints
// actually produce the intended layout, not just that HomeShell compiles.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_coaching_app/screens/home_shell.dart';

void main() {
  group('HomeShell', () {
    testWidgets(
      'Given a narrow (phone-width) viewport, When HomeShell builds, '
      'Then it shows only the Today screen - no always-visible chat panel',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(const MaterialApp(home: HomeShell()));
        await tester.pumpAndSettle(const Duration(seconds: 10));

        expect(find.text('Summary'), findsOneWidget);
        // The persistent chat panel only exists in the wide layout - on
        // narrow, "Ask Coach" reaches it via a full-screen push instead.
        expect(find.text('AI Health Coach'), findsNothing);
        expect(find.text('Ask Coach'), findsOneWidget);
      },
    );

    testWidgets(
      'Given a wide (desktop-width) viewport, When HomeShell builds, '
      'Then Today and the AI coach chat panel are both visible side by side',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(const MaterialApp(home: HomeShell()));
        await tester.pumpAndSettle(const Duration(seconds: 10));

        expect(find.text('Summary'), findsOneWidget);
        expect(find.text('AI Health Coach'), findsOneWidget);
        // Redundant once the panel is always visible - should be hidden.
        expect(find.text('Ask Coach'), findsNothing);
        expect(find.text('Care Team'), findsOneWidget);
      },
    );

    testWidgets(
      'Given the viewport width sits exactly at the breakpoint, When '
      'HomeShell builds, Then it takes the wide (>=) path',
      (WidgetTester tester) async {
        tester.view.physicalSize = Size(HomeShell.wideBreakpoint, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(const MaterialApp(home: HomeShell()));
        await tester.pumpAndSettle(const Duration(seconds: 10));

        expect(find.text('AI Health Coach'), findsOneWidget);
      },
    );
  });
}
