import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../widgets/quick_suggestions.dart';
import '../services/gemini_service.dart';

/// AI Chat screen with modern interface inspired by ChatGPT/Claude
class AIChatScreen extends StatefulWidget {
  final int? steps;
  final double? heartRate;
  final Duration? sleepDuration;

  const AIChatScreen({
    super.key,
    this.steps,
    this.heartRate,
    this.sleepDuration,
  });

  @override
  State<AIChatScreen> createState() => _AIChatScreenState();
}

class _AIChatScreenState extends State<AIChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  final GeminiService _geminiService = GeminiService();
  bool _isTyping = false;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _messages.add(ChatMessage(
      text: "⏳ Connecting to AI coach...",
      isUser: false,
      timestamp: DateTime.now(),
    ));
    _initializeGemini();
  }

  Future<void> _initializeGemini() async {
    try {
      await _geminiService.initialize(
        steps: widget.steps,
        heartRate: widget.heartRate,
        sleepDuration: widget.sleepDuration,
      );
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _messages[0] = ChatMessage(
            text: "👋 Hello! I'm your AI health coach, here to support you through your care journey. How can I help you today?",
            isUser: false,
            timestamp: DateTime.now(),
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _messages[0] = ChatMessage(
            text: "⚠️ Unable to connect to the AI service. Please check your connection and try again.",
            isUser: false,
            timestamp: DateTime.now(),
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty || _isInitializing) return;

    final userMessage = ChatMessage(
      text: _messageController.text.trim(),
      isUser: true,
      timestamp: DateTime.now(),
    );

    setState(() {
      _messages.add(userMessage);
      _isTyping = true;
    });

    _messageController.clear();
    _scrollToBottom();

    try {
      final response = await _geminiService.sendMessage(userMessage.text);
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            text: response,
            isUser: false,
            timestamp: DateTime.now(),
          ));
          _isTyping = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            text: "❌ Error: $e",
            isUser: false,
            timestamp: DateTime.now(),
          ));
          _isTyping = false;
        });
        _scrollToBottom();
      }
    }
  }

  // ignore: unused_element
  void _simulateAIResponse(String userMessage) {
    // Simulation d'une réponse contextuelle basée sur les données de santé
    Future.delayed(const Duration(seconds: 2), () {
      String response = _generateContextualResponse(userMessage);
      
      setState(() {
        _messages.add(ChatMessage(
          text: response,
          isUser: false,
          timestamp: DateTime.now(),
        ));
        _isTyping = false;
      });
      _scrollToBottom();
    });
  }

  String _generateContextualResponse(String userMessage) {
    final message = userMessage.toLowerCase();
    
    if (message.contains('pas') || message.contains('marche') || message.contains('activité')) {
      return "🚶‍♂️ Avec vos 8,247 pas aujourd'hui, vous êtes sur la bonne voie ! L'OMS recommande 10,000 pas par jour. Voici quelques conseils pour augmenter votre activité :\n\n• Prenez les escaliers au lieu de l'ascenseur\n• Marchez pendant vos appels téléphoniques\n• Garez-vous plus loin de votre destination\n\nVoulez-vous que je vous propose un plan d'activité personnalisé ?";
    }
    
    if (message.contains('sommeil') || message.contains('dormir') || message.contains('fatigue')) {
      return "😴 Votre sommeil de 7h45 est excellent ! C'est dans la fourchette optimale de 7-9h. Pour maintenir cette qualité :\n\n• Gardez des horaires réguliers\n• Évitez les écrans 1h avant le coucher\n• Maintenez votre chambre fraîche (18-20°C)\n\nAvez-vous des difficultés particulières avec votre sommeil ?";
    }
    
    if (message.contains('cœur') || message.contains('cardiaque') || message.contains('rythme')) {
      return "❤️ Votre fréquence cardiaque au repos de 68.5 bpm est excellente ! C'est le signe d'une bonne condition cardiovasculaire.\n\n**Plages normales :**\n• Excellente : 60-69 bpm\n• Bonne : 70-79 bpm\n• Moyenne : 80-89 bpm\n\nPour maintenir cette santé cardiaque, continuez votre activité physique régulière !";
    }
    
    if (message.contains('nutrition') || message.contains('manger') || message.contains('alimentation')) {
      return "🥗 Une bonne nutrition complète parfaitement votre activité physique ! Voici mes recommandations :\n\n**Bases d'une alimentation saine :**\n• 5 portions de fruits et légumes/jour\n• Protéines à chaque repas\n• Hydratation : 1.5-2L d'eau/jour\n• Limiter les aliments ultra-transformés\n\nVoulez-vous des suggestions de repas adaptés à votre niveau d'activité ?";
    }
    
    // Réponse générale
    return "🤖 Je suis là pour vous accompagner dans votre parcours santé ! Basé sur vos données actuelles :\n\n📊 **Votre bilan :**\n• Activité : Très bonne (8,247 pas)\n• Sommeil : Excellent (7h45)\n• Rythme cardiaque : Optimal (68.5 bpm)\n\nVous pouvez me poser des questions sur :\n• Conseils d'activité physique\n• Optimisation du sommeil\n• Nutrition et hydratation\n• Gestion du stress\n\nQue souhaitez-vous améliorer en priorité ?";
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: _buildMessagesList(),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF1C1C1E),
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF11998E), Color(0xFF38EF7D)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.psychology_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI Health Coach',
                style: GoogleFonts.barlow(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'Online',
                style: GoogleFonts.barlow(
                  color: const Color(0xFF38EF7D),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          onPressed: () => _showChatOptions(),
        ),
      ],
    );
  }

  Widget _buildMessagesList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _messages.length + (_isTyping ? 1 : 0) + (_messages.length == 1 ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length && _isTyping) {
          return _buildTypingIndicator();
        }
        if (index == _messages.length && _messages.length == 1) {
          return QuickSuggestions(
            onSuggestionTap: (suggestion) {
              _messageController.text = suggestion;
              _sendMessage();
            },
            healthData: {
              'steps': widget.steps ?? 0,
              'heartRate': widget.heartRate ?? 0,
              'sleepHours': widget.sleepDuration != null
                  ? widget.sleepDuration!.inMinutes / 60.0
                  : 0.0,
            },
          );
        }
        return _buildMessageBubble(_messages[index]);
      },
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!message.isUser) ...[
            _buildAvatar(false),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: message.isUser 
                  ? CrossAxisAlignment.end 
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: message.isUser 
                        ? const Color(0xFF007AFF)
                        : const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(18).copyWith(
                      bottomLeft: message.isUser 
                          ? const Radius.circular(18)
                          : const Radius.circular(4),
                      bottomRight: message.isUser 
                          ? const Radius.circular(4)
                          : const Radius.circular(18),
                    ),
                    border: message.isUser 
                        ? null
                        : Border.all(
                            color: const Color(0xFF2C2C2E),
                            width: 1,
                          ),
                  ),
                  child: Text(
                    message.text,
                    style: GoogleFonts.barlow(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(message.timestamp),
                  style: GoogleFonts.barlow(
                    color: const Color(0xFF8E8E93),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          if (message.isUser) ...[
            const SizedBox(width: 12),
            _buildAvatar(true),
          ],
        ],
      ),
    );
  }

  Widget _buildAvatar(bool isUser) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: isUser 
            ? const LinearGradient(
                colors: [Color(0xFF007AFF), Color(0xFF5AC8FA)],
              )
            : const LinearGradient(
                colors: [Color(0xFF11998E), Color(0xFF38EF7D)],
              ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        isUser ? Icons.person : Icons.psychology_rounded,
        color: Colors.white,
        size: 18,
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _buildAvatar(false),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: const Color(0xFF2C2C2E),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTypingDot(0),
                const SizedBox(width: 4),
                _buildTypingDot(1),
                const SizedBox(width: 4),
                _buildTypingDot(2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypingDot(int index) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1.0),
      duration: const Duration(milliseconds: 600),
      builder: (context, value, child) {
        return Transform.scale(
          scale: value,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: const Color(0xFF8E8E93),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        border: Border(
          top: BorderSide(color: Color(0xFF2C2C2E), width: 1),
        ),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2C2C2E),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _messageController,
                  style: GoogleFonts.barlow(
                    color: Colors.white,
                    fontSize: 16,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Ask your health question...',
                    hintStyle: GoogleFonts.barlow(
                      color: const Color(0xFF8E8E93),
                      fontSize: 16,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) { _sendMessage(); },
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () { _sendMessage(); },
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF11998E), Color(0xFF38EF7D)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Icon(
                  Icons.send_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);
    
    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}min ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${time.day}/${time.month} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
    }
  }

  void _showChatOptions() {
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
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF8E8E93),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            _buildOptionTile(
              icon: Icons.refresh,
              title: 'New conversation',
              onTap: () {
                Navigator.pop(context);
                _geminiService.resetChat();
                setState(() {
                  _messages.clear();
                  _messages.add(ChatMessage(
                    text: "👋 New conversation! How can I help you?",
                    isUser: false,
                    timestamp: DateTime.now(),
                  ));
                });
              },
            ),
            _buildOptionTile(
              icon: Icons.share,
              title: 'Share conversation',
              onTap: () {
                Navigator.pop(context);
                // Implémenter le partage
              },
            ),
            _buildOptionTile(
              icon: Icons.info_outline,
              title: 'About AI Coach',
              onTap: () {
                Navigator.pop(context);
                _showAboutDialog();
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildOptionTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(
        title,
        style: GoogleFonts.barlow(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: onTap,
    );
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: Text(
          'AI Health Coach',
          style: GoogleFonts.barlow(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Your personal assistant for a healthier lifestyle. I provide guidance on physical activity, sleep, nutrition and general well-being.\n\n⚠️ My advice does not replace professional medical opinion.',
          style: GoogleFonts.barlow(
            color: const Color(0xFF8E8E93),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Got it',
              style: GoogleFonts.barlow(
                color: const Color(0xFF38EF7D),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Model for chat messages
class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
  });
}
