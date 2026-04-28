// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:health_coaching_app/main.dart';

void main() {
  testWidgets('Health Coaching App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const HealthCoachingApp());

    // Verify that our app loads with the expected title
    expect(find.text('Today\'s Health'), findsOneWidget);
    expect(find.text('Health Coaching'), findsOneWidget);
    
    // Verify health metric cards are present
    expect(find.text('Steps Today'), findsOneWidget);
    expect(find.text('Resting Heart Rate'), findsOneWidget);
    expect(find.text('Sleep Duration'), findsOneWidget);
    
    // Verify the app has a refresh indicator (pull to refresh)
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });
}
