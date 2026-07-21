import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_database/firebase_database.dart';
import '../../../core/security/secure_storage_provider.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_dialog.dart';
import '../../auth/data/auth_provider.dart';

class SecuritySettingsScreen extends ConsumerStatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  ConsumerState<SecuritySettingsScreen> createState() =>
      _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState
    extends ConsumerState<SecuritySettingsScreen> {
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _firebaseKeyController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isScrolled = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    final scrolled = _scrollController.offset > 10;
    if (scrolled != _isScrolled) {
      setState(() => _isScrolled = scrolled);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _apiKeyController.dispose();
    _firebaseKeyController.dispose();
    super.dispose();
  }

  void _saveKeys() async {
    final authState = ref.read(authProvider);
    final isAdmin = (authState.role ?? 'user').toLowerCase() == 'admin';

    if (!isAdmin) {
      GlassToast.show(
        context,
        icon: const Icon(Icons.error_outline, color: Colors.redAccent),
        color: Colors.redAccent,
        message: 'Security key modification restricted to Administrators.',
        behave: ToastBehavior.error,
      );
      return;
    }

    bool saved = false;
    if (_apiKeyController.text.trim().isNotEmpty) {
      await ref
          .read(apiKeyProvider.notifier)
          .saveApiKey(_apiKeyController.text.trim());
      saved = true;
    }
    if (_firebaseKeyController.text.trim().isNotEmpty) {
      final newKey = _firebaseKeyController.text.trim();
      await ref.read(firebaseKeyProvider.notifier).saveKey(newKey);

      // Propagate globally to Firebase Realtime Database
      try {
        await FirebaseDatabase.instance
            .ref('system/config/encryption_key')
            .set(newKey);
      } catch (_) {}
      saved = true;
    }
    if (saved && mounted) {
      GlassToast.show(
        context,
        icon: const Icon(Icons.check_circle_outline, color: Colors.green),
        color: Colors.green,
        message: 'Security credentials propagated globally.',
        behave: ToastBehavior.success,
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final apiKey = ref.watch(apiKeyProvider);
    final firebaseKey = ref.watch(firebaseKeyProvider);
    final isDark = theme.brightness == Brightness.dark;
    final authState = ref.watch(authProvider);
    final isAdmin = (authState.role ?? 'user').toLowerCase() == 'admin';

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Security Credentials',
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
              padding: const EdgeInsets.all(24.0),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Container(
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
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Icon(
                                Icons.vpn_key_outlined,
                                size: 52,
                                color: theme.primaryColor,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Security Encryption Keys',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.outfit(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Node API key section
                              Text(
                                'ESPHome API Key: ${apiKey != null ? '••••••••••••••••' : 'None'}',
                                style: GoogleFonts.inter(
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black87,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: _apiKeyController,
                                enabled: isAdmin,
                                decoration: InputDecoration(
                                  labelText: 'Enter Secret AES Node Key',
                                  border: const OutlineInputBorder(),
                                  prefixIcon: const Icon(Icons.router_outlined),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                  helperText: !isAdmin
                                      ? 'Admin access required to edit'
                                      : null,
                                ),
                                obscureText: true,
                              ),
                              const SizedBox(height: 6),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: InkWell(
                                  onTap: () =>
                                      _showApiKeyDetailsDialog(context),
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
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),

                              // Firebase Encrypted DB key section
                              Text(
                                'Firebase Payload Key: ${firebaseKey != null ? '••••••••••••••••' : 'None'}',
                                style: GoogleFonts.inter(
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black87,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: _firebaseKeyController,
                                enabled: isAdmin,
                                decoration: InputDecoration(
                                  labelText: 'Enter Firebase payload Key',
                                  border: const OutlineInputBorder(),
                                  prefixIcon: const Icon(Icons.cloud_outlined),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                  helperText: !isAdmin
                                      ? 'Admin access required to edit'
                                      : null,
                                ),
                                obscureText: true,
                              ),

                              if (!isAdmin) ...[
                                const SizedBox(height: 16),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: Colors.amber.withOpacity(0.3),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.security_outlined,
                                        color: Colors.amber,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'Non-admin users cannot alter root system keys to prevent network failure.',
                                          style: GoogleFonts.inter(
                                            color: Colors.amber.shade200,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],

                              const SizedBox(height: 24),
                              ElevatedButton(
                                onPressed: isAdmin ? _saveKeys : null,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: Text(
                                  'Save Credentials',
                                  style: GoogleFonts.outfit(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
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
