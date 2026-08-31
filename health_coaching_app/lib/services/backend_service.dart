import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Client for the local-only Python health_coach backend
/// (`python -m health_coach.cli serve`, see backend/health_coach/api.py).
/// The backend binds 127.0.0.1:8765 and is never reached over a real
/// network - only loopback (desktop / iOS simulator) or a device-to-host
/// tunnel you set up yourself (e.g. `adb reverse tcp:8765 tcp:8765` for an
/// Android emulator/device).
class BackendUnavailableException implements Exception {
  final String message;
  BackendUnavailableException(this.message);
  @override
  String toString() => message;
}

class BackendService {
  static const String baseUrl = 'http://127.0.0.1:8765';
  static const Duration _timeout = Duration(seconds: 5);

  /// Sends today's steps/HR/sleep as wearable samples and returns the raw
  /// /ingest response (`{days_processed, latest_risk}`), or null if the
  /// backend rejected the request.
  ///
  /// `source` must honestly reflect where these numbers actually came from -
  /// 'samsung_health' for a real Health Connect read, 'simulated' for the
  /// demo fallback. Real bug this fixed: every call used to hardcode
  /// 'watch' regardless, so simulated demo numbers (the same 8247
  /// steps/68.5 bpm/7.75h every time) got stored indistinguishable from a
  /// genuine device reading - there was no way to tell them apart later, or
  /// to clean out only the fake ones without also deleting real history.
  Future<Map<String, dynamic>?> ingestToday({
    required String patientId,
    required int steps,
    required double restingHeartRate,
    required int sleepMinutes,
    double? calories,
    required String source,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final body = jsonEncode({
      'patient_id': patientId,
      'samples': [
        {'signal': 'steps', 'value': steps.toDouble(), 'timestamp': now, 'source': source},
        {'signal': 'resting_heart_rate', 'value': restingHeartRate, 'timestamp': now, 'source': source},
        {'signal': 'sleep_minutes', 'value': sleepMinutes.toDouble(), 'timestamp': now, 'source': source},
        if (calories != null)
          {'signal': 'calories', 'value': calories, 'timestamp': now, 'source': source},
      ],
    });

    final response = await http
        .post(Uri.parse('$baseUrl/ingest'), headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(_timeout);

    if (response.statusCode != 200) return null;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Ingests one historical day's totals (used for the "import history since
  /// a given date" backfill in Settings) - same /ingest endpoint as
  /// ingestToday, but for an arbitrary past day and tagged with a distinct
  /// source ('samsung_health_import' by default) so backfilled rows are
  /// identifiable from both a live real sync ('samsung_health') and old
  /// simulated-fallback rows ('simulated'/'watch'). Timestamp is pinned to
  /// local noon (converted to UTC) specifically so the backend's
  /// `timestamp.date()` day-bucketing (features.py `group_samples_by_day`)
  /// can never land on the wrong calendar day near a midnight boundary,
  /// regardless of timezone offset. Any metric left null is simply omitted
  /// for that day rather than sent as a fabricated zero.
  Future<Map<String, dynamic>?> ingestDay({
    required String patientId,
    required DateTime day,
    int? steps,
    double? restingHeartRate,
    int? sleepMinutes,
    double? calories,
    String source = 'samsung_health_import',
  }) async {
    final localNoon = DateTime(day.year, day.month, day.day, 12);
    final ts = localNoon.toUtc().toIso8601String();
    final samples = [
      if (steps != null) {'signal': 'steps', 'value': steps.toDouble(), 'timestamp': ts, 'source': source},
      if (restingHeartRate != null)
        {'signal': 'resting_heart_rate', 'value': restingHeartRate, 'timestamp': ts, 'source': source},
      if (sleepMinutes != null)
        {'signal': 'sleep_minutes', 'value': sleepMinutes.toDouble(), 'timestamp': ts, 'source': source},
      if (calories != null) {'signal': 'calories', 'value': calories, 'timestamp': ts, 'source': source},
    ];
    if (samples.isEmpty) return null;

    final body = jsonEncode({'patient_id': patientId, 'samples': samples});
    final response = await http
        .post(Uri.parse('$baseUrl/ingest'), headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(_timeout);

    if (response.statusCode != 200) return null;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Today's risk summary (`risk_level`, zscores, rule `hits`), or null if
  /// there's no data for this patient yet (backend returns 404 until the
  /// first /ingest call).
  Future<Map<String, dynamic>?> getSummary(String patientId) async {
    final response = await http.get(Uri.parse('$baseUrl/summary/$patientId')).timeout(_timeout);
    if (response.statusCode != 200) return null;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Multi-day history (`GET /trend/{patientId}`) - real stored rows/periods
  /// only, oldest to newest, never padded with invented dates. Returns the
  /// full decoded response: `period=daily` gives a `days` list (one entry
  /// per real day), `period=weekly`/`monthly` gives a `periods` list
  /// instead (see backend/health_coach/features.py's aggregate_period for
  /// what day_count means). Returns null only if the backend itself
  /// couldn't be reached - an empty list under either key means "reachable,
  /// but no history yet," which callers should tell apart from "offline."
  Future<Map<String, dynamic>?> getTrend(
    String patientId, {
    int days = 30,
    String period = 'daily',
  }) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/trend/$patientId?days=$days&period=$period'))
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Today's activity level (`GET /activity-summary/{patientId}`) - a
  /// deterministic label (never AI-guessed - see backend/health_coach/
  /// activity.py) plus an AI-generated, grounded explanation of why.
  /// Recomputed fresh server-side on every call, so it's safe to re-request
  /// this whenever real data changes meaningfully during the day. Returns
  /// null if unreachable or there's no data for today yet.
  Future<Map<String, dynamic>?> getActivitySummary(String patientId) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/activity-summary/$patientId'))
          .timeout(const Duration(seconds: 30)); // LLM generation can take longer than other calls
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Right-to-access/data-portability (`GET /patient/{patientId}/export`) -
  /// every row stored locally for this patient, as plain JSON. Returns null
  /// if the backend can't be reached.
  Future<Map<String, dynamic>?> exportPatientData(String patientId) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/patient/$patientId/export')).timeout(_timeout);
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Right-to-erasure (`DELETE /patient/{patientId}`) - permanently deletes
  /// every row for this patient across all local tables. Irreversible by
  /// design (see PRIVACY.md) - there is no soft-delete or backup to recover
  /// from. Returns the per-table row counts deleted, or null on failure.
  Future<Map<String, dynamic>?> deletePatientData(String patientId) async {
    try {
      final response = await http.delete(Uri.parse('$baseUrl/patient/$patientId')).timeout(_timeout);
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Clinician-facing escalation summary (structured fields plus a
  /// ready-to-share `text` block) - see backend/health_coach/escalation.py.
  /// Returns null if there's no risk assessment for this patient yet.
  Future<Map<String, dynamic>?> getEscalationSummary(String patientId) async {
    final response = await http.get(Uri.parse('$baseUrl/escalation/$patientId')).timeout(_timeout);
    if (response.statusCode != 200) return null;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Sends a chat message to the guideline-grounded coach and returns its
  /// reply. Throws [BackendUnavailableException] if the local backend can't
  /// be reached - callers should show a friendly fallback, not crash.
  Future<String> chat(String patientId, String message) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'patient_id': patientId, 'message': message}),
          )
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw BackendUnavailableException('Backend returned HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['reply'] as String;
    } on BackendUnavailableException {
      rethrow;
    } catch (e) {
      throw BackendUnavailableException(e.toString());
    }
  }
}
