import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real, persisted app settings - local device storage only (SharedPreferences),
/// never sent anywhere, same local-first principle as the rest of the app.
/// A ChangeNotifier singleton so any screen can listen and rebuild live when
/// a setting changes (e.g. main.dart's theme, today_screen.dart's accent).
class AppSettings extends ChangeNotifier {
  static final AppSettings _instance = AppSettings._internal();
  factory AppSettings() => _instance;
  AppSettings._internal();

  static const String _keyAccentColorIndex = 'accent_color_index';
  static const String _keyUseSamsungHealthData = 'use_samsung_health_data';

  /// A handful of real presets rather than a full color wheel - simple,
  /// unambiguous, and covers the common "which accent do you want" ask.
  static const List<AccentOption> accentOptions = [
    AccentOption('Blue', Color(0xFF007AFF)),
    AccentOption('Green', Color(0xFF34C759)),
    AccentOption('Red', Color(0xFFFF3B30)),
    AccentOption('Orange', Color(0xFFFF9500)),
    AccentOption('Purple', Color(0xFFAF52DE)),
    AccentOption('Teal', Color(0xFF5AC8FA)),
  ];

  int _accentColorIndex = 0;
  // Defaults to true: matches the app's existing behavior before this
  // setting existed (attempt real Health Connect/HealthKit data, fall back
  // to simulated only on denied/unsupported). Turning this off forces
  // simulated data even when real data would otherwise be available - an
  // explicit, honest override for demoing or troubleshooting.
  bool _useSamsungHealthData = true;
  bool _loaded = false;

  Color get accentColor => accentOptions[_accentColorIndex].color;
  int get accentColorIndex => _accentColorIndex;
  bool get useSamsungHealthData => _useSamsungHealthData;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final storedIndex = prefs.getInt(_keyAccentColorIndex) ?? 0;
    _accentColorIndex = storedIndex.clamp(0, accentOptions.length - 1);
    _useSamsungHealthData = prefs.getBool(_keyUseSamsungHealthData) ?? true;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setAccentColorIndex(int index) async {
    if (index == _accentColorIndex) return;
    _accentColorIndex = index;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyAccentColorIndex, index);
  }

  Future<void> setUseSamsungHealthData(bool value) async {
    if (value == _useSamsungHealthData) return;
    _useSamsungHealthData = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseSamsungHealthData, value);
  }
}

class AccentOption {
  final String name;
  final Color color;
  const AccentOption(this.name, this.color);
}
