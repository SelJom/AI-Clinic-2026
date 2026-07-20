import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

/// Service responsible for local LLM integration via Ollama with ESMO clinical guidelines.
/// Loads guidelines from bundled assets and maintains a chat session with
/// a system prompt containing patient health context.
class GeminiService {
  static const String _ollamaUrl = 'http://localhost:11434/api/chat';
  static const String _model = 'qwen2.5:14b-instruct';

  List<Map<String, dynamic>> _history = [];
  String _systemPrompt = '';
  List<Map<String, dynamic>> _guidelines = [];
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Initializes the Ollama service with patient health data and ESMO guidelines.
  Future<void> initialize({
    int? steps,
    double? heartRate,
    Duration? sleepDuration,
  }) async {
    await _loadGuidelines();

    _systemPrompt = _buildSystemPrompt(
      steps: steps,
      heartRate: heartRate,
      sleepDuration: sleepDuration,
    );

    _history = [];
    _initialized = true;
  }

  /// Loads ESMO guidelines from the bundled JSONL asset file.
  Future<void> _loadGuidelines() async {
    try {
      final jsonlString = await rootBundle.loadString(
        'assets/guidelines/esmo_guidelines.jsonl',
      );
      final lines = jsonlString
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      _guidelines = lines
          .map((l) => json.decode(l) as Map<String, dynamic>)
          .toList();
    } catch (e) {
      print('Error loading ESMO guidelines: $e');
      _guidelines = [];
    }
  }

  /// Builds a compact base system prompt with health metrics only (no guidelines).
  /// Guidelines are injected per-query via mini-RAG in sendMessage().
  String _buildSystemPrompt({
    int? steps,
    double? heartRate,
    Duration? sleepDuration,
  }) {
    final stepsStr = steps != null ? '$steps steps' : 'data unavailable';
    final hrStr = heartRate != null ? '${heartRate.round()} bpm' : 'data unavailable';
    final sleepStr = sleepDuration != null
        ? '${sleepDuration.inHours}h ${sleepDuration.inMinutes % 60}min'
        : 'data unavailable';

    return '''You are an empathetic AI health coach specialised in supporting patients with early-stage breast cancer. You use wearable data and ESMO 2024 clinical guidelines to deliver personalised coaching.

## Current wearable data
- Steps today: $stepsStr
- Resting heart rate: $hrStr
- Sleep (last night): $sleepStr

## Absolute rules
1. ALWAYS reference the patient's actual wearable values in your response when relevant.
2. Ground your advice in the ESMO guidelines provided in each message (section [RELEVANT ESMO GUIDELINES]).
3. For any medical decision or unusual symptom, immediately refer the patient to their care team.
4. Be empathetic, concise and actionable. Use bullet points.
5. Never invent statistics. Always respond in English.''';
  }

  /// Selects the most relevant ESMO guidelines for a given query using keyword scoring.
  List<Map<String, dynamic>> _selectRelevantGuidelines(String query, {int maxCount = 15}) {
    final queryLower = query.toLowerCase();
    final stopWords = {'est', 'les', 'des', 'une', 'que', 'qui', 'pour', 'dans', 'avec', 'sur', 'par', 'mon', 'ma', 'mes', 'je', 'vous', 'de', 'du', 'en', 'et', 'il', 'elle', 'pas', 'the', 'and', 'for', 'with', 'this', 'that', 'from'};
    final queryWords = queryLower
        .split(RegExp(r'[\W_]+'))
        .where((w) => w.length > 3 && !stopWords.contains(w))
        .toSet();

    final scored = _guidelines.map((g) {
      final text = ((g['text'] as String?) ?? '').toLowerCase();
      int score = 0;
      for (final word in queryWords) {
        if (text.contains(word)) score += 2;
      }
      final level = (g['evidence_level'] as String?) ?? '';
      if (level == 'I') score += 2;
      else if (level == 'II') score += 1;
      return (score: score, guideline: g);
    }).toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final relevant = scored.where((e) => e.score > 0).take(maxCount).map((e) => e.guideline).toList();
    return relevant.isEmpty ? scored.take(5).map((e) => e.guideline).toList() : relevant;
  }

  /// Formats a list of guidelines into a compact text block.
  String _formatGuidelines(List<Map<String, dynamic>> guidelines) {
    return guidelines.map((g) {
      final text = ((g['text'] as String?) ?? '')
          .replaceAll(RegExp(r'\(cid:[^)]+\)'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final level = (g['evidence_level'] as String?) ?? '';
      final grade = (g['recommendation_grade'] as String?) ?? '';
      final tag = (level.isNotEmpty && grade.isNotEmpty) ? ' [N°$level/$grade]' : '';
      return '- $text$tag';
    }).join('\n');
  }

  /// Sends a message to Ollama and returns the response.
  /// Maintains full conversation history for multi-turn dialogue.
  Future<String> sendMessage(String userMessage) async {
    if (!_initialized) {
      throw Exception('GeminiService not initialized');
    }

    final relevant = _selectRelevantGuidelines(userMessage);
    final guidelinesBlock = _formatGuidelines(relevant);
    final augmentedMessage = guidelinesBlock.isNotEmpty
        ? '[RELEVANT ESMO GUIDELINES]\n$guidelinesBlock\n\n[Patient message]\n$userMessage'
        : userMessage;

    _history.add({'role': 'user', 'content': augmentedMessage});

    final body = jsonEncode({
      'model': _model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        ..._history,
      ],
      'stream': false,
    });

    final response = await http.post(
      Uri.parse(_ollamaUrl),
      headers: {'Content-Type': 'application/json'},
      body: body,
    ).timeout(const Duration(seconds: 180));

    if (response.statusCode != 200) {
      _history.removeLast();
      throw Exception('Ollama HTTP ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final assistantContent =
        (data['message'] as Map<String, dynamic>)['content'] as String;

    _history.add({'role': 'assistant', 'content': assistantContent});
    return assistantContent;
  }

  /// Resets the conversation history while keeping the same system prompt.
  void resetChat() {
    _history = [];
  }
}
