import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/security/firebase_encryption_service.dart';

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

  String? get _currentUserUid => _auth.currentUser?.uid;

  Future<NodePermissionStatus> checkNodeAccess(String nodeMac) async {
    final uid = _currentUserUid;
    if (uid == null) return NodePermissionStatus.unapproved;

    try {
      // 1. Check approved_nodes
      final approvedRef = _db.ref('approved_nodes/$nodeMac');
      final approvedSnapshot = await approvedRef.get();
      
      if (approvedSnapshot.exists) {
        final data = approvedSnapshot.value as Map?;
        if (data != null) {
          // Decrypt owner_uid to check ownership
          final encryptedOwner = data['owner_uid'] as String?;
          if (encryptedOwner != null) {
            final decryptedOwner = _encryptionService.decryptField(encryptedOwner);
            if (decryptedOwner == uid) return NodePermissionStatus.approved;
          }

          // Check shared_users list
          final sharedUsers = data['shared_users'] as Map?;
          if (sharedUsers != null && sharedUsers.containsKey(uid)) {
            return NodePermissionStatus.approved;
          }
        }
      }

      // 2. Check pending_requests
      final pendingRef = _db.ref('pending_requests/$nodeMac');
      final pendingSnapshot = await pendingRef.get();
      if (pendingSnapshot.exists) {
        return NodePermissionStatus.pending;
      }
    } catch (_) {}

    return NodePermissionStatus.unapproved;
  }

  Future<void> requestNodeAccess(String nodeMac, String userEmail) async {
    final uid = _currentUserUid;
    if (uid == null) return;

    final pendingRef = _db.ref('pending_requests/$nodeMac');

    final encryptedUid = _encryptionService.encryptField(uid);
    final encryptedEmail = _encryptionService.encryptField(userEmail);
    final encryptedNodeMac = _encryptionService.encryptField(nodeMac);

    await pendingRef.set({
      'node_id': encryptedNodeMac,
      'requested_by_uid': encryptedUid,
      'requested_by_email': encryptedEmail,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<PendingAccessRequest>> getPendingRequests() async {
    final List<PendingAccessRequest> requests = [];
    try {
      final snapshot = await _db.ref('pending_requests').get();
      if (snapshot.exists && snapshot.value is Map) {
        final data = snapshot.value as Map;
        data.forEach((key, val) {
          if (val is Map) {
            final nodeMac = key.toString();
            final encryptedEmail = val['requested_by_email'] as String? ?? '';
            final encryptedUid = val['requested_by_uid'] as String? ?? '';
            final timestamp = val['timestamp'] as int? ?? 0;

            final decryptedEmail = _encryptionService.decryptField(encryptedEmail);
            final decryptedUid = _encryptionService.decryptField(encryptedUid);

            requests.add(PendingAccessRequest(
              nodeMac: nodeMac,
              requestedByUid: decryptedUid,
              requestedByEmail: decryptedEmail,
              timestamp: timestamp,
            ));
          }
        });
      }
    } catch (_) {}
    return requests;
  }

  Future<void> approveRequest(String nodeMac, String requesterUid) async {
    final adminUid = _currentUserUid;
    if (adminUid == null) return;

    final approvedRef = _db.ref('approved_nodes/$nodeMac');
    final pendingRef = _db.ref('pending_requests/$nodeMac');

    final encryptedNodeMac = _encryptionService.encryptField(nodeMac);
    final encryptedAdminUid = _encryptionService.encryptField(adminUid);

    await approvedRef.set({
      'node_id': encryptedNodeMac,
      'owner_uid': encryptedAdminUid,
      'shared_users': {
        requesterUid: true,
      }
    });

    await pendingRef.remove();
  }
}

final nodeAccessProvider = FutureProvider.family<NodePermissionStatus, String>((ref, mac) async {
  final service = ref.watch(nodePermissionServiceProvider);
  return service.checkNodeAccess(mac);
});
