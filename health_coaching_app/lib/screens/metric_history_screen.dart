import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/backend_service.dart';

enum HistoryPeriod { daily, weekly, monthly }

/// Focused history view for a single metric (steps, heart rate, sleep, or
/// calories), reached by tapping its card on the Summary screen. Backed by
/// `GET /trend/{patientId}?period=...` - real stored rows/periods only,
/// same "never invent data" principle as the rest of the app; a week or
/// month with partial coverage says so via `day_count` rather than quietly
/// implying full coverage.
class MetricHistoryScreen extends StatefulWidget {
  final String patientId;
  final String metricKey; // 'resting_hr' | 'sleep_hours' | 'steps' | 'calories'
  final String title;
  final String unit;
  final Color color;
  final int digits;

  const MetricHistoryScreen({
    super.key,
    required this.patientId,
    required this.metricKey,
    required this.title,
    required this.unit,
    this.color = const Color(0xFF007AFF),
    this.digits = 0,
  });

  @override
  State<MetricHistoryScreen> createState() => _MetricHistoryScreenState();
}

class _MetricHistoryScreenState extends State<MetricHistoryScreen> {
  final BackendService _backendService = BackendService();

  HistoryPeriod _period = HistoryPeriod.daily;
  List<Map<String, dynamic>>? _entries;
  bool _isLoading = true;
  bool _backendReachable = true;

  static const Map<HistoryPeriod, String> _periodParam = {
    HistoryPeriod.daily: 'daily',
    HistoryPeriod.weekly: 'weekly',
    HistoryPeriod.monthly: 'monthly',
  };

  // How far back to ask the backend for, per period - a wider raw window
  // for weekly/monthly since aggregation compresses many days into few
  // buckets. The backend only ever returns real rows regardless of this
  // number, so asking for more than actually exists is harmless.
  static const Map<HistoryPeriod, int> _daysLookback = {
    HistoryPeriod.daily: 30,
    HistoryPeriod.weekly: 180,
    HistoryPeriod.monthly: 400,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final response = await _backendService.getTrend(
      widget.patientId,
      days: _daysLookback[_period]!,
      period: _periodParam[_period]!,
    );
    if (!mounted) return;
    setState(() {
      _backendReachable = response != null;
      if (response == null) {
        _entries = null;
      } else {
        _entries = (_period == HistoryPeriod.daily
                ? response['days'] as List
                : response['periods'] as List)
            .cast<Map<String, dynamic>>();
      }
      _isLoading = false;
    });
  }

  void _setPeriod(HistoryPeriod p) {
    if (p == _period) return;
    setState(() => _period = p);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1E),
        elevation: 0,
        title: Text(widget.title, style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: _buildPeriodSelector(),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF007AFF)))
                : !_backendReachable
                    ? _buildError()
                    : (_entries == null || _entries!.isEmpty)
                        ? _buildEmpty()
                        : _buildContent(_entries!),
          ),
        ],
      ),
    );
  }

  Widget _buildPeriodSelector() {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(12)),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: HistoryPeriod.values.map((p) {
          final selected = p == _period;
          final label = switch (p) {
            HistoryPeriod.daily => 'Daily',
            HistoryPeriod.weekly => 'Weekly',
            HistoryPeriod.monthly => 'Monthly',
          };
          return Expanded(
            child: GestureDetector(
              onTap: () => _setPeriod(p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? widget.color : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.barlow(
                    color: selected ? Colors.white : const Color(0xFF8E8E93),
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
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
              "Can't reach the local coaching service right now. "
              'Make sure it is running: python -m health_coach.cli serve',
              textAlign: TextAlign.center,
              style: GoogleFonts.barlow(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          "No history yet for ${widget.title.toLowerCase()} - it'll appear here once you've synced a few days of data.",
          textAlign: TextAlign.center,
          style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 15),
        ),
      ),
    );
  }

  Widget _buildContent(List<Map<String, dynamic>> entries) {
    final spots = <FlSpot>[];
    for (var i = 0; i < entries.length; i++) {
      final v = entries[i][widget.metricKey];
      if (v is num) spots.add(FlSpot(i.toDouble(), v.toDouble()));
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: const Color(0xFF007AFF),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        children: [
          if (spots.length > 1) ...[
            _buildChart(spots),
            const SizedBox(height: 20),
          ],
          Text(
            'History',
            style: GoogleFonts.barlow(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          for (final e in entries.reversed) _buildHistoryRow(e),
        ],
      ),
    );
  }

  Widget _buildChart(List<FlSpot> spots) {
    return Container(
      height: 200,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(16)),
      child: LineChart(
        LineChartData(
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: const Color(0xFF2C2C2E), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) => Text(
                  value.round().toString(),
                  style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 11),
                ),
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: widget.color,
              barWidth: 3,
              dotData: FlDotData(show: spots.length <= 20),
              belowBarData: BarAreaData(show: true, color: widget.color.withValues(alpha: 0.15)),
            ),
          ],
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (touched) => touched
                  .map((s) => LineTooltipItem(
                        '${s.y.toStringAsFixed(widget.digits)}${widget.unit}',
                        GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold),
                      ))
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryRow(Map<String, dynamic> e) {
    final value = e[widget.metricKey];
    final valueText = value == null ? 'No data' : '${(value as num).toStringAsFixed(widget.digits)}${widget.unit}';

    final String label;
    String? subtitle;
    if (_period == HistoryPeriod.daily) {
      label = e['day'] as String;
    } else {
      label = '${e['period_start']} to ${e['period_end']}';
      final dayCount = e['day_count'] as int?;
      if (dayCount != null) {
        subtitle = '$dayCount day${dayCount == 1 ? '' : 's'} of data in this period';
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: const Color(0xFF1C1C1E), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle, style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 12)),
                ],
              ],
            ),
          ),
          Text(
            valueText,
            style: GoogleFonts.barlow(color: widget.color, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
