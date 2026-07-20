import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Widget for displaying quick suggestion buttons in the chat
class QuickSuggestions extends StatelessWidget {
  final Function(String) onSuggestionTap;
  final Map<String, dynamic>? healthData;

  const QuickSuggestions({
    super.key,
    required this.onSuggestionTap,
    this.healthData,
  });

  @override
  Widget build(BuildContext context) {
    final suggestions = _buildSuggestions();
    
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Suggested questions',
            style: GoogleFonts.barlow(
              color: const Color(0xFF8E8E93),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: suggestions.map((suggestion) => _buildSuggestionChip(suggestion)).toList(),
          ),
        ],
      ),
    );
  }

  List<String> _buildSuggestions() {
    if (healthData != null) {
      final steps = healthData!['steps'] ?? 0;
      final heartRate = healthData!['heartRate'] ?? 0;
      final sleepHours = healthData!['sleepHours'] ?? 0;
      
      return [
        'How can I improve my ${steps} daily steps?',
        'Is my resting heart rate of ${heartRate} bpm normal?',
        'Tips to improve my ${sleepHours}h of sleep',
        'What exercise programme would you recommend?',
        'How can I improve my nutrition?',
        'Stress management techniques',
      ];
    }
    
    // Suggestions par défaut
    return [
      'How do I start an exercise routine?',
      'Tips for better sleep',
      'What diet should I follow?',
      'How to manage stress?',
      'Exercises for beginners',
      'Optimal hydration',
    ];
  }

  Widget _buildSuggestionChip(String suggestion) {
    return GestureDetector(
      onTap: () => onSuggestionTap(suggestion),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFF2C2C2E),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lightbulb_outline,
              color: Color(0xFF38EF7D),
              size: 16,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                suggestion,
                style: GoogleFonts.barlow(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
