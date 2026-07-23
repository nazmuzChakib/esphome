import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/network/debug_log_service.dart';
import '../../../core/security/node_security_service.dart';
import '../../../core/widgets/app_background.dart';
import '../../../core/widgets/custom_toast.dart';
import '../../../core/widgets/glass_container.dart';

class DebugMonitorScreen extends ConsumerStatefulWidget {
  const DebugMonitorScreen({super.key});

  @override
  ConsumerState<DebugMonitorScreen> createState() => _DebugMonitorScreenState();
}

class _DebugMonitorScreenState extends ConsumerState<DebugMonitorScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _selectedSource = 'ALL';
  bool _autoScroll = true;
  bool _autoDecrypt = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    // Attach static DebugLogger to riverpod notifier
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifier = ref.read(debugLogServiceProvider.notifier);
      DebugLogger.attach(notifier);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Color _getSourceColor(String source) {
    switch (source.toUpperCase()) {
      case 'WS':
        return const Color(0xFF6366F1); // Indigo / Cyan
      case 'HTTP':
        return const Color(0xFF10B981); // Emerald / Mint
      case 'UDP':
        return const Color(0xFFA855F7); // Purple
      case 'FIREBASE':
        return const Color(0xFFF59E0B); // Amber / Orange
      case 'SYSTEM':
      default:
        return const Color(0xFF06B6D4); // Cyan
    }
  }

  Color _getLevelColor(LogLevel level) {
    switch (level) {
      case LogLevel.success:
        return const Color(0xFF22C55E);
      case LogLevel.warning:
        return const Color(0xFFEAB308);
      case LogLevel.error:
        return const Color(0xFFEF4444);
      case LogLevel.info:
        return const Color(0xFF38BDF8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(debugLogServiceProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Attach static logger instance
    final notifier = ref.read(debugLogServiceProvider.notifier);
    DebugLogger.attach(notifier);

    // Apply filtering
    final filteredLogs = logs.where((entry) {
      final matchesSource =
          _selectedSource == 'ALL' ||
          entry.source.toUpperCase() == _selectedSource;
      final matchesSearch =
          _searchQuery.isEmpty ||
          entry.payload.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          entry.source.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          (entry.mac != null &&
              entry.mac!.toLowerCase().contains(_searchQuery.toLowerCase()));
      return matchesSource && matchesSearch;
    }).toList();

    // Trigger auto-scroll on new log arrival
    ref.listen<List<DebugLogEntry>>(debugLogServiceProvider, (previous, next) {
      if (_autoScroll && (next.length > (previous?.length ?? 0))) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    });

    return Stack(
      children: [
        AppBackground(isDark: isDark),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            elevation: 0,
            backgroundColor: Colors.transparent,
            title: Text(
              'Debug Data Monitor',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
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
              ),
            ),
            flexibleSpace: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(color: Colors.transparent),
              ),
            ),
            actions: [
              // Auto decrypt toggle
              IconButton(
                tooltip: _autoDecrypt ? 'Auto-Decrypt On' : 'Auto-Decrypt Off',
                icon: Icon(
                  _autoDecrypt
                      ? Icons.lock_open_rounded
                      : Icons.lock_outline_rounded,
                  color: _autoDecrypt
                      ? const Color(0xFF10B981)
                      : (isDark ? Colors.white54 : Colors.black45),
                ),
                onPressed: () {
                  setState(() => _autoDecrypt = !_autoDecrypt);
                  AppToast.info(
                    context,
                    message: _autoDecrypt
                        ? 'Auto-decryption enabled'
                        : 'Auto-decryption disabled',
                  );
                },
              ),
              // Auto scroll toggle
              IconButton(
                tooltip: _autoScroll
                    ? 'Pause Auto-Scroll'
                    : 'Resume Auto-Scroll',
                icon: Icon(
                  _autoScroll
                      ? Icons.arrow_downward_rounded
                      : Icons.pause_circle_outline_rounded,
                  color: _autoScroll
                      ? const Color(0xFF6366F1)
                      : (isDark ? Colors.white54 : Colors.black45),
                ),
                onPressed: () {
                  setState(() => _autoScroll = !_autoScroll);
                  if (_autoScroll) _scrollToBottom();
                },
              ),
              // Copy All Logs
              IconButton(
                tooltip: 'Copy Logs',
                icon: const Icon(Icons.copy_all_rounded),
                onPressed: () {
                  final exportText = notifier.exportFormattedLogs();
                  Clipboard.setData(ClipboardData(text: exportText));
                  AppToast.success(
                    context,
                    message: 'Debug logs copied to clipboard!',
                  );
                },
              ),
              // Clear logs
              IconButton(
                tooltip: 'Clear Monitor Logs',
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                onPressed: () async {
                  await notifier.clearLogs();
                  if (context.mounted) {
                    AppToast.info(context, message: 'Debug logs cleared');
                  }
                },
              ),
            ],
          ),
          body: Column(
            children: [
              // Filter Bar & Search Input
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: GlassContainer(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      // Search Bar
                      TextField(
                        controller: _searchController,
                        style: GoogleFonts.firaCode(fontSize: 13),
                        onChanged: (val) => setState(() => _searchQuery = val),
                        decoration: InputDecoration(
                          hintText: 'Filter payload / MAC / command...',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 20,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.clear_rounded,
                                    size: 18,
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _searchQuery = '');
                                  },
                                )
                              : null,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: isDark
                              ? Colors.black.withOpacity(0.3)
                              : Colors.white.withOpacity(0.6),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Source Filter Chips
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children:
                              [
                                'ALL',
                                'WS',
                                'HTTP',
                                'UDP',
                                'FIREBASE',
                                'SYSTEM',
                              ].map((src) {
                                final isSelected = _selectedSource == src;
                                final color = src == 'ALL'
                                    ? const Color(0xFF6366F1)
                                    : _getSourceColor(src);

                                return Padding(
                                  padding: const EdgeInsets.only(right: 8.0),
                                  child: ChoiceChip(
                                    label: Text(
                                      src,
                                      style: GoogleFonts.outfit(
                                        fontSize: 12,
                                        fontWeight: isSelected
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: isSelected
                                            ? Colors.white
                                            : (isDark
                                                  ? Colors.white70
                                                  : Colors.black54),
                                      ),
                                    ),
                                    selected: isSelected,
                                    selectedColor: color,
                                    backgroundColor: isDark
                                        ? Colors.black.withOpacity(0.25)
                                        : Colors.white.withOpacity(0.4),
                                    onSelected: (val) {
                                      if (val) {
                                        setState(() => _selectedSource = src);
                                      }
                                    },
                                  ),
                                );
                              }).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Live Terminal Log Output Stream
              Expanded(
                child: filteredLogs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.terminal_rounded,
                              size: 64,
                              color: isDark ? Colors.white24 : Colors.black26,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No telemetry data captured yet',
                              style: GoogleFonts.outfit(
                                fontSize: 15,
                                color: isDark ? Colors.white54 : Colors.black45,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Listening for live WS, HTTP, UDP & Firebase traffic...',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: isDark ? Colors.white38 : Colors.black38,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: GlassContainer(
                          padding: const EdgeInsets.all(8.0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: ListView.builder(
                              controller: _scrollController,
                              itemCount: filteredLogs.length,
                              itemBuilder: (context, index) {
                                final entry = filteredLogs[index];
                                return _buildLogCard(entry, isDark);
                              },
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLogCard(DebugLogEntry entry, bool isDark) {
    final sourceColor = _getSourceColor(entry.source);
    final levelColor = _getLevelColor(entry.level);

    // Attempt to decrypt encrypted frame [Timestamp]:[Base64]
    String? decryptedJsonStr;
    if (_autoDecrypt && entry.payload.contains(':')) {
      try {
        final nodeSecurity = ref.read(nodeSecurityServiceProvider);
        final decryptedMap = nodeSecurity.decryptEncryptedFrame(
          frame: entry.payload,
          checkReplayWindow: false,
        );
        if (decryptedMap != null && decryptedMap.isNotEmpty) {
          const encoder = JsonEncoder.withIndent('  ');
          decryptedJsonStr = encoder.convert(decryptedMap);
        }
      } catch (_) {}
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8.0),
      padding: const EdgeInsets.all(10.0),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF090D16) : const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sourceColor.withOpacity(0.3), width: 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Time + Source Badge + Direction + MAC
          Row(
            children: [
              Text(
                '[${entry.formattedTime}]',
                style: GoogleFonts.firaCode(
                  fontSize: 11,
                  color: const Color(0xFF94A3B8),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: sourceColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: sourceColor, width: 0.8),
                ),
                child: Text(
                  entry.source.toUpperCase(),
                  style: GoogleFonts.firaCode(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: sourceColor,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                entry.direction == 'INBOUND'
                    ? Icons.south_west_rounded
                    : (entry.direction == 'OUTBOUND'
                          ? Icons.north_east_rounded
                          : Icons.sync_alt_rounded),
                size: 14,
                color: levelColor,
              ),
              const SizedBox(width: 4),
              Text(
                entry.direction,
                style: GoogleFonts.firaCode(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: levelColor,
                ),
              ),
              if (entry.mac != null && entry.mac!.isNotEmpty) ...[
                const Spacer(),
                Text(
                  entry.mac!,
                  style: GoogleFonts.firaCode(
                    fontSize: 10,
                    color: Colors.amberAccent,
                  ),
                ),
              ],
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                icon: const Icon(
                  Icons.copy_rounded,
                  size: 14,
                  color: Colors.white54,
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: entry.payload));
                  AppToast.info(context, message: 'Payload copied');
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Code/Terminal Payload Block
          SelectableText(
            entry.payload,
            style: GoogleFonts.firaCode(
              fontSize: 12,
              height: 1.35,
              color: entry.level == LogLevel.error
                  ? const Color(0xFFFCA5A5)
                  : (entry.level == LogLevel.warning
                        ? const Color(0xFFFDE047)
                        : const Color(0xFFE2E8F0)),
            ),
          ),
          // Decrypted Payload Section (if available)
          if (decryptedJsonStr != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10.0),
              decoration: BoxDecoration(
                color: const Color(0xFF064E3B).withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF10B981).withOpacity(0.7),
                  width: 1.0,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.lock_open_rounded,
                        size: 14,
                        color: Color(0xFF34D399),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'DECRYPTED PAYLOAD',
                        style: GoogleFonts.firaCode(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF34D399),
                        ),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(
                            ClipboardData(text: decryptedJsonStr!),
                          );
                          AppToast.success(
                            context,
                            message: 'Decrypted JSON copied to clipboard',
                          );
                        },
                        child: Row(
                          children: [
                            const Icon(
                              Icons.copy_rounded,
                              size: 12,
                              color: Color(0xFF34D399),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Copy JSON',
                              style: GoogleFonts.firaCode(
                                fontSize: 10,
                                color: const Color(0xFF34D399),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    decryptedJsonStr,
                    style: GoogleFonts.firaCode(
                      fontSize: 12,
                      height: 1.35,
                      color: const Color(0xFFA7F3D0),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
