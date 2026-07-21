import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../core/security/firebase_encryption_service.dart';
import '../../../core/utils/device_info_helper.dart';
import '../../../core/utils/email_helper.dart';
import '../../../core/cache/cache_keys.dart';
import '../../auth/data/auth_provider.dart';

enum NodePermissionStatus { approved, pending, unapproved }

class PendingAccessRequest {
  final String nodeMac;
  final String requestedByUid;
  final String requestedByEmail;
  final int timestamp;

  PendingAccessRequest({
    required this.nodeMac,
    required this.requestedByUid,
    required this.requestedByEmail,
    required this.timestamp,
  });
}

final nodePermissionServiceProvider = Provider<NodePermissionService>((ref) {
  final encryptionService = ref.watch(firebaseEncryptionServiceProvider);
  return NodePermissionService(encryptionService);
});

class NodePermissionService {
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseEncryptionService _encryptionService;

  NodePermissionService(this._encryptionService);

  String _hashEmail(String email) {
    return EmailHelper.hashEmail(email);
  }

  String _hashMac(String mac) {
    return sha256.convert(utf8.encode(mac)).toString();
  }

  Future<String> _getDeviceId() => DeviceInfoHelper.getStableDeviceId();

  Future<NodePermissionStatus> checkNodeAccess(String nodeMac) async {
    final user = _auth.currentUser;
    if (user == null || user.email == null) {
      return NodePermissionStatus.unapproved;
    }

    final email = user.email!;
    final emailHash = _hashEmail(email);
    final macHash = _hashMac(nodeMac);
    final deviceId = await _getDeviceId();

    // ── Load from Cache First (Parallel/Instant) ──
    final permissionsBox = await Hive.openBox(CacheKeys.permissionsBox);

    // ── Admin Role Instant Bypass (Local Hive check) ──
    try {
      if (Hive.isBoxOpen(CacheKeys.userProfileBox)) {
        final profileBox = Hive.box(CacheKeys.userProfileBox);
        final cachedRole = profileBox.get(CacheKeys.roleKey) as String?;
        if (cachedRole == 'admin') {
          await permissionsBox.put(
            'permission_$nodeMac',
            NodePermissionStatus.approved.name,
          );
          return NodePermissionStatus.approved;
        }
      }
    } catch (_) {}

    final cachedStatusStr =
        permissionsBox.get('permission_$nodeMac') as String?;
    final NodePermissionStatus? cachedStatus = cachedStatusStr != null
        ? NodePermissionStatus.values.firstWhere(
            (e) => e.name == cachedStatusStr,
            orElse: () => NodePermissionStatus.unapproved,
          )
        : null;

    // Check internet connection in parallel
    final hasInternet = await _checkInternetConnection();
    if (!hasInternet) {
      return cachedStatus ?? NodePermissionStatus.unapproved;
    }

    try {
      // 1. Verify admin bypass
      final adminSnap = await _db
          .ref('admins/$emailHash')
          .get()
          .timeout(const Duration(seconds: 4));
      if (adminSnap.exists) {
        await permissionsBox.put(
          'permission_$nodeMac',
          NodePermissionStatus.approved.name,
        );
        return NodePermissionStatus.approved;
      }

      // Slow path: decrypt role
      final roleSnap = await _db
          .ref('users/$emailHash/role')
          .get()
          .timeout(const Duration(seconds: 4));
      if (roleSnap.exists && roleSnap.value is String) {
        final role = _encryptionService.decryptField(roleSnap.value as String);
        if (role == 'admin') {
          await _db.ref('admins/$emailHash').set({
            'role': 'admin',
            'grantedAt': DateTime.now().millisecondsSinceEpoch,
          });
          await permissionsBox.put(
            'permission_$nodeMac',
            NodePermissionStatus.approved.name,
          );
          return NodePermissionStatus.approved;
        }
      }

      // 2. Check approved devices
      final deviceRef = _db.ref('users/$emailHash/devices/$deviceId');
      final deviceSnap = await deviceRef.get().timeout(
        const Duration(seconds: 4),
      );
      if (!deviceSnap.exists) {
        await permissionsBox.put(
          'permission_$nodeMac',
          NodePermissionStatus.unapproved.name,
        );
        return NodePermissionStatus.unapproved;
      } else {
        final val = deviceSnap.value;
        String status = 'unapproved';
        if (val is Map && val['status'] != null) {
          status = _encryptionService.decryptField(val['status'] as String);
        } else if (val is String) {
          status = _encryptionService.decryptField(val);
        }
        if (status != 'approved') {
          await permissionsBox.put(
            'permission_$nodeMac',
            NodePermissionStatus.unapproved.name,
          );
          return NodePermissionStatus.unapproved;
        }
      }

      // 3. Check approved nodes
      final approvedRef = _db.ref('approved_nodes/$emailHash/nodes/$macHash');
      final approvedSnapshot = await approvedRef.get().timeout(
        const Duration(seconds: 4),
      );
      if (approvedSnapshot.exists) {
        await permissionsBox.put(
          'permission_$nodeMac',
          NodePermissionStatus.approved.name,
        );
        return NodePermissionStatus.approved;
      }

      // 4. Check pending requests
      final pendingRef = _db.ref('pending_requests/$macHash/$emailHash');
      final pendingSnapshot = await pendingRef.get().timeout(
        const Duration(seconds: 4),
      );
      if (pendingSnapshot.exists) {
        await permissionsBox.put(
          'permission_$nodeMac',
          NodePermissionStatus.pending.name,
        );
        return NodePermissionStatus.pending;
      }
    } catch (_) {
      // On timeout/error, return cached status if available
      if (cachedStatus != null) return cachedStatus;
    }

    await permissionsBox.put(
      'permission_$nodeMac',
      NodePermissionStatus.unapproved.name,
    );
    return NodePermissionStatus.unapproved;
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

  Future<void> requestNodeAccess(String nodeMac, String userEmail) async {
    final user = _auth.currentUser;
    if (user == null) return;

    final emailHash = _hashEmail(userEmail);
    final macHash = _hashMac(nodeMac);
    final deviceId = await _getDeviceId();

    final pendingRef = _db.ref('pending_requests/$macHash/$emailHash');

    final encryptedEmail = _encryptionService.encryptField(userEmail);
    final encryptedUid = _encryptionService.encryptField(user.uid);
    final encryptedNodeMac = _encryptionService.encryptField(nodeMac);
    final encryptedDeviceId = _encryptionService.encryptField(deviceId);

    await pendingRef.set({
      'node_id': encryptedNodeMac,
      'requested_by_uid': encryptedUid,
      'requested_by_email': encryptedEmail,
      'device_id': encryptedDeviceId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<PendingAccessRequest>> getPendingRequests() async {
    final List<PendingAccessRequest> requests = [];
    try {
      final snapshot = await _db.ref('pending_requests').get();
      if (snapshot.exists && snapshot.value is Map) {
        final data = snapshot.value as Map;
        data.forEach((macHashKey, userMapVal) {
          if (userMapVal is Map) {
            userMapVal.forEach((emailHashKey, val) {
              if (val is Map) {
                final encryptedNodeMac = val['node_id'] as String? ?? '';
                final encryptedEmail =
                    val['requested_by_email'] as String? ?? '';
                final encryptedUid = val['requested_by_uid'] as String? ?? '';
                final timestamp = val['timestamp'] as int? ?? 0;

                final decryptedEmail = _encryptionService.decryptField(
                  encryptedEmail,
                );
                final decryptedUid = _encryptionService.decryptField(
                  encryptedUid,
                );
                final decryptedNodeMac = _encryptionService.decryptField(
                  encryptedNodeMac,
                );

                requests.add(
                  PendingAccessRequest(
                    nodeMac: decryptedNodeMac,
                    requestedByUid: decryptedUid,
                    requestedByEmail: decryptedEmail,
                    timestamp: timestamp,
                  ),
                );
              }
            });
          }
        });
      }
    } catch (_) {}
    return requests;
  }

  Future<void> approveRequest(String nodeMac, String requesterEmail) async {
    final emailHash = _hashEmail(requesterEmail);
    final macHash = _hashMac(nodeMac);

    final approvedRef = _db.ref('approved_nodes/$emailHash/nodes/$macHash');
    final pendingRef = _db.ref('pending_requests/$macHash/$emailHash');

    final encryptedNodeMac = _encryptionService.encryptField(nodeMac);

    // Save under approved_nodes/$emailHash/nodes/$macHash
    await approvedRef.set(encryptedNodeMac);

    // Remove from pending_requests/$macHash/$emailHash
    await pendingRef.remove();
  }

  /// Watches node access status in real-time using Firebase streams.
  /// Emits a new status whenever the approved_nodes or pending_requests changes.
  /// Does NOT call .get() inside the stream to avoid blocking the realtime channel.
  Stream<NodePermissionStatus> watchNodeAccess(String nodeMac) async* {
    final user = _auth.currentUser;
    if (user == null || user.email == null) {
      yield NodePermissionStatus.unapproved;
      return;
    }
    final email = user.email!;
    final emailHash = _hashEmail(email);
    final macHash = _hashMac(nodeMac);

    // Fast admin check first (one-time)
    try {
      final adminSnap = await _db.ref('admins/$emailHash').get();
      if (adminSnap.exists) {
        yield NodePermissionStatus.approved;
        return;
      }
    } catch (_) {}

    // Listen to approved_nodes path in realtime
    await for (final event
        in _db.ref('approved_nodes/$emailHash/nodes/$macHash').onValue) {
      if (event.snapshot.exists) {
        yield NodePermissionStatus.approved;
      } else {
        // Not approved - check pending
        try {
          final pendingSnap = await _db
              .ref('pending_requests/$macHash/$emailHash')
              .get();
          if (pendingSnap.exists) {
            yield NodePermissionStatus.pending;
          } else {
            yield NodePermissionStatus.unapproved;
          }
        } catch (_) {
          yield NodePermissionStatus.unapproved;
        }
      }
    }
  }
}

class NodePermissionNotifier extends StateNotifier<NodePermissionStatus> {
  final NodePermissionService _service;
  final String _mac;

  NodePermissionNotifier(this._service, this._mac)
    : super(_getCachedStatusSync(_mac)) {
    _checkAccess();
  }

  static NodePermissionStatus _getCachedStatusSync(String mac) {
    try {
      if (Hive.isBoxOpen(CacheKeys.userProfileBox)) {
        final profileBox = Hive.box(CacheKeys.userProfileBox);
        final role = profileBox.get(CacheKeys.roleKey) as String?;
        if (role == 'admin') {
          return NodePermissionStatus.approved;
        }
      }
      final box = Hive.box(CacheKeys.permissionsBox);
      final cached = box.get('permission_$mac') as String?;
      if (cached != null) {
        return NodePermissionStatus.values.firstWhere(
          (e) => e.name == cached,
          orElse: () => NodePermissionStatus.unapproved,
        );
      }
    } catch (_) {}
    return NodePermissionStatus.unapproved;
  }

  Future<void> _checkAccess() async {
    final status = await _service.checkNodeAccess(_mac);
    if (mounted && state != status) {
      state = status;
    }
  }

  Future<void> refresh() async {
    final status = await _service.checkNodeAccess(_mac);
    if (mounted && state != status) {
      state = status;
    }
  }
}

final nodeAccessProvider =
    StateNotifierProvider.family<
      NodePermissionNotifier,
      NodePermissionStatus,
      String
    >((ref, mac) {
      final service = ref.watch(nodePermissionServiceProvider);
      // Re-evaluate whenever auth role changes
      ref.watch(authProvider.select((state) => state.role));
      return NodePermissionNotifier(service, mac);
    });

final nodeAccessStreamProvider =
    StreamProvider.family<NodePermissionStatus, String>((ref, mac) {
      final service = ref.watch(nodePermissionServiceProvider);
      return service.watchNodeAccess(mac);
    });
