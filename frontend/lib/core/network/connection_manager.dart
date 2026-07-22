import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../cache/local_cache_service.dart';
import '../security/node_security_service.dart';
import 'debug_log_service.dart';

final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  final nodeSecurity = ref.watch(nodeSecurityServiceProvider);
  final localCache = ref.watch(localCacheServiceProvider);
  return ConnectionManager(nodeSecurity, localCache);
});

class ConnectionManager {
  final NodeSecurityService _nodeSecurity;
  final LocalCacheService _localCache;

  final Map<String, WebSocketChannel> _wsChannels = {};
  final Map<String, bool> _wsConnectedStatus = {};
  final Map<String, StreamSubscription?> _wsSubscriptions = {};

  ConnectionManager(this._nodeSecurity, this._localCache);

  /// Ensure WebSocket connection to a specific ESP32 node
  Future<bool> connectNodeWebSocket(
    String mac,
    String ip, {
    String? apiKey,
  }) async {
    if (ip.isEmpty) return false;
    if (_wsConnectedStatus[mac] == true && _wsChannels.containsKey(mac)) {
      return true;
    }

    try {
      DebugLogger.log(
        source: 'WS',
        direction: 'INTERNAL',
        payload: 'Connecting WebSocket to ws://$ip:80/ws',
        level: LogLevel.info,
        mac: mac,
      );

      final wsUrl = Uri.parse('ws://$ip:80/ws');
      final channel = WebSocketChannel.connect(wsUrl);

      _wsChannels[mac] = channel;
      _wsConnectedStatus[mac] = true;

      _wsSubscriptions[mac]?.cancel();
      _wsSubscriptions[mac] = channel.stream.listen(
        (data) {
          _handleIncomingFrame(mac: mac, rawData: data, apiKey: apiKey);
        },
        onError: (err) {
          DebugLogger.log(
            source: 'WS',
            direction: 'INTERNAL',
            payload: 'WebSocket error: $err',
            level: LogLevel.error,
            mac: mac,
          );
          _closeWsSession(mac);
        },
        onDone: () {
          DebugLogger.log(
            source: 'WS',
            direction: 'INTERNAL',
            payload: 'WebSocket closed/done',
            level: LogLevel.warning,
            mac: mac,
          );
          _closeWsSession(mac);
        },
      );

      // Send initial SYNC request frame to pull current states & configuration from node
      final syncFrame = _nodeSecurity.createEncryptedFrame(
        payload: {'path': 'sync', 'action': 'SYNC'},
        targetMac: mac,
        apiKey: apiKey,
      );
      channel.sink.add(syncFrame);
      DebugLogger.log(
        source: 'WS',
        direction: 'OUTBOUND',
        payload: syncFrame,
        level: LogLevel.info,
        mac: mac,
      );

      // On successful WS connection, replay any pending offline commands for this node
      _flushOfflineQueueForNode(mac);
      return true;
    } catch (e) {
      DebugLogger.log(
        source: 'WS',
        direction: 'INTERNAL',
        payload: 'Failed to connect WebSocket: $e',
        level: LogLevel.error,
        mac: mac,
      );
      _closeWsSession(mac);
      return false;
    }
  }

  void _closeWsSession(String mac) {
    _wsConnectedStatus[mac] = false;
    _wsSubscriptions[mac]?.cancel();
    _wsSubscriptions[mac] = null;
    try {
      _wsChannels[mac]?.sink.close();
    } catch (_) {}
    _wsChannels.remove(mac);
  }

  /// Parse, decrypt, cache to Local DB, and trigger UI update
  void _handleIncomingFrame({
    required String mac,
    required dynamic rawData,
    String? apiKey,
  }) {
    if (rawData is! String) return;

    DebugLogger.log(
      source: 'WS',
      direction: 'INBOUND',
      payload: rawData,
      level: LogLevel.success,
      mac: mac,
    );

    final decryptedPayload = _nodeSecurity.decryptEncryptedFrame(
      frame: rawData,
      apiKey: apiKey,
    );

    if (decryptedPayload != null) {
      // 1. Immediately cache to local Hive DB
      final pathType = decryptedPayload['path'] ?? 'states';
      _localCache.cacheNodePayload(
        mac: mac,
        pathType: pathType,
        payload: decryptedPayload,
      );
    }
  }

