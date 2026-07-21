import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:image_picker/image_picker.dart';
import '../../auth/data/auth_provider.dart';
import '../../update/data/update_provider.dart';
import '../../update/presentation/update_dialog.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/utils/avatar_helper.dart';
import '../../../core/widgets/glass_container.dart';
import '../../../core/widgets/app_background.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // General settings state
  String _dashboardLayout = 'grid'; // grid, list, minimal
  String _timeFormat = '12h'; // 12h, 24h
  String _appVersion = 'Loading...';

  // Scroll-aware AppBar
  final ScrollController _scrollController = ScrollController();
  bool _isScrolled = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadGeneralSettings();
    _loadVersion();
  }

  void _onScroll() {
    final scrolled = _scrollController.offset > 10;
    if (scrolled != _isScrolled) {
      setState(() => _isScrolled = scrolled);
    }
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

  void _loadGeneralSettings() async {
    final box = await Hive.openBox('settings');
    setState(() {
      _dashboardLayout = box.get('dashboardLayout', defaultValue: 'grid');
      _timeFormat = box.get('timeFormat', defaultValue: '12h');
    });
  }

  void _saveGeneralSettings(String key, String value) async {
    final box = await Hive.openBox('settings');
    await box.put(key, value);
  }

  Future<void> _pickBackgroundImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        final box = await Hive.openBox('settings');
        await box.put('bgImagePath', image.path);
        if (mounted) {
          GlassToast.show(
            context,
            icon: const Icon(Icons.check_circle_outline_rounded),
            color: Colors.green,
            message: 'App background image set successfully.',
            behave: ToastBehavior.success,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        GlassToast.show(
          context,
          icon: const Icon(
            Icons.error_outline_rounded,
            color: Colors.redAccent,
          ),
          color: Colors.redAccent,
          message: 'Failed to pick image: ${e.toString()}',
          behave: ToastBehavior.error,
        );
      }
    }
  }

  Future<void> _clearBackgroundImage() async {
    final box = await Hive.openBox('settings');
    await box.delete('bgImagePath');
    if (mounted) {
      GlassToast.show(
        context,
        icon: const Icon(Icons.check_circle_outline_rounded),
        color: Colors.green,
        message: 'Background reset to default.',
        behave: ToastBehavior.success,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildGlassCard({
    required Widget child,
    Color? color,
    EdgeInsetsGeometry? padding,
  }) {
    return GlassContainer(
      borderRadius: 16.0,
      color: color,
      padding: padding ?? const EdgeInsets.all(16.0),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Settings',
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
            filter: ImageFilter.blur(
              sigmaX: _isScrolled ? 20.0 : 0.0,
              sigmaY: _isScrolled ? 20.0 : 0.0,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: _isScrolled
                    ? (isDark
                          ? const Color(0xFF0A0F1E).withOpacity(0.82)
                          : Colors.white.withOpacity(0.85))
                    : Colors.transparent,
                border: Border(
                  bottom: BorderSide(
                    color: _isScrolled
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
      ),
      body: Stack(
        children: [
          AppBackground(isDark: isDark),
          SafeArea(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Category: Account Profile
                  _buildSectionHeader('Account Profile'),
                  const SizedBox(height: 12),
                  _buildGlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Consumer(
                        builder: (context, ref, child) {
                          final authState = ref.watch(authProvider);
                          final displayName = authState.name;
                          final email = authState.email ?? '';
                          final avatarLetter =
                              (displayName != null && displayName.isNotEmpty)
                              ? displayName[0].toUpperCase()
                              : (email.isNotEmpty
                                    ? email[0].toUpperCase()
                                    : 'U');
                          final role = authState.role ?? 'user';
                          final isAdmin = role.toLowerCase() == 'admin';

                          final photoUrl = authState.photoUrl;

                          return CircleAvatar(
                            backgroundColor: isAdmin
                                ? Colors.amber.withOpacity(0.15)
                                : theme.primaryColor.withOpacity(0.12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: AvatarHelper.buildAvatarImage(
                                photoUrl: photoUrl,
                                width: 40,
                                height: 40,
                                placeholderBuilder: () => Text(
                                  avatarLetter,
                                  style: GoogleFonts.outfit(
                                    fontWeight: FontWeight.bold,
                                    color: isAdmin
                                        ? Colors.amber
                                        : theme.primaryColor,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      title: Consumer(
                        builder: (context, ref, child) {
                          final authState = ref.watch(authProvider);
                          final displayName = authState.name;
                          return Text(
                            (displayName != null && displayName.isNotEmpty)
                                ? displayName
                                : (authState.email ?? 'Not Logged In'),
                            style: GoogleFonts.outfit(
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
                          );
                        },
                      ),
                      subtitle: Consumer(
                        builder: (context, ref, child) {
                          final authState = ref.watch(authProvider);
                          final role = authState.role ?? 'user';
                          final isAdmin = role.toLowerCase() == 'admin';

                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isAdmin
                                    ? Icons.admin_panel_settings_rounded
                                    : Icons.person_rounded,
                                size: 14,
                                color: isAdmin
                                    ? Colors.amber
                                    : theme.primaryColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                isAdmin ? 'Administrator' : 'Standard User',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: isAdmin
                                      ? Colors.amber
                                      : theme.primaryColor,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      trailing: const Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 14,
                      ),
                      onTap: () => context.push('/profile'),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Category: Quick controls
                  _buildSectionHeader('Quick Configurations'),
                  const SizedBox(height: 12),

                  // Layout switcher
                  _buildGlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Dashboard Device Layout',
                          style: GoogleFonts.outfit(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Choose between grid, list, or minimal device layouts.',
                          style: GoogleFonts.inter(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _buildLayoutOption(
                                'grid',
                                Icons.grid_view_rounded,
                                'Grid View',
                                theme,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildLayoutOption(
                                'list',
                                Icons.view_list_rounded,
                                'List View',
                                theme,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildLayoutOption(
                                'minimal',
                                Icons.view_headline_rounded,
                                'Minimal',
                                theme,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Physical GPIO switch mode is now configured per-load, not globally.
                  const SizedBox(height: 16),

                  // ── Category: Appearance ────────────────────────────────────
                  _buildSectionHeader('Appearance'),
                  const SizedBox(height: 12),
                  _buildGlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.wallpaper_rounded,
                              size: 20,
                              color: theme.primaryColor,
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'App Background',
                                  style: GoogleFonts.outfit(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  'Choose a custom image or gradient blobs.',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Background preview & controls
                        ValueListenableBuilder(
                          valueListenable: Hive.box(
                            'settings',
                          ).listenable(keys: ['bgImagePath']),
                          builder: (context, Box box, _) {
                            final String? bgPath = box.get('bgImagePath');

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Preview box
                                Container(
                                  height: 100,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isDark
                                          ? Colors.white.withOpacity(0.1)
                                          : Colors.black.withOpacity(0.08),
                                    ),
                                  ),
                                  child: bgPath != null && bgPath.isNotEmpty
                                      ? Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Image.file(
                                              File(bgPath),
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  const _PreviewGradientBlobs(),
                                            ),
                                            Align(
                                              alignment: Alignment.topRight,
                                              child: Padding(
                                                padding: const EdgeInsets.all(
                                                  6,
                                                ),
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 3,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black
                                                        .withOpacity(0.6),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          8,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    'Custom',
                                                    style: GoogleFonts.inter(
                                                      fontSize: 10,
                                                      color: Colors.white,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : const _PreviewGradientBlobs(),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        icon: const Icon(
                                          Icons.photo_library_rounded,
                                          size: 16,
                                        ),
                                        label: Text(
                                          'Pick Image',
                                          style: GoogleFonts.inter(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        onPressed: _pickBackgroundImage,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: theme.primaryColor
                                              .withOpacity(0.15),
                                          foregroundColor: theme.primaryColor,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 10,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (bgPath != null &&
                                        bgPath.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      ElevatedButton.icon(
                                        icon: const Icon(
                                          Icons.restore_rounded,
                                          size: 16,
                                        ),
                                        label: Text(
                                          'Reset',
                                          style: GoogleFonts.inter(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        onPressed: _clearBackgroundImage,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.redAccent
                                              .withOpacity(0.12),
                                          foregroundColor: Colors.redAccent,
                                          elevation: 0,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 10,
                                            horizontal: 12,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Clock display format - compact binary switch
                  _buildGlassCard(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.access_time_filled,
                              size: 20,
                              color: theme.primaryColor,
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Time Format',
                                  style: GoogleFonts.outfit(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  _timeFormat == '12h'
                                      ? '12-hour (AM/PM)'
                                      : '24-hour',
                                  style: GoogleFonts.inter(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        // Compact toggle 12h / 24h
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withOpacity(0.07)
                                : Colors.black.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isDark
                                  ? Colors.white.withOpacity(0.12)
                                  : Colors.black.withOpacity(0.06),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: ['12h', '24h'].map((opt) {
                              final selected = _timeFormat == opt;
                              return GestureDetector(
                                onTap: () {
                                  setState(() => _timeFormat = opt);
                                  _saveGeneralSettings('timeFormat', opt);
                                  GlassToast.show(
                                    context,
                                    icon: const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                    ),
                                    color: Colors.green,
                                    message: 'Time format: $opt',
                                    behave: ToastBehavior.success,
                                  );
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? theme.primaryColor
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                  child: Text(
                                    opt,
                                    style: GoogleFonts.outfit(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: selected
                                          ? Colors.white
                                          : (isDark
                                                ? Colors.white54
                                                : Colors.black45),
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Category: Admin / Access Management
                  Consumer(
                    builder: (context, ref, child) {
                      final authState = ref.watch(authProvider);
                      final isAdmin =
                          (authState.role ?? 'user').toLowerCase() == 'admin';
                      if (!isAdmin) return const SizedBox.shrink();

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildSectionHeader('Access Management'),
                          const SizedBox(height: 12),
                          _buildGlassCard(
                            padding: EdgeInsets.zero,
                            child: Column(
                              children: [
                                ListTile(
                                  leading: const Icon(
                                    Icons.admin_panel_settings_outlined,
                                    color: Colors.amber,
                                  ),
                                  title: Text(
                                    'Access Control Manager',
                                    style: GoogleFonts.outfit(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  subtitle: const Text(
                                    'Manage device verification and node permission controls',
                                  ),
                                  trailing: const Icon(
                                    Icons.arrow_forward_ios_rounded,
                                    size: 14,
                                  ),
                                  onTap: () =>
                                      context.push('/settings/access-control'),
                                ),
                                const Divider(
                                  height: 1,
                                  indent: 16,
                                  endIndent: 16,
                                ),
                                ListTile(
                                  leading: const Icon(
                                    Icons.storage_rounded,
                                    color: Colors.cyan,
                                  ),
                                  title: Text(
                                    'Database Inspector (Debug)',
                                    style: GoogleFonts.outfit(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  subtitle: const Text(
                                    'Inspect raw encrypted and decrypted database records',
                                  ),
                                  trailing: const Icon(
                                    Icons.arrow_forward_ios_rounded,
                                    size: 14,
                                  ),
                                  onTap: () =>
                                      context.push('/settings/db-inspector'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                        ],
                      );
                    },
                  ),

                  // Category: Automation
                  _buildSectionHeader('Automation'),
                  const SizedBox(height: 12),
                  _buildGlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(
                        Icons.bolt_rounded,
                        color: theme.primaryColor,
                      ),
                      title: Text(
                        'Global Automations',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text(
                        'Configure automation actions across all nodes',
                      ),
                      trailing: const Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 14,
                      ),
                      onTap: () => context.push('/settings/bulk-rules'),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Category: Security & Privacy
                  _buildSectionHeader('Security & Privacy'),
                  const SizedBox(height: 12),

                  // API Security Decryption Key tile
                  _buildGlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(Icons.security, color: theme.primaryColor),
                      title: Text(
                        'API Security Decryption Key',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text(
                        'Update Decryption AES-128 API keys',
                      ),
                      trailing: const Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 14,
                      ),
                      onTap: () => context.push('/settings/security'),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Privacy Policy tile
                  _buildGlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(
                        Icons.policy_rounded,
                        color: theme.primaryColor,
                      ),
                      title: Text(
                        'Privacy Policy',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text(
                        'Review how your data is stored and used',
                      ),
                      trailing: const Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 14,
                      ),
                      onTap: () => _showPrivacyPolicy(context),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Category: App Service
                  if (!kIsWeb) ...[
                    _buildSectionHeader('App Service'),
                    const SizedBox(height: 12),
                    _buildGlassCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        leading: Icon(
                          Icons.system_update_rounded,
                          color: theme.primaryColor,
                        ),
                        title: Text(
                          'Check for Updates',
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'Check for latest app version on GitHub',
                        ),
                        trailing: const Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 14,
                        ),
                        onTap: () async {
                          showDialog(
                            context: context,
                            barrierDismissible: false,
                            builder: (context) => const _UpdateCheckingDialog(),
                          );
                          await ref
                              .read(updateProvider.notifier)
                              .checkForUpdates();
                          if (context.mounted) {
                            Navigator.of(context).pop(); // pop loader
                            showDialog(
                              context: context,
                              builder: (context) => const UpdateDialog(),
                            );
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  Center(
                    child: Text(
                      'ESPHome Client $_appVersion',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: isDark
                            ? const Color(0xFF64748B)
                            : const Color(0xFF94A3B8),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPrivacyPolicy(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (_, controller) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.black.withOpacity(0.5)
                    : Colors.white.withOpacity(0.7),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withOpacity(0.1)
                      : Colors.black.withOpacity(0.06),
                ),
              ),
              padding: const EdgeInsets.all(24),
              child: ListView(
                controller: controller,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text(
                    'Privacy Policy',
                    style: GoogleFonts.outfit(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _policySection(
                    'Data Collection',
                    'ESPHome collects your email address and device hardware identifiers solely for authentication and device management. No personal data is sold or shared with third parties.',
                  ),
                  _policySection(
                    'Data Storage',
                    'All user data is stored in Firebase Realtime Database under your configured project. Sensitive fields (email, role, device status) are AES-128 encrypted client-side before being stored.',
                  ),
                  _policySection(
                    'Device Information',
                    'Your device model and hardware ID are collected to provide multi-device management capabilities. This information is encrypted and only visible to your account administrator.',
                  ),
                  _policySection(
                    'Automation & Sensors',
                    'Sensor data (temperature, humidity) and automation rules are stored locally on your device and synchronized with your Firebase project. This data is not accessible to ESPHome developers.',
                  ),
                  _policySection(
                    'Updates',
                    'The app may check GitHub releases for updates. No personally identifiable information is transmitted during update checks.',
                  ),
                  _policySection(
                    'Contact',
                    'For privacy concerns or data deletion requests, contact your system administrator.',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Last updated: July 2026',
                    style: GoogleFonts.inter(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _policySection(String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.outfit(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          Text(body, style: GoogleFonts.inter(fontSize: 13, height: 1.5)),
        ],
      ),
    );
  }

  Widget _buildLayoutOption(
    String layoutMode,
    IconData icon,
    String label,
    ThemeData theme,
  ) {
    final isSelected = _dashboardLayout == layoutMode;
    return InkWell(
      onTap: () {
        setState(() => _dashboardLayout = layoutMode);
        _saveGeneralSettings('dashboardLayout', layoutMode);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 95,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? theme.primaryColor.withOpacity(0.15)
              : Colors.transparent,
          border: Border.all(
            color: isSelected
                ? theme.primaryColor
                : Colors.grey.withOpacity(0.3),
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isSelected ? theme.primaryColor : Colors.grey,
              size: 28,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: GoogleFonts.outfit(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? theme.primaryColor : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: Text(
        title,
        style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class SlidingOptionSelector extends StatefulWidget {
  final String currentValue;
  final List<String> values;
  final List<IconData> icons;
  final List<String> labels;
  final List<String> sublabels;
  final ValueChanged<String> onChanged;

  const SlidingOptionSelector({
    super.key,
    required this.currentValue,
    required this.values,
    required this.icons,
    required this.labels,
    required this.sublabels,
    required this.onChanged,
  });

  @override
  State<SlidingOptionSelector> createState() => _SlidingOptionSelectorState();
}

class _SlidingOptionSelectorState extends State<SlidingOptionSelector> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final int selectedIndex = widget.values.indexOf(widget.currentValue);

    return Container(
      height: 70,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.black.withOpacity(0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.08)
              : Colors.black.withOpacity(0.04),
          width: 1.2,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final double toggleWidth = width / widget.values.length;

          return Stack(
            children: [
              // Animated Background Sliding Capsule
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutBack,
                left: selectedIndex * toggleWidth + 4,
                top: 4,
                bottom: 4,
                width: toggleWidth - 8,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: theme.primaryColor.withOpacity(0.18),
                    border: Border.all(
                      color: theme.primaryColor.withOpacity(0.4),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: theme.primaryColor.withOpacity(0.2),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
              // Option Buttons
              Row(
                children: List.generate(widget.values.length, (index) {
                  final val = widget.values[index];
                  final label = widget.labels[index];
                  final sublabel = widget.sublabels[index];
                  final icon = widget.icons[index];
                  final isSelected = index == selectedIndex;

                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onChanged(val),
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 150),
                        scale: isSelected ? 1.02 : 1.0,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              icon,
                              color: isSelected
                                  ? theme.primaryColor
                                  : (isDark ? Colors.white54 : Colors.black45),
                              size: 20,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              label,
                              style: GoogleFonts.outfit(
                                fontSize: 13,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                color: isSelected
                                    ? theme.primaryColor
                                    : (isDark
                                          ? Colors.white70
                                          : Colors.black87),
                              ),
                            ),
                            Text(
                              sublabel,
                              style: GoogleFonts.inter(
                                fontSize: 9,
                                color: isDark ? Colors.white38 : Colors.black38,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─── Background preview thumbnail ────────────────────────────────────────────
class _PreviewGradientBlobs extends StatelessWidget {
  const _PreviewGradientBlobs();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF0F172A), const Color(0xFF020617)]
              : [const Color(0xFFF8FAFC), const Color(0xFFE2E8F0)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -20,
            left: -20,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF6366F1).withOpacity(0.35),
              ),
            ),
          ),
          Positioned(
            bottom: -20,
            right: -20,
            child: Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFEC4899).withOpacity(0.28),
              ),
            ),
          ),
          Center(
            child: Text(
              'Default Gradient',
              style: GoogleFonts.inter(
                fontSize: 11,
                color: isDark ? Colors.white54 : Colors.black45,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpdateCheckingDialog extends StatelessWidget {
  const _UpdateCheckingDialog();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18.0, sigmaY: 18.0),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black.withOpacity(0.4)
                  : Colors.white.withOpacity(0.55),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.12)
                    : Colors.black.withOpacity(0.08),
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Theme.of(context).primaryColor,
                ),
                const SizedBox(height: 24),
                Text(
                  'Checking for Updates',
                  style: GoogleFonts.outfit(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Connecting to GitHub...',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: isDark ? Colors.white60 : Colors.black54,
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
