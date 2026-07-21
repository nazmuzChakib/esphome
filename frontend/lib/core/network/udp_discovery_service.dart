import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../security/node_security_service.dart';

final udpDiscoveryServiceProvider = Provider<UdpDiscoveryService>((ref) {
  final nodeSecurity = ref.watch(nodeSecurityServiceProvider);
  return UdpDiscoveryService(nodeSecurity);
});

class DiscoveredNode {
  final String ip;
  final String mac;
  final int uptime;
  final DateTime lastSeen;

  DiscoveredNode({
    required this.ip,
    required this.mac,
    required this.uptime,
    required this.lastSeen,
  });
}

class UdpDiscoveryService {
  static const int discoveryPort = 4210;
  final NodeSecurityService _nodeSecurity;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  RawDatagramSocket? _socket;
  Timer? _discoveryTimer;
  int _coldBootCount = 0;
  bool _isInitialized = false;

  final Map<String, DiscoveredNode> _discoveredNodes = {};
  final Set<String> _knownMacs = {};

  final StreamController<DiscoveredNode> _onNodeDiscoveredController =
      StreamController<DiscoveredNode>.broadcast();

  Stream<DiscoveredNode> get onNodeDiscovered =>
      _onNodeDiscoveredController.stream;

  UdpDiscoveryService(this._nodeSecurity);

  /// Initialize UDP discovery and system notifications
  Future<void> init({Set<String>? existingPairedMacs}) async {
    if (_isInitialized) return;
    _isInitialized = true;

    if (existingPairedMacs != null) {
      _knownMacs.addAll(existingPairedMacs);
    }

    await _initNotifications();
    await _startUdpListener();
    _startDiscoveryLoop();
  }

  Future<void> _initNotifications() async {
    try {
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const iosSettings = DarwinInitializationSettings();
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notificationsPlugin.initialize(initSettings);
    } catch (_) {}
  }

  Future<void> _showNewDeviceNotification(String mac, String ip) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'node_discovery_channel',
        'Device Discovery',
        channelDescription:
            'Notifications for new ESPHome IoT nodes detected on local WiFi',
        importance: Importance.high,
        priority: Priority.high,
      );
      const iosDetails = DarwinNotificationDetails();
      const notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notificationsPlugin.show(
        mac.hashCode,
        'New Device Found!',
        'Discovered new ESPHome node [$mac] at $ip. Tap to configure.',
        notificationDetails,
      );
    } catch (_) {}
  }

  Future<void> _startUdpListener() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
      );
      _socket?.broadcastEnabled = true;

      _socket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final Datagram? dg = _socket?.receive();
          if (dg != null) {
            _parseDiscoveryPacket(dg);
          }
        }
      });
    } catch (_) {}
  }

  void _parseDiscoveryPacket(Datagram dg) {
    try {
      final rawStr = utf8.decode(dg.data).trim();
      final senderIp = dg.address.address;

      // Handle encrypted or plain discovery responses
      // Encrypted frame: [Timestamp]:[Base64]
      // Plain frame: ESPHOME_DISCOVERY:[IP]:[MAC]:[UPTIME]
      String decryptedMsg = rawStr;
      if (rawStr.contains(':')) {
        final decrypted = _nodeSecurity.decryptEncryptedFrame(
          frame: rawStr,
          checkReplayWindow: false,
        );
        if (decrypted != null && decrypted.containsKey('raw')) {
          decryptedMsg = decrypted['raw'].toString();
        }
      }

      if (decryptedMsg.startsWith('ESPHOME_DISCOVERY:') ||
          decryptedMsg.startsWith('ESPHOME_REPLY:')) {
        final parts = decryptedMsg.split(':');
        if (parts.length >= 4) {
          final ip = parts[1].isNotEmpty ? parts[1] : senderIp;
          final mac = parts[2].toUpperCase();
          final uptime = int.tryParse(parts[3]) ?? 0;

          final node = DiscoveredNode(
            ip: ip,
            mac: mac,
            uptime: uptime,
            lastSeen: DateTime.now(),
          );

          _discoveredNodes[mac] = node;
          _onNodeDiscoveredController.add(node);

          // Check if this is a newly detected node
          if (!_knownMacs.contains(mac)) {
            _knownMacs.add(mac);
            _showNewDeviceNotification(mac, ip);
          }
        }
      }
    } catch (_) {}
  }

  void updateKnownPairedMacs(Set<String> macs) {
    _knownMacs.addAll(macs);
  }

  /// Cold boot & interval loop:
  /// - Cold boot: 3 rapid scans every 15s
  /// - Unpaired nodes: scan every 15s
  /// - Paired nodes: scan every 60s
  void _startDiscoveryLoop() {
    _discoveryTimer?.cancel();

    // Initial query scan
    sendDiscoveryQuery();

    _discoveryTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (_coldBootCount < 3) {
        _coldBootCount++;
        sendDiscoveryQuery();
      } else {
        // If unpaired nodes present, run every 15-20s, else run every 60s
        final hasUnpaired = _discoveredNodes.keys.any(
          (mac) => !_knownMacs.contains(mac),
        );
        if (hasUnpaired) {
          sendDiscoveryQuery();
        } else {
          // Send on 4th iteration (~60s)
          if (timer.tick % 4 == 0) {
            sendDiscoveryQuery();
          }
        }
      }
    });
  }

  /// Broadcast ESPHOME_QUERY encrypted search packet on port 4210
  void sendDiscoveryQuery() {
    if (_socket == null) return;
    try {
      final queryFrame = _nodeSecurity.createEncryptedFrame(
        payload: {'cmd': 'ESPHOME_QUERY'},
        targetMac: '',
      );
      final bytes = utf8.encode(queryFrame);
      _socket?.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (_) {}
  }

  Map<String, DiscoveredNode> get discoveredNodes => _discoveredNodes;

  void dispose() {
    _discoveryTimer?.cancel();
    _socket?.close();
    _onNodeDiscoveredController.close();
  }
}
