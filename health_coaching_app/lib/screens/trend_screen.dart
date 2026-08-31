import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/backend_service.dart';

/// History/trend view - charts for resting HR, sleep, and steps over time.
/// Backed by `GET /trend/{patientId}` (backend/health_coach/api.py), which
/// returns only real stored days - this screen never pads or invents dates,
/// same principle as the deterministic chat answers in coach.py.
class TrendScreen extends StatefulWidget {
  final String patientId;

  const TrendScreen({super.key, required this.patientId});

  @override
  State<TrendScreen> createState() => _TrendScreenState();
}

class _TrendScreenState extends State<TrendScreen> {
  final BackendService _backendService = BackendService();
  List<Map<String, dynamic>>? _days;
  bool _isLoading = true;
  bool _backendReachable = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final response = await _backendService.getTrend(widget.patientId);
    if (!mounted) return;
    setState(() {
      _days = response == null ? null : (response['days'] as List).cast<Map<String, dynamic>>();
      _backendReachable = response != null;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1E),
        elevation: 0,
        title: Text('Trends', style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF007AFF)))
          : !_backendReachable
              ? _buildError()
              : (_days == null || _days!.isEmpty)
                  ? _buildEmpty()
                  : _buildCharts(_days!),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.show_chart_rounded, color: Color(0xFF8E8E93), size: 40),
            const SizedBox(height: 16),
            Text(
              "No history yet - trends will appear here once you've synced a few days of data.",
              textAlign: TextAlign.center,
              style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCharts(List<Map<String, dynamic>> days) {
    return RefreshIndicator(
      onRefresh: _load,
      color: const Color(0xFF007AFF),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (days.length < 3)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Only ${days.length} day${days.length == 1 ? '' : 's'} of history so far - '
                'trends get more useful the longer you sync.',
                style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 13),
              ),
            ),
          _TrendChart(
            title: 'Resting Heart Rate',
            unit: 'bpm',
            color: const Color(0xFFFF3B30),
            days: days,
            valueKey: 'resting_hr',
            baselineKey: 'hr_baseline',
          ),
          const SizedBox(height: 28),
          _TrendChart(
            title: 'Sleep',
            unit: 'h',
            color: const Color(0xFF5856D6),
            days: days,
            valueKey: 'sleep_hours',
            baselineKey: 'sleep_baseline',
          ),
          const SizedBox(height: 28),
          _TrendChart(
            title: 'Steps',
            unit: '',
            color: const Color(0xFF007AFF),
            days: days,
            valueKey: 'steps',
            baselineKey: 'steps_baseline',
          ),
          const SizedBox(height: 28),
          _TrendChart(
            title: 'Calories',
            unit: ' kcal',
            color: const Color(0xFFFF9500),
            days: days,
            valueKey: 'calories',
            baselineKey: 'calories_baseline',
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// One metric's line chart: the real values as a solid line, and (when
/// available) the patient's own rolling baseline as a faint reference line -
/// the same personal-baseline concept the rule engine and chat already use,
/// finally visible instead of only ever being described in text.
class _TrendChart extends StatelessWidget {
  final String title;
  final String unit;
  final Color color;
  final List<Map<String, dynamic>> days;
  final String valueKey;
  final String baselineKey;

  const _TrendChart({
    required this.title,
    required this.unit,
    required this.color,
    required this.days,
    required this.valueKey,
    required this.baselineKey,
  });

  @override
  Widget build(BuildContext context) {
    final valueSpots = <FlSpot>[];
    final baselineSpots = <FlSpot>[];
    for (var i = 0; i < days.length; i++) {
      final v = days[i][valueKey];
      if (v is num) valueSpots.add(FlSpot(i.toDouble(), v.toDouble()));
      final b = days[i][baselineKey];
      if (b is num) baselineSpots.add(FlSpot(i.toDouble(), b.toDouble()));
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: GoogleFonts.barlow(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          SizedBox(
            height: 180,
            child: valueSpots.isEmpty
                ? Center(
                    child: Text('No data', style: GoogleFonts.barlow(color: const Color(0xFF8E8E93))),
                  )
                : LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: _niceInterval(valueSpots),
                        getDrawingHorizontalLine: (_) => FlLine(color: const Color(0xFF2C2C2E), strokeWidth: 1),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 36,
                            getTitlesWidget: (value, meta) => Text(
                              value.round().toString(),
                              style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 11),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 24,
                            interval: (days.length / 4).clamp(1, days.length).ceilToDouble(),
                            getTitlesWidget: (value, meta) {
                              final i = value.round();
                              if (i < 0 || i >= days.length) return const SizedBox.shrink();
                              final day = days[i]['day'] as String; // "YYYY-MM-DD"
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  day.substring(5), // "MM-DD"
                                  style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 10),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      lineBarsData: [
                        if (baselineSpots.length > 1)
                          LineChartBarData(
                            spots: baselineSpots,
                            isCurved: false,
                            color: const Color(0xFF8E8E93),
                            barWidth: 1.5,
                            dashArray: [6, 4],
                            dotData: const FlDotData(show: false),
                          ),
                        LineChartBarData(
                          spots: valueSpots,
                          isCurved: true,
                          color: color,
                          barWidth: 3,
                          dotData: FlDotData(show: valueSpots.length <= 14),
                          belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.15)),
                        ),
                      ],
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (spots) => spots.map((s) {
                            return LineTooltipItem(
                              '${s.y.toStringAsFixed(unit == 'h' ? 1 : 0)}$unit',
                              GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ),
          ),
          if (baselineSpots.length > 1) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Container(width: 16, height: 2, color: const Color(0xFF8E8E93)),
                const SizedBox(width: 6),
                Text(
                  'Your personal baseline',
                  style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 12),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  double _niceInterval(List<FlSpot> spots) {
    if (spots.isEmpty) return 1;
    final maxY = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final minY = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final range = (maxY - minY).abs();
    if (range < 1) return 1;
    return range / 4;
  }
}
