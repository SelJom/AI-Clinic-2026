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
  Future<Map<String, dynamic>?> ingestToday({
    required String patientId,
    required int steps,
    required double restingHeartRate,
    required int sleepMinutes,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final body = jsonEncode({
      'patient_id': patientId,
      'samples': [
        {'signal': 'steps', 'value': steps.toDouble(), 'timestamp': now, 'source': 'watch'},
        {'signal': 'resting_heart_rate', 'value': restingHeartRate, 'timestamp': now, 'source': 'watch'},
        {'signal': 'sleep_minutes', 'value': sleepMinutes.toDouble(), 'timestamp': now, 'source': 'watch'},
      ],
    });

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
