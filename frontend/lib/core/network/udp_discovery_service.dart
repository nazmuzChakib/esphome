import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../security/node_security_service.dart';
import 'debug_log_service.dart';

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

      DebugLogger.log(
        source: 'UDP',
        direction: 'INBOUND',
        payload: rawStr,
        level: LogLevel.info,
      );

      // Handle encrypted or plain discovery responses
      // Encrypted frame: [Timestamp]:[Base64]
      // Plain frame: ESPHOME_DISCOVERY:[IP]:[MAC]:[UPTIME]
      String decryptedMsg = rawStr;
      if (rawStr.contains(':')) {
        final decrypted = _nodeSecurity.decryptEncryptedFrame(
          frame: rawStr,
          checkReplayWindow: false,
        );
        if (decrypted != null) {
          if (decrypted.containsKey('cmd') &&
              decrypted['cmd'] == 'ESPHOME_QUERY') {
            // Self-loopback query packet from local app socket broadcast. Ignore.
            return;
          }
          if (decrypted.containsKey('raw')) {
            decryptedMsg = decrypted['raw'].toString();
            if (decryptedMsg.contains('ESPHOME_QUERY')) {
              // Self-loopback query
              return;
            }
          }
        }
      }

      if (decryptedMsg.startsWith('ESPHOME_DISCOVERY:') ||
          decryptedMsg.startsWith('ESPHOME_REPLY:')) {
        final parts = decryptedMsg.split(':');
        if (parts.length >= 4) {
          final ip = parts[1].isNotEmpty ? parts[1] : senderIp;
          final mac = parts
              .sublist(2, parts.length - 1)
              .join(':')
              .toUpperCase();
          final uptime = int.tryParse(parts.last) ?? 0;

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

  /// Check if device is connected to a WiFi / LAN network
  Future<bool> _isWifiConnected() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        final isWifiInterface =
            name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('en') ||
            name.contains('eth');

        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.address != '0.0.0.0') {
            final ip = addr.address;
            final isPrivateIp =
                ip.startsWith('192.168.') ||
                ip.startsWith('10.') ||
                RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(ip);

            if (isWifiInterface || isPrivateIp) {
              return true;
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  /// Broadcast ESPHOME_QUERY encrypted search packet on port 4210
  Future<void> sendDiscoveryQuery() async {
    if (_socket == null) return;

    final wifiConnected = await _isWifiConnected();
    if (!wifiConnected) {
      DebugLogger.log(
        source: 'UDP',
        direction: 'INTERNAL',
        payload: 'UDP Discovery skipped: WiFi network not connected',
        level: LogLevel.warning,
      );
      return;
    }

    try {
      final queryFrame = _nodeSecurity.createEncryptedFrame(
        payload: {'cmd': 'ESPHOME_QUERY'},
        targetMac: '',
      );
      final bytes = utf8.encode(queryFrame);
      _socket?.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
      DebugLogger.log(
        source: 'UDP',
        direction: 'OUTBOUND',
        payload:
            'Broadcast discovery query: ESPHOME_QUERY (Port $discoveryPort)',
        level: LogLevel.info,
      );
    } catch (_) {}
  }

  Map<String, DiscoveredNode> get discoveredNodes => _discoveredNodes;

  void dispose() {
    _discoveryTimer?.cancel();
    _socket?.close();
    _onNodeDiscoveredController.close();
  }
}
