import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/backend_service.dart';

/// Shows today's activity level and why - backed by
/// `GET /activity-summary/{patientId}`. The level itself is a deterministic
/// label (see backend/health_coach/activity.py); only the natural-language
/// explanation is AI-generated, and it's grounded through the same
/// ground_reply/ground_citations pipeline every chat reply goes through.
class ActivitySummaryScreen extends StatefulWidget {
  final String patientId;

  const ActivitySummaryScreen({super.key, required this.patientId});

  @override
  State<ActivitySummaryScreen> createState() => _ActivitySummaryScreenState();
}

class _ActivitySummaryScreenState extends State<ActivitySummaryScreen> {
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
    final summary = await _backendService.getActivitySummary(widget.patientId);
    if (!mounted) return;
    setState(() {
      _summary = summary;
      if (summary == null) {
        _errorMessage = "Can't reach the local coaching service right now, or there's no "
            "data yet today. Make sure it's running: python -m health_coach.cli serve";
      }
      _isLoading = false;
    });
  }

  Color _tierColor(String? tier) {
    switch (tier) {
      case 'positive':
        return const Color(0xFF34C759);
      case 'caution':
        return const Color(0xFFFF9500);
      case 'concern':
        return const Color(0xFFFF3B30);
      default:
        return const Color(0xFF8E8E93);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1E),
        elevation: 0,
        title: Text('Activity Level', style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF007AFF)))
          : _errorMessage != null
              ? _buildError()
              : _buildContent(_summary!),
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
            Text(_errorMessage!, textAlign: TextAlign.center, style: GoogleFonts.barlow(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 16),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(Map<String, dynamic> summary) {
    final level = summary['level'] as String? ?? 'Unknown';
    final tier = summary['tier'] as String?;
    final why = summary['summary'] as String? ?? '';
    final color = _tierColor(tier);

    return RefreshIndicator(
      onRefresh: _load,
      color: const Color(0xFF007AFF),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [color.withValues(alpha: 0.85), color],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 10))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_iconFor(tier), color: Colors.white, size: 32),
                const SizedBox(height: 16),
                Text(level, style: GoogleFonts.barlow(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text("Today's activity", style: GoogleFonts.barlow(color: Colors.white.withValues(alpha: 0.85), fontSize: 15)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('Why', style: GoogleFonts.barlow(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(16)),
            child: Text(
              why,
              style: GoogleFonts.barlow(color: Colors.white.withValues(alpha: 0.9), fontSize: 15, height: 1.5),
            ),
          ),
          const SizedBox(height: 16),
          _buildMetricsRow(summary),
          const SizedBox(height: 16),
          Text(
            'This reflects a deterministic rule based on your own data, with an AI-written '
            "explanation of it - it's not a diagnosis.",
            textAlign: TextAlign.center,
            style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsRow(Map<String, dynamic> summary) {
    final hr = summary['resting_hr'];
    final sleep = summary['sleep_hours'];
    final steps = summary['steps'];
    final calories = summary['calories'];
    return Row(
      children: [
        Expanded(child: _metricChip('HR', hr == null ? '—' : '${(hr as num).round()} bpm')),
        const SizedBox(width: 8),
        Expanded(child: _metricChip('Sleep', sleep == null ? '—' : '${(sleep as num).toStringAsFixed(1)}h')),
        const SizedBox(width: 8),
        Expanded(child: _metricChip('Steps', steps == null ? '—' : '${steps as int}')),
        const SizedBox(width: 8),
        Expanded(child: _metricChip('kcal', calories == null ? '—' : '${(calories as num).round()}')),
      ],
    );
  }

  Widget _metricChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Text(value, style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 2),
          Text(label, style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 11)),
        ],
      ),
    );
  }

  IconData _iconFor(String? tier) {
    switch (tier) {
      case 'positive':
        return Icons.emoji_events_rounded;
      case 'caution':
        return Icons.self_improvement_rounded;
      case 'concern':
        return Icons.favorite_rounded;
      default:
        return Icons.directions_walk_rounded;
    }
  }
}
