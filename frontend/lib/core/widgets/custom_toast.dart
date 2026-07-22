import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum ToastBehavior {
  success,
  info,
  warning,
  error,
}

class GlassToast extends StatefulWidget {
  final Widget icon;
  final Color color;
  final String message;
  final String? title;
  final Duration timeout;
  final ToastBehavior behave;
  final VoidCallback onDismiss;

  const GlassToast({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
    this.title,
    required this.timeout,
    required this.behave,
    required this.onDismiss,
  });

  static void show(
    BuildContext context, {
    required Widget icon,
    required Color color,
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
    ToastBehavior behave = ToastBehavior.info,
  }) {
    late OverlayEntry overlayEntry;
    overlayEntry = OverlayEntry(
      builder: (context) => SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: GlassToast(
            icon: icon,
            color: color,
            message: message,
            title: title,
            timeout: timeout,
            behave: behave,
            onDismiss: () {
              overlayEntry.remove();
            },
          ),
        ),
      ),
    );
    Overlay.of(context).insert(overlayEntry);
  }

  /// Master Shortcut: Display Success Toast
  static void success(
    BuildContext context, {
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
  }) {
    show(
      context,
      icon: const Icon(Icons.check_circle_outline, color: Colors.green),
      color: Colors.green,
      message: message,
      title: title,
      timeout: timeout,
      behave: ToastBehavior.success,
    );
  }

  /// Master Shortcut: Display Error Toast
  static void error(
    BuildContext context, {
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
  }) {
    show(
      context,
      icon: const Icon(Icons.error_outline, color: Colors.redAccent),
      color: Colors.redAccent,
      message: message,
      title: title,
      timeout: timeout,
      behave: ToastBehavior.error,
    );
  }

  /// Master Shortcut: Display Warning Toast
  static void warning(
    BuildContext context, {
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
  }) {
    show(
      context,
      icon: const Icon(Icons.warning_amber_rounded, color: Colors.amber),
      color: Colors.amber,
      message: message,
      title: title,
      timeout: timeout,
      behave: ToastBehavior.warning,
    );
  }

  /// Master Shortcut: Display Info Toast
  static void info(
    BuildContext context, {
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
  }) {
    show(
      context,
      icon: const Icon(Icons.info_outline, color: Color(0xFF6366F1)),
      color: const Color(0xFF6366F1),
      message: message,
      title: title,
      timeout: timeout,
      behave: ToastBehavior.info,
    );
  }

  @override
  State<GlassToast> createState() => _GlassToastState();
}

/// Unified Master Toast Utility Class
class AppToast {
  static void success(
    BuildContext context, {
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
  }) {
    GlassToast.success(context, message: message, title: title, timeout: timeout);
  }

  static void error(
    BuildContext context, {
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
  }) {
    GlassToast.error(context, message: message, title: title, timeout: timeout);
  }

  static void warning(
    BuildContext context, {
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
  }) {
    GlassToast.warning(context, message: message, title: title, timeout: timeout);
  }

  static void info(
    BuildContext context, {
    required String message,
    String? title,
    Duration timeout = const Duration(seconds: 3),
  }) {
    GlassToast.info(context, message: message, title: title, timeout: timeout);
  }
}

class _GlassToastState extends State<GlassToast> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    // Spring/Elastic slide effect
    _slideAnimation = Tween<double>(begin: -150.0, end: 16.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const ElasticOutCurve(0.9),
      ),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOut,
      ),
    );

    _controller.forward();

    // Auto-dismiss logic
    Future.delayed(widget.timeout, () {
      if (mounted) {
        _controller.reverse().then((_) {
          widget.onDismiss();
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Toast styling based on behavior types
    Color borderAccentColor = widget.color;
    String headerTitle = widget.title ?? _getDefaultTitle(widget.behave);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slideAnimation.value),
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: child,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Material(
          color: Colors.transparent,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.black.withOpacity(0.4)
                      : Colors.white.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withOpacity(0.08)
                        : Colors.black.withOpacity(0.06),
                    width: 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    // Toast type color indicator bar
                    Container(
                      width: 4,
                      height: 38,
                      decoration: BoxDecoration(
                        color: borderAccentColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Icon
                    CircleAvatar(
                      backgroundColor: borderAccentColor.withOpacity(0.15),
                      radius: 18,
                      child: IconTheme(
                        data: IconThemeData(color: borderAccentColor, size: 20),
                        child: widget.icon,
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Toast Messages Text
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            headerTitle,
                            style: GoogleFonts.outfit(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.message,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Close Trigger button
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      color: isDark ? Colors.white38 : Colors.black38,
                      onPressed: () {
                        _controller.reverse().then((_) {
                          widget.onDismiss();
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _getDefaultTitle(ToastBehavior behave) {
    switch (behave) {
      case ToastBehavior.success:
        return 'Success';
      case ToastBehavior.error:
        return 'Alert';
      case ToastBehavior.warning:
        return 'Warning';
      case ToastBehavior.info:
        return 'Notification';
    }
  }
}
