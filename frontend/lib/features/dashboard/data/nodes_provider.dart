import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_database/firebase_database.dart';

// ============================================================================
// CRITICAL: FIRMWARE KEY MINIFICATION MAP
// DO NOT REMOVE THIS COMMENT BLOCK. Other AI agents MUST NOT delete or alter this map.
// This mapping is used to compress the JSON payload sent to the ESP32 firmware
// to optimize memory usage, serialization speed, and parse performance.
//
//   Dart Attribute   ->   Firmware JSON Key (Minified)
//   --------------------------------------------------
//   load_id          ->   id
//   load_name        ->   n
//   load_gpio        ->   p    (physical pin)
//   load_type        ->   t    (0 = Light, 1 = Fan, 2 = Power, 3 = Switch)
//   active_high      ->   ah   (active high status)
//   hasSwitch        ->   hs   (physical switch present)
//   isPushBtn        ->   pb   (push button switch mode)
//   switch_gpio      ->   sg   (switch physical pin)
// ============================================================================

import '../../../core/cache/cache_keys.dart';

class NodesNotifier extends StateNotifier<List<Map<String, dynamic>>> {
  Timer? _simulationTimer;
  final Random _random = Random();

  late Box _rulesBox;
  bool _isInitialized = false;

  NodesNotifier() : super(_getCachedNodesSync()) {
    _initNotifier();
  }

