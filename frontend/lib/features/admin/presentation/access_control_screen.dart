import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/widgets/glass_container.dart';
import '../../../core/widgets/glass_dialog.dart';
import '../../../core/widgets/app_background.dart';
import '../data/access_control_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../../../core/utils/device_info_helper.dart';

// ─── Realtime pending requests StreamProvider ─────────────────────────────────
final pendingRequestsStreamProvider =
    StreamProvider<List<Map<String, dynamic>>>((ref) {
      final service = ref.watch(accessControlServiceProvider);
      return service.watchPendingRequests();
    });

class AccessControlScreen extends ConsumerStatefulWidget {
  const AccessControlScreen({super.key});

  @override
  ConsumerState<AccessControlScreen> createState() =>
      _AccessControlScreenState();
}

class _AccessControlScreenState extends ConsumerState<AccessControlScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoading = true;
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _approvedNodes = [];
  String _currentDeviceId = '';

  // Track already-seen pending request count to detect new arrivals at runtime
  int _lastSeenPendingCount = 0;
  bool _pendingPopupShown = false;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _reloadData();
    _initNotifications();
  }

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await _notificationsPlugin.initialize(initializationSettings);
  }

  Future<void> _showSystemNotification(Map<String, dynamic> req) async {
    final email = req['requestedByEmail'] as String;
    final mac = req['nodeMac'] as String;

    try {
      const AndroidNotificationDetails androidPlatformChannelSpecifics =
          AndroidNotificationDetails(
            'node_pairing_channel',
            'Node Pairing Requests',
            channelDescription:
                'Notifications for new ESPHome node pairing requests',
            importance: Importance.max,
            priority: Priority.high,
            showWhen: true,
          );
      const NotificationDetails platformChannelSpecifics = NotificationDetails(
        android: androidPlatformChannelSpecifics,
      );
      await _notificationsPlugin.show(
        req.hashCode,
        'New Node Pairing Request',
        'User $email requested pairing for Node [$mac]',
        platformChannelSpecifics,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _reloadData() async {
    setState(() => _isLoading = true);
    final service = ref.read(accessControlServiceProvider);
    try {
      final users = await service.getUsersList();
      final approved = await service.getApprovedNodesList();
      final currentId = await DeviceInfoHelper.getStableDeviceId();
      setState(() {
        _users = users;
        _approvedNodes = approved;
        _currentDeviceId = currentId;
        _isLoading = false;
      });
    } catch (_) {
      setState(() => _isLoading = false);
    }
  }

  void _showLoadingToast(String message) {
    GlassToast.show(
      context,
      icon: const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      ),
      color: Colors.blueAccent,
      message: message,
      behave: ToastBehavior.info,
    );
  }

  void _showSuccessToast(String message) {
    GlassToast.show(
      context,
      icon: const Icon(Icons.check_circle_outline, color: Colors.green),
      color: Colors.green,
      message: message,
      behave: ToastBehavior.success,
    );
  }

  /// Shows a popup when a new access request arrives at runtime.
  void _showRuntimeApprovalPopup(
    Map<String, dynamic> req,
    List<Map<String, dynamic>> allPending,
  ) {
    if (_pendingPopupShown) return;
    _pendingPopupShown = true;

    final email = req['requestedByEmail'] as String;
    final mac = req['nodeMac'] as String;
    final macHash = req['macHash'] as String;
    final emailHash = req['emailHash'] as String;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: GlassContainer(
            borderRadius: 20.0,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.orangeAccent.withOpacity(0.15),
                      ),
                      child: const Icon(
                        Icons.notification_important_rounded,
                        color: Colors.orangeAccent,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'New Access Request',
                        style: GoogleFonts.outfit(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('User: $email', style: GoogleFonts.inter(fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                  'Requesting access to node:\n$mac',
                  style: GoogleFonts.inter(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          _pendingPopupShown = false;
                          _showLoadingToast('Rejecting request...');
                          await ref
                              .read(accessControlServiceProvider)
                              .rejectNodeRequest(macHash, emailHash);
                          _showSuccessToast('Request rejected.');
                          _reloadData();
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Reject',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          _pendingPopupShown = false;
                          _showLoadingToast('Approving request...');
                          await ref
                              .read(accessControlServiceProvider)
                              .approveNodeRequest(macHash, emailHash, mac);
                          _showSuccessToast('Access approved for $email');
                          _reloadData();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Approve',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _pendingPopupShown = false;
                    // Goes to pending tab - will be visible there
                    _tabController.animateTo(1);
                  },
                  child: Text(
                    'View All Pending (${allPending.length})',
                    style: GoogleFonts.inter(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => _pendingPopupShown = false);
  }

  Widget _buildGlassCard({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: GlassContainer(
        borderRadius: 16.0,
        padding: const EdgeInsets.all(16.0),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Listen to pending requests stream for realtime popup
    final pendingStream = ref.watch(pendingRequestsStreamProvider);
    pendingStream.whenData((pending) {
      if (pending.length > _lastSeenPendingCount && pending.isNotEmpty) {
        _lastSeenPendingCount = pending.length;
        // Show popup & push system notification for newest request
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _showSystemNotification(pending.last);
            if (!_pendingPopupShown) {
              _showRuntimeApprovalPopup(pending.last, pending);
            }
          }
        });
      } else {
        _lastSeenPendingCount = pending.length;
      }
    });

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        title: Text(
          'Access Control Manager',
          style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
        ),
        leading: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark
                ? Colors.white.withOpacity(0.1)
                : Colors.black.withOpacity(0.05),
            border: Border.all(
              color: isDark
                  ? Colors.white.withOpacity(0.15)
                  : Colors.black.withOpacity(0.08),
              width: 1.5,
            ),
          ),
          child: IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new_rounded,
              size: 16,
              color: isDark ? Colors.white : Colors.black87,
            ),
            onPressed: () => Navigator.maybePop(context),
            padding: EdgeInsets.zero,
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
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: theme.primaryColor,
          labelColor: isDark ? Colors.white : Colors.black87,
          unselectedLabelColor: Colors.grey,
          labelStyle: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
          tabs: [
            const Tab(
              text: 'Users & Devices',
              icon: Icon(Icons.people_alt_rounded, size: 20),
            ),
            Tab(
              icon: const Icon(Icons.pending_actions_rounded, size: 20),
              child: pendingStream.when(
                data: (pending) => pending.isEmpty
                    ? const Text('Requests')
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Requests'),
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orangeAccent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${pending.length}',
                              style: GoogleFonts.outfit(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                loading: () => const Text('Requests'),
                error: (err, stack) => const Text('Requests'),
              ),
            ),
            const Tab(
              text: 'Approved',
              icon: Icon(Icons.verified_user_rounded, size: 20),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          AppBackground(isDark: isDark),
          Positioned(
            top: -100,
            right: -80,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.primaryColor.withOpacity(isDark ? 0.12 : 0.08),
              ),
            ),
          ),
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabController,
                  children: [
                    RefreshIndicator(
                      onRefresh: _reloadData,
                      child: _buildUsersTab(),
                    ),
                    // Requests tab driven by realtime stream
                    pendingStream.when(
                      data: (pending) => RefreshIndicator(
                        onRefresh: _reloadData,
                        child: _buildRequestsTab(pending),
                      ),
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Center(
                        child: Text(
                          'Error loading requests',
                          style: GoogleFonts.inter(color: Colors.redAccent),
                        ),
                      ),
                    ),
                    RefreshIndicator(
                      onRefresh: _reloadData,
                      child: _buildApprovedNodesTab(),
                    ),
                  ],
                ),
        ],
      ),
    );
  }

  Widget _buildUsersTab() {
    final theme = Theme.of(context);
    if (_users.isEmpty) {

      return Center(
        child: Text(
          'No users found.',
          style: GoogleFonts.inter(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _users.length,
      itemBuilder: (context, index) {
        final user = _users[index];
        final email = user['email'] as String;
        final role = user['role'] as String;
        final emailHash = user['emailHash'] as String;
        final devices = user['devices'] as List<Map<String, String>>;
        final isAdmin = role == 'admin';

        return _buildGlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          email,
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${devices.length} device${devices.length == 1 ? '' : 's'} registered',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Role Switcher
                  PopupMenuButton<String>(
                    initialValue: role,
                    onSelected: (newRole) async {
                      _showLoadingToast('Updating user role...');
                      await ref
                          .read(accessControlServiceProvider)
                          .updateUserRole(emailHash, newRole);
                      _showSuccessToast('Role updated to $newRole');
                      _reloadData();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'user',
                        child: Text(
                          'Standard User',
                          style: GoogleFonts.inter(fontSize: 13),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'admin',
                        child: Text(
                          'Administrator',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: Colors.amber,
                          ),
                        ),
                      ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: isAdmin
                            ? Colors.amber.withOpacity(0.15)
                            : Colors.blue.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isAdmin
                              ? Colors.amber.withOpacity(0.5)
                              : Colors.blue.withOpacity(0.3),
                        ),
                      ),
                      child: Text(
                        role.toUpperCase(),
                        style: GoogleFonts.outfit(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isAdmin ? Colors.amber : Colors.blue,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 24, color: Colors.white12),
              Text(
                'Registered Devices:',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              if (devices.isEmpty)
                Text(
                  'No active device configurations.',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey,
                  ),
                )
              else
                ...devices.map((device) {
                  final devId = device['id'] ?? '';
                  final status = device['status'] ?? 'pending';
                  // Show human-readable name if available, fallback to short ID
                  final displayName =
                      (device['name'] != null &&
                          device['name']!.isNotEmpty &&
                          device['name'] != devId)
                      ? device['name']!
                      : '${devId.substring(0, devId.length.clamp(0, 12))}...';
                  final isApproved = status == 'approved';
                  final isCurrent = devId == _currentDeviceId;

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Icon(
                                isCurrent
                                    ? Icons.phone_android_rounded
                                    : Icons.devices_rounded,
                                size: 14,
                                color: isCurrent
                                    ? theme.primaryColor
                                    : (isApproved
                                        ? Colors.greenAccent
                                        : Colors.orange),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  displayName,
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isCurrent) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: theme.primaryColor.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(
                                      color: theme.primaryColor.withOpacity(0.5),
                                      width: 0.8,
                                    ),
                                  ),
                                  child: Text(
                                    'This Device',
                                    style: GoogleFonts.inter(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: theme.primaryColor,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        // Device status switch
                        Row(
                          children: [
                            Text(
                              status.toUpperCase(),
                              style: GoogleFonts.outfit(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: isApproved
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Switch.adaptive(
                              value: isApproved,
                              activeColor: Colors.greenAccent,
                              onChanged: (approved) async {
                                final newStatus = approved
                                    ? 'approved'
                                    : 'unapproved';
                                _showLoadingToast(
                                  'Updating device verification...',
                                );
                                await ref
                                    .read(accessControlServiceProvider)
                                    .updateDeviceStatus(
                                      emailHash,
                                      devId,
                                      newStatus,
                                    );
                                _showSuccessToast('Device status: $newStatus');
                                _reloadData();
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              tooltip: 'Remove Device',
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    backgroundColor: Colors.grey.shade900
                                        .withOpacity(0.95),
                                    title: Text(
                                      'Remove Device',
                                      style: GoogleFonts.outfit(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    content: Text(
                                      'Are you sure you want to remove "$displayName" for $email?',
                                      style: GoogleFonts.inter(
                                        color: Colors.white70,
                                        fontSize: 13,
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.redAccent,
                                        ),
                                        child: const Text('Remove'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) {
                                  _showLoadingToast('Removing device...');
                                  await ref
                                      .read(accessControlServiceProvider)
                                      .removeDevice(emailHash, devId);
                                  _showSuccessToast('Device removed');
                                  _reloadData();
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRequestsTab(List<Map<String, dynamic>> pendingRequests) {
    if (pendingRequests.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 48,
              color: Colors.grey.withOpacity(0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'No pending requests.',
              style: GoogleFonts.inter(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: pendingRequests.length,
      itemBuilder: (context, index) {
        final req = pendingRequests[index];
        final email = req['requestedByEmail'] as String;
        final mac = req['nodeMac'] as String;
        final macHash = req['macHash'] as String;
        final emailHash = req['emailHash'] as String;

        return _buildGlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.vpn_key_outlined,
                    color: Colors.orangeAccent,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Access Request',
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'User: $email',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Target Node MAC: $mac',
                style: GoogleFonts.inter(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () async {
                      _showLoadingToast('Rejecting request...');
                      await ref
                          .read(accessControlServiceProvider)
                          .rejectNodeRequest(macHash, emailHash);
                      _showSuccessToast('Request rejected.');
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Reject'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () async {
                      _showLoadingToast('Approving request...');
                      await ref
                          .read(accessControlServiceProvider)
                          .approveNodeRequest(macHash, emailHash, mac);
                      _showSuccessToast('Access approved for $email');
                      _reloadData();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Approve'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildApprovedNodesTab() {
    if (_approvedNodes.isEmpty) {
      return Center(
        child: Text(
          'No approved node mapping settings found.',
          style: GoogleFonts.inter(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _approvedNodes.length,
      itemBuilder: (context, index) {
        final node = _approvedNodes[index];
        final email = node['email'] as String;
        final nodeMac = node['nodeMac'] as String;
        final emailHash = node['emailHash'] as String;
        final macHash = node['macHash'] as String;

        return _buildGlassCard(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      email,
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'MAC: $nodeMac',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.delete_sweep_rounded,
                  color: Colors.redAccent,
                ),
                onPressed: () async {
                  final confirm = await GlassDialog.show<bool>(
                    context,
                    title: const Text('Revoke Permissions'),
                    content: Text(
                      'Are you sure you want to block access to node $nodeMac for user $email?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(
                          'Cancel',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Revoke'),
                      ),
                    ],
                  );

                  if (confirm == true) {
                    _showLoadingToast('Revoking permissions...');
                    await ref
                        .read(accessControlServiceProvider)
                        .revokeNodeAccess(emailHash, macHash);
                    _showSuccessToast('Access permission revoked.');
                    _reloadData();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
