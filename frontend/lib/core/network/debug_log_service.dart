import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

enum LogLevel { info, success, warning, error }

class DebugLogEntry {
  final String id;
  final DateTime timestamp;
  final String source; // WS, HTTP, UDP, Firebase, System
  final String direction; // INBOUND, OUTBOUND, INTERNAL
  final String payload;
  final LogLevel level;
  final String? mac;

  DebugLogEntry({
    required this.id,
    required this.timestamp,
    required this.source,
    required this.direction,
    required this.payload,
    this.level = LogLevel.info,
    this.mac,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'timestamp': timestamp.toIso8601String(),
      'source': source,
      'direction': direction,
      'payload': payload,
      'level': level.name,
      'mac': mac,
    };
  }

  factory DebugLogEntry.fromMap(Map<dynamic, dynamic> map) {
    return DebugLogEntry(
      id:
          map['id'] as String? ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp:
          DateTime.tryParse(map['timestamp'] as String? ?? '') ??
          DateTime.now(),
      source: map['source'] as String? ?? 'System',
      direction: map['direction'] as String? ?? 'INTERNAL',
      payload: map['payload'] as String? ?? '',
      level: LogLevel.values.firstWhere(
        (e) => e.name == map['level'],
        orElse: () => LogLevel.info,
      ),
      mac: map['mac'] as String?,
    );
  }

  String get formattedTime => DateFormat('HH:mm:ss.SSS').format(timestamp);
}

final debugLogServiceProvider =
    StateNotifierProvider<DebugLogNotifier, List<DebugLogEntry>>((ref) {
      return DebugLogNotifier();
    });

class DebugLogNotifier extends StateNotifier<List<DebugLogEntry>> {
  static const String boxName = 'debug_logs_box';
  static const int maxLogEntries = 500;
  Box? _box;

  DebugLogNotifier() : super([]) {
    _initHive();
  }

  Future<void> _initHive() async {
    try {
      if (!Hive.isBoxOpen(boxName)) {
        _box = await Hive.openBox(boxName);
      } else {
        _box = Hive.box(boxName);
      }
      _loadFromHive();
    } catch (_) {}
  }

  void _loadFromHive() {
    if (_box == null) return;
    try {
      final rawList = _box!.get('entries', defaultValue: []);
      if (rawList is List) {
        final loaded = rawList
            .map(
              (item) => DebugLogEntry.fromMap(
                Map<dynamic, dynamic>.from(item as Map),
              ),
            )
            .toList();
        state = loaded;
      }
    } catch (_) {}
  }

  /// Add a new live debug log entry
  void log({
    required String source,
    required String direction,
    required String payload,
    LogLevel level = LogLevel.info,
    String? mac,
  }) {
    final entry = DebugLogEntry(
      id: '${DateTime.now().millisecondsSinceEpoch}_${state.length}',
      timestamp: DateTime.now(),
      source: source,
      direction: direction,
      payload: _formatPayload(payload),
      level: level,
      mac: mac,
    );

    final updated = [...state, entry];
    if (updated.length > maxLogEntries) {
      updated.removeRange(0, updated.length - maxLogEntries);
    }
    state = updated;
    _persistToHive();
  }

  String _formatPayload(String raw) {
    final trimmed = raw.trim();
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        final decoded = jsonDecode(trimmed);
        const encoder = JsonEncoder.withIndent('  ');
        return encoder.convert(decoded);
      } catch (_) {}
    }
    return raw;
  }

  void _persistToHive() async {
    if (_box != null && _box!.isOpen) {
      try {
        final serializable = state.map((e) => e.toMap()).toList();
        await _box!.put('entries', serializable);
      } catch (_) {}
    }
  }

  /// Clear all debug logs
  Future<void> clearLogs() async {
    state = [];
    if (_box != null && _box!.isOpen) {
      await _box!.delete('entries');
    }
  }

  /// Export logs as plain formatted text string
  String exportFormattedLogs() {
    final buffer = StringBuffer();
    buffer.writeln('=== ESPHome Debug Data Monitor Logs ===');
    buffer.writeln('Exported At: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Total Entries: ${state.length}');
    buffer.writeln('=======================================\n');

    for (final entry in state) {
      buffer.writeln(
        '[${entry.formattedTime}] [${entry.source}] [${entry.direction}] [${entry.level.name.toUpperCase()}] ${entry.mac != null ? "MAC: ${entry.mac}" : ""}',
      );
      buffer.writeln(entry.payload);
      buffer.writeln('-' * 60);
    }
    return buffer.toString();
  }
}

/// Global static logger instance for direct invocation without BuildContext
class DebugLogger {
  static DebugLogNotifier? _notifierInstance;

  static void attach(DebugLogNotifier notifier) {
    _notifierInstance = notifier;
  }

  static void log({
    required String source,
    required String direction,
    required String payload,
    LogLevel level = LogLevel.info,
    String? mac,
  }) {
    _notifierInstance?.log(
      source: source,
      direction: direction,
      payload: payload,
      level: level,
      mac: mac,
    );
  }
}
