import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:open_app_file/open_app_file.dart';
import 'package:permission_handler/permission_handler.dart';

final updateProvider = StateNotifierProvider<UpdateNotifier, UpdateState>((
  ref,
) {
  return UpdateNotifier();
});

class UpdateState {
  final bool hasUpdate;
  final String latestVersion;
  final String? downloadUrl;
  final String? matchedAbi;
  final String? localApkPath;
  final bool isDownloading;
  final double downloadProgress;
  final String? error;
  final String? releaseNotes;
  final bool isChecking;

  UpdateState({
    required this.hasUpdate,
    required this.latestVersion,
    this.downloadUrl,
    this.matchedAbi,
    this.localApkPath,
    this.isDownloading = false,
    this.downloadProgress = 0.0,
    this.error,
    this.releaseNotes,
    this.isChecking = false,
  });

  UpdateState copyWith({
    bool? hasUpdate,
    String? latestVersion,
    String? downloadUrl,
    String? matchedAbi,
    String? localApkPath,
    bool? isDownloading,
    double? downloadProgress,
    String? error,
    String? releaseNotes,
    bool? isChecking,
  }) {
    return UpdateState(
      hasUpdate: hasUpdate ?? this.hasUpdate,
      latestVersion: latestVersion ?? this.latestVersion,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      matchedAbi: matchedAbi ?? this.matchedAbi,
      localApkPath: localApkPath ?? this.localApkPath,
      isDownloading: isDownloading ?? this.isDownloading,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      error: error ?? this.error,
      releaseNotes: releaseNotes ?? this.releaseNotes,
      isChecking: isChecking ?? this.isChecking,
    );
  }
}

class UpdateNotifier extends StateNotifier<UpdateState> {
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  static const int _notificationId = 999;

  UpdateNotifier()
    : super(
        UpdateState(
          hasUpdate: false,
          latestVersion: '1.0.0',
          releaseNotes: '',
          isChecking: false,
        ),
      ) {
    _initNotifications();
  }

