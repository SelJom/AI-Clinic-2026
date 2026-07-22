import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/backend_service.dart';
import '../services/health_service.dart';
import 'ai_chat_screen.dart';
import 'escalation_screen.dart';

/// Main screen displaying today's health metrics
/// Shows steps, resting heart rate, and sleep duration with refresh capability
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

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

  // Backend coaching state
  Map<String, dynamic>? _backendSummary;
  bool _backendReachable = true;

  // UI state variables
  bool _isLoading = false;
  bool _hasPermissions = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeHealthData();
  }

  /// Initialize health data and request permissions
  Future<void> _initializeHealthData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // For demo mode, always load the demo data
      print('🎯 Demo mode: Loading demo health data');
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
      ]);

      setState(() {
        _steps = results[0] as int?;
        _restingHeartRate = results[1] as double?;
        _sleepDuration = results[2] as Duration?;
      });

      await _syncWithBackend();
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
      await _backendService.ingestToday(
        patientId: _patientId,
        steps: _steps!,
        restingHeartRate: _restingHeartRate!,
        sleepMinutes: _sleepDuration!.inMinutes,
      );
      final summary = await _backendService.getSummary(_patientId);
      if (!mounted) return;
      setState(() {
        _backendSummary = summary;
        _backendReachable = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _backendReachable = false;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: RefreshIndicator(
        onRefresh: _hasPermissions ? _loadHealthData : _initializeHealthData,
        color: const Color(0xFF007AFF),
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
                              fontSize: 28, // Reduced from 34 to fit better
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
                            // Refresh button
                            IconButton(
                              onPressed: _isLoading ? null : (_hasPermissions ? _loadHealthData : _initializeHealthData),
                              icon: _isLoading 
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFF007AFF),
                                    ),
                                  )
                                : const Icon(
                                    Icons.refresh_rounded,
                                    color: Color(0xFF007AFF),
                                    size: 20,
                                  ),
                            ),
                            // Profile icon
                            GestureDetector(
                              onTap: _showProfileMenu,
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF007AFF),
                                  borderRadius: BorderRadius.circular(14),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF007AFF).withValues(alpha: 0.3),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.person_rounded,
                                  color: Colors.white,
                                  size: 16,
                                ),
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
                  
                  // Date header
                  Text(
                    _getFormattedDate(),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: const Color(0xFF8E8E93),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  
                  const SizedBox(height: 24),

                  // Error message display
                  if (_errorMessage != null) ...[
                    _buildErrorCard(),
                    const SizedBox(height: 20),
                  ],

                  // Main health metrics grid
                  _buildMainMetricsGrid(),
                  
                  const SizedBox(height: 24),
                  
                  // AI Coach Section
                  _buildAICoachSection(),
                  
                  const SizedBox(height: 24),
                  
                  // Secondary metrics
                  _buildSecondaryMetrics(),
                  
                  const SizedBox(height: 32),

                  // Permissions info
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
        border: Border.all(
          color: const Color(0xFFFF3B30).withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFF3B30).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.error_outline_rounded,
              color: Color(0xFFFF3B30),
              size: 20,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(
                color: Color(0xFFFF3B30),
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build main metrics grid (Steps as hero card)
  Widget _buildMainMetricsGrid() {
    return Column(
      children: [
        // Hero Steps Card
        _buildHeroStepsCard(),
        
        const SizedBox(height: 16),
        
        // Heart Rate and Sleep in a row
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
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Build hero steps card (large, prominent)
  Widget _buildHeroStepsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF007AFF), Color(0xFF5AC8FA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF007AFF).withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
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
                child: const Icon(
                  Icons.directions_walk_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const Spacer(),
              if (_isLoading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Steps',
            style: GoogleFonts.barlow(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _isLoading ? '---' : _formatSteps(_steps),
            style: GoogleFonts.barlow(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.bold,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Today',
            style: GoogleFonts.barlow(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
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
  }) {
    return Container(
      height: 140,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.3),
            blurRadius: 15,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 20,
            ),
          ),
          const Spacer(),
          Text(
            title,
            style: GoogleFonts.barlow(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          if (_isLoading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          else
            Text(
              value,
              style: GoogleFonts.barlow(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.5,
              ),
            ),
        ],
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
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: const Color(0xFFFFFFFF),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              _buildInsightRow(
                icon: Icons.trending_up_rounded,
                title: 'Activity Level',
                value: _getActivityLevel(),
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
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            color: color,
            size: 20,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.barlow(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF8E8E93),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: GoogleFonts.barlow(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFFFFFFFF),
                ),
              ),
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
        border: Border.all(
          color: const Color(0xFFFF9500).withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9500).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.health_and_safety_rounded,
                  color: Color(0xFFFF9500),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Health Permissions',
                style: GoogleFonts.barlow(
                  color: const Color(0xFFFF9500),
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Grant access to your health data to see personalized insights and track your progress over time.',
            style: GoogleFonts.barlow(
              color: const Color(0xFFFF9500),
              fontSize: 15,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// Get activity level based on steps
  String _getActivityLevel() {
    if (_steps == null) return 'No data';
    if (_steps! >= 10000) return 'Excellent';
    if (_steps! >= 7500) return 'Good';
    if (_steps! >= 5000) return 'Fair';
    return 'Low';
  }

  /// Get last updated time (demo version)
  String _getLastUpdated() {
    // Fixed demo time for presentation - looks like recent sync
    return 'Just now';
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
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: const Color(0xFFFFFFFF),
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: gradientColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: gradientColors.first.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
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
                    child: const Icon(
                      Icons.psychology_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _coachCardBadge(),
                      style: GoogleFonts.barlow(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'Daily Insights',
                style: GoogleFonts.barlow(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _coachInsightText(),
                style: GoogleFonts.barlow(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => AIChatScreen(
                              patientId: _patientId,
                              healthData: _currentHealthDataForChat(),
                            ),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.chat_bubble_outline_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Ask Coach',
                              style: GoogleFonts.barlow(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => EscalationScreen(patientId: _patientId),
                          ),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.medical_services_rounded,
                              color: Color(0xFF11998E),
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Care Team',
                              style: GoogleFonts.barlow(
                                color: const Color(0xFF11998E),
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
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


  /// Show profile menu - iPhone Health style
  void _showProfileMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            
            const SizedBox(height: 24),
            
            // Profile header
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF007AFF),
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF007AFF).withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(
                Icons.person_rounded,
                color: Colors.white,
                size: 40,
              ),
            ),
            
            const SizedBox(height: 16),
            
            Text(
              'Health Profile',
              style: GoogleFonts.barlow(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            
            const SizedBox(height: 8),
            
            Text(
              'Manage your health data and preferences',
              style: GoogleFonts.barlow(
                fontSize: 15,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF8E8E93),
              ),
            ),
            
            const SizedBox(height: 32),
            
            // Menu options
            _buildProfileMenuItem(
              icon: Icons.settings_rounded,
              title: 'Settings',
              subtitle: 'App preferences and data sources',
              onTap: () {
                Navigator.pop(context);
                // TODO: Navigate to settings
              },
            ),
            
            _buildProfileMenuItem(
              icon: Icons.privacy_tip_rounded,
              title: 'Privacy',
              subtitle: 'Data sharing and permissions',
              onTap: () {
                Navigator.pop(context);
                // TODO: Navigate to privacy settings
              },
            ),
            
            _buildProfileMenuItem(
              icon: Icons.help_outline_rounded,
              title: 'Help & Support',
              subtitle: 'Get help with the app',
              onTap: () {
                Navigator.pop(context);
                // TODO: Navigate to help
              },
            ),
            
            const SizedBox(height: 32),
          ],
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
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: const Color(0xFF007AFF),
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.barlow(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: GoogleFonts.barlow(
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      color: const Color(0xFF8E8E93),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: Color(0xFF8E8E93),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}
