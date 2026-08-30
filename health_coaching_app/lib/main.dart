import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/home_shell.dart';

/// Main entry point for the Health Coaching App
void main() {
  runApp(const HealthCoachingApp());
}

/// Root widget for the Health Coaching application
/// Configures app-wide theme and navigation
class HealthCoachingApp extends StatelessWidget {
  const HealthCoachingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Health Coaching',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // Dark mode Apple-inspired color scheme
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A84FF), // Apple blue for dark mode
          brightness: Brightness.dark,
          surface: const Color(0xFF1C1C1E), // iOS dark background
          onSurface: const Color(0xFFFFFFFF), // iOS dark text
        ),
        useMaterial3: true,
        
        // Barlow font typography for dark mode (modern alternative to Baga)
        textTheme: GoogleFonts.barlowTextTheme(
          ThemeData.dark().textTheme.copyWith(
            headlineLarge: GoogleFonts.barlow(
              fontSize: 34,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.5,
              color: const Color(0xFFFFFFFF),
            ),
            headlineMedium: GoogleFonts.barlow(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              letterSpacing: -0.3,
              color: const Color(0xFFFFFFFF),
            ),
            titleLarge: GoogleFonts.barlow(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: const Color(0xFFFFFFFF),
            ),
            bodyLarge: GoogleFonts.barlow(
              fontSize: 17,
              fontWeight: FontWeight.w400,
              letterSpacing: -0.2,
              color: const Color(0xFFFFFFFF),
            ),
            bodyMedium: GoogleFonts.barlow(
              fontSize: 15,
              fontWeight: FontWeight.w400,
              letterSpacing: -0.1,
              color: const Color(0xFFFFFFFF),
            ),
          ),
        ),
        
        // Dark mode card design
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFF2C2C2E), // Dark card background
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
        
        // Dark mode buttons
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            backgroundColor: const Color(0xFF0A84FF),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: GoogleFonts.barlow(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
        ),
        
        // Dark mode app bar
        appBarTheme: AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: const Color(0xFF000000),
          foregroundColor: const Color(0xFFFFFFFF),
          titleTextStyle: GoogleFonts.barlow(
            fontSize: 34,
            fontWeight: FontWeight.bold,
            color: const Color(0xFFFFFFFF),
            letterSpacing: -0.5,
          ),
        ),
      ),
      home: const HomeShell(),
    );
  }
}