  /// Send Command: Try Primary WebSocket -> Secondary Local HTTP API -> Quaternary Offline Queue
  Future<bool> sendCommand({
    required String mac,
    required String ip,
    required Map<String, dynamic> payload,
    String? apiKey,
  }) async {
    final frame = _nodeSecurity.createEncryptedFrame(
      payload: payload,
      targetMac: mac,
      apiKey: apiKey,
    );

    // 1. Primary WebSocket Connection (Ensure connected first)
    if (ip.isNotEmpty) {
      if (_wsConnectedStatus[mac] != true || !_wsChannels.containsKey(mac)) {
        await connectNodeWebSocket(mac, ip, apiKey: apiKey);
        await Future.delayed(const Duration(milliseconds: 150));
      }

      if (_wsConnectedStatus[mac] == true && _wsChannels.containsKey(mac)) {
        try {
          _wsChannels[mac]!.sink.add(frame);
          DebugLogger.log(
            source: 'WS',
            direction: 'OUTBOUND',
            payload: frame,
            level: LogLevel.info,
            mac: mac,
          );
          return true;
        } catch (_) {
          _closeWsSession(mac);
        }
      }
    }

    // 2. Secondary Local HTTP API Fallback Connection
    if (ip.isNotEmpty) {
      final success = await _sendHttpFallback(ip: ip, frame: frame, mac: mac);
      if (success) return true;
    }

    // 3. Queue offline command to Hive DB if node is currently unreachable
    DebugLogger.log(
      source: 'System',
      direction: 'INTERNAL',
      payload: 'Node unreachable. Enqueuing command to offline Hive DB queue',
      level: LogLevel.warning,
      mac: mac,
    );

    await _localCache.enqueueOfflineCommand({
      'mac': mac,
      'ip': ip,
      'payload': payload,
      'apiKey': apiKey,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    return false;
  }

  Future<bool> _sendHttpFallback({
    required String ip,
    required String frame,
    String? mac,
  }) async {
    try {
      DebugLogger.log(
        source: 'HTTP',
        direction: 'OUTBOUND',
        payload: 'POST http://$ip:80/api/set-state\nPayload: $frame',
        level: LogLevel.warning,
        mac: mac,
      );

      final url = Uri.parse('http://$ip:80/api/set-state');
      final response = await http
          .post(url, headers: {'Content-Type': 'text/plain'}, body: frame)
          .timeout(const Duration(seconds: 3));

      DebugLogger.log(
        source: 'HTTP',
        direction: 'INBOUND',
        payload: 'Status ${response.statusCode}: ${response.body}',
        level: response.statusCode == 200 ? LogLevel.success : LogLevel.error,
        mac: mac,
      );

      return response.statusCode == 200;
    } catch (e) {
      DebugLogger.log(
        source: 'HTTP',
        direction: 'INTERNAL',
        payload: 'HTTP fallback failed: $e',
        level: LogLevel.error,
        mac: mac,
      );
      return false;
    }
  }

  Future<void> _flushOfflineQueueForNode(String mac) async {
    final queue = _localCache.getOfflineQueue();
    if (queue.isEmpty) return;

    final remaining = <Map<String, dynamic>>[];
    for (var cmd in queue) {
      if (cmd['mac'] == mac) {
        final ip = cmd['ip'] ?? '';
        final payload = Map<String, dynamic>.from(cmd['payload'] ?? {});
        final apiKey = cmd['apiKey'] as String?;

        final sent = await sendCommand(
          mac: mac,
          ip: ip,
          payload: payload,
          apiKey: apiKey,
        );
        if (!sent) {
          remaining.add(cmd);
        } else {
          // Add a 200ms pacing delay between queued command sends to protect ESP32 EventBus buffer from overflowing
          await Future.delayed(const Duration(milliseconds: 200));
        }
      } else {
        remaining.add(cmd);
      }
    }

    if (remaining.length != queue.length) {
      await _localCache.clearOfflineQueue();
      for (var r in remaining) {
        await _localCache.enqueueOfflineCommand(r);
      }
    }
  }

  bool isWsConnected(String mac) => _wsConnectedStatus[mac] == true;

  void dispose() {
    for (var mac in _wsChannels.keys.toList()) {
      _closeWsSession(mac);
    }
  }
}
