import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:io' show Platform;

/// A helper class providing stable, human-readable device information.
///
/// Device ID is deterministic per physical device and does NOT change across
/// logins/reinstalls. It is based on hardware-level identifiers.
///
/// Device Name is a human-friendly label (e.g. "Samsung Galaxy S24").
/// Admins will see this name instead of raw hashes in the Access Control UI.
class DeviceInfoHelper {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  /// Returns a stable, hardware-bound device ID string.
  /// This ID will NOT change across logins or reinstalls on the same device.
  /// Falls back to a hash of the device name if no hardware ID is available.
  static Future<String> getStableDeviceId() async {
    try {
      if (kIsWeb) {
        final box = await Hive.openBox('web_device');
        String? id = box.get('device_id');
        if (id == null) {
          id = 'web_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';
          await box.put('device_id', id);
        }
        return id;
      }
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        // androidInfo.id is the ANDROID_ID which persists until factory reset.
        // It's stable per device + signing key combination.
        return 'android_${info.id}';
      } else if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        // identifierForVendor is stable for same vendor within a device.
        return 'ios_${info.identifierForVendor ?? _hashString(info.name)}';
      } else if (Platform.isMacOS) {
        final info = await _deviceInfo.macOsInfo;
        return 'macos_${info.systemGUID ?? _hashString(info.computerName)}';
      } else if (Platform.isWindows) {
        final info = await _deviceInfo.windowsInfo;
        return 'win_${info.deviceId}';
      } else if (Platform.isLinux) {
        final info = await _deviceInfo.linuxInfo;
        return 'linux_${info.machineId ?? _hashString(info.name)}';
      }
    } catch (_) {}
    return 'unknown_device';
  }

  /// Returns a human-readable display name for this device.
  /// Shown in Admin's "Users & Devices" panel instead of raw hashes.
  static Future<String> getDeviceDisplayName() async {
    try {
      if (kIsWeb) {
        final info = await _deviceInfo.webBrowserInfo;
        final browser = info.browserName.name;
        final rawPlatform = info.platform ?? '';
        String os = 'Web';
        if (rawPlatform.contains('Win')) {
          os = 'Windows';
        } else if (rawPlatform.contains('Mac') || rawPlatform.contains('iPhone') || rawPlatform.contains('iPad')) {
          os = 'macOS';
        } else if (rawPlatform.contains('Linux')) {
          os = 'Linux';
        }
        return "${browser.capitalize()}, $os";
      }
      if (Platform.isAndroid) {
        final info = await _deviceInfo.androidInfo;
        return '${info.brand.capitalize()} ${info.model}';
      } else if (Platform.isIOS) {
        final info = await _deviceInfo.iosInfo;
        return info.name.isNotEmpty ? info.name : 'iOS Device';
      } else if (Platform.isMacOS) {
        final info = await _deviceInfo.macOsInfo;
        return info.computerName.isNotEmpty ? info.computerName : 'Mac Device';
      } else if (Platform.isWindows) {
        final info = await _deviceInfo.windowsInfo;
        return info.computerName.isNotEmpty
            ? 'Windows PC (${info.computerName})'
            : 'Windows PC';
      } else if (Platform.isLinux) {
        final info = await _deviceInfo.linuxInfo;
        return info.prettyName.isNotEmpty ? info.prettyName : 'Linux Device';
      }
    } catch (_) {}
    return 'Unknown Device';
  }

  /// SHA-256 based short hash for fallback identifiers.
  static String _hashString(String input) {
    return sha256
        .convert(utf8.encode(input))
        .toString()
        .substring(0, 16);
  }
}

extension on String {
  String capitalize() {
    if (isEmpty) return this;
    return '${this[0].toUpperCase()}${substring(1).toLowerCase()}';
  }
}
