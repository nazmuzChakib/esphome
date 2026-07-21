import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../cache/local_cache_service.dart';
import '../security/node_security_service.dart';

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
  Future<bool> connectNodeWebSocket(String mac, String ip, {String? apiKey}) async {
    if (ip.isEmpty) return false;
    if (_wsConnectedStatus[mac] == true && _wsChannels.containsKey(mac)) {
      return true;
    }

    try {
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
          _closeWsSession(mac);
        },
        onDone: () {
          _closeWsSession(mac);
        },
      );

      // On successful WS connection, replay any pending offline commands for this node
      _flushOfflineQueueForNode(mac);
      return true;
    } catch (_) {
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
          return true;
        } catch (_) {
          _closeWsSession(mac);
        }
      }
    }

    // 2. Secondary Local HTTP API Fallback Connection
    if (ip.isNotEmpty) {
      final success = await _sendHttpFallback(ip: ip, frame: frame);
      if (success) return true;
    }

    // 3. Queue offline command to Hive DB if node is currently unreachable
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
  }) async {
    try {
      final url = Uri.parse('http://$ip:80/api/set-state');
      final response = await http
          .post(url, headers: {'Content-Type': 'text/plain'}, body: frame)
          .timeout(const Duration(seconds: 3));

      return response.statusCode == 200;
    } catch (_) {
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
