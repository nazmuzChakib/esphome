import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../core/security/firebase_encryption_service.dart';
import '../../../core/security/node_security_service.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/glass_container.dart';

class DatabaseInspectorScreen extends ConsumerStatefulWidget {
  const DatabaseInspectorScreen({super.key});

  @override
  ConsumerState<DatabaseInspectorScreen> createState() =>
      _DatabaseInspectorScreenState();
}

class _DatabaseInspectorScreenState
    extends ConsumerState<DatabaseInspectorScreen> {
  final List<String> _boxes = const [
    'settings',
    'rules',
    'cached_nodes',
    'cached_node_states',
    'offline_command_queue',
    'cached_user_profile',
    'cached_permissions',
  ];

  String? _selectedBox;
  Map<dynamic, dynamic> _boxData = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (_boxes.isNotEmpty) {
      _loadBoxData(_boxes.first);
    }
  }

  void _loadBoxData(String boxName) async {
    setState(() {
      _selectedBox = boxName;
      _isLoading = true;
      _boxData = {};
    });

    try {
      final box = await Hive.openBox(boxName);
      final data = <dynamic, dynamic>{};
      for (var key in box.keys) {
        data[key] = box.get(key);
      }
      setState(() {
        _boxData = data;
      });
    } catch (_) {
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final encService = ref.watch(firebaseEncryptionServiceProvider);
    final nodeSecurity = ref.watch(nodeSecurityServiceProvider);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.transparent,
        title: Text(
          'Database Inspector',
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
      ),
      body: Stack(
        children: [
          AppBackground(isDark: isDark),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Horizontal Box Selector
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _boxes.map((boxName) {
                        final selected = _selectedBox == boxName;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: ChoiceChip(
                            label: Text(
                              boxName,
                              style: GoogleFonts.outfit(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: selected
                                    ? Colors.white
                                    : (isDark
                                          ? Colors.white70
                                          : Colors.black87),
                              ),
                            ),
                            selected: selected,
                            onSelected: (_) => _loadBoxData(boxName),
                            selectedColor: theme.primaryColor,
                            backgroundColor: isDark
                                ? Colors.white.withOpacity(0.08)
                                : Colors.black.withOpacity(0.05),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),

                // Data Viewer
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _boxData.isEmpty
                      ? Center(
                          child: Text(
                            'No data in this box',
                            style: GoogleFonts.inter(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          itemCount: _boxData.length,
                          itemBuilder: (context, index) {
                            final key = _boxData.keys.elementAt(index);
                            final val = _boxData[key];

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: GlassContainer(
                                borderRadius: 16.0,
                                padding: const EdgeInsets.all(16.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Key: $key',
                                      style: GoogleFonts.outfit(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: theme.primaryColor,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    const Divider(),
                                    const SizedBox(height: 8),
                                    _buildValueDisplay(
                                      val,
                                      encService,
                                      nodeSecurity,
                                      isDark,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildValueDisplay(
    dynamic value,
    FirebaseEncryptionService encService,
    NodeSecurityService nodeSecurity,
    bool isDark,
  ) {
    if (value is String) {
      final decrypted = _tryDecrypt(value, encService, nodeSecurity);
      if (decrypted.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Raw Data:',
              style: GoogleFonts.inter(
                fontSize: 11,
                color: Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            SelectableText(
              value,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                color: Colors.grey,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '🔓 Decrypted Data:',
              style: GoogleFonts.inter(
                fontSize: 11,
                color: const Color(0xFF10B981),
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            SelectableText(
              decrypted,
              style: GoogleFonts.firaCode(
                fontSize: 12.5,
                color: isDark
                    ? const Color(0xFFA7F3D0)
                    : const Color(0xFF047857),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        );
      } else {
        return SelectableText(
          value,
          style: GoogleFonts.inter(
            fontSize: 13,
            color: isDark ? Colors.white70 : Colors.black87,
          ),
        );
      }
    } else if (value is Map) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: value.entries.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.key}: ',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white70 : Colors.black87,
                  ),
                ),
                Expanded(
                  child: _buildValueDisplay(
                    entry.value,
                    encService,
                    nodeSecurity,
                    isDark,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      );
    } else if (value is List) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: List.generate(value.length, (idx) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '[$idx]: ',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                Expanded(
                  child: _buildValueDisplay(
                    value[idx],
                    encService,
                    nodeSecurity,
                    isDark,
                  ),
                ),
              ],
            ),
          );
        }),
      );
    } else {
      return SelectableText(
        value.toString(),
        style: GoogleFonts.inter(
          fontSize: 13,
          color: isDark ? Colors.white70 : Colors.black87,
        ),
      );
    }
  }

  String _tryDecrypt(
    String val,
    FirebaseEncryptionService encService,
    NodeSecurityService nodeSecurity,
  ) {
    if (val.contains(':')) {
      try {
        final map = nodeSecurity.decryptEncryptedFrame(
          frame: val,
          checkReplayWindow: false,
        );
        if (map != null && map.isNotEmpty) {
          return const JsonEncoder.withIndent('  ').convert(map);
        }
      } catch (_) {}
    }

    if (val.length >= 32) {
      try {
        final decrypted = encService.decryptField(val);
        if (decrypted != val) return decrypted;
      } catch (_) {}
    }
    return '';
  }
}
