import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/app_settings.dart';
import '../services/backend_service.dart';
import '../services/health_service.dart';
import '../widgets/animated_tap.dart';
import 'activity_summary_screen.dart';
import 'ai_chat_screen.dart';
import 'escalation_screen.dart';
import 'metric_history_screen.dart';
import 'settings_screen.dart';
import 'trend_screen.dart';

/// Main screen displaying today's health metrics
/// Shows activity level, steps, resting heart rate, sleep, and calories.
class TodayScreen extends StatefulWidget {
  /// True when shown side-by-side with an always-visible chat panel
  /// (see home_shell.dart's wide-screen layout) - hides the "Ask Coach"
  /// button in that case, since opening the coach via navigation would be
  /// redundant when it's already visible next to this screen.
  final bool embedded;

  const TodayScreen({super.key, this.embedded = false});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  final HealthService _healthService = HealthService();
  final BackendService _backendService = BackendService();

  // Single local user for this prototype - no accounts/auth yet, so the
  // backend just needs a stable id to key baselines/history against.
  static const String _patientId = 'local-user';

  // Health data state variables
  int? _steps;
  double? _restingHeartRate;
  Duration? _sleepDuration;
  double? _calories;

  // Backend coaching state
  Map<String, dynamic>? _backendSummary;
  bool _backendReachable = true;

  // Activity level (hero card) state
  Map<String, dynamic>? _activitySummary;
  bool _isLoadingActivity = false;
  // The steps/calories "bucket" the activity summary was last generated
  // for - re-fetching the AI summary on every tick would be wasteful (and
  // slow, it's an LLM call); only re-fetch when steps crosses a new 1000,
  // or calories a new 100, since the summary was last computed.
  int _lastActivityStepsBucket = 0;
  int _lastActivityCaloriesBucket = 0;

  // UI state variables
  bool _isLoading = false;
  bool _hasPermissions = false;
  String? _errorMessage;

