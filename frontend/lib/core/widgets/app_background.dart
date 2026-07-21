import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

// ============================================================================
// APP BACKGROUND — Reusable background widget
// Displays default gradient blobs OR a user-selected custom image.
// Listens to Hive settings box for 'bgImagePath' key.
// ============================================================================

class AppBackground extends StatelessWidget {
  final bool isDark;
  const AppBackground({super.key, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: Hive.box('settings').listenable(keys: ['bgImagePath']),
      builder: (context, Box box, _) {
        final String? bgPath = box.get('bgImagePath');

        if (bgPath != null && bgPath.isNotEmpty) {
          return _CustomImageBackground(imagePath: bgPath, isDark: isDark);
        }

        return _GradientBlobsBackground(isDark: isDark);
      },
    );
  }
}

// ─── Default Gradient Blobs ──────────────────────────────────────────────────

class _GradientBlobsBackground extends StatelessWidget {
  final bool isDark;
  const _GradientBlobsBackground({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [const Color(0xFF0F172A), const Color(0xFF020617)]
              : [const Color(0xFFF8FAFC), const Color(0xFFE2E8F0)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -80,
            left: -80,
            child: _GlowBlob(
              size: 320,
              color: const Color(0xFF6366F1),
              opacity: isDark ? 0.22 : 0.15,
            ),
          ),
          Positioned(
            bottom: -100,
            right: -80,
            child: _GlowBlob(
              size: 360,
              color: const Color(0xFFEC4899),
              opacity: isDark ? 0.18 : 0.12,
            ),
          ),
          Positioned(
            top: 250,
            right: -50,
            child: _GlowBlob(
              size: 200,
              color: const Color(0xFF14B8A6),
              opacity: isDark ? 0.15 : 0.08,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowBlob extends StatelessWidget {
  final double size;
  final Color color;
  final double opacity;
  const _GlowBlob({
    required this.size,
    required this.color,
    required this.opacity,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withOpacity(opacity),
      ),
    );
  }
}

// ─── Custom Image Background ──────────────────────────────────────────────────

class _CustomImageBackground extends StatelessWidget {
  final String imagePath;
  final bool isDark;
  const _CustomImageBackground({required this.imagePath, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Custom background image
        kIsWeb
            ? Image.network(
                imagePath,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _GradientBlobsBackground(isDark: isDark),
              )
            : Image.file(
                File(imagePath),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _GradientBlobsBackground(isDark: isDark),
              ),
        // Dark/light overlay for readability
        Container(
          color: isDark
              ? Colors.black.withOpacity(0.55)
              : Colors.white.withOpacity(0.35),
        ),
        // Subtle blur for glassmorphism harmony
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 2.0, sigmaY: 2.0),
          child: Container(color: Colors.transparent),
        ),
      ],
    );
  }
}
