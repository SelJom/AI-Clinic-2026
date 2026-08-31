import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/backend_service.dart';
import '../widgets/animated_tap.dart';
import '../widgets/quick_suggestions.dart';

/// AI Chat screen with modern interface inspired by ChatGPT/Claude
class AIChatScreen extends StatefulWidget {
  final String patientId;
  final Map<String, dynamic>? healthData;

  /// True when shown as an always-visible side panel (see home_shell.dart's
  /// wide-screen layout) rather than pushed onto the navigation stack -
  /// drops the Scaffold/AppBar and back button, since there's no pushed
  /// route to pop back to and no need to hide the rest of the app to see it.
  final bool embedded;

  const AIChatScreen({
    super.key,
    required this.patientId,
    this.healthData,
    this.embedded = false,
  });

  @override
  State<AIChatScreen> createState() => _AIChatScreenState();
}

class _AIChatScreenState extends State<AIChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final BackendService _backendService = BackendService();
  final List<ChatMessage> _messages = [];
  bool _isTyping = false;

  @override
  void initState() {
    super.initState();
    // Welcome message
    _messages.add(ChatMessage(
      text: "👋 Hi! I'm your AI health coach. How can I help you today?",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _sendMessage() {
    if (_messageController.text.trim().isEmpty) return;

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

    _fetchCoachReply(userMessage.text);
  }

  /// Calls the local guideline-grounded coach (backend/health_coach/api.py
  /// `/chat`). If the backend isn't running, degrades to a message telling
  /// the user how to start it rather than fabricating a reply.
  Future<void> _fetchCoachReply(String message) async {
    String reply;
    try {
      reply = await _backendService.chat(widget.patientId, message);
    } on BackendUnavailableException {
      reply = "I can't reach the local coaching service right now. On your "
          'dev machine, run:\npython -m health_coach.cli serve';
    }

    if (!mounted) return;
    setState(() {
      _messages.add(ChatMessage(
        text: reply,
        isUser: false,
        timestamp: DateTime.now(),
      ));
      _isTyping = false;
    });
    _scrollToBottom();
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
    if (widget.embedded) {
      // No Scaffold/AppBar/back button: this is a permanent panel next to
      // TodayScreen, not a pushed route - there's nothing to pop back to,
      // and the whole point is that the rest of the app stays visible.
      return Container(
        color: const Color(0xFF000000),
        child: Column(
          children: [
            _buildEmbeddedHeader(),
            Expanded(child: _buildMessagesList()),
            _buildInputArea(),
          ],
        ),
      );
    }
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

  Widget _buildEmbeddedHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        border: Border(bottom: BorderSide(color: Color(0xFF2C2C2E), width: 1)),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF11998E), Color(0xFF38EF7D)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.psychology_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI Health Coach',
                  style: GoogleFonts.barlow(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Online',
                  style: GoogleFonts.barlow(color: const Color(0xFF38EF7D), fontSize: 11, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ],
        ),
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
            healthData: widget.healthData,
          );
        }
        return _buildMessageBubble(_messages[index]);
      },
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    // Fade + slide-up on appearance - runs once per bubble the first time
    // it's built (new message added, or an existing one scrolling into a
    // freshly-built ListView.builder item), giving messages a bit of life
    // instead of just popping into place.
    return TweenAnimationBuilder<double>(
      key: ValueKey(message),
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(offset: Offset(0, (1 - value) * 12), child: child),
        );
      },
      child: Padding(
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
                  child: message.isUser
                      ? Text(
                          message.text,
                          style: GoogleFonts.barlow(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            height: 1.4,
                          ),
                        )
                      : _TypewriterText(
                          message: message,
                          style: GoogleFonts.barlow(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            height: 1.4,
                          ),
                          onCharacterRevealed: _scrollToBottom,
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
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            AnimatedTap(
              onTap: _sendMessage,
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
                // TODO: implement sharing
              },
            ),
            _buildOptionTile(
              icon: Icons.info_outline,
              title: 'About the AI coach',
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
          'Your personal assistant for a healthier lifestyle. I can help with guidance on physical activity, sleep, nutrition, and general well-being.\n\n⚠️ My advice does not replace professional medical guidance.',
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

  /// Set once the flowy reveal in [_TypewriterText] has fully played through
  /// this message, so scrolling it back into view (ListView.builder can
  /// rebuild off-screen items) shows the finished text instantly instead of
  /// re-running the animation every time.
  bool hasAnimated;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.hasAnimated = false,
  });
}

/// Reveals [message.text] a few characters at a time, like watching a reply
/// get typed out live rather than popping onto the screen fully formed.
/// Deliberately a post-hoc reveal of an already-complete reply rather than
/// true token streaming from Ollama: the grounding safety net in
/// llm_backends.py (ground_reply/ground_citations) needs the full response
/// before it can safely check and rewrite any fabricated number - showing
/// tokens as they arrive would mean briefly displaying text that might get
/// silently corrected a moment later, which defeats the point of grounding
/// the reply before the patient ever sees it.
class _TypewriterText extends StatefulWidget {
  final ChatMessage message;
  final TextStyle style;
  final VoidCallback? onCharacterRevealed;

  const _TypewriterText({
    required this.message,
    required this.style,
    this.onCharacterRevealed,
  });

  @override
  State<_TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<_TypewriterText> {
  late int _charCount;
  Timer? _timer;

  static const _tick = Duration(milliseconds: 18);
  static const _charsPerTick = 2;

  @override
  void initState() {
    super.initState();
    if (widget.message.hasAnimated || widget.message.text.isEmpty) {
      _charCount = widget.message.text.length;
    } else {
      _charCount = 0;
      _timer = Timer.periodic(_tick, _onTick);
    }
  }

  void _onTick(Timer timer) {
    if (!mounted) {
      timer.cancel();
      return;
    }
    final total = widget.message.text.length;
    setState(() {
      _charCount = (_charCount + _charsPerTick).clamp(0, total);
    });
    widget.onCharacterRevealed?.call();
    if (_charCount >= total) {
      timer.cancel();
      widget.message.hasAnimated = true;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(widget.message.text.substring(0, _charCount), style: widget.style);
  }
}