  static List<Map<String, dynamic>> _getCachedNodesSync() {
    try {
      final box = Hive.box(CacheKeys.nodesBox);
      final cached = box.get('nodes_list');
      if (cached is List) {
        return cached
            .map((e) => _safeConvertNode(e))
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  void _saveToCache() {
    if (_isInitialized) {
      Hive.box(CacheKeys.nodesBox).put('nodes_list', state);
      try {
        FirebaseDatabase.instance.ref('nodes').set(state);
      } catch (_) {}
    }
  }

  // ── Deep Recursive Conversion Helpers ─────────────────────────────────────
  // Fixes: TypeError: Instance of 'LinkedMap<Object?, Object?>' is not a subtype
  // of type 'Map<String, dynamic>' when data comes from Firebase.

  static Map<String, dynamic> _deepConvertMap(Map<dynamic, dynamic> input) {
    return input.map((k, v) {
      final key = k.toString();
      if (v is Map) return MapEntry(key, _deepConvertMap(v));
      if (v is List) return MapEntry(key, _deepConvertList(v));
      return MapEntry(key, v);
    });
  }

  static List<dynamic> _deepConvertList(List<dynamic> input) {
    return input.map((e) {
      if (e is Map) return _deepConvertMap(e);
      if (e is List) return _deepConvertList(e);
      return e;
    }).toList();
  }

  static Map<String, dynamic> _safeConvertNode(dynamic item) {
    if (item is Map) return _deepConvertMap(item);
    return {};
  }

  // ── Initializer ─────────────────────────────────────────────────────────────

  Future<void> _initNotifier() async {
    _rulesBox = await Hive.openBox('rules');
    _isInitialized = true;
    _startSimulation();

    // Listen to local cache mutations to reactively update state and re-render UI
    Hive.box(CacheKeys.nodesBox).listenable().addListener(() {
      final updatedCached = _getCachedNodesSync();
      if (updatedCached.isNotEmpty) {
        state = updatedCached;
      }
    });

    // Parallel check internet and sync Firebase with a timeout
    _syncFirebaseNodes();
  }

  Future<bool> _checkInternetConnection() async {
    if (kIsWeb) return true;
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _syncFirebaseNodes() async {
    final hasInternet = await _checkInternetConnection();
    final nodesBox = Hive.box(CacheKeys.nodesBox);

    if (hasInternet) {
      try {
        final event = await FirebaseDatabase.instance
            .ref('nodes')
            .once()
            .timeout(const Duration(seconds: 8));

        if (event.snapshot.exists && event.snapshot.value != null) {
          final val = event.snapshot.value;
          final List<Map<String, dynamic>> parsedNodes = [];
          if (val is List) {
            for (var item in val) {
              if (item != null) {
                final converted = _safeConvertNode(item);
                if (converted.isNotEmpty) parsedNodes.add(converted);
              }
            }
          } else if (val is Map) {
            val.forEach((key, item) {
              if (item != null) {
                final converted = _safeConvertNode(item);
                if (converted.isNotEmpty) parsedNodes.add(converted);
              }
            });
          }

          if (parsedNodes.isNotEmpty) {
            // Direct cache update
            await nodesBox.put('nodes_list', parsedNodes);

            // UI renders from Cache
            final updatedCached = nodesBox.get('nodes_list');
            if (updatedCached is List) {
              final updatedList = updatedCached
                  .map((e) => _safeConvertNode(e))
                  .where((e) => e.isNotEmpty)
                  .toList();
              state = updatedList;
            }
          }
        }
      } catch (_) {}
    } else {
      // If offline and cache is empty, inject mock data directly
      if (state.isEmpty) {
        final List<Map<String, dynamic>> initialList = [];
        for (var node in _initialNodes) {
          initialList.add(_safeConvertNode(node));
        }
        state = initialList;
        await nodesBox.put('nodes_list', initialList);
      }
    }

    // Set up Firebase Realtime Database synchronization stream listener
    try {
      FirebaseDatabase.instance.ref('nodes').onValue.listen((event) async {
        if (event.snapshot.exists && event.snapshot.value != null) {
          final val = event.snapshot.value;
          final List<Map<String, dynamic>> parsedNodes = [];
          if (val is List) {
            for (var item in val) {
              if (item != null) {
                final converted = _safeConvertNode(item);
                if (converted.isNotEmpty) parsedNodes.add(converted);
              }
            }
          } else if (val is Map) {
            val.forEach((key, item) {
              if (item != null) {
                final converted = _safeConvertNode(item);
                if (converted.isNotEmpty) parsedNodes.add(converted);
              }
            });
          }

          if (parsedNodes.isNotEmpty) {
            // Direct cache update
            await nodesBox.put('nodes_list', parsedNodes);

            // UI renders from Cache
            final updatedCached = nodesBox.get('nodes_list');
            if (updatedCached is List) {
              final updatedList = updatedCached
                  .map((e) => _safeConvertNode(e))
                  .where((e) => e.isNotEmpty)
                  .toList();
              state = updatedList;
            }
          }
        }
      });
    } catch (_) {}

    // Check if both cache and firebase are empty to inject simulation nodes
    if (state.isEmpty && hasInternet) {
      Timer(const Duration(seconds: 4), () async {
        try {
          final snap = await FirebaseDatabase.instance
              .ref('nodes')
              .get()
              .timeout(const Duration(seconds: 5));
          if (!snap.exists || snap.value == null) {
            final List<Map<String, dynamic>> initialList = [];
            for (var node in _initialNodes) {
              initialList.add(_safeConvertNode(node));
            }
            state = initialList;
            await nodesBox.put('nodes_list', initialList);
            await FirebaseDatabase.instance.ref('nodes').set(initialList);
          }
        } catch (_) {}
      });
    }
  }

  static final List<Map<String, dynamic>> _initialNodes = [
    {
      'name': 'Living Room Gateway',
      'mac': 'AA:BB:CC:DD:01:02',
      'mac4': '0102',
      'ip': '192.168.1.50',
      'status': 'local',
      'temp': 24.5,
      'humi': 55.0,
      'tempHistory': [24.0, 24.2, 24.3, 24.4, 24.5],
      'sensors': ['temperature', 'humidity'],
      // sensorReadings: generic map for any sensor key — extended sensor support
      'sensorReadings': {'temperature': 24.5, 'humidity': 55.0},
      'loads': [
        {
          'load_id': '1001',
          'load_name': 'Reading Room Light',
          'load_gpio': 4,
          'load_type': 0, // Light
          'active_high': true,
          'hasSwitch': true,
          'isPushBtn': false,
          'switch_gpio': 2,
          'state': false,
          'override': false,
        },
        {
          'load_id': '1002',
          'load_name': 'Fan Relay',
          'load_gpio': 12,
          'load_type': 1, // Fan
          'active_high': true,
          'hasSwitch': true,
          'isPushBtn': false,
          'switch_gpio': 16,
          'state': false,
          'override': false,
        },
      ],
    },
    {
      'name': 'Kitchen Controller',
      'mac': 'AA:BB:CC:DD:03:04',
      'mac4': '0304',
      'ip': '192.168.1.51',
      'status': 'cloud',
      'temp': 28.2,
      'humi': 60.5,
      'tempHistory': [27.5, 27.8, 28.0, 28.1, 28.2],
      'sensors': ['temperature', 'humidity'],
      'sensorReadings': {'temperature': 28.2, 'humidity': 60.5},
      'loads': [
        {
          'load_id': '1003',
          'load_name': 'Kitchen Light',
          'load_gpio': 13,
          'load_type': 0, // Light
          'active_high': true,
          'hasSwitch': true,
          'isPushBtn': false,
          'switch_gpio': 15,
          'state': false,
          'override': false,
        },
        {
          'load_id': '1004',
          'load_name': 'Exhaust Fan',
          'load_gpio': 14,
          'load_type': 1, // Fan
          'active_high': true,
          'hasSwitch': false,
          'isPushBtn': false,
          'switch_gpio': -1,
          'state': false,
          'override': false,
        },
      ],
    },
    {
      'name': 'Bedroom Node',
      'mac': 'AA:BB:CC:DD:05:06',
      'mac4': '0506',
      'ip': '192.168.1.52',
      'status': 'offline',
      'temp': 22.0,
      'humi': 48.0,
      'tempHistory': [22.0],
      'sensors': [], // No sensors
      'sensorReadings': {},
      'loads': [
        {
          'load_id': '1005',
          'load_name': 'AC Switch',
          'load_gpio': 15,
          'load_type': 2, // Power/Socket
          'active_high': true,
          'hasSwitch': true,
          'isPushBtn': true,
          'switch_gpio': 12,
          'state': false,
          'override': false,
        },
      ],
    },
  ];

  void _startSimulation() {
    _simulationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _simulateSensorFluctuationAndRules();
    });
  }

  void _simulateSensorFluctuationAndRules() {
    if (!_isInitialized) return;

    final List<Map<String, dynamic>> rules = [];
    for (var key in _rulesBox.keys) {
      if (key != 'isFreshOpen') {
        final val = _rulesBox.get(key);
        if (val is Map) {
          rules.add(Map<String, dynamic>.from(val));
        }
      }
    }

    state = state.map((node) {
      final List<String> sensors = List<String>.from(node['sensors']);
      if (sensors.isEmpty) return node;

      final double tempDelta = (_random.nextDouble() - 0.5) * 0.8;
      final double humiDelta = (_random.nextDouble() - 0.5) * 1.5;

      final double newTemp = double.parse(
        (node['temp'] + tempDelta).toStringAsFixed(1),
      );
      final double newHumi = double.parse(
        (node['humi'] + humiDelta).toStringAsFixed(1),
      );

      final List<double> history =
          (node['tempHistory'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          <double>[];
      history.add(newTemp);
      if (history.length > 10) {
        history.removeAt(0);
      }

      final List<Map<String, dynamic>> updatedLoads =
          List<Map<String, dynamic>>.from(
            (node['loads'] as List).map((l) => Map<String, dynamic>.from(l)),
          );

      for (var rule in rules) {
        if (rule['nodeMac'] == node['mac'] ||
            rule['nodeName'] == node['name']) {
          final String logicalOp =
              rule['op'] ?? rule['logical_operator'] ?? 'AND';
          final List conditions = rule['conds'] ?? rule['conditions'] ?? [];
          final String? targetLoadId =
              rule['act']?.toString() ?? rule['action_target']?.toString();
          final String? targetLoadName =
              rule['loads'] != null && (rule['loads'] as List).isNotEmpty
              ? rule['loads'][0]
              : null;
          final bool actionVal =
              rule['val'] ??
              (rule['action_value'] == 1 || rule['action_value'] == true);

          bool ruleResult = false;

          if (conditions.isEmpty) {
            // Fallback evaluation for simple old rule format
            final String sensorType = rule['sensor'] ?? 'Temperature';
            final double sensorVal =
                (sensorType == 'Temperature' || sensorType == 'temp')
                ? newTemp
                : newHumi;
            final double threshold = (rule['threshold'] ?? 30.0).toDouble();
            final double hysteresis = (rule['hysteresis'] ?? 1.0).toDouble();
            final String operator = rule['operator'] ?? 'ABOVE';

            if (operator == 'ABOVE') {
              if (sensorVal > (threshold + hysteresis)) {
                ruleResult = true;
              } else if (sensorVal < (threshold - hysteresis)) {
                ruleResult = false;
              } else {
                continue; // Do nothing inside hysteresis deadband
              }
            } else {
              if (sensorVal < (threshold - hysteresis)) {
                ruleResult = true;
              } else if (sensorVal > (threshold + hysteresis)) {
                ruleResult = false;
              } else {
                continue;
              }
            }
          } else {
            // Evaluate multi-condition list
            final List<bool> condResults = [];
            final now = DateTime.now();
            final currentHour = now.hour;
            final currentMinute = now.minute;

            for (var cond in conditions) {
              final String type = cond['t'] ?? cond['type'] ?? 'sensor';
              if (type == 'sensor') {
                final String src = cond['src'] ?? cond['source'] ?? 'temp';
                final double sensorVal = (src == 'temp' || src == 'temperature')
                    ? newTemp
                    : newHumi;
                final double threshold =
                    (cond['th'] ?? cond['threshold'] ?? 30.0).toDouble();
                final double hysteresis =
                    (cond['hy'] ?? cond['hysteresis'] ?? 1.0).toDouble();
                final String op = cond['op'] ?? cond['operator'] ?? '>';

                final targetLoad = updatedLoads.firstWhere(
                  (l) =>
                      (targetLoadId != null && l['load_id'] == targetLoadId) ||
                      (targetLoadName != null &&
                          (l['load_name'] == targetLoadName ||
                              l['name'] == targetLoadName)),
                  orElse: () => <String, dynamic>{},
                );
                final bool currentLoadState = targetLoad['state'] == true;

                bool condResult = false;
                if (op == '>' || op == 'ABOVE') {
                  if (currentLoadState == actionVal) {
                    condResult = sensorVal > (threshold - hysteresis);
                  } else {
                    condResult = sensorVal > (threshold + hysteresis);
                  }
                } else if (op == '<' || op == 'UNDER' || op == 'BELOW') {
                  if (currentLoadState == actionVal) {
                    condResult = sensorVal < (threshold + hysteresis);
                  } else {
                    condResult = sensorVal < (threshold - hysteresis);
                  }
                } else {
                  condResult = false;
                }
                condResults.add(condResult);
              } else if (type == 'time') {
                final String op = cond['op'] ?? cond['operator'] ?? 'after';
                final String timeValStr = cond['v'] ?? cond['value'] ?? '00:00';
                final List<String> timeParts = timeValStr.split(':');
                final int condHour = int.tryParse(timeParts[0]) ?? 0;
                final int condMin = int.tryParse(timeParts[1]) ?? 0;

                final int currentMinutesSinceMidnight =
                    currentHour * 60 + currentMinute;
                final int condMinutesSinceMidnight = condHour * 60 + condMin;

                if (op == 'after') {
                  condResults.add(
                    currentMinutesSinceMidnight >= condMinutesSinceMidnight,
                  );
                } else if (op == 'before') {
                  condResults.add(
                    currentMinutesSinceMidnight <= condMinutesSinceMidnight,
                  );
                } else if (op == 'between') {
                  final String endTimeValStr =
                      cond['ev'] ?? cond['end_value'] ?? '23:59';
                  final List<String> endTimeParts = endTimeValStr.split(':');
                  final int endCondHour = int.tryParse(endTimeParts[0]) ?? 23;
                  final int endCondMin = int.tryParse(endTimeParts[1]) ?? 59;
                  final int endCondMinutesSinceMidnight =
                      endCondHour * 60 + endCondMin;

                  if (condMinutesSinceMidnight <= endCondMinutesSinceMidnight) {
                    condResults.add(
                      currentMinutesSinceMidnight >= condMinutesSinceMidnight &&
                          currentMinutesSinceMidnight <=
                              endCondMinutesSinceMidnight,
                    );
                  } else {
                    // Over midnight span
                    condResults.add(
                      currentMinutesSinceMidnight >= condMinutesSinceMidnight ||
                          currentMinutesSinceMidnight <=
                              endCondMinutesSinceMidnight,
                    );
                  }
                } else {
                  condResults.add(false);
                }
              }
            }

            if (logicalOp == 'AND') {
              ruleResult =
                  condResults.isNotEmpty && condResults.every((r) => r);
            } else {
              // OR
              ruleResult = condResults.isNotEmpty && condResults.any((r) => r);
            }
          }

          // Apply state update to matching loads
          for (var load in updatedLoads) {
            final String lId = load['load_id']?.toString() ?? '';
            final String lName =
                load['load_name']?.toString() ?? load['name']?.toString() ?? '';

            if ((targetLoadId != null && lId == targetLoadId) ||
                (targetLoadName != null && lName == targetLoadName)) {
              final bool isOverridden = load['override'] == true;
              final bool targetState = ruleResult ? actionVal : !actionVal;

              if (isOverridden) {
                if (load['state'] == targetState) {
                  load['override'] = false;
                }
              } else {
                load['state'] = targetState;
              }
            }
          }
        }
      }

      // Update sensorReadings map for extended sensor support
      final Map<String, dynamic> existingReadings =
          (node['sensorReadings'] is Map)
          ? Map<String, dynamic>.from(node['sensorReadings'] as Map)
          : {};
      if (sensors.contains('temperature')) {
        existingReadings['temperature'] = newTemp;
      }
      if (sensors.contains('humidity')) {
        existingReadings['humidity'] = newHumi;
      }

      return {
        ...node,
        'temp': newTemp,
        'humi': newHumi,
        'tempHistory': history,
        'loads': updatedLoads,
        'sensorReadings': existingReadings,
      };
    }).toList();
    _saveToCache();
  }

  // ── Dynamic Rule Management ─────────────────────────────────────────────────
  // Rules are stored in Hive 'rules' box AND synced to Firebase for firmware.

  Future<void> addFirebaseRule(String mac, Map<String, dynamic> rule) async {
    try {
      final node = state.firstWhere((n) => n['mac'] == mac);
      final nodeRef = FirebaseDatabase.instance.ref(
        'nodes/${node['mac4'] ?? mac}/rules/${rule['id']}',
      );
      await nodeRef.set(rule);
    } catch (_) {}
  }

  Future<void> deleteFirebaseRule(String mac, String ruleId) async {
    try {
      final node = state.firstWhere((n) => n['mac'] == mac);
      await FirebaseDatabase.instance
          .ref('nodes/${node['mac4'] ?? mac}/rules/$ruleId')
          .remove();
    } catch (_) {}
  }

  void toggleLoadState(String mac, String loadId) {
    state = state.map((node) {
      if (node['mac'] != mac) return node;

      final List<Map<String, dynamic>> updatedLoads = (node['loads'] as List)
          .map((load) {
            final Map<String, dynamic> loadMap = Map<String, dynamic>.from(
              load,
            );
            if (loadMap['load_id'] == loadId) {
              loadMap['state'] = !loadMap['state'];
              loadMap['override'] = true;
            }
            return loadMap;
          })
          .toList();

      return {...node, 'loads': updatedLoads};
    }).toList();
    _saveToCache();
  }

  bool addLoad({
    required String mac,
    required String loadName,
    required int gpio,
    required int type,
    required bool activeHigh,
    required bool hasSwitch,
    required bool isPushBtn,
    int? switchGpio,
  }) {
    final targetNode = state.firstWhere((n) => n['mac'] == mac);
    final List loads = targetNode['loads'] as List;

    // Validation: Check duplicate names
    for (var load in loads) {
      final nameVal =
          load['load_name']?.toString().toLowerCase() ??
          load['name']?.toString().toLowerCase();
      if (nameVal == loadName.toLowerCase()) return false;
      if (load['load_gpio'] == gpio || load['switch_gpio'] == gpio) {
        return false;
      }
      if (hasSwitch && switchGpio != null) {
        if (load['load_gpio'] == switchGpio ||
            load['switch_gpio'] == switchGpio) {
          return false;
        }
      }
    }

    // Generate unique 4-8 digit load_id
    String newId;
    do {
      newId = (1000 + _random.nextInt(99999000)).toString().substring(0, 6);
    } while (loads.any((l) => l['load_id'] == newId));

    state = state.map((node) {
      if (node['mac'] != mac) return node;

      final List<Map<String, dynamic>> updatedLoads =
          List<Map<String, dynamic>>.from(node['loads'] as List)..add({
            'load_id': newId,
            'load_name': loadName,
            'load_gpio': gpio,
            'load_type': type,
            'active_high': activeHigh,
            'hasSwitch': hasSwitch,
            'isPushBtn': isPushBtn,
            'switch_gpio': hasSwitch ? (switchGpio ?? -1) : -1,
            'state': false,
            'override': false,
          });

      return {...node, 'loads': updatedLoads};
    }).toList();
    return true;
  }

  bool editLoad({
    required String mac,
    required String loadId,
    required String newLoadName,
    required int newLoadType,
  }) {
    final targetNode = state.firstWhere((n) => n['mac'] == mac);
    final List loads = targetNode['loads'] as List;

    for (var load in loads) {
      if (load['load_id'] != loadId) {
        final nameVal =
            load['load_name']?.toString().toLowerCase() ??
            load['name']?.toString().toLowerCase();
        if (nameVal == newLoadName.toLowerCase()) return false;
      }
    }

    state = state.map((node) {
      if (node['mac'] != mac) return node;

      final List<Map<String, dynamic>> updatedLoads = (node['loads'] as List)
          .map((load) {
            final Map<String, dynamic> loadMap = Map<String, dynamic>.from(
              load,
            );
            if (loadMap['load_id'] == loadId) {
              loadMap['load_name'] = newLoadName;
              loadMap['load_type'] = newLoadType;
            }
            return loadMap;
          })
          .toList();

      return {...node, 'loads': updatedLoads};
    }).toList();
    return true;
  }

  Map<String, dynamic> deleteLoad(String mac, String loadId) {
    final targetNode = state.firstWhere((n) => n['mac'] == mac);
    final List loads = targetNode['loads'] as List;
    final load = loads.firstWhere(
      (l) => l['load_id'] == loadId,
      orElse: () => null,
    );

    if (load == null) {
      return {'success': false, 'error': 'Load not found'};
    }

    // Safety check: Block if load is ON
    if (load['state'] == true) {
      return {
        'success': false,
        'error':
            'Cannot delete load because it is currently ON. Please turn it OFF first.',
      };
    }

    // Clean up rules matching this load
    final loadName =
        load['load_name']?.toString() ?? load['name']?.toString() ?? '';
    _cleanupRulesForLoad(targetNode['name'], loadId, loadName);

    state = state.map((node) {
      if (node['mac'] != mac) return node;

      final List<Map<String, dynamic>> updatedLoads =
          List<Map<String, dynamic>>.from(node['loads'] as List)
            ..removeWhere((l) => l['load_id'] == loadId);

      return {...node, 'loads': updatedLoads};
    }).toList();

    return {'success': true, 'error': null};
  }

  void _cleanupRulesForLoad(
    String nodeName,
    String loadId,
    String loadName,
  ) async {
    final rulesBox = await Hive.openBox('rules');
    final bulkBox = await Hive.openBox('bulk_rules');

    final keysToDelete = [];
    for (var key in rulesBox.keys) {
      if (key != 'isFreshOpen') {
        final val = rulesBox.get(key);
        if (val is Map) {
          final rule = Map<String, dynamic>.from(val);
          final List ruleLoads = rule['loads'] ?? [];
          final String? ruleAct =
              rule['act']?.toString() ?? rule['action_target']?.toString();

          if (rule['nodeName'] == nodeName) {
            // Check if rule targets ONLY this load
            if ((ruleLoads.length == 1 &&
                    (ruleLoads.contains(loadId) ||
                        ruleLoads.contains(loadName))) ||
                (ruleAct == loadId)) {
              keysToDelete.add(key);
            } else if (ruleLoads.contains(loadId) ||
                ruleLoads.contains(loadName)) {
              final updatedLoads = List<String>.from(ruleLoads)
                ..remove(loadId)
                ..remove(loadName);
              rule['loads'] = updatedLoads;
              await rulesBox.put(key, rule);
            }
          }
        }
      }
    }
    for (var key in keysToDelete) {
      await rulesBox.delete(key);
    }

    // Reset/redeploy child rules inside bulk_rules
    for (var key in bulkBox.keys) {
      final val = bulkBox.get(key);
      if (val is Map) {
        final bulkRule = Map<String, dynamic>.from(val);
        final childRuleIds = List<String>.from(bulkRule['childRuleIds'] ?? []);
        for (var childId in childRuleIds) {
          final childVal = rulesBox.get(childId);
          if (childVal is Map) {
            final childRule = Map<String, dynamic>.from(childVal);
            if (childRule['nodeName'] == nodeName) {
              final List ruleLoads = childRule['loads'] ?? [];
              if (ruleLoads.contains(loadId) || ruleLoads.contains(loadName)) {
                final updatedLoads = List<String>.from(ruleLoads)
                  ..remove(loadId)
                  ..remove(loadName);
                if (updatedLoads.isEmpty) {
                  await rulesBox.delete(childId);
                } else {
                  childRule['loads'] = updatedLoads;
                  await rulesBox.put(childId, childRule);
                }
              }
            }
          }
        }
      }
    }
  }

  Map<String, dynamic> getMinifiedPayload(String mac) {
    final node = state.firstWhere((n) => n['mac'] == mac);
    final List loads = node['loads'] as List;
    final List<Map<String, dynamic>> minifiedLoads = loads.map((l) {
      return {
        'id': l['load_id']?.toString() ?? '',
        'n': l['load_name']?.toString() ?? l['name']?.toString() ?? '',
        'p': l['load_gpio'] is int
            ? l['load_gpio']
            : int.tryParse(l['load_gpio']?.toString() ?? '0') ?? 0,
        't': l['load_type'] is int
            ? l['load_type']
            : int.tryParse(l['load_type']?.toString() ?? '0') ?? 0,
        'ah': l['active_high'] == true,
        'hs': l['hasSwitch'] == true,
        'pb': l['isPushBtn'] == true,
        'sg': l['switch_gpio'] is int
            ? l['switch_gpio']
            : int.tryParse(l['switch_gpio']?.toString() ?? '-1') ?? -1,
      };
    }).toList();

    return {
      'mac': node['mac'],
      'mac4': node['mac4'],
      'ip': node['ip'],
      'loads': minifiedLoads,
    };
  }

  @override
  void dispose() {
    _simulationTimer?.cancel();
    super.dispose();
  }
}

final nodesProvider =
    StateNotifierProvider<NodesNotifier, List<Map<String, dynamic>>>((ref) {
      return NodesNotifier();
    });