  Future<void> _initNotifications() async {
    if (kIsWeb) return;
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await _notificationsPlugin.initialize(initializationSettings);

    try {
      final androidPlugin = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidPlugin != null) {
        await androidPlugin.requestNotificationsPermission();
      }
    } catch (_) {}
  }

  Future<void> checkForUpdates() async {
    if (kIsWeb) return; // Updates not applicable on web
    try {
      state = state.copyWith(error: null, isChecking: true);

      // Determine device ABI
      final deviceInfo = DeviceInfoPlugin();
      final androidInfo = await deviceInfo.androidInfo;
      final abis = androidInfo.supportedAbis;

      String targetAbi = 'arm64-v8a'; // default fallback
      if (abis.isNotEmpty) {
        targetAbi = abis.first;
      }

      // Query GitHub Releases
      final response = await http
          .get(
            Uri.parse(
              'https://api.github.com/repos/nazmuzChakib/esphome/releases/latest',
            ),
            headers: {
              'User-Agent': 'ESPHome-Client-App',
              'Accept': 'application/vnd.github.v3+json',
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String tagName = data['tag_name'] ?? '';
        final String cleanTag = tagName.startsWith('v')
            ? tagName.substring(1)
            : tagName;

        final packageInfo = await PackageInfo.fromPlatform();
        final currentVersion = packageInfo.version;

        if (_isNewerVersion(currentVersion, cleanTag)) {
          // Extract release notes description
          final String body = data['body'] ?? 'No release notes provided.';

          // Find matching ABI split APK asset
          String? downloadUrl;
          final assets = data['assets'] as List? ?? [];
          for (var asset in assets) {
            final name = (asset['name'] as String).toLowerCase();
            if (name.endsWith('.apk') &&
                name.contains(targetAbi.toLowerCase())) {
              downloadUrl = asset['browser_download_url'];
              break;
            }
          }

          // Fallback to general APK if ABI-specific not found
          if (downloadUrl == null) {
            for (var asset in assets) {
              final name = (asset['name'] as String).toLowerCase();
              if (name.endsWith('.apk')) {
                downloadUrl = asset['browser_download_url'];
                break;
              }
            }
          }

          if (downloadUrl != null) {
            // Check if already downloaded in local internal storage to prevent duplicate downloading
            final appDir = await getApplicationSupportDirectory();
            final localApkFile = File(
              '${appDir.path}/ESPHome_v${cleanTag}_$targetAbi.apk',
            );
            final alreadyDownloaded = await localApkFile.exists();

            state = UpdateState(
              hasUpdate: true,
              latestVersion: cleanTag,
              downloadUrl: downloadUrl,
              matchedAbi: targetAbi,
              localApkPath: alreadyDownloaded ? localApkFile.path : null,
              releaseNotes: body,
              isChecking: false,
            );

            // Trigger system notification about new update availability
            try {
              await _notificationsPlugin.show(
                100, // Unique notification ID for update alert
                'New Update Available',
                'Version v$cleanTag is available for download.',
                const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'app_updates',
                    'App Updates',
                    channelDescription: 'Notifications for new app releases',
                    importance: Importance.high,
                    priority: Priority.high,
                  ),
                ),
              );
            } catch (_) {}
          } else {
            state = state.copyWith(
              error: 'No compatible APK found in release assets.',
              isChecking: false,
            );
          }
        } else {
          state = UpdateState(
            hasUpdate: false,
            latestVersion: cleanTag,
            releaseNotes: '',
            isChecking: false,
          );
        }
      } else {
        state = state.copyWith(
          error: 'Failed to verify updates: HTTP ${response.statusCode}',
          isChecking: false,
        );
      }
    } catch (e) {
      state = state.copyWith(
        error: 'Failed to verify updates: ${e.toString()}',
        isChecking: false,
      );
    } finally {
      state = state.copyWith(isChecking: false);
    }
  }

  bool _isNewerVersion(String current, String latest) {
    try {
      final cParts = current
          .split('+')
          .first
          .split('.')
          .map(int.parse)
          .toList();
      final lParts = latest.split('+').first.split('.').map(int.parse).toList();
      for (int i = 0; i < 3; i++) {
        final cVal = i < cParts.length ? cParts[i] : 0;
        final lVal = i < lParts.length ? lParts[i] : 0;
        if (lVal > cVal) return true;
        if (lVal < cVal) return false;
      }
    } catch (_) {}
    return false;
  }

  Future<void> downloadAndInstallApk() async {
    final url = state.downloadUrl;
    final ver = state.latestVersion;
    final abi = state.matchedAbi;

    if (url == null || abi == null || kIsWeb) return;

    // Proactively request runtime permission on Android 13+
    if (Platform.isAndroid) {
      try {
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          await Permission.notification.request();
        }
      } catch (_) {}
    }

    // Check if cached first (to prevent downloading the same file again)
    final appDir = await getApplicationSupportDirectory();
    final localFile = File('${appDir.path}/ESPHome_v${ver}_$abi.apk');
    if (await localFile.exists()) {
      debugPrint('Update APK already downloaded: ${localFile.path}');
      state = state.copyWith(
        localApkPath: localFile.path,
        isDownloading: false,
      );
      _triggerApkInstall(localFile.path);
      return;
    }

    try {
      state = state.copyWith(isDownloading: true, downloadProgress: 0.0);

      // Create a temporary file to avoid partial/corrupted files being cached as complete
      final tempFile = File('${appDir.path}/ESPHome_v${ver}_$abi.apk.tmp');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      // Setup network request to download file
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      final int totalBytes =
          response.contentLength ?? 12 * 1024 * 1024; // default fallback 12MB
      int downloadedBytes = 0;
      final List<int> bytesList = [];

      int lastNotificationPct = -1;
      DateTime lastNotificationTime = DateTime.now();

      await for (var chunk in response.stream) {
        bytesList.addAll(chunk);
        downloadedBytes += chunk.length;

        final progress = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
        state = state.copyWith(downloadProgress: progress);

        final pct = (progress * 100).toInt();
        final now = DateTime.now();

        // Throttle updates to prevent lagging the system UI thread
        if (pct - lastNotificationPct >= 3 ||
            now.difference(lastNotificationTime).inMilliseconds >= 800 ||
            pct == 100) {
          lastNotificationPct = pct;
          lastNotificationTime = now;

          await _notificationsPlugin.show(
            _notificationId,
            'Downloading Update v$ver',
            '$pct% downloaded ($abi)',
            NotificationDetails(
              android: AndroidNotificationDetails(
                'ota_updates',
                'OTA Updates',
                channelDescription: 'OTA Updates progress channel',
                importance: Importance.low,
                priority: Priority.low,
                onlyAlertOnce: true,
                showProgress: true,
                maxProgress: 100,
                progress: pct,
                playSound: false,
                enableVibration: false,
              ),
            ),
          );
        }
      }

      // Write complete bytes to temp file first
      await tempFile.writeAsBytes(bytesList);
      client.close();

      // Rename temp file to final APK name once complete
      if (await localFile.exists()) {
        await localFile.delete();
      }
      await tempFile.rename(localFile.path);

      // Show complete notification
      await _notificationsPlugin.show(
        _notificationId,
        'Download Complete',
        'Update v$ver is ready to install.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'ota_updates',
            'OTA Updates',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );

      state = state.copyWith(
        isDownloading: false,
        localApkPath: localFile.path,
      );

      _triggerApkInstall(localFile.path);
    } catch (e) {
      state = state.copyWith(
        isDownloading: false,
        error: 'Download failed: ${e.toString()}',
      );
      await _notificationsPlugin.cancel(_notificationId);
    }
  }

  void _triggerApkInstall(String path) {
    debugPrint('Triggering android package installer for $path');
    try {
      OpenAppFile.open(path);
    } catch (e) {
      debugPrint('Failed to open APK installer: $e');
      state = state.copyWith(error: 'Failed to open package installer: $e');
    }
  }
}
