import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../core/theme/theme_provider.dart';
import '../../update/data/update_provider.dart';
import '../../update/presentation/update_dialog.dart';
import '../data/nodes_provider.dart';
import '../../../core/widgets/glass_container.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_dialog.dart';
import '../../../core/utils/sensor_registry.dart';
import '../../auth/data/auth_provider.dart';
import '../../control/data/node_permission_service.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../../core/network/udp_discovery_service.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  DateTime? _lastBackPressTime;

  bool _showSeconds = true;
  Timer? _clockTimer;
  DateTime _currentDateTime = DateTime.now();

  // Scroll-aware AppBar state
  final ScrollController _scrollController = ScrollController();
  bool _isScrolled = false;
  bool _isUpdateDialogShowing = false;

  StreamSubscription<DiscoveredNode>? _discoverySub;
  final Set<String> _promptedMacs = {};

  @override
  void initState() {
    super.initState();

    _scrollController.addListener(_onScroll);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _currentDateTime = DateTime.now();
        });
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final udpService = ref.read(udpDiscoveryServiceProvider);
      _discoverySub?.cancel();
      _discoverySub = udpService.onNodeDiscovered.listen((node) {
        if (mounted) {
          _handleNewDiscoveredNodePopup(node);
        }
      });
    });

    // Delay connection check: give Firebase SDK 5 seconds to establish connection
    // before reporting offline to avoid false-positive "cannot connect" at startup.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(const Duration(seconds: 5));
      if (!mounted) return;
      _checkServerConnection();
      if (!kIsWeb) {
        await ref.read(updateProvider.notifier).checkForUpdates();
        if (!context.mounted) return;
        if (ref.read(updateProvider).hasUpdate) {
          showDialog(
            context: context,
            builder: (context) => const UpdateDialog(),
          );
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      int checks = 0;
      while (mounted && checks < 30) {
        final auth = ref.read(authProvider);
        if (auth.isAuthenticated && !auth.isLoading) {
          if ((auth.firstName == null || auth.firstName!.trim().isEmpty) ||
              (auth.lastName == null || auth.lastName!.trim().isEmpty)) {
            _showUpdateProfileDialog();
          }
          break;
        }
        await Future.delayed(const Duration(milliseconds: 500));
        checks++;
      }
    });
  }

  void _handleNewDiscoveredNodePopup(DiscoveredNode node) {
    final cleanMac = node.mac.replaceAll(':', '').toUpperCase();
    final existingNodes = ref.read(nodesProvider);
    final isAlreadyAdded = existingNodes.any(
      (n) =>
          (n['mac'] as String? ?? '').replaceAll(':', '').toUpperCase() ==
          cleanMac,
    );

    if (isAlreadyAdded || _promptedMacs.contains(cleanMac)) {
      return;
    }
    _promptedMacs.add(cleanMac);

    final apiKeyController = TextEditingController(text: 'ESPHome_sec_node');
    final nameController = TextEditingController();
    bool isAdvancedExpanded = false;

    GlassDialog.show(
      context,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.wifi_find_rounded,
            color: Colors.blueAccent,
            size: 24,
          ),
          const SizedBox(width: 8),
          Text(
            'New Node Discovered!',
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: StatefulBuilder(
        builder: (context, setDialogState) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final mac4 = cleanMac.length >= 4
              ? cleanMac.substring(cleanMac.length - 4)
              : cleanMac;

          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'A new ESP32 node was detected on your local Wi-Fi network.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withOpacity(0.05)
                        : Colors.black.withOpacity(0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withOpacity(0.1)
                          : Colors.black.withOpacity(0.06),
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'MAC Address:',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          Text(
                            node.mac,
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'IP Address:',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          Text(
                            node.ip,
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () {
                    setDialogState(() {
                      isAdvancedExpanded = !isAdvancedExpanded;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 4,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.tune_rounded,
                              size: 16,
                              color: Theme.of(context).primaryColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Advanced Settings',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                          ],
                        ),
                        Icon(
                          isAdvancedExpanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 20,
                          color: Theme.of(context).primaryColor,
                        ),
                      ],
                    ),
                  ),
                ),
                if (isAdvancedExpanded) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameController,
                    style: GoogleFonts.inter(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Node Name (Optional)',
                      hintText: 'ESP32 Node ($mac4)',
                      prefixIcon: const Icon(Icons.label_outline, size: 18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: apiKeyController,
                    style: GoogleFonts.inter(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Custom API Key',
                      hintText: 'ESPHome_sec_node',
                      prefixIcon: const Icon(Icons.key_rounded, size: 18),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Ignore', style: GoogleFonts.outfit(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: () async {
            Navigator.pop(context);
            final customKey = apiKeyController.text.trim();
            final customName = nameController.text.trim();

            final success = ref
                .read(nodesProvider.notifier)
                .addDiscoveredNode(
                  mac: node.mac,
                  ip: node.ip,
                  apiKey: customKey.isNotEmpty ? customKey : 'ESPHome_sec_node',
                  name: customName,
                );

            if (success && mounted) {
              final auth = ref.read(authProvider);
              if (auth.role == 'admin') {
                GlassToast.show(
                  context,
                  icon: const Icon(
                    Icons.check_circle_outline,
                    color: Colors.green,
                  ),
                  color: Colors.green,
                  message: 'Node added successfully!',
                  behave: ToastBehavior.success,
                );
              } else {
                GlassToast.show(
                  context,
                  icon: const Icon(
                    Icons.lock_clock_rounded,
                    color: Colors.orangeAccent,
                  ),
                  color: Colors.orange,
                  message:
                      'Node added. Pending Admin approval for full control.',
                  behave: ToastBehavior.info,
                );
              }
            }
          },
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            'Add Node',
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  void _onScroll() {
    final scrolled = _scrollController.offset > 10;
    if (scrolled != _isScrolled) {
      setState(() => _isScrolled = scrolled);
    }
  }

  Future<void> _checkServerConnection() async {
    // 1. Check if we have mobile data or WiFi interface enabled
    if (!kIsWeb) {
      final hasInterface = await _hasNetworkInterface();
      if (!hasInterface) {
        if (mounted) {
          GlassToast.show(
            context,
            icon: const Icon(Icons.wifi_off_rounded, color: Colors.redAccent),
            color: Colors.red,
            message: 'For using this app you need to connect to the internet',
            behave: ToastBehavior.error,
          );
        }
        return;
      }
    }

    // 2. We have a network interface, now check Firebase connection
    StreamSubscription<DatabaseEvent>? subscription;
    Timer? timeoutTimer;
    bool hasConnected = false;

    try {
      subscription = FirebaseDatabase.instance
          .ref('.info/connected')
          .onValue
          .listen((event) {
            final connected = event.snapshot.value as bool? ?? false;
            if (connected) {
              hasConnected = true;
              subscription?.cancel();
              timeoutTimer?.cancel();
            }
          });

      timeoutTimer = Timer(const Duration(seconds: 8), () async {
        subscription?.cancel();
        if (!hasConnected) {
          // Verify if internet lookup succeeds (e.g. google.com)
          final hasInternet = await _checkInternetConnection();
          if (!hasInternet && mounted) {
            GlassToast.show(
              context,
              icon: const Icon(Icons.wifi_off_rounded, color: Colors.redAccent),
              color: Colors.red,
              message: 'For using this app you need to connect to the internet',
              behave: ToastBehavior.error,
            );
          } else if (mounted) {
            GlassToast.show(
              context,
              icon: const Icon(
                Icons.cloud_off_rounded,
                color: Colors.orangeAccent,
              ),
              color: Colors.orange,
              message:
                  'Cannot connect to the server. Running in offline cached mode.',
              behave: ToastBehavior.warning,
            );
          }
        }
      });
    } catch (_) {
      subscription?.cancel();
      timeoutTimer?.cancel();
    }
  }

  Future<bool> _hasNetworkInterface() async {
    // Web cannot check network interfaces via dart:io; assume connected
    if (kIsWeb) return true;
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.any,
      );
      return interfaces.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _checkInternetConnection() async {
    if (kIsWeb) return true;
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _clockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final isDark = theme.brightness == Brightness.dark;

    // Listen to global nodes state
    final nodes = ref.watch(nodesProvider);

    // Listen to dynamic user role updates
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.requiresReload) {
        _showReloadDialog(context, ref);
      }
      if (previous != null &&
          previous.isAuthenticated &&
          next.isAuthenticated) {
        if (previous.role != next.role &&
            previous.role != null &&
            next.role != null) {
          _showRoleChangedDialog(context, previous.role!, next.role!);
        }
      }
    });

    // Read current user role
    final authState = ref.watch(authProvider);
    // User display name resolution (display_name > first_name + last_name > email prefix)
    final String userDisplayName;
    if (authState.name != null && authState.name!.trim().isNotEmpty) {
      userDisplayName = authState.name!.trim();
    } else if (authState.firstName != null &&
        authState.firstName!.trim().isNotEmpty) {
      userDisplayName =
          "${authState.firstName!.trim()} ${authState.lastName?.trim() ?? ''}"
              .trim();
    } else {
      userDisplayName = _getUserFirstName(authState.email);
    }
    final greeting = _getTimeGreeting();

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPressTime == null ||
            now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          GlassToast.show(
            context,
            icon: const Icon(Icons.exit_to_app_rounded),
            color: Colors.redAccent,
            message: 'Press back again to exit',
            behave: ToastBehavior.warning,
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Reusable background — gradient blobs or custom image from settings
            AppBackground(isDark: isDark),
            ValueListenableBuilder(
              valueListenable: Hive.box(
                'settings',
              ).listenable(keys: ['dashboardLayout']),
              builder: (context, Box box, _) {
                final layoutMode = box.get(
                  'dashboardLayout',
                  defaultValue: 'grid',
                );

                // NestedScrollView with outer controller for scroll-aware AppBar
                return NestedScrollView(
                  controller: _scrollController,
                  headerSliverBuilder: (ctx, innerBoxIsScrolled) {
                    final scrolled = innerBoxIsScrolled || _isScrolled;
                    return [
                      // ── Scroll-Aware Pinned Sliver AppBar ─────────────────
                      SliverAppBar(
                        pinned: true,
                        elevation: 0,
                        backgroundColor: Colors.transparent,
                        surfaceTintColor: Colors.transparent,
                        flexibleSpace: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(
                              sigmaX: scrolled ? 20.0 : 0.0,
                              sigmaY: scrolled ? 20.0 : 0.0,
                            ),
                            child: Container(
                              decoration: BoxDecoration(
                                color: scrolled
                                    ? (isDark
                                          ? const Color(
                                              0xFF0A0F1E,
                                            ).withOpacity(0.82)
                                          : Colors.white.withOpacity(0.85))
                                    : Colors.transparent,
                                border: Border(
                                  bottom: BorderSide(
                                    color: scrolled
                                        ? (isDark
                                              ? Colors.white.withOpacity(0.12)
                                              : Colors.black.withOpacity(0.08))
                                        : Colors.transparent,
                                    width: 1.0,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        actions: [
                          IconButton(
                            icon: Icon(
                              themeMode == ThemeMode.dark
                                  ? Icons.light_mode
                                  : Icons.dark_mode,
                            ),
                            onPressed: () {
                              ref
                                  .read(themeModeProvider.notifier)
                                  .toggleTheme();
                            },
                            tooltip: 'Toggle Theme',
                          ),
                          IconButton(
                            icon: const Icon(Icons.settings),
                            onPressed: () => context.push('/settings'),
                            tooltip: 'Settings',
                          ),
                        ],
                        title: RichText(
                          text: TextSpan(
                            text: 'ESP',
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                              color: const Color(0xFF3B82F6),
                            ),
                            children: [
                              TextSpan(
                                text: 'Home',
                                style: GoogleFonts.outfit(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 20,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                              if (kIsWeb)
                                TextSpan(
                                  text: ' - Dashboard',
                                  style: GoogleFonts.outfit(
                                    fontWeight: FontWeight.w400,
                                    fontSize: 16,
                                    color: isDark
                                        ? Colors.white70
                                        : Colors.black54,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: SafeArea(
                          top: false,
                          bottom: false,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildGreetingText(
                                  theme,
                                  isDark,
                                  greeting,
                                  userDisplayName,
                                ),
                                const SizedBox(height: 12),
                                // Sensor telemetry banner
                                _buildTelemetryBanner(theme, isDark, nodes),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ];
                  },
                  body: _buildNodesView(theme, isDark, nodes, layoutMode),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Returns a time-based greeting
  String _getTimeGreeting() {
    final hour = _currentDateTime.hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  Widget _buildGreetingText(
    ThemeData theme,
    bool isDark,
    String greeting,
    String userDisplayName,
  ) {
    final timeFormat = Hive.box(
      'settings',
    ).get('timeFormat', defaultValue: '12h');
    final formattedTime = _formatTimeDisplay(
      _currentDateTime.hour,
      _currentDateTime.minute,
      _currentDateTime.second,
      timeFormat,
      _showSeconds,
    );

    final dayName = _getDayName(_currentDateTime.weekday);
    final monthName = _getMonthName(_currentDateTime.month);
    final day = _currentDateTime.day;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Left Column: Greetings & Name
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                greeting,
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                userDisplayName,
                style: GoogleFonts.outfit(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        ),
        // Right Column: Date & Time (Clickable to toggle seconds)
        GestureDetector(
          onTap: () => setState(() => _showSeconds = !_showSeconds),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.access_time_rounded,
                    size: 15,
                    color: theme.primaryColor,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    formattedTime,
                    style: GoogleFonts.outfit(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$dayName, $day $monthName',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _getDayName(int day) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return days[day - 1];
  }

  String _getMonthName(int month) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return months[month - 1];
  }

  void _showUpdateProfileDialog() {
    if (_isUpdateDialogShowing) return;
    _isUpdateDialogShowing = true;
    final firstCtrl = TextEditingController();
    final lastCtrl = TextEditingController();
    final nameCtrl = TextEditingController();

    GlassDialog.show(
      context,
      barrierDismissible: false,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.person_outline_rounded,
            color: Colors.blueAccent,
            size: 24,
          ),
          const SizedBox(width: 8),
          Text(
            'Please Update Your Profile',
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Set your details to personalize your ESPHome dashboard and permissions.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: firstCtrl,
              style: GoogleFonts.inter(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'First Name',
                prefixIcon: const Icon(Icons.person),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: lastCtrl,
              style: GoogleFonts.inter(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Last Name',
                prefixIcon: const Icon(Icons.person),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              style: GoogleFonts.inter(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Display Name (Optional)',
                prefixIcon: const Icon(Icons.badge_outlined),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () async {
            final first = firstCtrl.text.trim();
            final last = lastCtrl.text.trim();
            final name = nameCtrl.text.trim();
            if (first.isNotEmpty && last.isNotEmpty) {
              Navigator.pop(context);
              _isUpdateDialogShowing = false;
              await ref
                  .read(authProvider.notifier)
                  .updateProfile(firstName: first, lastName: last, name: name);
              if (mounted) {
                GlassToast.show(
                  context,
                  icon: const Icon(
                    Icons.check_circle_outline,
                    color: Colors.green,
                  ),
                  color: Colors.green,
                  message: 'Profile updated successfully!',
                  behave: ToastBehavior.success,
                );
              }
            } else {
              GlassToast.show(
                context,
                icon: const Icon(Icons.error_outline, color: Colors.redAccent),
                color: Colors.redAccent,
                message: 'First and Last name cannot be empty',
                behave: ToastBehavior.error,
              );
            }
          },
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            'Update Profile',
            style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// Extracts the display name from email (before @ or full email prefix)
  String _getUserFirstName(String? email) {
    if (email == null || email.isEmpty) return 'User';
    final atIndex = email.indexOf('@');
    final raw = atIndex > 0 ? email.substring(0, atIndex) : email;
    // Capitalize first letter
    return raw.isNotEmpty
        ? '${raw[0].toUpperCase()}${raw.substring(1)}'
        : 'User';
  }

  // ─────────────────────────────────────────────────────────────────────
  // Telemetry Banner — Universal SensorRegistry-based rendering
  // Displays ALL sensors across all nodes (averaged). Supports any sensor key.
  // ─────────────────────────────────────────────────────────────────────

  Widget _buildTelemetryBanner(
    ThemeData theme,
    bool isDark,
    List<Map<String, dynamic>> nodes,
  ) {
    // Collect all unique sensor keys from all nodes
    final Map<String, List<num>> sensorAccumulator = {};

    for (final node in nodes) {
      // Primary: use sensorReadings if available (extended sensor support)
      final dynamic readings = node['sensorReadings'];
      if (readings is Map && readings.isNotEmpty) {
        readings.forEach((k, v) {
          final key = k.toString();
          if (v is num) {
            sensorAccumulator.putIfAbsent(key, () => []).add(v);
          }
        });
      } else {
        // Fallback: legacy temp/humi fields
        final sensors = node['sensors'];
        if (sensors is List) {
          if (sensors.contains('temperature') && node['temp'] is num) {
            sensorAccumulator
                .putIfAbsent('temperature', () => [])
                .add(node['temp'] as num);
          }
          if (sensors.contains('humidity') && node['humi'] is num) {
            sensorAccumulator
                .putIfAbsent('humidity', () => [])
                .add(node['humi'] as num);
          }
        }
      }
    }

    if (sensorAccumulator.isEmpty) return const SizedBox.shrink();

    // Compute averages
    final List<MapEntry<String, double>> avgEntries = sensorAccumulator.entries
        .map(
          (e) =>
              MapEntry(e.key, e.value.reduce((a, b) => a + b) / e.value.length),
        )
        .toList();

    return GlassContainer(
      borderRadius: 20.0,
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: MediaQuery.of(context).size.width - 48,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (int i = 0; i < avgEntries.length; i++) ...[
                _buildSensorChip(
                  sensorKey: avgEntries[i].key,
                  value: avgEntries[i].value,
                  isDark: isDark,
                ),
                if (i < avgEntries.length - 1)
                  Container(
                    height: 32,
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: isDark
                        ? Colors.white.withOpacity(0.12)
                        : Colors.black.withOpacity(0.08),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSensorChip({
    required String sensorKey,
    required double value,
    required bool isDark,
  }) {
    final def = SensorRegistry.get(sensorKey);
    final isNarrow = MediaQuery.of(context).size.width < 380;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(def.icon, color: def.color, size: isNarrow ? 18 : 22),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Avg ${def.label}',
              style: GoogleFonts.inter(
                fontSize: isNarrow ? 9 : 10,
                color: const Color(0xFF94A3B8),
              ),
            ),
            Text(
              def.formatValue(value),
              style: GoogleFonts.outfit(
                fontSize: isNarrow ? 13 : 15,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNodesView(
    ThemeData theme,
    bool isDark,
    List<Map<String, dynamic>> nodes,
    String layoutMode,
  ) {
    if (nodes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.devices_other_rounded,
                size: 48,
                color: isDark ? Colors.white24 : Colors.black26,
              ),
              const SizedBox(height: 16),
              Text(
                'No devices added yet',
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Please wait for cloud sync or set up nodes.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: isDark ? Colors.white38 : Colors.black38,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (layoutMode == 'list') {
      return _buildNodesList(theme, isDark, nodes);
    } else if (layoutMode == 'minimal') {
      return _buildNodesMinimal(theme, isDark, nodes);
    } else {
      // Default: grid
      return _buildNodesGrid(theme, isDark, nodes);
    }
  }

  // === 1. GRID LAYOUT ===
  Widget _buildNodesGrid(
    ThemeData theme,
    bool isDark,
    List<Map<String, dynamic>> nodes,
  ) {
    return GridView.builder(
      // Reduced top padding: fixes the gap between sensor ribbon and node cards
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: MediaQuery.of(context).size.width < 360 ? 185 : 170,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        final node = nodes[index];
        return _NodePermissionGate(
          nodeMac: node['mac'] ?? '',
          layout: 'grid',
          child: _buildNodeGridCard(theme, isDark, node),
        );
      },
    );
  }

  Widget _buildNodeGridCard(
    ThemeData theme,
    bool isDark,
    Map<String, dynamic> node,
  ) {
    final statusColor = _getStatusColor(node['status']);
    final statusText = _getStatusText(node['status']);
    final statusIcon = _getStatusIcon(node['status']);
    final hasSensors =
        node['sensors'] is List && (node['sensors'] as List).isNotEmpty;

    return GlassContainer(
      borderRadius: 16.0,
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: () {
          context.push(
            '/node/${node['mac']}',
            extra: {
              'ip': node['ip'],
              'name': node['name'],
              'sensors': node['sensors'],
            },
          );
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(statusIcon, color: statusColor, size: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      statusText,
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    node['name'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Uptime: 03h 24m',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      color: const Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Render Sensor Summary conditionally with wrapping to prevent overflows
              if (hasSensors)
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.thermostat,
                          size: 11,
                          color: Colors.orange,
                        ),
                        const SizedBox(width: 1),
                        Text(
                          '${node['temp']}°C',
                          style: GoogleFonts.inter(fontSize: 9.5),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.water_drop,
                          size: 11,
                          color: Colors.blue,
                        ),
                        const SizedBox(width: 1),
                        Text(
                          '${node['humi']}%',
                          style: GoogleFonts.inter(fontSize: 9.5),
                        ),
                      ],
                    ),
                  ],
                )
              else
                Text(
                  'No Sensors Connected',
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // === 2. LIST LAYOUT ===
  Widget _buildNodesList(
    ThemeData theme,
    bool isDark,
    List<Map<String, dynamic>> nodes,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        final node = nodes[index];
        final statusColor = _getStatusColor(node['status']);
        final statusIcon = _getStatusIcon(node['status']);
        final hasSensors =
            node['sensors'] is List && (node['sensors'] as List).isNotEmpty;

        return _NodePermissionGate(
          nodeMac: node['mac'] ?? '',
          layout: 'list',
          child: GlassContainer(
            borderRadius: 16.0,
            margin: const EdgeInsets.only(bottom: 12),
            padding: EdgeInsets.zero,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              onTap: () {
                context.push(
                  '/node/${node['mac']}',
                  extra: {
                    'ip': node['ip'],
                    'name': node['name'],
                    'sensors': node['sensors'],
                  },
                );
              },
              leading: CircleAvatar(
                backgroundColor: statusColor.withOpacity(0.15),
                child: Icon(statusIcon, color: statusColor),
              ),
              title: Text(
                node['name'],
                style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: hasSensors
                    ? Row(
                        children: [
                          const Icon(
                            Icons.thermostat,
                            size: 14,
                            color: Colors.orange,
                          ),
                          Text(
                            ' ${node['temp']}°C ',
                            style: GoogleFonts.inter(fontSize: 12),
                          ),
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.water_drop,
                            size: 14,
                            color: Colors.blue,
                          ),
                          Text(
                            ' ${node['humi']}%',
                            style: GoogleFonts.inter(fontSize: 12),
                          ),
                        ],
                      )
                    : Text(
                        'No Sensors',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: Colors.grey,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.grey),
            ),
          ),
        );
      },
    );
  }

  // === 3. MINIMAL LAYOUT ===
  Widget _buildNodesMinimal(
    ThemeData theme,
    bool isDark,
    List<Map<String, dynamic>> nodes,
  ) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 2.2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: nodes.length,
      itemBuilder: (context, index) {
        final node = nodes[index];
        final statusColor = _getStatusColor(node['status']);

        return _NodePermissionGate(
          nodeMac: node['mac'] ?? '',
          layout: 'minimal',
          child: GlassContainer(
            borderRadius: 12.0,
            border: Border.all(color: statusColor.withOpacity(0.4), width: 1),
            padding: EdgeInsets.zero,
            child: InkWell(
              onTap: () {
                context.push(
                  '/node/${node['mac']}',
                  extra: {
                    'ip': node['ip'],
                    'name': node['name'],
                    'sensors': node['sensors'],
                  },
                );
              },
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12.0,
                  vertical: 8.0,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node['name'],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _getStatusText(node['status']),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Utility Status Helpers
  Color _getStatusColor(String status) {
    if (status == 'local') return Colors.green;
    if (status == 'cloud') return Colors.indigoAccent;
    return Colors.grey;
  }

  String _getStatusText(String status) {
    if (status == 'local') return 'Local WS';
    if (status == 'cloud') return 'Cloud MQTT';
    return 'Offline';
  }

  IconData _getStatusIcon(String status) {
    if (status == 'local') return Icons.wifi;
    if (status == 'cloud') return Icons.cloud_outlined;
    return Icons.wifi_off_outlined;
  }

  String _formatTimeDisplay(
    int hour,
    int minute,
    int second,
    String userFormat,
    bool showSeconds,
  ) {
    final secStr = showSeconds ? ':${second.toString().padLeft(2, '0')}' : '';
    if (userFormat == '24h') {
      return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}$secStr';
    }
    final ampm = hour >= 12 ? 'PM' : 'AM';
    final h12 = hour % 12 == 0 ? 12 : hour % 12;
    return '$h12:${minute.toString().padLeft(2, '0')}$secStr $ampm';
  }

  void _showRoleChangedDialog(
    BuildContext context,
    String oldRole,
    String newRole,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1E1B29).withOpacity(0.8)
                  : Colors.white.withOpacity(0.8),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Theme.of(context).primaryColor.withOpacity(0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.blueAccent.withOpacity(0.12),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.blueAccent.withOpacity(0.15),
                  ),
                  child: const Icon(
                    Icons.security_update_good_rounded,
                    color: Colors.blueAccent,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Role Updated',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your security authorization role has been updated from "${oldRole.toUpperCase()}" to "${newRole.toUpperCase()}". Your settings configuration is synchronized.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                  ),
                  child: Text(
                    'Acknowledge & Refresh',
                    style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showReloadDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1E1B29).withOpacity(0.8)
                  : Colors.white.withOpacity(0.8),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Theme.of(context).primaryColor.withOpacity(0.2),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.orangeAccent.withOpacity(0.12),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.orangeAccent.withOpacity(0.15),
                  ),
                  child: const Icon(
                    Icons.sync_problem_rounded,
                    color: Colors.orangeAccent,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Please reload app',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.orangeAccent,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Account credentials mismatch detected. Please reload to apply new settings.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white70
                        : Colors.black87,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    ref.read(authProvider.notifier).applyNewDataAndRender();
                    Navigator.of(ctx).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                  ),
                  child: Text(
                    'Reload',
                    style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// _DashboardBackgroundBlobs is replaced by AppBackground (core/widgets/app_background.dart)

// ─────────────────────────────────────────────────────────────────────────────
// Sticky TabBar Delegate for SliverPersistentHeader
// ─────────────────────────────────────────────────────────────────────────────

class _NodePermissionGate extends ConsumerWidget {
  final String nodeMac;
  final String layout;
  final Widget child;

  const _NodePermissionGate({
    required this.nodeMac,
    required this.layout,
    required this.child,
  });

  Future<void> _request(BuildContext context, WidgetRef ref) async {
    final authState = ref.read(authProvider);
    final email = authState.email ?? '';
    await ref
        .read(nodePermissionServiceProvider)
        .requestNodeAccess(nodeMac, email);
    ref.invalidate(nodeAccessProvider(nodeMac)); // Refresh status
    GlassToast.show(
      context,
      icon: const Icon(
        Icons.hourglass_empty_rounded,
        color: Colors.orangeAccent,
      ),
      color: Colors.orange,
      message: 'Access requested. Awaiting Admin approval.',
      behave: ToastBehavior.info,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(nodeAccessProvider(nodeMac));

    if (status == NodePermissionStatus.approved) {
      return child;
    }

    final isPending = status == NodePermissionStatus.pending;

    if (layout == 'list') {
      return GlassContainer(
        borderRadius: 16.0,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                      (isPending ? Colors.orangeAccent : Colors.redAccent)
                          .withOpacity(0.15),
                  child: Icon(
                    isPending
                        ? Icons.pending_actions_outlined
                        : Icons.lock_outline_rounded,
                    color: isPending ? Colors.orangeAccent : Colors.redAccent,
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Node: ${nodeMac.length > 8 ? nodeMac.substring(nodeMac.length - 8) : nodeMac}',
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      isPending
                          ? 'Pending admin approval'
                          : 'Access restricted',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (!isPending)
              ElevatedButton(
                onPressed: () => _request(context, ref),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Request', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
      );
    } else if (layout == 'minimal') {
      return GlassContainer(
        borderRadius: 12.0,
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              nodeMac.length > 8
                  ? nodeMac.substring(nodeMac.length - 8)
                  : nodeMac,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isPending ? Icons.pending_actions : Icons.lock,
                  color: isPending ? Colors.orangeAccent : Colors.redAccent,
                  size: 12,
                ),
                const SizedBox(width: 4),
                Text(
                  isPending ? 'Pending' : 'Lock',
                  style: GoogleFonts.inter(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
            if (!isPending) ...[
              const SizedBox(height: 2),
              GestureDetector(
                onTap: () => _request(context, ref),
                child: Text(
                  'Request',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).primaryColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ] else ...[
              const SizedBox(height: 2),
              Text(
                'Awaiting',
                style: GoogleFonts.inter(fontSize: 9, color: Colors.grey),
              ),
            ],
          ],
        ),
      );
    } else {
      // Default: grid
      return GlassContainer(
        borderRadius: 16.0,
        padding: const EdgeInsets.all(12.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              isPending
                  ? Icons.pending_actions_outlined
                  : Icons.lock_outline_rounded,
              color: isPending ? Colors.orangeAccent : Colors.redAccent,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              isPending ? 'Pending' : 'Access Denied',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (!isPending)
              SizedBox(
                height: 28,
                child: ElevatedButton(
                  onPressed: () => _request(context, ref),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Request Access',
                    style: TextStyle(fontSize: 10),
                  ),
                ),
              )
            else
              Text(
                'Awaiting approval',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(fontSize: 9, color: Colors.grey),
              ),
          ],
        ),
      );
    }
  }
}
