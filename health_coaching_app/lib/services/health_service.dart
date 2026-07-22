import 'dart:io' show Platform;
import 'package:health/health.dart';

/// Service class responsible for managing health data access and permissions.
/// Handles HealthKit (iOS) and Health Connect (Android) integration.
///
/// IMPORTANT: the `health` package (v13+) removed its singleton pattern -
/// `Health()` is a plain constructor that returns a *new* instance every
/// call, and the docs require `configure()` to be called once before the
/// plugin is used at all. The previous version of this file called
/// `Health()` fresh in every method and never called `configure()` -
/// this rewrite fixes both by keeping one instance (`_health`) for the
/// lifetime of this singleton service, configured lazily on first use.
class HealthService {
  static final HealthService _instance = HealthService._internal();
  factory HealthService() => _instance;
  HealthService._internal();

  final Health _health = Health();
  bool _configured = false;

  /// Health data types we need for the app
  static const List<HealthDataType> _dataTypes = [
    HealthDataType.STEPS,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.SLEEP_IN_BED, // Better for sleep tracking
  ];

  /// Permissions for reading health data
  static const List<HealthDataAccess> _permissions = [
    HealthDataAccess.READ,
    HealthDataAccess.READ,
    HealthDataAccess.READ,
  ];

  /// Health Connect / HealthKit only exist on Android/iOS. Desktop builds
  /// (this app also targets desktop, see README) have no such concept, so
  /// treat them as "always simulated" rather than letting the plugin fail.
  bool get _platformSupportsHealthData => Platform.isAndroid || Platform.isIOS;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  /// Checks current permission status without prompting the user.
  Future<bool> requestPermissions() async {
    if (!_platformSupportsHealthData) return false;
    try {
      await _ensureConfigured();
      bool? hasPermissions = await _health.hasPermissions(_dataTypes, permissions: _permissions);
      return hasPermissions ?? false;
    } catch (e) {
      print('Error checking health permissions: $e');
      return false;
    }
  }

  /// Shows the OS permission dialog (Health Connect consent screen /
  /// HealthKit authorization sheet) and returns whether permission was
  /// actually granted afterwards.
  Future<bool> requestPermissionsForRealDevice() async {
    if (!_platformSupportsHealthData) return false;
    try {
      await _ensureConfigured();
      await _health.requestAuthorization(_dataTypes, permissions: _permissions);
      bool? hasPermissions = await _health.hasPermissions(_dataTypes, permissions: _permissions);
      return hasPermissions ?? false;
    } catch (e) {
      print('Error requesting health permissions: $e');
      return false;
    }
  }

  /// Whether real device reads should be attempted at all: wrong platform,
  /// the plugin failing to configure, or no granted permission all fall
  /// back to simulated data rather than surfacing an error to the user -
  /// this is a health-coaching demo, not a diagnostic tool, so a graceful
  /// fallback is preferable to a crash or a blank screen.
  Future<bool> _shouldUseSimulatedData() async {
    if (!_platformSupportsHealthData) return true;
    try {
      await _ensureConfigured();
      if (!_health.isDataTypeAvailable(HealthDataType.STEPS)) return true;

      bool? hasPermissions = await _health.hasPermissions(_dataTypes, permissions: _permissions);
      if (hasPermissions == true) return false;

      // First run on this device: ask once. If the user declines, every
      // subsequent call keeps falling back to simulated data (hasPermissions
      // will keep returning false/null) rather than re-prompting each time.
      bool granted = await requestPermissionsForRealDevice();
      return !granted;
    } catch (e) {
      print('Error determining health data availability: $e');
      return true;
    }
  }

  /// Get steps count for today
  Future<int?> getSteps() async {
    try {
      bool useSimulated = await _shouldUseSimulatedData();
      if (useSimulated) {
        return _getSimulatedSteps();
      }

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);

      List<HealthDataPoint> healthData = await _health.getHealthDataFromTypes(
        types: [HealthDataType.STEPS],
        startTime: startOfDay,
        endTime: now,
      );

      if (healthData.isNotEmpty) {
        int totalSteps = 0;
        for (var point in healthData) {
          if (point.value is NumericHealthValue) {
            totalSteps += (point.value as NumericHealthValue).numericValue.toInt();
          }
        }
        return totalSteps;
      }

      return 0; // Tried, found no data for today yet.
    } catch (e) {
      print('Error fetching steps from Health Connect/HealthKit: $e');
      return _getSimulatedSteps();
    }
  }

  /// Generate realistic demo steps data for presentation
  int _getSimulatedSteps() {
    return 8247;
  }

  /// Generate realistic demo heart rate data for presentation
  double _getSimulatedHeartRate() {
    return 68.5;
  }

  /// Generate realistic demo sleep duration for presentation
  double _getSimulatedSleepDuration() {
    return 7.75;
  }

  /// Get average resting heart rate (recent data)
  Future<double?> getRestingHeartRate() async {
    try {
      bool useSimulated = await _shouldUseSimulatedData();
      if (useSimulated) {
        return _getSimulatedHeartRate();
      }

      DateTime now = DateTime.now();
      DateTime weekAgo = now.subtract(const Duration(days: 7));

      List<HealthDataPoint> healthData = await _health.getHealthDataFromTypes(
        types: [HealthDataType.RESTING_HEART_RATE],
        startTime: weekAgo,
        endTime: now,
      );

      if (healthData.isEmpty) {
        return null;
      }

      double totalHeartRate = 0;
      int count = 0;
      for (HealthDataPoint point in healthData) {
        if (point.value is NumericHealthValue) {
          totalHeartRate += (point.value as NumericHealthValue).numericValue;
          count++;
        }
      }

      if (count == 0) return null;
      return totalHeartRate / count;
    } catch (e) {
      print('Error fetching resting heart rate data: $e');
      return _getSimulatedHeartRate();
    }
  }

  /// Get last night's sleep duration
  Future<Duration?> getSleepDuration() async {
    try {
      bool useSimulated = await _shouldUseSimulatedData();
      if (useSimulated) {
        final hours = _getSimulatedSleepDuration();
        return Duration(minutes: (hours * 60).round());
      }

      DateTime now = DateTime.now();
      DateTime today6AM = DateTime(now.year, now.month, now.day, 6);
      DateTime yesterday6PM = today6AM.subtract(const Duration(hours: 12));

      if (now.hour < 12) {
        today6AM = today6AM.subtract(const Duration(days: 1));
        yesterday6PM = yesterday6PM.subtract(const Duration(days: 1));
      }

      List<HealthDataPoint> healthData = await _health.getHealthDataFromTypes(
        types: [HealthDataType.SLEEP_IN_BED],
        startTime: yesterday6PM,
        endTime: today6AM.add(const Duration(hours: 6)),
      );

      if (healthData.isEmpty) {
        return null;
      }

      Duration totalSleep = Duration.zero;
      for (HealthDataPoint point in healthData) {
        if (point.value is NumericHealthValue) {
          int minutes = (point.value as NumericHealthValue).numericValue.toInt();
          totalSleep += Duration(minutes: minutes);
        }
      }

      return totalSleep;
    } catch (e) {
      print('Error fetching sleep data: $e');
      final hours = _getSimulatedSleepDuration();
      return Duration(minutes: (hours * 60).round());
    }
  }

  /// Check if health data is available on this device
  Future<bool> isHealthDataAvailable() async {
    if (!_platformSupportsHealthData) return false;
    try {
      await _ensureConfigured();
      return _health.isDataTypeAvailable(HealthDataType.STEPS);
    } catch (e) {
      print('Error checking health data availability: $e');
      return false;
    }
  }
}
