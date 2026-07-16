import 'dart:async';
import 'dart:ui';
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
import '../../auth/data/auth_provider.dart';
import '../../control/data/node_permission_service.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  DateTime? _lastBackPressTime;

  bool _showSeconds = true;
  Timer? _clockTimer;
  DateTime _currentDateTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _currentDateTime = DateTime.now();
        });
      }
    });

    // Auto-trigger update check on load
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(updateProvider.notifier).checkForUpdates();
      if (!context.mounted) return;
      if (ref.read(updateProvider).hasUpdate) {
        showDialog(
          context: context,
          builder: (context) => const UpdateDialog(),
        );
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final isDark = theme.brightness == Brightness.dark;

    // Listen to global nodes state
    final nodes = ref.watch(nodesProvider);

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
        appBar: AppBar(
          elevation: 0,
          backgroundColor: Colors.transparent,
          centerTitle: true,
          title: RichText(
            text: TextSpan(
              text: 'Dashboard - ',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
              children: [
                TextSpan(
                  text: 'ESP',
                  style: GoogleFonts.outfit(
                    color: theme.primaryColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                TextSpan(
                  text: 'Home',
                  style: GoogleFonts.outfit(
                    color: isDark ? Colors.white : Colors.black87,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          ),
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                color: isDark
                    ? Colors.black.withOpacity(0.1)
                    : Colors.white.withOpacity(0.1),
              ),
            ),
          ),
          actions: [
            // Theme toggler
            IconButton(
              icon: Icon(
                themeMode == ThemeMode.dark
                    ? Icons.light_mode
                    : Icons.dark_mode,
              ),
              onPressed: () {
                ref.read(themeModeProvider.notifier).toggleTheme();
              },
              tooltip: 'Toggle Theme',
            ),
            // Check update manually
            IconButton(
              icon: const Icon(Icons.update),
              onPressed: () async {
                await ref.read(updateProvider.notifier).checkForUpdates();
                if (context.mounted) {
                  showDialog(
                    context: context,
                    builder: (context) => const UpdateDialog(),
                  );
                }
              },
              tooltip: 'Check Updates',
            ),
            IconButton(
              icon: const Icon(Icons.playlist_play_rounded),
              onPressed: () => context.push('/settings/bulk-rules'),
              tooltip: 'Bulk Rules',
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => context.push('/settings'),
              tooltip: 'Settings',
            ),
          ],
        ),
        body: Stack(
          children: [
            _DashboardBackgroundBlobs(isDark: isDark),
            ValueListenableBuilder(
              valueListenable: Hive.box(
                'settings',
              ).listenable(keys: ['dashboardLayout']),
              builder: (context, Box box, _) {
                final layoutMode = box.get(
                  'dashboardLayout',
                  defaultValue: 'grid',
                );

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Top Telemetry Cards Banner (Calculated Dynamically)
                    _buildClockRibbon(theme, isDark),
                    _buildTelemetryBanner(theme, isDark, nodes),
                    // Room Navigation Tabbar
                    TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      labelColor: theme.primaryColor,
                      unselectedLabelColor: isDark
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF475569),
                      indicatorColor: theme.primaryColor,
                      tabs: const [
                        Tab(text: 'All Nodes'),
                        Tab(text: 'Living Room'),
                        Tab(text: 'Kitchen'),
                        Tab(text: 'Bedroom'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildNodesView(theme, isDark, nodes, layoutMode),
                          _buildNodesView(
                            theme,
                            isDark,
                            nodes
                                .where(
                                  (n) => n['name'] == 'Living Room Gateway',
                                )
                                .toList(),
                            layoutMode,
                          ),
                          _buildNodesView(
                            theme,
                            isDark,
                            nodes
                                .where((n) => n['name'] == 'Kitchen Controller')
                                .toList(),
                            layoutMode,
                          ),
                          _buildNodesView(
                            theme,
                            isDark,
                            nodes
                                .where((n) => n['name'] == 'Bedroom Node')
                                .toList(),
                            layoutMode,
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClockRibbon(ThemeData theme, bool isDark) {
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
    final formattedDate =
        '${_currentDateTime.day.toString().padLeft(2, '0')}-${_currentDateTime.month.toString().padLeft(2, '0')}-${_currentDateTime.year}';

    return Container(
      margin: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.06)
                  : Colors.black.withOpacity(0.03),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.06),
                width: 1.5,
              ),
            ),
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _showSeconds = !_showSeconds;
                });
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.schedule, size: 14, color: theme.primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    '$formattedDate | $formattedTime',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTelemetryBanner(
    ThemeData theme,
    bool isDark,
    List<Map<String, dynamic>> nodes,
  ) {
    // Dynamically calculate averages of active nodes
    final tempNodes = nodes
        .where((n) => (n['sensors'] as List).contains('temperature'))
        .toList();
    final double avgTemp = tempNodes.isEmpty
        ? 0.0
        : tempNodes.map((n) => n['temp'] as double).reduce((a, b) => a + b) /
              tempNodes.length;

    final humiNodes = nodes
        .where((n) => (n['sensors'] as List).contains('humidity'))
        .toList();
    final double avgHumi = humiNodes.isEmpty
        ? 0.0
        : humiNodes.map((n) => n['humi'] as double).reduce((a, b) => a + b) /
              humiNodes.length;

    return GlassContainer(
      borderRadius: 24.0,
      margin: const EdgeInsets.only(left: 16, right: 16, bottom: 16, top: 4),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 360;
          if (isNarrow) {
            return Column(
              children: [
                _buildTelemetryItem(
                  icon: Icons.thermostat,
                  label: 'Avg Temperature',
                  value: '${avgTemp.toStringAsFixed(1)} °C',
                  color: Colors.orangeAccent,
                ),
                const SizedBox(height: 12),
                Divider(
                  height: 1.5,
                  color: isDark
                      ? Colors.white.withOpacity(0.15)
                      : Colors.black.withOpacity(0.1),
                ),
                const SizedBox(height: 12),
                _buildTelemetryItem(
                  icon: Icons.water_drop_outlined,
                  label: 'Avg Humidity',
                  value: '${avgHumi.toStringAsFixed(1)} %',
                  color: Colors.blueAccent,
                ),
              ],
            );
          } else {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Expanded(
                  child: _buildTelemetryItem(
                    icon: Icons.thermostat,
                    label: 'Avg Temperature',
                    value: '${avgTemp.toStringAsFixed(1)} °C',
                    color: Colors.orangeAccent,
                  ),
                ),
                Container(
                  height: 40,
                  width: 1.5,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: isDark
                      ? Colors.white.withOpacity(0.15)
                      : Colors.black.withOpacity(0.1),
                ),
                Expanded(
                  child: _buildTelemetryItem(
                    icon: Icons.water_drop_outlined,
                    label: 'Avg Humidity',
                    value: '${avgHumi.toStringAsFixed(1)} %',
                    color: Colors.blueAccent,
                  ),
                ),
              ],
            );
          }
        },
      ),
    );
  }

  Widget _buildTelemetryItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: const Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
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
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 1.1,
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
    final hasSensors = (node['sensors'] as List).isNotEmpty;

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
          padding: const EdgeInsets.all(12.0),
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
              Expanded(
                child: Column(
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
              ),
              const SizedBox(height: 4),
              // Render Sensor Summary conditionally
              if (hasSensors)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.thermostat,
                          size: 12,
                          color: Colors.orange,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${node['temp']}°C',
                          style: GoogleFonts.inter(fontSize: 10),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Icon(
                          Icons.water_drop,
                          size: 12,
                          color: Colors.blue,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '${node['humi']}%',
                          style: GoogleFonts.inter(fontSize: 10),
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
        final hasSensors = (node['sensors'] as List).isNotEmpty;

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
}

class _DashboardBackgroundBlobs extends StatelessWidget {
  final bool isDark;
  const _DashboardBackgroundBlobs({required this.isDark});

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
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(
                  0xFF6366F1,
                ).withOpacity(isDark ? 0.22 : 0.15),
              ),
            ),
          ),
          Positioned(
            bottom: -100,
            right: -80,
            child: Container(
              width: 360,
              height: 360,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(
                  0xFFEC4899,
                ).withOpacity(isDark ? 0.18 : 0.12),
              ),
            ),
          ),
          Positioned(
            top: 250,
            right: -50,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(
                  0xFF14B8A6,
                ).withOpacity(isDark ? 0.15 : 0.08),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Access requested. Awaiting Admin approval.'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accessAsync = ref.watch(nodeAccessProvider(nodeMac));

    return accessAsync.when(
      data: (status) {
        if (status == NodePermissionStatus.approved) {
          return child;
        }

        final isDark = Theme.of(context).brightness == Brightness.dark;
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
                        color: isPending
                            ? Colors.orangeAccent
                            : Colors.redAccent,
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
                    child: const Text(
                      'Request',
                      style: TextStyle(fontSize: 11),
                    ),
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
                      style: GoogleFonts.inter(
                        fontSize: 10,
                        color: Colors.grey,
                      ),
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
      },
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 1.5)),
      error: (err, stack) => child,
    );
  }
}
