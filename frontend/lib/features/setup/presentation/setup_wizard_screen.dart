import 'dart:io';
import 'dart:ui';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import '../../../core/security/secure_storage_provider.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/widgets/glass_dialog.dart';

class SetupWizardScreen extends ConsumerStatefulWidget {
  const SetupWizardScreen({super.key});

  @override
  ConsumerState<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends ConsumerState<SetupWizardScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // Form parameters
  final TextEditingController _apiKeyController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Permission statuses
  bool _notificationGranted = kIsWeb;
  bool _locationGranted = kIsWeb;
  bool _storageGranted = kIsWeb;
  bool _installerGranted = kIsWeb;
  bool _agreedToTerms = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    if (kIsWeb) return;

    final notificationStatus = await Permission.notification.status;
    final locationStatus = await Permission.location.status;
    final installerStatus = await Permission.requestInstallPackages.status;

    // Android 13+ (API 33+): storage permission replaced by photos/media permissions
    bool storageGranted = false;
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        // Use mediaLibrary (photos/videos/audio) for Android 13+
        final mediaStatus = await Permission.photos.status;
        storageGranted = mediaStatus.isGranted;
      } else {
        final storageStatus = await Permission.storage.status;
        storageGranted = storageStatus.isGranted;
      }
    } else {
      final storageStatus = await Permission.storage.status;
      storageGranted = storageStatus.isGranted;
    }

    setState(() {
      _notificationGranted = notificationStatus.isGranted;
      _locationGranted = locationStatus.isGranted;
      _storageGranted = storageGranted;
      _installerGranted = installerStatus.isGranted;
    });
  }

  Future<void> _requestNotificationPermission() async {
    final status = await Permission.notification.request();
    setState(() {
      _notificationGranted = status.isGranted;
    });
  }

  Future<void> _requestLocationPermission() async {
    final status = await Permission.location.request();
    setState(() {
      _locationGranted = status.isGranted;
    });
  }

  Future<void> _requestStoragePermission() async {
    if (kIsWeb) return;
    // Android 13+ (API 33+): use photos/media permission instead of legacy storage
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        final status = await Permission.photos.request();
        setState(() => _storageGranted = status.isGranted);
        return;
      }
    }
    final status = await Permission.storage.request();
    setState(() => _storageGranted = status.isGranted);
  }

  Future<void> _requestInstallerPermission() async {
    if (kIsWeb) return;
    final status = await Permission.requestInstallPackages.request();
    setState(() {
      _installerGranted = status.isGranted;
    });
  }

  Future<void> _completeWizard() async {
    if (_formKey.currentState?.validate() ?? false) {
      // Save API key securely
      await ref
          .read(apiKeyProvider.notifier)
          .saveApiKey(_apiKeyController.text.trim());

      // Mark wizard completed in Hive Box
      final box = await Hive.openBox('settings');
      await box.put('wizardCompleted', true);

      if (mounted) {
        context.go('/login');
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          _SetupWizardBackgroundBlobs(isDark: isDark),
          SafeArea(
            child: Column(
              children: [
                // Page indicators
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      3,
                      (index) => _buildIndicator(index),
                    ),
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (int page) {
                      setState(() {
                        _currentPage = page;
                      });
                    },
                    children: [
                      _buildWelcomeSlide(theme, isDark),
                      _buildPermissionSlide(theme, isDark),
                      _buildSettingsSlide(theme, isDark),
                    ],
                  ),
                ),
                // Bottom Action buttons
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (_currentPage > 0)
                        TextButton(
                          onPressed: () {
                            _pageController.previousPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut,
                            );
                          },
                          child: Text(
                            'Back',
                            style: GoogleFonts.outfit(
                              fontSize: 16,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                        )
                      else
                        const SizedBox.shrink(),
                      ElevatedButton(
                        onPressed: () {
                          if (_currentPage == 0 && !_agreedToTerms) {
                            GlassToast.show(
                              context,
                              icon: const Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.amber,
                              ),
                              color: Colors.amber,
                              message:
                                  'You must agree to the Terms & Conditions and Privacy Policy to proceed.',
                              behave: ToastBehavior.info,
                            );
                            return;
                          }
                          if (_currentPage == 1 &&
                              (!_notificationGranted ||
                                  !_locationGranted ||
                                  !_storageGranted ||
                                  !_installerGranted)) {
                            GlassToast.show(
                              context,
                              icon: const Icon(
                                Icons.security_rounded,
                                color: Colors.redAccent,
                              ),
                              color: Colors.red,
                              message:
                                  'All permissions must be allowed to proceed.',
                              behave: ToastBehavior.error,
                            );
                            return;
                          }

                          if (_currentPage < 2) {
                            _pageController.nextPage(
                              duration: const Duration(milliseconds: 300),
                              curve: Curves.easeInOut,
                            );
                          } else {
                            _completeWizard();
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 32,
                            vertical: 16,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _currentPage == 2 ? 'Get Started' : 'Next',
                              style: GoogleFonts.outfit(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.arrow_forward, size: 16),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIndicator(int index) {
    final isSelected = index == _currentPage;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.symmetric(horizontal: 4.0),
      height: 8.0,
      width: isSelected ? 24.0 : 8.0,
      decoration: BoxDecoration(
        color: isSelected
            ? Theme.of(context).primaryColor
            : Colors.grey.withOpacity(0.5),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  Widget _buildGlassCard({required Widget child}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.all(24.0),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.06)
                  : Colors.black.withOpacity(0.03),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.06),
                width: 1.5,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildWelcomeSlide(ThemeData theme, bool isDark) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
        child: _buildGlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.primaryColor.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.home_outlined,
                  size: 48,
                  color: theme.primaryColor,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Welcome to ESPHome',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Control your home smart nodes locally with AES-128-CBC security encryption and cloud fallback through secure MQTT.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: isDark
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF475569),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 12),
              Row(
                children: [
                  Checkbox(
                    value: _agreedToTerms,
                    onChanged: (val) {
                      setState(() {
                        _agreedToTerms = val ?? false;
                      });
                    },
                    activeColor: theme.primaryColor,
                  ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        text: 'I agree to the ',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : Colors.black87,
                        ),
                        children: [
                          TextSpan(
                            text: 'Terms & Conditions',
                            style: const TextStyle(
                              color: Colors.blueAccent,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = _showTermsDialog,
                          ),
                          const TextSpan(text: ' and '),
                          TextSpan(
                            text: 'Privacy Policy',
                            style: const TextStyle(
                              color: Colors.blueAccent,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = _showPrivacyDialog,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTermsDialog() {
    GlassDialog.show(
      context,
      title: const Text('Terms & Conditions'),
      content: const SizedBox(
        height: 200,
        child: SingleChildScrollView(
          child: Text(
            '1. Acceptance of Terms: By utilizing this ESPHome client app, you agree to comply with local automation regulations and device security standards.\n\n'
            '2. Security & Encryption: Communications are locally encrypted with AES-128. You are solely responsible for protecting your secret API Keys.\n\n'
            '3. Device Access: This app manages hardware configurations and GPIO states on your network. Proceed only with devices you own or have permission to control.',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  void _showPrivacyDialog() {
    GlassDialog.show(
      context,
      title: const Text('Privacy Policy'),
      content: const SizedBox(
        height: 200,
        child: SingleChildScrollView(
          child: Text(
            '1. Data Collection: We do not sell or share any user details. We collect your email and device identifiers solely for authentication and authorization verification.\n\n'
            '2. Data Security: Sensitive user configurations (email, role, device ID) are client-side encrypted before being synced to the database.\n\n'
            '3. Storage: General local parameters are saved inside encrypted storage keys or secure local settings boxes.',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildPermissionSlide(ThemeData theme, bool isDark) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
        child: _buildGlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  'Required Permissions',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  'Initialize required capabilities for scans, logs, and updates.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF475569),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildPermissionRow(
                theme,
                Icons.notifications_outlined,
                'Notifications',
                'Receive alarms & warnings',
                _notificationGranted,
                _requestNotificationPermission,
              ),
              const SizedBox(height: 8),
              _buildPermissionRow(
                theme,
                Icons.location_on_outlined,
                'Location Scans',
                'Scan local Wi-Fi nodes',
                _locationGranted,
                _requestLocationPermission,
              ),
              if (!kIsWeb) ...[
                const SizedBox(height: 8),
                _buildPermissionRow(
                  theme,
                  Icons.folder_open_outlined,
                  'Storage Caching',
                  'Store rule configs & caches',
                  _storageGranted,
                  _requestStoragePermission,
                ),
                const SizedBox(height: 8),
                _buildPermissionRow(
                  theme,
                  Icons.system_update_alt_rounded,
                  'Package Installer',
                  'Allow software updates install',
                  _installerGranted,
                  _requestInstallerPermission,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionRow(
    ThemeData theme,
    IconData icon,
    String title,
    String description,
    bool isGranted,
    VoidCallback onRequest,
  ) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.black.withOpacity(0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.06)
              : Colors.black.withOpacity(0.04),
          width: 1.0,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: theme.primaryColor.withOpacity(0.15),
            child: Icon(icon, color: theme.primaryColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
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
                const SizedBox(height: 2),
                Text(
                  description,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: const Color(0xFF94A3B8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          isGranted
              ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
              : TextButton(
                  onPressed: onRequest,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Allow', style: TextStyle(fontSize: 13)),
                ),
        ],
      ),
    );
  }

  Widget _buildSettingsSlide(ThemeData theme, bool isDark) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
        child: _buildGlassCard(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Security Configuration',
                  style: GoogleFonts.outfit(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Set up the default cryptographic token to secure communications with your ESP32 nodes.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF475569),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _apiKeyController,
                  decoration: InputDecoration(
                    labelText: 'Cryptographic API Key',
                    prefixIcon: const Icon(Icons.security_rounded),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  obscureText: true,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter a default api key to proceed';
                    }
                    if (value.length < 8) {
                      return 'API Key must be at least 8 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    onTap: () => _showApiKeyDetailsDialog(context),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        'Why do I need a Cryptographic API Key? Learn more.',
                        style: GoogleFonts.inter(
                          color: theme.primaryColor,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showApiKeyDetailsDialog(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    GlassDialog.show(
      context,
      title: const Text('Cryptographic API Key Details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The Cryptographic API Key acts as a secure access token for node-to-node and app-to-node communications.',
              style: GoogleFonts.inter(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              '🔑 Why it is needed:',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '• Encrypts commands sent from this app (e.g., toggling a switch or changing fan speed) using AES cryptography.\n'
              '• Secures live telemetry and sensor data streams from your physical ESP32 nodes.\n'
              '• Prevents unauthorized third-party devices on your local Wi-Fi network from controlling or accessing your smart home.',
              style: GoogleFonts.inter(
                fontSize: 12,
                height: 1.4,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '⚙️ How it works:',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'This app and your ESP32 microcontrollers share the same secret key. Every network packet is digitally signed and encrypted. If a request lacks a valid signature, the node rejects it immediately.',
              style: GoogleFonts.inter(
                fontSize: 12,
                height: 1.4,
                color: isDark ? Colors.white70 : Colors.black87,
              ),
            ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.primaryColor,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Got It'),
        ),
      ],
    );
  }
}

class _SetupWizardBackgroundBlobs extends StatelessWidget {
  final bool isDark;
  const _SetupWizardBackgroundBlobs({required this.isDark});

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
