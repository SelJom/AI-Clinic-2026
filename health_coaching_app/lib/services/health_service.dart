import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_settings.dart';

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

  /// SLEEP_IN_BED is an iOS/HealthKit-only type in the `health` plugin - it
  /// is simply absent from the plugin's Android type map (verified directly
  /// in the installed package source: `dataTypeKeysAndroid` in
  /// heath_data_types.dart has no SLEEP_IN_BED entry, and the Kotlin-side
  /// `mapToType` used by hasPermissions/isDataTypeAvailable/read has no
  /// SLEEP_IN_BED -> Record mapping either). Requesting it on Android is
  /// silently a no-op: isDataTypeAvailable() returns false before any real
  /// query runs, Health Connect never even shows a "Sommeil" permission
  /// category to grant, and every call fell through to the simulated 7.75h
  /// constant - confirmed live (device logcat showed STEPS/ACTIVE_ENERGY
  /// query lines but never one for sleep, and the app's Sleep card matched
  /// the simulated value exactly). SLEEP_SESSION is the real Health Connect
  /// analog - Samsung Health writes one SleepSessionRecord per night to it.
  static HealthDataType get _sleepType =>
      Platform.isIOS ? HealthDataType.SLEEP_IN_BED : HealthDataType.SLEEP_SESSION;

  /// Health data types we need for the app. HEART_RATE (regular samples) is
  /// listed alongside RESTING_HEART_RATE (a distinct Health Connect record
  /// type, `RestingHeartRateRecord`) deliberately - confirmed live on a real
  /// Samsung device that Samsung Health writes frequent regular HEART_RATE
  /// samples (about one every 10 minutes) but never a dedicated resting-HR
  /// record, so RESTING_HEART_RATE permission alone left the heart-rate card
  /// permanently empty even after granting access. getRestingHeartRate()
  /// below tries the dedicated record first and falls back to deriving an
  /// estimate from regular samples.
  static List<HealthDataType> get _dataTypes => [
        HealthDataType.STEPS,
        HealthDataType.RESTING_HEART_RATE,
        HealthDataType.HEART_RATE,
        _sleepType,
        HealthDataType.ACTIVE_ENERGY_BURNED, // Calories - Samsung Health syncs this to Health Connect
      ];

  /// Permissions for reading health data - one READ per entry in _dataTypes.
  static List<HealthDataAccess> get _permissions =>
      List.filled(_dataTypes.length, HealthDataAccess.READ);

  /// Health Connect / HealthKit only exist on Android/iOS. Desktop builds
  /// (this app also targets desktop, see README) have no such concept, so
  /// treat them as "always simulated" rather than letting the plugin fail.
  bool get _platformSupportsHealthData => Platform.isAndroid || Platform.isIOS;

  static const _permissionsPromptedKey = 'health_permissions_prompted_once';

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  /// Checks current permission status (all 4 types together) without
  /// prompting the user. Kept for a future "permission status" UI; per-metric
  /// reads below no longer depend on this all-or-nothing result.
  Future<bool> requestPermissions() async {
    if (!_platformSupportsHealthData) return false;
    try {
      await _ensureConfigured();
      bool? hasPermissions = await _health.hasPermissions(_dataTypes, permissions: _permissions);
      return hasPermissions ?? false;
    } catch (e) {
      debugPrint('Error checking health permissions: $e');
      return false;
    }
  }

  /// Shows the OS permission dialog (Health Connect consent screen /
  /// HealthKit authorization sheet) and returns whether ALL 4 types ended up
  /// granted. The dialog itself always lists every type with its own
  /// checkbox - the user can grant some and deny others in that single
  /// dialog, which is exactly the case _canUseReal() below handles per
  /// metric; this return value is only a convenience summary.
  Future<bool> requestPermissionsForRealDevice() async {
    if (!_platformSupportsHealthData) return false;
    try {
      await _ensureConfigured();
      await _health.requestAuthorization(_dataTypes, permissions: _permissions);
      bool? hasPermissions = await _health.hasPermissions(_dataTypes, permissions: _permissions);
      return hasPermissions ?? false;
    } catch (e) {
      debugPrint('Error requesting health permissions: $e');
      return false;
    }
  }

  /// Triggers the OS consent dialog for all 4 types together exactly once
  /// per install (tracked in SharedPreferences, not just in-memory, so it
  /// survives app restarts) - Health Connect/HealthKit show one dialog
  /// listing every type regardless of how many types we ask for at once, so
  /// batching this way means one prompt instead of up to four. If the user
  /// grants some types and denies others in that single dialog, each getter
  /// below still finds out per-type via _canUseReal() on every call - this
  /// just avoids re-nagging with the OS dialog after the first ask.
  Future<void> _ensurePromptedOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_permissionsPromptedKey) == true) return;
      await requestPermissionsForRealDevice();
      await prefs.setBool(_permissionsPromptedKey, true);
    } catch (e) {
      debugPrint('Error prompting for health permissions: $e');
    }
  }

  /// Whether a specific metric can be read from the real device: checked
  /// independently per HealthDataType, NOT gated on every other type also
  /// being granted. Real bug this replaces: the previous version checked
  /// hasPermissions() against all 4 types as one bundle, so granting Steps +
  /// Heart Rate but denying Sleep made the app fall back to simulated data
  /// for ALL FOUR metrics, including the two that were actually granted.
  /// Samsung Health / Health Connect very commonly end up partially granted
  /// (e.g. no ECG-capable watch paired, or the user declines one type in the
  /// consent dialog), so that all-or-nothing check meant real data rarely
  /// got used at all in practice.
  Future<bool> _canUseReal(HealthDataType type, HealthDataAccess access) async {
    if (!_platformSupportsHealthData) return false;
    // Explicit user override (Settings > "Use Samsung Health data") - forces
    // simulated data even when real data would otherwise be available.
    if (!AppSettings().useSamsungHealthData) return false;
    try {
      await _ensureConfigured();
      if (!_health.isDataTypeAvailable(type)) return false;
      await _ensurePromptedOnce();
      bool? hasPermission = await _health.hasPermissions([type], permissions: [access]);
      return hasPermission == true;
    } catch (e) {
      debugPrint('Error checking permission for $type: $e');
      return false;
    }
  }

  /// Get steps count for today
  Future<int?> getSteps() async {
    try {
      bool canUseReal = await _canUseReal(HealthDataType.STEPS, HealthDataAccess.READ);
      if (!canUseReal) {
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
      debugPrint('Error fetching steps from Health Connect/HealthKit: $e');
      return _getSimulatedSteps();
    }
  }

  /// Get active calories burned today
  Future<double?> getCalories() async {
    try {
      bool canUseReal = await _canUseReal(HealthDataType.ACTIVE_ENERGY_BURNED, HealthDataAccess.READ);
      if (!canUseReal) {
        return _getSimulatedCalories();
      }

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);

      List<HealthDataPoint> healthData = await _health.getHealthDataFromTypes(
        types: [HealthDataType.ACTIVE_ENERGY_BURNED],
        startTime: startOfDay,
        endTime: now,
      );

      if (healthData.isNotEmpty) {
        double totalCalories = 0;
        for (var point in healthData) {
          if (point.value is NumericHealthValue) {
            totalCalories += (point.value as NumericHealthValue).numericValue.toDouble();
          }
        }
        return totalCalories;
      }

      return 0; // Tried, found no data for today yet.
    } catch (e) {
      debugPrint('Error fetching calories from Health Connect/HealthKit: $e');
      return _getSimulatedCalories();
    }
  }

  /// Generate realistic demo steps data for presentation
  int _getSimulatedSteps() {
    return 8247;
  }

  /// Generate realistic demo calories data for presentation
  double _getSimulatedCalories() {
    return 412.0;
  }

  /// Generate realistic demo heart rate data for presentation
  double _getSimulatedHeartRate() {
    return 68.5;
  }

  /// Generate realistic demo sleep duration for presentation
  double _getSimulatedSleepDuration() {
    return 7.75;
  }

  /// Get resting heart rate, preferring a real dedicated resting-HR record
  /// and falling back to an estimate derived from regular heart-rate samples
  /// when the source (e.g. Samsung Health) never writes one - see the
  /// _dataTypes comment above for why both are requested.
  Future<double?> getRestingHeartRate() async {
    try {
      bool anyRealSourceGranted = false;

      if (await _canUseReal(HealthDataType.RESTING_HEART_RATE, HealthDataAccess.READ)) {
        anyRealSourceGranted = true;
        final now = DateTime.now();
        final weekAgo = now.subtract(const Duration(days: 7));
        final restingData = await _health.getHealthDataFromTypes(
          types: [HealthDataType.RESTING_HEART_RATE],
          startTime: weekAgo,
          endTime: now,
        );
        final avg = _averageNumeric(restingData);
        if (avg != null) return avg;
        // Permission granted but genuinely nothing recorded under this
        // record type - fall through and try regular HEART_RATE samples
        // instead of giving up here.
      }

      if (await _canUseReal(HealthDataType.HEART_RATE, HealthDataAccess.READ)) {
        anyRealSourceGranted = true;
        final now = DateTime.now();
        final dayAgo = now.subtract(const Duration(hours: 24));
        final hrData = await _health.getHealthDataFromTypes(
          types: [HealthDataType.HEART_RATE],
          startTime: dayAgo,
          endTime: now,
        );
        // No dedicated resting-state value available from this source, so
        // use the most recent regular-sample reading - this is what
        // Samsung Health's own "Heart Rate" tile shows too (the latest
        // measurement, not a derived resting estimate), so matching it
        // means our card agrees with the number the patient already sees
        // in Samsung Health instead of silently computing something else.
        final latest = _latestNumeric(hrData);
        if (latest != null) return latest;
      }

      // At least one heart-rate permission is granted and available, but
      // neither source has any data yet (e.g. just granted, nothing synced
      // from the watch since) - honest "no data" beats a fake number, same
      // as steps/calories reporting a real 0 instead of simulating.
      if (anyRealSourceGranted) return null;

      return _getSimulatedHeartRate();
    } catch (e) {
      debugPrint('Error fetching resting heart rate data: $e');
      return _getSimulatedHeartRate();
    }
  }

  double? _averageNumeric(List<HealthDataPoint> points) {
    double total = 0;
    int count = 0;
    for (final point in points) {
      if (point.value is NumericHealthValue) {
        total += (point.value as NumericHealthValue).numericValue;
        count++;
      }
    }
    return count == 0 ? null : total / count;
  }

  double? _latestNumeric(List<HealthDataPoint> points) {
    double? latestValue;
    DateTime? latestTime;
    for (final point in points) {
      if (point.value is NumericHealthValue) {
        if (latestTime == null || point.dateTo.isAfter(latestTime)) {
          latestTime = point.dateTo;
          latestValue = (point.value as NumericHealthValue).numericValue.toDouble();
        }
      }
    }
    return latestValue;
  }

  /// Get last night's sleep duration
  Future<Duration?> getSleepDuration() async {
    try {
      bool canUseReal = await _canUseReal(_sleepType, HealthDataAccess.READ);
      if (!canUseReal) {
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
        types: [_sleepType],
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
      debugPrint('Error fetching sleep data: $e');
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
      debugPrint('Error checking health data availability: $e');
      return false;
    }
  }

  /// Whether today's readings are real device data or the simulated
  /// fallback - used to honestly tag samples pushed to the backend (see
  /// BackendService.ingestToday) instead of always claiming 'watch'
  /// regardless of where the numbers actually came from. Steps is used as
  /// the representative check: in the normal flow every type is granted
  /// together in one Health Connect/HealthKit consent dialog, so steps
  /// being real is a reliable proxy for "we're in real-data mode right
  /// now" without re-running all four permission checks.
  Future<bool> isReadingRealData() => _canUseReal(HealthDataType.STEPS, HealthDataAccess.READ);

  /// Pulls historical per-day totals from [start] (inclusive) to
  /// [endExclusive] (exclusive), for the "import my health history" backfill
  /// in Settings. Each Health Connect/HealthKit type is queried ONCE across
  /// the whole range (not once per day - a month of per-day queries would be
  /// 30x the round trips), then the raw data points are bucketed into
  /// calendar days here. Days where a given metric is missing come back null
  /// for that field rather than a fabricated 0 - the backend only stores
  /// what's provided (see BackendService.ingestDay).
  Future<List<DailyHealthTotals>> getHistoricalDailyTotals(
    DateTime start,
    DateTime endExclusive,
  ) async {
    if (!await isReadingRealData()) return [];

    DateTime dayKey(DateTime t) {
      final local = t.toLocal();
      return DateTime(local.year, local.month, local.day);
    }

    final stepsByDay = <DateTime, int>{};
    final stepsPoints = await _health.getHealthDataFromTypes(
      types: [HealthDataType.STEPS],
      startTime: start,
      endTime: endExclusive,
    );
    for (final p in stepsPoints) {
      if (p.value is NumericHealthValue) {
        final k = dayKey(p.dateFrom);
        stepsByDay[k] = (stepsByDay[k] ?? 0) + (p.value as NumericHealthValue).numericValue.toInt();
      }
    }

    final caloriesByDay = <DateTime, double>{};
    if (await _canUseReal(HealthDataType.ACTIVE_ENERGY_BURNED, HealthDataAccess.READ)) {
      final caloriesPoints = await _health.getHealthDataFromTypes(
        types: [HealthDataType.ACTIVE_ENERGY_BURNED],
        startTime: start,
        endTime: endExclusive,
      );
      for (final p in caloriesPoints) {
        if (p.value is NumericHealthValue) {
          final k = dayKey(p.dateFrom);
          caloriesByDay[k] = (caloriesByDay[k] ?? 0) + (p.value as NumericHealthValue).numericValue.toDouble();
        }
      }
    }

    // Heart rate per day: same preference order as getRestingHeartRate() -
    // a real RestingHeartRateRecord for that day if one exists (averaged),
    // else the latest regular HEART_RATE sample that day (matches what
    // Samsung Health's own tile would have shown that day).
    final hrByDay = <DateTime, double>{};
    if (await _canUseReal(HealthDataType.HEART_RATE, HealthDataAccess.READ)) {
      final hrPoints = await _health.getHealthDataFromTypes(
        types: [HealthDataType.HEART_RATE],
        startTime: start,
        endTime: endExclusive,
      );
      final latestTimeByDay = <DateTime, DateTime>{};
      for (final p in hrPoints) {
        if (p.value is NumericHealthValue) {
          final k = dayKey(p.dateTo);
          if (!latestTimeByDay.containsKey(k) || p.dateTo.isAfter(latestTimeByDay[k]!)) {
            latestTimeByDay[k] = p.dateTo;
            hrByDay[k] = (p.value as NumericHealthValue).numericValue.toDouble();
          }
        }
      }
    }
    if (await _canUseReal(HealthDataType.RESTING_HEART_RATE, HealthDataAccess.READ)) {
      final restingPoints = await _health.getHealthDataFromTypes(
        types: [HealthDataType.RESTING_HEART_RATE],
        startTime: start,
        endTime: endExclusive,
      );
      final sumByDay = <DateTime, double>{};
      final countByDay = <DateTime, int>{};
      for (final p in restingPoints) {
        if (p.value is NumericHealthValue) {
          final k = dayKey(p.dateFrom);
          sumByDay[k] = (sumByDay[k] ?? 0) + (p.value as NumericHealthValue).numericValue;
          countByDay[k] = (countByDay[k] ?? 0) + 1;
        }
      }
      sumByDay.forEach((k, total) {
        hrByDay[k] = total / countByDay[k]!; // dedicated resting record wins over the regular-sample estimate
      });
    }

    final sleepMinutesByDay = <DateTime, int>{};
    if (await _canUseReal(_sleepType, HealthDataAccess.READ)) {
      final sleepPoints = await _health.getHealthDataFromTypes(
        types: [_sleepType],
        startTime: start,
        endTime: endExclusive,
      );
      for (final p in sleepPoints) {
        if (p.value is NumericHealthValue) {
          // Bucketed by wake-up (end) time, not start time, so a session
          // spanning midnight counts toward the morning it ended - same
          // convention as getSleepDuration()'s "last night" window above.
          final k = dayKey(p.dateTo);
          sleepMinutesByDay[k] =
              (sleepMinutesByDay[k] ?? 0) + (p.value as NumericHealthValue).numericValue.toInt();
        }
      }
    }

    final allDays = <DateTime>{
      ...stepsByDay.keys,
      ...caloriesByDay.keys,
      ...hrByDay.keys,
      ...sleepMinutesByDay.keys,
    }.toList()
      ..sort();

    return allDays
        .map((day) => DailyHealthTotals(
              day: day,
              steps: stepsByDay[day],
              calories: caloriesByDay[day],
              restingHeartRate: hrByDay[day],
              sleepMinutes: sleepMinutesByDay[day],
            ))
        .toList();
  }
}

/// One day's real, historically-pulled totals - see
/// HealthService.getHistoricalDailyTotals. Any field left null means that
/// metric genuinely has no data for that day, not a zero.
class DailyHealthTotals {
  final DateTime day;
  final int? steps;
  final double? calories;
  final double? restingHeartRate;
  final int? sleepMinutes;

  DailyHealthTotals({
    required this.day,
    this.steps,
    this.calories,
    this.restingHeartRate,
    this.sleepMinutes,
  });
}
