import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import '../services/backend_service.dart';

/// Shows the clinician-facing escalation summary from
/// `GET /escalation/{patientId}` (backend/health_coach/escalation.py) and
/// lets the patient share/export it. This is the actual delivery mechanism
/// that was missing: the summary itself existed in the backend already, but
/// nothing in the app surfaced it before this screen.
class EscalationScreen extends StatefulWidget {
  final String patientId;

  const EscalationScreen({super.key, required this.patientId});

  @override
  State<EscalationScreen> createState() => _EscalationScreenState();
}

class _EscalationScreenState extends State<EscalationScreen> {
  final BackendService _backendService = BackendService();
  Map<String, dynamic>? _summary;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final summary = await _backendService.getEscalationSummary(widget.patientId);
      setState(() {
        _summary = summary;
        if (summary == null) {
          _errorMessage = 'No risk assessment available yet for this patient.';
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = "Can't reach the local coaching service right now. "
            'Make sure it is running: python -m health_coach.cli serve';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _share() {
    final text = _summary?['text'] as String?;
    if (text == null) return;
    Share.share(text, subject: 'Health coach escalation summary');
  }

  Color _riskColor(String? riskLevel) {
    switch (riskLevel) {
      case 'escalate':
        return const Color(0xFFFF3B30);
      case 'elevated':
        return const Color(0xFFFF9500);
      case 'watch':
        return const Color(0xFFFFC107);
      default:
        return const Color(0xFF38EF7D);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1E),
        elevation: 0,
        title: Text(
          'Escalation Summary',
          style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_summary != null)
            IconButton(
              icon: const Icon(Icons.ios_share_rounded, color: Colors.white),
              onPressed: _share,
              tooltip: 'Share with your care team',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF007AFF)))
          : _errorMessage != null
              ? _buildError()
              : _buildSummary(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: Color(0xFFFF9500), size: 40),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: GoogleFonts.barlow(color: Colors.white, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummary() {
    final summary = _summary!;
    final riskLevel = summary['risk_level'] as String? ?? 'unknown';
    final features = (summary['features'] as Map?)?.cast<String, dynamic>() ?? {};
    final findings = (summary['findings'] as List?)?.cast<dynamic>() ?? [];
    final trend = (summary['recent_trend'] as List?)?.cast<dynamic>() ?? [];
    final color = _riskColor(riskLevel);

    return RefreshIndicator(
      onRefresh: _load,
      color: const Color(0xFF007AFF),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(Icons.monitor_heart_rounded, color: color, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        riskLevel.toUpperCase(),
                        style: GoogleFonts.barlow(color: color, fontWeight: FontWeight.bold, fontSize: 18),
                      ),
                      Text(
                        'For ${summary['day']}',
                        style: GoogleFonts.barlow(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle('Measurements vs. your baseline'),
          _measurementRow('Resting heart rate', features['resting_hr'], features['hr_baseline'], features['hr_zscore'], 'bpm'),
          _measurementRow('Sleep', features['sleep_hours'], features['sleep_baseline'], features['sleep_zscore'], 'h'),
          _measurementRow('Steps', features['steps'], features['steps_baseline'], features['steps_zscore'], ''),
          if (findings.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle('Flagged findings'),
            for (final f in findings) _findingCard(f as Map),
          ],
          if (trend.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionTitle('Recent trend'),
            for (final t in trend) _trendRow(t as Map),
          ],
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _share,
            icon: const Icon(Icons.ios_share_rounded),
            label: const Text('Share with your care team'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Generated locally from your own baseline and guideline retrieval. '
            'Not a diagnosis - for your clinician to review alongside their own judgment.',
            textAlign: TextAlign.center,
            style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: GoogleFonts.barlow(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _measurementRow(String label, dynamic value, dynamic baseline, dynamic zscore, String unit) {
    final valueText = value == null ? 'n/a' : '$value$unit';
    final baselineText = baseline == null ? 'n/a' : '$baseline$unit';
    final zscoreText = zscore == null ? '' : ' (z ${(zscore as num).toStringAsFixed(1)})';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: GoogleFonts.barlow(color: Colors.white70, fontSize: 14)),
          ),
          Expanded(
            flex: 3,
            child: Text(
              '$valueText - baseline $baselineText$zscoreText',
              style: GoogleFonts.barlow(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _findingCard(Map finding) {
    final escalate = finding['escalate'] == true;
    final citations = (finding['citations'] as List?)?.cast<dynamic>() ?? [];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: escalate ? const Color(0xFFFF3B30) : const Color(0xFF2C2C2E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${finding['title']}',
            style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
          ),
          for (final c in citations)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'guideline context: ${(c as Map)['text']}',
                style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _trendRow(Map day) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        '${day['day']}: RHR ${day['resting_hr'] ?? 'n/a'}, Sleep ${day['sleep_hours'] ?? 'n/a'}h, Steps ${day['steps'] ?? 'n/a'}',
        style: GoogleFonts.barlow(color: Colors.white60, fontSize: 13),
      ),
    );
  }
}
