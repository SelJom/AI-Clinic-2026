import 'package:flutter/material.dart';
import 'ai_chat_screen.dart';
import 'today_screen.dart';

/// Must match TodayScreen's own patient id (health_coach's local single-user
/// prototype id) - duplicated here rather than shared via TodayScreen's
/// private state, to embed the chat panel without reaching into TodayScreen
/// internals.
const String _patientId = 'local-user';

/// Responsive root of the app.
///
/// On narrow (phone-width) screens: just TodayScreen, reaching the AI coach
/// via its existing full-screen push - the correct, unchanged native mobile
/// pattern.
///
/// On wide screens (desktop browser, tablet landscape): TodayScreen and the
/// AI coach chat side by side, both always visible. This is a direct fix for
/// two things found by actually running the app on a wide viewport: opening
/// the coach via a full-screen push meant losing sight of the rest of the
/// app entirely, and a single narrow mobile-shaped column left most of a
/// wide window looking empty. Neither of those exist on an actual phone,
/// which is why the narrow path below is untouched.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  /// Below this width, behave exactly like a phone. Chosen to cover tablet
  /// landscape and up, not just desktop.
  static const double wideBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < wideBreakpoint) {
          return const TodayScreen();
        }
        return Scaffold(
          backgroundColor: const Color(0xFF000000),
          body: Row(
            children: [
              const Expanded(flex: 3, child: TodayScreen(embedded: true)),
              const VerticalDivider(width: 1, thickness: 1, color: Color(0xFF1C1C1E)),
              Expanded(
                flex: 2,
                child: AIChatScreen(patientId: _patientId, embedded: true),
              ),
            ],
          ),
        );
      },
    );
  }
}
