import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../auth/data/auth_provider.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  String _appVersion = 'Loading...';

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _navigateToNext();
  }

  void _loadVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = 'v${packageInfo.version}';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _appVersion = 'v1.0.0';
        });
      }
    }
  }

  void _navigateToNext() async {
    // Wait for 3 seconds of showing splash screen
    await Future.delayed(const Duration(seconds: 3));

    if (!context.mounted) return;

    final box = await Hive.openBox('settings');
    if (!context.mounted) return;
    final isWizardCompleted = box.get('wizardCompleted', defaultValue: false);

    if (!isWizardCompleted) {
      context.go('/wizard');
    } else {
      final authState = ref.read(authProvider);
      if (authState.isAuthenticated) {
        context.go('/dashboard');
      } else {
        context.go('/login');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [const Color(0xFF0F172A), const Color(0xFF020617)]
                : [const Color(0xFFF8FAFC), const Color(0xFFE2E8F0)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const IotDiscoveryAnimation(),
              const SizedBox(height: 40),
              Text(
                'ESPHome Client',
                style: GoogleFonts.outfit(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Secure Node Control Ecosystem',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                ),
              ),
              const SizedBox(height: 48),
              Text(
                _appVersion,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class IotDiscoveryAnimation extends StatefulWidget {
  const IotDiscoveryAnimation({super.key});

  @override
  State<IotDiscoveryAnimation> createState() => _IotDiscoveryAnimationState();
}

class _IotDiscoveryAnimationState extends State<IotDiscoveryAnimation> with TickerProviderStateMixin {
  late AnimationController _rippleController;
  late AnimationController _nodesController;

  @override
  void initState() {
    super.initState();
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _nodesController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..forward();
  }

  @override
  void dispose() {
    _rippleController.dispose();
    _nodesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    final List<Map<String, dynamic>> nodes = [
      {'icon': Icons.lightbulb_outline_rounded, 'angle': -pi / 4, 'delay': 0.2},
      {'icon': Icons.toys_outlined, 'angle': pi / 2 + pi / 6, 'delay': 0.5},
      {'icon': Icons.power_rounded, 'angle': pi, 'delay': 0.8},
    ];

    return SizedBox(
      height: 250,
      width: 250,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Concentric fading signal waves
          AnimatedBuilder(
            animation: _rippleController,
            builder: (context, child) {
              return CustomPaint(
                size: const Size(220, 220),
                painter: RipplePainter(
                  progress: _rippleController.value,
                  color: theme.primaryColor,
                ),
              );
            },
          ),
          // 2. Connecting lines from central hub to discovered nodes
          AnimatedBuilder(
            animation: _nodesController,
            builder: (context, child) {
              return CustomPaint(
                size: const Size(220, 220),
                painter: ConnectionLinePainter(
                  progress: _nodesController.value,
                  nodes: nodes,
                  color: theme.primaryColor.withOpacity(0.5),
                ),
              );
            },
          ),
          // 3. Discovered Nodes (floating around the central gateway)
          ...nodes.map((node) {
            final double angle = node['angle'];
            final double delay = node['delay'];
            
            final Animation<double> nodeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
              CurvedAnimation(
                parent: _nodesController,
                curve: Interval(delay, (delay + 0.25).clamp(0.0, 1.0), curve: Curves.easeOutBack),
              ),
            );

            const double radius = 85.0;
            final double dx = radius * cos(angle);
            final double dy = radius * sin(angle);

            return AnimatedBuilder(
              animation: nodeAnimation,
              builder: (context, child) {
                if (nodeAnimation.value == 0.0) return const SizedBox.shrink();
                return Transform.translate(
                  offset: Offset(dx, dy),
                  child: Transform.scale(
                    scale: nodeAnimation.value,
                    child: Opacity(
                      opacity: nodeAnimation.value,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark ? Colors.white.withOpacity(0.06) : Colors.black.withOpacity(0.04),
                          border: Border.all(
                            color: theme.primaryColor.withOpacity(0.35),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: theme.primaryColor.withOpacity(0.12),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Icon(
                          node['icon'],
                          size: 20,
                          color: theme.primaryColor,
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          }),
          // 4. Central pulsing Gateway Hub
          ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.08).animate(
              CurvedAnimation(
                parent: _rippleController,
                curve: Curves.easeInOut,
              ),
            ),
            child: Container(
              height: 76,
              width: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.primaryColor.withOpacity(0.18),
                border: Border.all(
                  color: theme.primaryColor.withOpacity(0.4),
                  width: 2.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: theme.primaryColor.withOpacity(0.35),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(
                Icons.sensors,
                size: 38,
                color: theme.primaryColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class RipplePainter extends CustomPainter {
  final double progress;
  final Color color;

  RipplePainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    for (int i = 0; i < 3; i++) {
      final rippleProgress = (progress + i / 3.0) % 1.0;
      final radius = maxRadius * rippleProgress;
      final opacity = (1.0 - rippleProgress) * 0.45;
      
      final paint = Paint()
        ..color = color.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant RipplePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}

class ConnectionLinePainter extends CustomPainter {
  final double progress;
  final List<Map<String, dynamic>> nodes;
  final Color color;

  ConnectionLinePainter({
    required this.progress,
    required this.nodes,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const double radius = 85.0;

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (var node in nodes) {
      final double angle = node['angle'];
      final double delay = node['delay'];

      if (progress > delay) {
        final double lineProgress = ((progress - delay) / 0.25).clamp(0.0, 1.0);
        if (lineProgress <= 0.0) continue;

        final double destX = radius * cos(angle);
        final double destY = radius * sin(angle);
        
        final currentOffset = center + Offset(destX * lineProgress, destY * lineProgress);
        _drawDashedLine(canvas, center, currentOffset, paint);
      }
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const double dashWidth = 4.0;
    const double dashSpace = 4.0;
    
    final double dx = p2.dx - p1.dx;
    final double dy = p2.dy - p1.dy;
    final double distance = sqrt(dx * dx + dy * dy);
    if (distance <= 0) return;
    
    final double angle = atan2(dy, dx);
    double drawn = 0.0;
    
    while (drawn < distance) {
      final double nextX = p1.dx + cos(angle) * (drawn + dashWidth);
      final double nextY = p1.dy + sin(angle) * (drawn + dashWidth);
      
      canvas.drawLine(
        Offset(p1.dx + cos(angle) * drawn, p1.dy + sin(angle) * drawn),
        Offset(nextX > p2.dx && dx > 0 ? p2.dx : nextX, nextY > p2.dy && dy > 0 ? p2.dy : nextY),
        paint,
      );
      
      drawn += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant ConnectionLinePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
