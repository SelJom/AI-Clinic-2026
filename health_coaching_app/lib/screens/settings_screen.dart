import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import '../services/app_settings.dart';
import '../services/backend_service.dart';
import '../services/health_service.dart';
import '../widgets/animated_tap.dart';

enum SettingsSection { general, privacy, help }

/// Real settings screen - appearance, data sources, and the two data rights
/// (`GET .../export`, `DELETE ...`) the backend already implements but the
/// app never surfaced before. Reached from the profile sheet; scroll to
/// jump straight to Privacy or Help if opened from those shortcuts.
class SettingsScreen extends StatefulWidget {
  final String patientId;
  final SettingsSection initialSection;

  const SettingsScreen({super.key, required this.patientId, this.initialSection = SettingsSection.general});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final BackendService _backendService = BackendService();
  final HealthService _healthService = HealthService();
  final GlobalKey _privacyKey = GlobalKey();
  final GlobalKey _helpKey = GlobalKey();
  bool _busy = false;

  /// Health Connect only grants apps a rolling window of past data (30 days
  /// on this device, confirmed live in its own "peut lire les données
  /// ajoutées après le 1 août 2026" notice) - this is that same start date,
  /// not an arbitrary choice. Import naturally stays correct if run again
  /// later: the window just slides forward with Health Connect's own limit.
  static final DateTime _importStart = DateTime.now().subtract(const Duration(days: 30));

