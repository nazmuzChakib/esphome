import 'dart:convert';
import 'dart:ui' show ImageFilter;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:image_picker/image_picker.dart';
import '../../auth/data/auth_provider.dart';
import '../../auth/data/auth_service.dart';
import '../../../core/utils/avatar_helper.dart';
import '../../../core/utils/device_info_helper.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/widgets/glass_dialog.dart';
import '../../../core/widgets/glass_container.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  String _timeFormat = '12h';
  String _currentDeviceId = 'unknown';
  bool _isSendingReset = false;

  @override
  void initState() {
    super.initState();
    _loadTimeFormat();
    _loadCurrentDeviceId();
  }

  void _loadTimeFormat() async {
    final box = await Hive.openBox('settings');
    setState(() {
      _timeFormat = box.get('timeFormat', defaultValue: '12h');
    });
  }

  void _loadCurrentDeviceId() async {
    // Use DeviceInfoHelper for stable, consistent device ID
    try {
      final id = await DeviceInfoHelper.getStableDeviceId();
      setState(() {
        _currentDeviceId = id;
      });
    } catch (_) {}
  }

  String _formatDateTime(DateTime? dateTime) {
    if (dateTime == null) return 'N/A';
    final months = [
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
    final monthStr = months[dateTime.month - 1];

    final hour = dateTime.hour;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final year = dateTime.year;
    final day = dateTime.day;

    if (_timeFormat == '12h') {
      final period = hour >= 12 ? 'PM' : 'AM';
      final hour12 = hour % 12 == 0 ? 12 : hour % 12;
      return '$monthStr $day, $year, $hour12:$minute $period';
    } else {
      final hour24 = hour.toString().padLeft(2, '0');
      return '$monthStr $day, $year, $hour24:$minute';
    }
  }

  void _handleResetPassword(String email) async {
    setState(() => _isSendingReset = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) {
        GlassToast.show(
          context,
          icon: const Icon(Icons.check_circle_outline, color: Colors.green),
          color: Colors.green,
          message: 'Password reset link sent to $email.',
          behave: ToastBehavior.success,
        );
      }
    } catch (e) {
      if (mounted) {
        GlassToast.show(
          context,
          icon: const Icon(Icons.error_outline, color: Colors.redAccent),
          color: Colors.redAccent,
          message: e.toString().replaceFirst(RegExp(r'^\[.*\]\s*'), ''),
          behave: ToastBehavior.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSendingReset = false);
      }
    }
  }

  void _handleLogout() {
    GlassDialog.show(
      context,
      title: const Text('Confirm Sign Out'),
      content: const Text(
        'Are you sure you want to sign out? Active session credentials will be cleared.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: GoogleFonts.inter(fontWeight: FontWeight.bold),
          ),
        ),
        ElevatedButton(
          onPressed: () async {
            Navigator.pop(context);
            await ref.read(authProvider.notifier).logout();
            if (mounted) {
              context.go('/login');
              GlassToast.show(
                context,
                icon: const Icon(
                  Icons.check_circle_outline,
                  color: Colors.green,
                ),
                color: Colors.green,
                message: 'Successfully logged out.',
                behave: ToastBehavior.success,
              );
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Sign Out'),
        ),
      ],
    );
  }

  Future<void> _pickProfileImage() async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 200,
        maxHeight: 200,
        imageQuality: 60,
      );
      if (image != null) {
        final bytes = await image.readAsBytes();
        final base64Image = 'data:image/jpeg;base64,${base64Encode(bytes)}';

        await ref
            .read(authProvider.notifier)
            .updateProfile(
              firstName: ref.read(authProvider).firstName ?? '',
              lastName: ref.read(authProvider).lastName ?? '',
              name: ref.read(authProvider).name ?? '',
              photoUrl: base64Image,
            );
        if (mounted) {
          GlassToast.show(
            context,
            icon: const Icon(Icons.check_circle_outline, color: Colors.green),
            color: Colors.green,
            message: 'Profile picture updated & synced.',
            behave: ToastBehavior.success,
          );
        }
      }
    } catch (_) {
      if (mounted) {
        GlassToast.show(
          context,
          icon: const Icon(Icons.error_outline, color: Colors.redAccent),
          color: Colors.red,
          message: 'Failed to process picture.',
          behave: ToastBehavior.error,
        );
      }
    }
  }

  void _showEditProfileDialog() {
    final authState = ref.read(authProvider);
    final initialName = authState.name != null && authState.name!.isNotEmpty
        ? authState.name!
        : '${authState.firstName ?? ''} ${authState.lastName ?? ''}'.trim();
    final nameCtrl = TextEditingController(text: initialName);
    String? currentPhoto = authState.photoUrl;

    GlassDialog.show(
      context,
      title: const Text('Edit Profile'),
      content: StatefulBuilder(
        builder: (context, setDialogState) {
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () async {
                    try {
                      final picker = ImagePicker();
                      final image = await picker.pickImage(
                        source: ImageSource.gallery,
                        maxWidth: 200,
                        maxHeight: 200,
                        imageQuality: 60,
                      );
                      if (image != null) {
                        final bytes = await image.readAsBytes();
                        final base64Image =
                            'data:image/jpeg;base64,${base64Encode(bytes)}';
                        setDialogState(() {
                          currentPhoto = base64Image;
                        });
                      }
                    } catch (_) {}
                  },
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(
                              context,
                            ).primaryColor.withOpacity(0.5),
                            width: 2.5,
                          ),
                        ),
                        child: CircleAvatar(
                          backgroundColor: Colors.white.withOpacity(0.1),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(45),
                            child: AvatarHelper.buildAvatarImage(
                              photoUrl: currentPhoto,
                              width: 90,
                              height: 90,
                              placeholderBuilder: () => const Icon(
                                Icons.person_rounded,
                                size: 45,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Theme.of(context).primaryColor,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.camera_alt_rounded,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Tap avatar to change photo',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    color: Colors.white60,
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    prefixIcon: Icon(Icons.badge_outlined),
                    hintText: 'Enter display name',
                  ),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () async {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) {
              GlassToast.show(
                context,
                icon: const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.amber,
                ),
                color: Colors.amber,
                message: 'Display name cannot be empty.',
                behave: ToastBehavior.warning,
              );
              return;
            }
            Navigator.pop(context);
            await ref
                .read(authProvider.notifier)
                .updateProfile(
                  firstName: authState.firstName ?? '',
                  lastName: authState.lastName ?? '',
                  name: name,
                  photoUrl: currentPhoto,
                );
            if (mounted) {
              GlassToast.show(
                context,
                icon: const Icon(
                  Icons.check_circle_outline,
                  color: Colors.green,
                ),
                color: Colors.green,
                message: 'Profile updated successfully.',
                behave: ToastBehavior.success,
              );
            }
          },
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }

  IconData _getDeviceIcon(String devId, String devName) {
    final lowerId = devId.toLowerCase();
    final lowerName = devName.toLowerCase();
    if (lowerId.contains('win') || lowerName.contains('windows')) {
      return Icons.laptop_windows_rounded;
    } else if (lowerId.contains('mac') ||
        lowerName.contains('macos') ||
        lowerName.contains('mac device')) {
      return Icons.laptop_mac_rounded;
    } else if (lowerId.contains('linux')) {
      return Icons.terminal_rounded;
    } else if (lowerId.contains('web') ||
        lowerName.contains('chrome') ||
        lowerName.contains('safari') ||
        lowerName.contains('firefox') ||
        lowerName.contains('edge')) {
      return Icons.language_rounded;
    }
    return Icons.phone_android_rounded;
  }

  Widget _buildAvatarPlaceholder(
    String avatarLetter,
    bool isAdmin,
    ThemeData theme,
  ) {
    return Text(
      avatarLetter,
      style: GoogleFonts.outfit(
        fontSize: 48,
        fontWeight: FontWeight.bold,
        color: isAdmin ? Colors.amber : theme.primaryColor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final authState = ref.watch(authProvider);
    final user = FirebaseAuth.instance.currentUser;
    final email = user?.email ?? authState.email ?? 'N/A';
    final role = authState.role ?? 'user';
    final isAdmin = role.toLowerCase() == 'admin';

    String providerName = 'Email/Password';
    if (user != null && user.providerData.isNotEmpty) {
      final prov = user.providerData.first.providerId;
      if (prov.contains('google')) {
        providerName = 'Google Account';
      }
    }

    final String userDisplayName;
    if (authState.name != null && authState.name!.trim().isNotEmpty) {
      userDisplayName = authState.name!.trim();
    } else if (authState.firstName != null &&
        authState.firstName!.trim().isNotEmpty) {
      userDisplayName =
          "${authState.firstName!.trim()} ${authState.lastName?.trim() ?? ''}"
              .trim();
    } else {
      userDisplayName = email.split('@').first;
    }
    final avatarLetter = userDisplayName.isNotEmpty
        ? userDisplayName[0].toUpperCase()
        : 'U';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'User Profile',
          style: GoogleFonts.outfit(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => context.pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_rounded),
            tooltip: 'Edit Profile',
            onPressed: _showEditProfileDialog,
          ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          _DashboardBackgroundBlobs(isDark: isDark),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
              child: Container(color: Colors.transparent),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 20.0,
                vertical: 16.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  // Avatar & Header section
                  Center(
                    child: Column(
                      children: [
                        // Glassmorphic Glowing Avatar Wrapper
                        GestureDetector(
                          onTap: _pickProfileImage,
                          child: Stack(
                            children: [
                              Container(
                                width: 110,
                                height: 110,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isAdmin
                                        ? Colors.amberAccent.withOpacity(0.5)
                                        : theme.primaryColor.withOpacity(0.4),
                                    width: 3.0,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          (isAdmin
                                                  ? Colors.amber
                                                  : theme.primaryColor)
                                              .withOpacity(0.2),
                                      blurRadius: 24,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: CircleAvatar(
                                  backgroundColor: isDark
                                      ? Colors.white.withOpacity(0.08)
                                      : Colors.black.withOpacity(0.05),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(55),
                                    child: AvatarHelper.buildAvatarImage(
                                      photoUrl: authState.photoUrl,
                                      width: 110,
                                      height: 110,
                                      placeholderBuilder: () =>
                                          _buildAvatarPlaceholder(
                                            avatarLetter,
                                            isAdmin,
                                            theme,
                                          ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: theme.primaryColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.camera_alt_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          userDisplayName,
                          style: GoogleFonts.outfit(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Role Badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: isAdmin
                                ? Colors.amber.withOpacity(0.12)
                                : theme.primaryColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: isAdmin
                                  ? Colors.amber.withOpacity(0.3)
                                  : theme.primaryColor.withOpacity(0.2),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isAdmin
                                    ? Icons.admin_panel_settings_rounded
                                    : Icons.person_rounded,
                                size: 16,
                                color: isAdmin
                                    ? Colors.amber
                                    : theme.primaryColor,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isAdmin ? 'Administrator' : 'Standard User',
                                style: GoogleFonts.outfit(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: isAdmin
                                      ? Colors.amber
                                      : theme.primaryColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Section: Account Details
                  _buildSectionTitle('Account Credentials'),
                  const SizedBox(height: 12),
                  GlassContainer(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        _buildInfoRow(
                          'Email Address',
                          email,
                          Icons.email_outlined,
                        ),
                        const Divider(height: 24),
                        _buildInfoRow(
                          'First Name',
                          authState.firstName ?? 'N/A',
                          Icons.person_outline_rounded,
                        ),
                        const Divider(height: 24),
                        _buildInfoRow(
                          'Last Name',
                          authState.lastName ?? 'N/A',
                          Icons.person_outline_rounded,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Section: Timestamps
                  _buildSectionTitle('Session History'),
                  const SizedBox(height: 12),
                  GlassContainer(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        _buildInfoRow(
                          'Registration Date',
                          _formatDateTime(user?.metadata.creationTime),
                          Icons.calendar_today_rounded,
                        ),
                        const Divider(height: 24),
                        _buildInfoRow(
                          'Last Active Session',
                          _formatDateTime(user?.metadata.lastSignInTime),
                          Icons.login_rounded,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Section: Device Registration
                  _buildSectionTitle('Registered Devices'),
                  const SizedBox(height: 12),
                  FutureBuilder<List<Map<String, String>>>(
                    future: ref.read(authServiceProvider).getUserDevices(email),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                        );
                      }
                      final devices = snapshot.data ?? [];
                      if (devices.isEmpty) {
                        return GlassContainer(
                          padding: const EdgeInsets.all(20),
                          child: Center(
                            child: Text(
                              'No registered devices found.',
                              style: GoogleFonts.inter(
                                color: Colors.grey,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        );
                      }
                      return GlassContainer(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: devices.length,
                          separatorBuilder: (c, i) =>
                              const Divider(indent: 16, endIndent: 16),
                          itemBuilder: (context, idx) {
                            final dev = devices[idx];
                            final devId = dev['id'] ?? '';
                            final devStatus = dev['status'] ?? 'pending';
                            // Human-readable name if available
                            final devName =
                                (dev['name'] != null &&
                                    dev['name']!.isNotEmpty &&
                                    dev['name'] != devId)
                                ? dev['name']!
                                : devId;
                            final isCurrent = devId == _currentDeviceId;

                            return ListTile(
                              leading: CircleAvatar(
                                radius: 18,
                                backgroundColor: isCurrent
                                    ? theme.primaryColor.withOpacity(0.12)
                                    : (isDark
                                          ? Colors.white10
                                          : Colors.black12),
                                child: Icon(
                                  _getDeviceIcon(devId, devName),
                                  size: 18,
                                  color: isCurrent
                                      ? theme.primaryColor
                                      : Colors.grey,
                                ),
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      devName,
                                      style: GoogleFonts.outfit(
                                        fontWeight: isCurrent
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        fontSize: 14,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isCurrent)
                                    Container(
                                      margin: const EdgeInsets.only(left: 8),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme.primaryColor.withOpacity(
                                          0.15,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
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
                              ),
                              subtitle: Text(
                                'Status: ${devStatus.toUpperCase()}',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  color: devStatus == 'approved'
                                      ? Colors.green
                                      : Colors.amber,
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    devStatus == 'approved'
                                        ? Icons.check_circle_outline
                                        : Icons.pending_outlined,
                                    color: devStatus == 'approved'
                                        ? Colors.green
                                        : Colors.amber,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton(
                                    icon: Icon(
                                      Icons.delete_outline_rounded,
                                      size: 18,
                                      color: isCurrent
                                          ? Colors.grey.withOpacity(0.5)
                                          : Colors.redAccent,
                                    ),
                                    tooltip: isCurrent
                                        ? 'Active device cannot be removed'
                                        : 'Remove Device',
                                    onPressed: isCurrent
                                        ? () {
                                            GlassToast.show(
                                              context,
                                              icon: const Icon(
                                                Icons.warning_amber_rounded,
                                                color: Colors.orangeAccent,
                                              ),
                                              color: Colors.orangeAccent,
                                              message:
                                                  'Active device cannot be removed. Please log out to unregister.',
                                              behave: ToastBehavior.warning,
                                            );
                                          }
                                        : () async {
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
                                                  'Are you sure you want to remove "$devName"?',
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
                                                      foregroundColor:
                                                          Colors.redAccent,
                                                    ),
                                                    child: const Text('Remove'),
                                                  ),
                                                ],
                                              ),
                                            );
                                            if (confirm == true && email.isNotEmpty) {
                                              await ref
                                                  .read(authServiceProvider)
                                                  .removeUserDevice(email, devId);
                                              setState(() {});
                                            }
                                          },
                                  ),
                                ],
                              ),

                            );
                          },
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 32),

                  // Section: Actions
                  if (user != null && providerName == 'Email/Password') ...[
                    ElevatedButton.icon(
                      icon: _isSendingReset
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.lock_reset_rounded),
                      label: const Text('Reset Account Password'),
                      onPressed: _isSendingReset
                          ? null
                          : () => _handleResetPassword(email),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        backgroundColor: theme.primaryColor.withOpacity(0.08),
                        foregroundColor: theme.primaryColor,
                        side: BorderSide(
                          color: theme.primaryColor.withOpacity(0.2),
                        ),
                        elevation: 0,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  ElevatedButton.icon(
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Sign Out of Account'),
                    onPressed: _handleLogout,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      backgroundColor: isDark
                          ? const Color(0xFF311A24).withOpacity(0.4)
                          : const Color(0xFFFEE2E2).withOpacity(0.4),
                      foregroundColor: Colors.redAccent,
                      side: BorderSide(
                        color: Colors.redAccent.withOpacity(0.2),
                      ),
                      elevation: 0,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4.0),
      child: Text(
        title,
        style: GoogleFonts.outfit(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: Colors.grey.shade500,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.primaryColor.withOpacity(0.8)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 3),
              SelectableText(
                value,
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
            top: 300,
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
