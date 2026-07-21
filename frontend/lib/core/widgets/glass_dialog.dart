import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class GlassDialog {
  static Future<T?> show<T>(
    BuildContext context, {
    required Widget title,
    required Widget content,
    List<Widget>? actions,
    bool barrierDismissible = true,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: 'GlassDialog',
      barrierColor: Colors.black.withOpacity(0.4),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) {
        return const SizedBox.shrink();
      },
      transitionBuilder: (context, anim1, anim2, child) {
        final curve = CurvedAnimation(parent: anim1, curve: Curves.easeOutBack);
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;

        return ScaleTransition(
          scale: curve,
          child: FadeTransition(
            opacity: anim1,
            child: Align(
              alignment: Alignment.center,
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20.0, sigmaY: 20.0),
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 340),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.black.withOpacity(0.4)
                              : Colors.white.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: isDark
                                ? Colors.white.withOpacity(0.12)
                                : Colors.black.withOpacity(0.08),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.15),
                              blurRadius: 24,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Title
                            DefaultTextStyle(
                              style: GoogleFonts.outfit(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                              textAlign: TextAlign.center,
                              child: title,
                            ),
                            const SizedBox(height: 16),
                            // Content
                            DefaultTextStyle(
                              style: GoogleFonts.inter(
                                fontSize: 13.5,
                                color: isDark ? Colors.white70 : Colors.black87,
                                height: 1.4,
                              ),
                              child: content,
                            ),
                            if (actions != null && actions.isNotEmpty) ...[
                              const SizedBox(height: 24),
                              // Vertical buttons layout similar to iOS Action sheets
                              // or horizontal if there are only 2 buttons
                              if (actions.length == 2)
                                Row(
                                  children: [
                                    Expanded(child: actions[0]),
                                    const SizedBox(width: 12),
                                    Expanded(child: actions[1]),
                                  ],
                                )
                              else
                                Column(
                                  children: actions.map((act) {
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 8.0),
                                      child: SizedBox(
                                        width: double.infinity,
                                        child: act,
                                      ),
                                    );
                                  }).toList(),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
