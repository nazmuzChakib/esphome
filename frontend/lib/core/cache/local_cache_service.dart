import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'cache_keys.dart';

final localCacheServiceProvider = Provider<LocalCacheService>((ref) {
  return LocalCacheService();
});

class LocalCacheService {
  static const String offlineQueueBoxName = 'offline_command_queue';
  static const String nodeStatesBoxName = 'cached_node_states';

  final StreamController<void> _updateNotifier =
      StreamController<void>.broadcast();

  Stream<void> get onDataChanged => _updateNotifier.stream;

  /// Initialize Hive boxes if not already opened
  Future<void> init() async {
    if (!Hive.isBoxOpen(CacheKeys.nodesBox)) {
      await Hive.openBox(CacheKeys.nodesBox);
    }
    if (!Hive.isBoxOpen(nodeStatesBoxName)) {
      await Hive.openBox(nodeStatesBoxName);
    }
    if (!Hive.isBoxOpen(offlineQueueBoxName)) {
      await Hive.openBox(offlineQueueBoxName);
    }
  }

  /// Parse and update node states directly to Local DB first, then trigger reactive UI update
  Future<void> cacheNodePayload({
    required String mac,
    required String pathType, // config, loads, states, sensors
    required dynamic payload,
  }) async {
    final box = Hive.isBoxOpen(nodeStatesBoxName)
        ? Hive.box(nodeStatesBoxName)
        : await Hive.openBox(nodeStatesBoxName);

    final key = '$mac/$pathType';
    await box.put(key, payload);

    // Notify listeners so UI re-renders with updated local cache
    _updateNotifier.add(null);
  }

  /// Save full nodes list into Hive cache
  Future<void> saveNodesList(List<Map<String, dynamic>> nodes) async {
    final box = Hive.isBoxOpen(CacheKeys.nodesBox)
        ? Hive.box(CacheKeys.nodesBox)
        : await Hive.openBox(CacheKeys.nodesBox);

    await box.put('nodes_list', nodes);
    _updateNotifier.add(null);
  }

  /// Read nodes list from Hive cache
  List<Map<String, dynamic>> getCachedNodes() {
    try {
      final box = Hive.box(CacheKeys.nodesBox);
      final cached = box.get('nodes_list');
      if (cached is List) {
        return cached.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  // ── Offline Queue Cache Handling ───────────────────────────────────────────

  /// Enqueue command payload to offline queue when connection is unavailable
  Future<void> enqueueOfflineCommand(Map<String, dynamic> commandData) async {
    final box = Hive.isBoxOpen(offlineQueueBoxName)
        ? Hive.box(offlineQueueBoxName)
        : await Hive.openBox(offlineQueueBoxName);

    final List list = box.get('queue', defaultValue: []);
    final updatedList = List<Map<String, dynamic>>.from(
      list.map((e) => Map<String, dynamic>.from(e as Map)),
    )..add(commandData);

    await box.put('queue', updatedList);
  }

  /// Get pending offline commands
  List<Map<String, dynamic>> getOfflineQueue() {
    try {
      final box = Hive.box(offlineQueueBoxName);
      final list = box.get('queue', defaultValue: []);
      if (list is List) {
        return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  /// Clear pending offline queue after successful replay
  Future<void> clearOfflineQueue() async {
    final box = Hive.isBoxOpen(offlineQueueBoxName)
        ? Hive.box(offlineQueueBoxName)
        : await Hive.openBox(offlineQueueBoxName);
    await box.delete('queue');
  }

  void dispose() {
    _updateNotifier.close();
  }
}