  // "Last updated" - a real timestamp, ticking live rather than a fixed
  // "Just now" string. The same 1-minute timer also drives the threshold
  // check for refreshing the activity summary.
  DateTime? _lastUpdated;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _initializeHealthData();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) => _onTick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Runs every minute: refreshes the "last updated" display, and - only
  /// when real data has moved enough to matter (1000 steps, 100 kcal) -
  /// quietly re-syncs and refreshes the AI activity summary.
  Future<void> _onTick() async {
    if (!mounted) return;
    setState(() {}); // repaint "X min ago" even if nothing else changed
    if (!_hasPermissions) return;

    final previousSteps = _steps;
    final previousCalories = _calories;
    final results = await Future.wait([
      _healthService.getSteps(),
      _healthService.getCalories(),
    ]);
    final newSteps = results[0] as int?;
    final newCalories = results[1] as double?;
    if (!mounted) return;

    final stepsChanged = newSteps != previousSteps;
    final caloriesChanged = newCalories != previousCalories;
    if (!stepsChanged && !caloriesChanged) return;

    setState(() {
      _steps = newSteps;
      _calories = newCalories;
    });
    await _syncWithBackend();

    final stepsBucket = (newSteps ?? 0) ~/ 1000;
    final caloriesBucket = (newCalories ?? 0) ~/ 100;
    if (stepsBucket != _lastActivityStepsBucket || caloriesBucket != _lastActivityCaloriesBucket) {
      await _refreshActivitySummary();
    }
  }

  /// Initialize health data and request permissions
  Future<void> _initializeHealthData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      debugPrint('🎯 Demo mode: Loading demo health data');
      await _loadHealthData();

      setState(() {
        _hasPermissions = true; // Pretend we have permissions for demo
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading demo data: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Load all health data from the service
  Future<void> _loadHealthData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Load all health metrics concurrently for better performance
      final results = await Future.wait([
        _healthService.getSteps(),
        _healthService.getRestingHeartRate(),
        _healthService.getSleepDuration(),
        _healthService.getCalories(),
      ]);

      setState(() {
        _steps = results[0] as int?;
        _restingHeartRate = results[1] as double?;
        _sleepDuration = results[2] as Duration?;
        _calories = results[3] as double?;
        _lastUpdated = DateTime.now();
      });

      await _syncWithBackend();
      await _refreshActivitySummary();
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading health data: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Sends today's metrics to the local backend and pulls back its
  /// personalized risk assessment. Failures here are expected whenever
  /// `python -m health_coach.cli serve` isn't running - they degrade to a
  /// message in the AI Coach card rather than surfacing as a hard error,
  /// since the raw health metrics above are still perfectly usable on
  /// their own.
  Future<void> _syncWithBackend() async {
    if (_steps == null || _restingHeartRate == null || _sleepDuration == null) {
      return;
    }
    try {
      final isReal = await _healthService.isReadingRealData();
      await _backendService.ingestToday(
        patientId: _patientId,
        steps: _steps!,
        restingHeartRate: _restingHeartRate!,
        sleepMinutes: _sleepDuration!.inMinutes,
        calories: _calories,
        source: isReal ? 'samsung_health' : 'simulated',
      );
      final summary = await _backendService.getSummary(_patientId);
      if (!mounted) return;
      setState(() {
        _backendSummary = summary;
        _backendReachable = true;
        _lastUpdated = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _backendReachable = false;
      });
    }
  }

  /// Fetches the AI-explained activity level for the hero card. The label
  /// itself is deterministic (backend/health_coach/activity.py); only the
  /// "why" text is AI-generated, grounded the same way chat replies are.
  Future<void> _refreshActivitySummary() async {
    setState(() => _isLoadingActivity = true);
    final summary = await _backendService.getActivitySummary(_patientId);
    if (!mounted) return;
    setState(() {
      _activitySummary = summary;
      _isLoadingActivity = false;
      _lastActivityStepsBucket = (_steps ?? 0) ~/ 1000;
      _lastActivityCaloriesBucket = (_calories ?? 0) ~/ 100;
    });
  }

  /// Format sleep duration as "7h 45min"
  String _formatSleepDuration(Duration? duration) {
    if (duration == null) return 'No data';

    int hours = duration.inHours;
    int minutes = duration.inMinutes % 60;

    if (hours == 0) {
      return '${minutes}min';
    } else if (minutes == 0) {
      return '${hours}h';
    } else {
      return '${hours}h ${minutes}min';
    }
  }

  /// Format heart rate with proper decimal places
  String _formatHeartRate(double? heartRate) {
    if (heartRate == null) return 'No data';
    return '${heartRate.round()} bpm';
  }

  /// Format steps count
  String _formatSteps(int? steps) {
    if (steps == null) return 'No data';
    return steps.toString();
  }

  /// Format calories burned
  String _formatCalories(double? calories) {
    if (calories == null) return 'No data';
    return '${calories.round()} kcal';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: RefreshIndicator(
        onRefresh: _hasPermissions ? _loadHealthData : _initializeHealthData,
        color: AppSettings().accentColor,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // Modern App Bar - iPhone Health style
            SliverAppBar(
              expandedHeight: 120,
              floating: false,
              pinned: true,
              backgroundColor: const Color(0xFF000000),
              elevation: 0,
              flexibleSpace: FlexibleSpaceBar(
                title: LayoutBuilder(
                  builder: (context, constraints) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Summary title on the left
                        Flexible(
                          child: Text(
                            'Summary',
                            style: GoogleFonts.barlow(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFFFFFFFF),
                              letterSpacing: -0.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Profile icon on the right
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Trends button
                            IconButton(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const TrendScreen(patientId: _patientId),
                                  ),
                                );
                              },
                              icon: Icon(Icons.show_chart_rounded, color: AppSettings().accentColor, size: 20),
                              tooltip: 'Trends',
                            ),
                            // Refresh button
                            IconButton(
                              onPressed: _isLoading ? null : (_hasPermissions ? _loadHealthData : _initializeHealthData),
                              icon: _isLoading
                                  ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: AppSettings().accentColor),
                                    )
                                  : Icon(Icons.refresh_rounded, color: AppSettings().accentColor, size: 20),
                            ),
                            // Profile icon
                            AnimatedTap(
                              onTap: _showProfileMenu,
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: AppSettings().accentColor,
                                  borderRadius: BorderRadius.circular(14),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppSettings().accentColor.withValues(alpha: 0.3),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.person_rounded, color: Colors.white, size: 16),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                titlePadding: const EdgeInsets.only(left: 20, right: 20, bottom: 16),
              ),
            ),

            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 8),
                  Text(
                    _getFormattedDate(),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: const Color(0xFF8E8E93),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 24),

                  if (_errorMessage != null) ...[
                    _buildErrorCard(),
                    const SizedBox(height: 20),
                  ],

                  _buildMainMetricsGrid(),
                  const SizedBox(height: 24),
                  _buildAICoachSection(),
                  const SizedBox(height: 24),
                  _buildSecondaryMetrics(),
                  const SizedBox(height: 32),

                  if (!_hasPermissions && _errorMessage != null) ...[
                    _buildPermissionsCard(),
                    const SizedBox(height: 20),
                  ],

                  const SizedBox(height: 40),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Get formatted date string
  String _getFormattedDate() {
    final now = DateTime.now();
    final weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}';
  }

  /// Build error card with modern design
  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B30).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFF3B30).withValues(alpha: 0.2), width: 1),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFF3B30).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.error_outline_rounded, color: Color(0xFFFF3B30), size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Color(0xFFFF3B30), fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  /// Navigates to the full daily/weekly/monthly history for one metric -
  /// tapping any card on this screen reaches its own history, per-metric.
  void _openHistory({
    required String metricKey,
    required String title,
    required String unit,
    required Color color,
    int digits = 0,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MetricHistoryScreen(
          patientId: _patientId,
          metricKey: metricKey,
          title: title,
          unit: unit,
          color: color,
          digits: digits,
        ),
      ),
    );
  }

  void _openActivitySummary() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ActivitySummaryScreen(patientId: _patientId)),
    );
  }

  /// Build main metrics grid: Activity Level as the hero card, then Heart
  /// Rate/Sleep and Steps/Calories in two rows below.
  Widget _buildMainMetricsGrid() {
    return Column(
      children: [
        _buildActivityHeroCard(),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildCompactMetricCard(
                icon: Icons.favorite_rounded,
                title: 'Heart Rate',
                value: _formatHeartRate(_restingHeartRate),
                unit: '',
                color: const Color(0xFFFF3B30),
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF6B6B), Color(0xFFFF3B30)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                onTap: () => _openHistory(
                  metricKey: 'resting_hr',
                  title: 'Heart Rate',
                  unit: ' bpm',
                  color: const Color(0xFFFF3B30),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildCompactMetricCard(
                icon: Icons.bedtime_rounded,
                title: 'Sleep',
                value: _formatSleepDuration(_sleepDuration),
                unit: '',
                color: const Color(0xFF5856D6),
                gradient: const LinearGradient(
                  colors: [Color(0xFF7B68EE), Color(0xFF5856D6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                onTap: () => _openHistory(
                  metricKey: 'sleep_hours',
                  title: 'Sleep',
                  unit: 'h',
                  color: const Color(0xFF5856D6),
                  digits: 1,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Steps next to Calories, as requested.
        Row(
          children: [
            Expanded(
              child: _buildCompactMetricCard(
                icon: Icons.directions_walk_rounded,
                title: 'Steps',
                value: _formatSteps(_steps),
                unit: '',
                color: const Color(0xFF007AFF),
                gradient: const LinearGradient(
                  colors: [Color(0xFF007AFF), Color(0xFF5AC8FA)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                onTap: () => _openHistory(metricKey: 'steps', title: 'Steps', unit: '', color: const Color(0xFF007AFF)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildCompactMetricCard(
                icon: Icons.local_fire_department_rounded,
                title: 'Calories',
                value: _formatCalories(_calories),
                unit: '',
                color: const Color(0xFFFF9500),
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFB340), Color(0xFFFF9500)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                onTap: () => _openHistory(
                  metricKey: 'calories',
                  title: 'Calories',
                  unit: ' kcal',
                  color: const Color(0xFFFF9500),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Color _activityTierColor(String? tier) {
    switch (tier) {
      case 'positive':
        return const Color(0xFF34C759);
      case 'caution':
        return const Color(0xFFFF9500);
      case 'concern':
        return const Color(0xFFFF3B30);
      default:
        return const Color(0xFF007AFF);
    }
  }

  /// Hero card: Activity Level, AI-explained on tap. Replaces the old
  /// Steps-only hero - Steps now lives in the compact grid below, next to
  /// Calories.
  Widget _buildActivityHeroCard() {
    final level = _activitySummary?['level'] as String?;
    final tier = _activitySummary?['tier'] as String?;
    final color = _activityTierColor(tier);

    return AnimatedTap(
      onTap: _openActivitySummary,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withValues(alpha: 0.85), color],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 28),
                ),
                const Spacer(),
                if (_isLoading || _isLoadingActivity)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                else
                  const Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 22),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Activity Level',
              style: GoogleFonts.barlow(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2),
            ),
            const SizedBox(height: 4),
            Text(
              _isLoading ? '---' : (level ?? 'Syncing...'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.barlow(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold, letterSpacing: -1),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap for why',
              style: GoogleFonts.barlow(color: Colors.white.withValues(alpha: 0.8), fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  /// Build compact metric card
  Widget _buildCompactMetricCard({
    required IconData icon,
    required String title,
    required String value,
    required String unit,
    required Color color,
    required Gradient gradient,
    VoidCallback? onTap,
  }) {
    return AnimatedTap(
      onTap: onTap,
      child: Container(
        height: 140,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 15, offset: const Offset(0, 6))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const Spacer(),
            // maxLines/ellipsis on both: this Column sits in a fixed-height
            // (140) card with a Spacer above it, so if either label ever
            // wraps to a second line - a longer value string, a wider
            // fallback font before Google Fonts finishes loading, larger
            // system text scaling - the fixed height overflows. Capping both
            // to one line keeps the card's height guarantee regardless.
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.barlow(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            if (_isLoading)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            else
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.barlow(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5),
              ),
          ],
        ),
      ),
    );
  }

  /// Build secondary metrics section
  Widget _buildSecondaryMetrics() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Health Insights',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(color: const Color(0xFFFFFFFF), fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: Column(
            children: [
              _buildInsightRow(
                icon: Icons.trending_up_rounded,
                title: 'Activity Level',
                value: _activitySummary?['level'] as String? ?? 'Syncing...',
                color: const Color(0xFF34C759),
              ),
              const SizedBox(height: 16),
              Divider(color: Colors.grey.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              _buildInsightRow(
                icon: Icons.schedule_rounded,
                title: 'Last Updated',
                value: _getLastUpdated(),
                color: const Color(0xFF8E8E93),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Build insight row
  Widget _buildInsightRow({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: GoogleFonts.barlow(fontSize: 15, fontWeight: FontWeight.w500, color: const Color(0xFF8E8E93))),
              const SizedBox(height: 2),
              Text(value, style: GoogleFonts.barlow(fontSize: 17, fontWeight: FontWeight.w600, color: const Color(0xFFFFFFFF))),
            ],
          ),
        ),
      ],
    );
  }

  /// Build permissions card
  Widget _buildPermissionsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9500).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFF9500).withValues(alpha: 0.2), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: const Color(0xFFFF9500).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
                child: const Icon(Icons.health_and_safety_rounded, color: Color(0xFFFF9500), size: 20),
              ),
              const SizedBox(width: 12),
              Text('Health Permissions', style: GoogleFonts.barlow(color: const Color(0xFFFF9500), fontSize: 17, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Grant access to your health data to see personalized insights and track your progress over time.',
            style: GoogleFonts.barlow(color: const Color(0xFFFF9500), fontSize: 15, fontWeight: FontWeight.w500, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// Real relative time, ticking every minute via _ticker - not a fixed
  /// "Just now" string.
  String _getLastUpdated() {
    if (_lastUpdated == null) return 'Never';
    final diff = DateTime.now().difference(_lastUpdated!);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  /// Risk level from the backend drives the card's tone: calm green when
  /// normal, amber/red as it climbs toward escalation.
  List<Color> _coachCardGradient() {
    final riskLevel = _backendSummary?['risk_level'] as String?;
    switch (riskLevel) {
      case 'escalate':
        return [const Color(0xFFFF6B6B), const Color(0xFFFF3B30)];
      case 'elevated':
        return [const Color(0xFFFF9F43), const Color(0xFFFF9500)];
      case 'watch':
        return [const Color(0xFFFFD93D), const Color(0xFFFFC107)];
      default:
        return [const Color(0xFF11998E), const Color(0xFF38EF7D)];
    }
  }

  String _coachCardBadge() {
    if (!_backendReachable) return 'Offline';
    final riskLevel = _backendSummary?['risk_level'] as String?;
    if (riskLevel == null) return 'Syncing';
    return riskLevel.substring(0, 1).toUpperCase() + riskLevel.substring(1);
  }

  /// Replaces the old fixed "Great job today!" copy with the backend's
  /// actual rule hits, or an honest status message if it isn't reachable.
  String _coachInsightText() {
    if (!_backendReachable) {
      return "Can't reach the local coaching service right now. On your "
          'dev machine, run:\npython -m health_coach.cli serve';
    }
    if (_backendSummary == null) {
      return 'Syncing with your local coach...';
    }
    final hits = (_backendSummary!['hits'] as List?)?.cast<dynamic>() ?? [];
    if (hits.isEmpty) {
      return 'Your heart rate, sleep, and activity all look consistent '
          'with your recent baseline. Keep up your routine.';
    }
    return hits.map((h) => '• $h').join('\n');
  }

  Map<String, dynamic> _currentHealthDataForChat() {
    return {
      'steps': _steps ?? 0,
      'heartRate': _restingHeartRate ?? 0,
      'sleepHours': _sleepDuration != null ? (_sleepDuration!.inMinutes / 60) : 0,
    };
  }

  /// Build AI Coach section
  Widget _buildAICoachSection() {
    final gradientColors = _coachCardGradient();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'AI Coach',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(color: const Color(0xFFFFFFFF), fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: gradientColors, begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: gradientColors.first.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 8))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.psychology_rounded, color: Colors.white, size: 28),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
                    child: Text(_coachCardBadge(), style: GoogleFonts.barlow(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'Daily Insights',
                style: GoogleFonts.barlow(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.3),
              ),
              const SizedBox(height: 8),
              Text(
                _coachInsightText(),
                style: GoogleFonts.barlow(color: Colors.white.withValues(alpha: 0.9), fontSize: 15, fontWeight: FontWeight.w400, height: 1.4),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  // On wide screens the chat is already visible in the side
                  // panel (see HomeShell) - a button that navigates to
                  // another copy of it would just be redundant.
                  if (!widget.embedded) ...[
                    Expanded(
                      child: AnimatedTap(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => AIChatScreen(patientId: _patientId, healthData: _currentHealthDataForChat()),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.chat_bubble_outline_rounded, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  'Ask Coach',
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  style: GoogleFonts.barlow(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: AnimatedTap(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => EscalationScreen(patientId: _patientId)),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.medical_services_rounded, color: Color(0xFF11998E), size: 18),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                'Care Team',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: GoogleFonts.barlow(color: const Color(0xFF11998E), fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Show profile menu - a draggable sheet you can slide up/through, with
  /// real, working entries (Settings pushes a real full settings screen;
  /// Privacy/Help are wired in settings_screen.dart, not TODOs).
  void _showProfileMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1C1C1E),
            borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
          ),
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.zero,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: AppSettings().accentColor,
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: [BoxShadow(color: AppSettings().accentColor.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 8))],
                  ),
                  child: const Icon(Icons.person_rounded, color: Colors.white, size: 40),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text('Health Profile', style: GoogleFonts.barlow(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  'Manage your health data and preferences',
                  style: GoogleFonts.barlow(fontSize: 15, fontWeight: FontWeight.w400, color: const Color(0xFF8E8E93)),
                ),
              ),
              const SizedBox(height: 32),
              _buildProfileMenuItem(
                icon: Icons.settings_rounded,
                title: 'Settings',
                subtitle: 'Appearance, data sources, and privacy',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const SettingsScreen(patientId: _patientId)));
                },
              ),
              _buildProfileMenuItem(
                icon: Icons.privacy_tip_rounded,
                title: 'Privacy',
                subtitle: 'What this app does and doesn\'t do with your data',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SettingsScreen(patientId: _patientId, initialSection: SettingsSection.privacy)),
                  );
                },
              ),
              _buildProfileMenuItem(
                icon: Icons.help_outline_rounded,
                title: 'Help & Support',
                subtitle: 'How this app works, and what it is not',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SettingsScreen(patientId: _patientId, initialSection: SettingsSection.help)),
                  );
                },
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  /// Build profile menu item
  Widget _buildProfileMenuItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFF2C2C2E), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: AppSettings().accentColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: GoogleFonts.barlow(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: GoogleFonts.barlow(fontSize: 15, fontWeight: FontWeight.w400, color: const Color(0xFF8E8E93))),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Color(0xFF8E8E93), size: 20),
          ],
        ),
      ),
    );
  }
}
