import 'package:flutter/material.dart';

/// Small, reusable tap-feedback wrapper: scales down slightly on press and
/// back on release, so buttons and cards feel responsive instead of static.
/// Used in place of a bare GestureDetector wherever a visible tap animation
/// was requested. `onTap` null disables both the tap and the animation.
class AnimatedTap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;

  const AnimatedTap({
    super.key,
    required this.child,
    required this.onTap,
    this.pressedScale = 0.96,
  });

  @override
  State<AnimatedTap> createState() => _AnimatedTapState();
}

class _AnimatedTapState extends State<AnimatedTap> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (widget.onTap == null) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