  Future<void> _importHistory() async {
    setState(() => _busy = true);
    try {
      final end = DateTime.now().add(const Duration(days: 1));
      final totals = await _healthService.getHistoricalDailyTotals(_importStart, end);
      if (!mounted) return;
      if (totals.isEmpty) {
        _showSnack(
          "No historical Health Connect data found - either it isn't granted, or Samsung Health hasn't synced anything yet.",
        );
        return;
      }
      int imported = 0;
      for (final day in totals) {
        final result = await _backendService.ingestDay(
          patientId: widget.patientId,
          day: day.day,
          steps: day.steps,
          restingHeartRate: day.restingHeartRate,
          sleepMinutes: day.sleepMinutes,
          calories: day.calories,
        );
        if (result != null) imported++;
      }
      if (!mounted) return;
      _showSnack('Imported $imported real day(s), tagged separately from any old demo data.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialSection != SettingsSection.general) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key = widget.initialSection == SettingsSection.privacy ? _privacyKey : _helpKey;
        final ctx = key.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300));
      });
    }
  }

  Future<void> _exportData() async {
    setState(() => _busy = true);
    final data = await _backendService.exportPatientData(widget.patientId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (data == null) {
      _showSnack("Can't reach the local coaching service right now.");
      return;
    }
    final pretty = const JsonEncoder.withIndent('  ').convert(data);
    await Share.share(pretty, subject: 'My health coaching data export');
  }

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: Text('Delete all my data?', style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(
          'This permanently deletes every record stored locally for you - wearable samples, daily '
          'features, risk assessments, and chat history. This cannot be undone; there is no backup.',
          style: GoogleFonts.barlow(color: const Color(0xFF8E8E93)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Color(0xFFFF3B30))),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    final result = await _backendService.deletePatientData(widget.patientId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == null) {
      _showSnack("Can't reach the local coaching service right now.");
      return;
    }
    final deleted = result['deleted'] as Map<String, dynamic>?;
    final total = deleted?.values.fold<int>(0, (sum, v) => sum + (v as int)) ?? 0;
    _showSnack('Deleted $total record(s). All local data for this profile is gone.');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings(),
      builder: (context, _) => Scaffold(
        backgroundColor: const Color(0xFF000000),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1C1C1E),
          elevation: 0,
          title: Text('Settings', style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        body: AbsorbPointer(
          absorbing: _busy,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _sectionTitle('Appearance'),
              _card(child: _buildAccentPicker()),
              const SizedBox(height: 24),

              _sectionTitle('Data Sources'),
              _card(
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Use Samsung Health data', style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        'When off, this app always uses simulated demo numbers, even if Health Connect '
                        'permission was granted.',
                        style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 13),
                      ),
                      value: AppSettings().useSamsungHealthData,
                      activeThumbColor: AppSettings().accentColor,
                      onChanged: (value) => AppSettings().setUseSamsungHealthData(value),
                    ),
                    Divider(color: Colors.grey.withValues(alpha: 0.2)),
                    _actionRow(
                      icon: Icons.history_rounded,
                      title: 'Import health history',
                      subtitle: 'Pulls real Samsung Health data for as far back as Health Connect allows '
                          '(${_importStart.toString().split(" ").first} onward) - tagged separately from '
                          'any simulated demo data, never mixed together',
                      onTap: _importHistory,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              _sectionTitle('Data & Privacy'),
              _card(
                child: Column(
                  children: [
                    _actionRow(
                      icon: Icons.download_rounded,
                      title: 'Export my data',
                      subtitle: 'Every record stored locally for you, as JSON',
                      onTap: _exportData,
                    ),
                    Divider(color: Colors.grey.withValues(alpha: 0.2)),
                    _actionRow(
                      icon: Icons.delete_forever_rounded,
                      title: 'Delete my data',
                      subtitle: 'Permanently erase everything - cannot be undone',
                      iconColor: const Color(0xFFFF3B30),
                      onTap: _confirmAndDelete,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              _sectionTitle('Privacy', key: _privacyKey),
              _card(child: _buildPrivacyContent()),
              const SizedBox(height: 24),

              _sectionTitle('Help & Support', key: _helpKey),
              _card(child: _buildHelpContent()),
              const SizedBox(height: 24),

              _sectionTitle('About'),
              _card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Health Coaching App', style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 6),
                    Text(
                      'A local-first health coach: wearable data, personal baselines, and '
                      'guideline-grounded coaching, computed entirely on this device and your '
                      'own local backend. Nothing is sent to any cloud service.',
                      style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Text(text, style: GoogleFonts.barlow(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
    );
  }

  Widget _card({required Widget child}) {
    // A Material (not a plain Container+BoxDecoration) so any ListTile/
    // InkWell nested inside paints its background/ink splashes correctly -
    // those widgets paint on the nearest Material ancestor, and a colored
    // Container in between silently hides that painting entirely.
    return Material(
      color: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  Widget _buildAccentPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Accent color', style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: List.generate(AppSettings.accentOptions.length, (i) {
            final option = AppSettings.accentOptions[i];
            final selected = i == AppSettings().accentColorIndex;
            return AnimatedTap(
              onTap: () => AppSettings().setAccentColorIndex(i),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: option.color,
                  shape: BoxShape.circle,
                  border: selected ? Border.all(color: Colors.white, width: 3) : null,
                  boxShadow: [BoxShadow(color: option.color.withValues(alpha: 0.4), blurRadius: 8)],
                ),
                child: selected ? const Icon(Icons.check_rounded, color: Colors.white, size: 20) : null,
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _actionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? iconColor,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? AppSettings().accentColor, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 12)),
                ],
              ),
            ),
            if (_busy)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF8E8E93), size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildPrivacyContent() {
    const bullets = [
      'Everything is stored in one local SQLite file on this backend\'s machine - no cloud sync, '
          'no analytics, no third-party SDK calls.',
      'The local API only binds to 127.0.0.1 and only accepts loopback origins - nothing reaches it '
          'from outside this device.',
      'The only outbound network call anywhere in the backend is to a local Ollama daemon, and only '
          'if one is already running - otherwise no network call happens at all.',
      'Right to access and right to erasure are both actually implemented above (Export/Delete my '
          'data), not just promised.',
      'Not yet done, honestly: no consent flow before first sync, no encryption at rest (the local '
          'database file is plain SQLite), no audit log, and no legal determination of GDPR or HIPAA '
          'applicability. See PRIVACY.md in the project repository for the full accounting.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in bullets)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: GoogleFonts.barlow(color: const Color(0xFF8E8E93))),
                Expanded(child: Text(b, style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 13, height: 1.4))),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildHelpContent() {
    final faqs = [
      ('Is this a diagnosis tool?', 'No. Everything here is a supportive, guideline-grounded coach - it explains and '
          'delivers what a deterministic rule engine already computed. It never replaces a clinician.'),
      ('The AI Coach card says "Offline" or "Can\'t reach the local coaching service" - why?',
          'The Flutter app talks to a local Python backend over 127.0.0.1:8765. Make sure it\'s running: '
          '"python -m health_coach.cli serve" from the backend/ folder on your computer.'),
      ('Why do my numbers look like demo data (8247 steps, 68.5 bpm, 7.75h, 412 kcal)?',
          'Those are the exact simulated fallback values, shown when this app can\'t read real Health '
          'Connect/HealthKit data - permission wasn\'t granted, or nothing has synced yet. Check '
          'Settings > Data Sources, and that Samsung Health is syncing to Health Connect.'),
      ('What happens if I tap "Delete my data"?', 'Every row stored for this profile - samples, daily '
          'features, risk assessments, chat history - is permanently removed. There is no backup, so '
          'this cannot be undone.'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (question, answer) in faqs)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(question, style: GoogleFonts.barlow(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 4),
                Text(answer, style: GoogleFonts.barlow(color: const Color(0xFF8E8E93), fontSize: 13, height: 1.4)),
              ],
            ),
          ),
      ],
    );
  }
}
