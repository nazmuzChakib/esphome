import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/security/firebase_encryption_service.dart';

final accessControlServiceProvider = Provider<AccessControlService>((ref) {
  final encryptionService = ref.watch(firebaseEncryptionServiceProvider);
  return AccessControlService(encryptionService);
});

class AccessControlService {
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final FirebaseEncryptionService _encryptionService;

  AccessControlService(this._encryptionService);

  /// Lists all users from the Database by fetching and decrypting email/role fields.
  Future<List<Map<String, dynamic>>> getUsersList() async {
    final List<Map<String, dynamic>> users = [];
    try {
      final snapshot = await _db.ref('users').get();
      if (snapshot.exists && snapshot.value is Map) {
        final data = snapshot.value as Map;
        data.forEach((key, val) {
          if (val is Map) {
            final String emailHash = key.toString();
            String email = 'Unknown Email';
            String role = 'user';

            if (val['email'] != null) {
              try {
                email = _encryptionService.decryptField(val['email'] as String);
              } catch (_) {}
            }
            if (val['role'] != null) {
              try {
                role = _encryptionService.decryptField(val['role'] as String);
              } catch (_) {}
            }

            final List<Map<String, String>> devices = [];
            if (val['devices'] is Map) {
              final devMap = val['devices'] as Map;
              devMap.forEach((dKey, dVal) {
                final deviceId = dKey.toString();
                // New structure: Map with status + name
                if (dVal is Map) {
                  try {
                    final status = dVal['status'] != null
                        ? _encryptionService.decryptField(
                            dVal['status'] as String,
                          )
                        : 'unknown';
                    final name = dVal['name'] != null
                        ? _encryptionService.decryptField(
                            dVal['name'] as String,
                          )
                        : deviceId;
                    devices.add({
                      'id': deviceId,
                      'status': status,
                      'name': name,
                    });
                  } catch (_) {}
                } else if (dVal is String) {
                  // Legacy: plain encrypted string
                  try {
                    final status = _encryptionService.decryptField(dVal);
                    devices.add({
                      'id': deviceId,
                      'status': status,
                      'name': deviceId,
                    });
                  } catch (_) {}
                }
              });
            }

            users.add({
              'emailHash': emailHash,
              'email': email,
              'role': role,
              'devices': devices,
            });
          }
        });
      }
    } catch (_) {}
    return users;
  }

  /// Updates user role client-side encrypted and synchronizes with admins/ database marker.
  Future<void> updateUserRole(String emailHash, String newRole) async {
    try {
      final encryptedRole = _encryptionService.encryptField(newRole);
      await _db.ref('users/$emailHash/role').set(encryptedRole);

      final adminRef = _db.ref('admins/$emailHash');
      if (newRole == 'admin') {
        await adminRef.set({
          'role': 'admin',
          'grantedAt': DateTime.now().millisecondsSinceEpoch,
        });
      } else {
        await adminRef.remove();
      }
    } catch (_) {}
  }

  /// Updates device status (approved/unapproved) - handles both Map and legacy String format.
  Future<void> updateDeviceStatus(
    String emailHash,
    String deviceId,
    String status,
  ) async {
    try {
      final encryptedStatus = _encryptionService.encryptField(status);
      // Check if device entry already has new Map structure
      final snap = await _db.ref('users/$emailHash/devices/$deviceId').get();
      if (snap.exists && snap.value is Map) {
        // Update only the status field
        await _db
            .ref('users/$emailHash/devices/$deviceId/status')
            .set(encryptedStatus);
      } else {
        // Legacy: just set the string directly
        await _db
            .ref('users/$emailHash/devices/$deviceId')
            .set(encryptedStatus);
      }
    } catch (_) {}
  }

  /// Realtime stream of pending access requests for admin live updates.
  Stream<List<Map<String, dynamic>>> watchPendingRequests() {
    return _db.ref('pending_requests').onValue.map((event) {
      final List<Map<String, dynamic>> requests = [];
      try {
        if (!event.snapshot.exists || event.snapshot.value == null) {
          return requests;
        }
        final rawValue = event.snapshot.value;
        if (rawValue is! Map) return requests;

        for (final macEntry in rawValue.entries) {
          final macHash = macEntry.key.toString();
          final userMap = macEntry.value;
          if (userMap is Map) {
            for (final userEntry in userMap.entries) {
              final emailHash = userEntry.key.toString();
              final details = userEntry.value;
              if (details is Map) {
                String nodeMac = '';
                String requestedByEmail = '';
                String deviceId = '';
                try {
                  if (details['node_id'] != null) {
                    nodeMac = _encryptionService.decryptField(
                      details['node_id'].toString(),
                    );
                  }
                  if (details['requested_by_email'] != null) {
                    requestedByEmail = _encryptionService.decryptField(
                      details['requested_by_email'].toString(),
                    );
                  }
                  if (details['device_id'] != null) {
                    deviceId = _encryptionService.decryptField(
                      details['device_id'].toString(),
                    );
                  }
                } catch (_) {}

                requests.add({
                  'macHash': macHash,
                  'emailHash': emailHash,
                  'nodeMac': nodeMac.isNotEmpty ? nodeMac : 'Unknown Node',
                  'requestedByEmail': requestedByEmail.isNotEmpty
                      ? requestedByEmail
                      : 'Unknown User',
                  'deviceId': deviceId,
                });
              }
            }
          }
        }
      } catch (_) {}
      return requests;
    });
  }

  /// Fetches and decrypts pending node request details.
  Future<List<Map<String, dynamic>>> getPendingRequests() async {
    final List<Map<String, dynamic>> requests = [];
    try {
      final snapshot = await _db.ref('pending_requests').get();
      if (snapshot.exists && snapshot.value != null) {
        final rawValue = snapshot.value;
        if (rawValue is Map) {
          for (final macEntry in rawValue.entries) {
            final macHash = macEntry.key.toString();
            final userMap = macEntry.value;
            if (userMap is Map) {
              for (final userEntry in userMap.entries) {
                final emailHash = userEntry.key.toString();
                final details = userEntry.value;
                if (details is Map) {
                  String nodeMac = '';
                  String requestedByEmail = '';
                  String deviceId = '';

                  try {
                    if (details['node_id'] != null) {
                      nodeMac = _encryptionService.decryptField(
                        details['node_id'].toString(),
                      );
                    }
                    if (details['requested_by_email'] != null) {
                      requestedByEmail = _encryptionService.decryptField(
                        details['requested_by_email'].toString(),
                      );
                    }
                    if (details['device_id'] != null) {
                      deviceId = _encryptionService.decryptField(
                        details['device_id'].toString(),
                      );
                    }
                  } catch (e) {
                    debugPrint('Error decrypting pending request: $e');
                  }

                  requests.add({
                    'macHash': macHash,
                    'emailHash': emailHash,
                    'nodeMac': nodeMac.isNotEmpty ? nodeMac : 'Unknown Node',
                    'requestedByEmail': requestedByEmail.isNotEmpty
                        ? requestedByEmail
                        : 'Unknown User',
                    'deviceId': deviceId,
                  });
                }
              }
            }
          }
        }
      }
    } catch (e, stack) {
      debugPrint('Exception in getPendingRequests: $e');
      debugPrint(stack.toString());
    }
    return requests;
  }

  /// Approves pending access and saves to approved_nodes permissions mapping.
  Future<void> approveNodeRequest(
    String macHash,
    String emailHash,
    String nodeMac,
  ) async {
    try {
      // 1. Write to approved_nodes
      final encryptedMac = _encryptionService.encryptField(nodeMac);
      await _db.ref('approved_nodes/$emailHash/nodes/$macHash').set({
        'node_id': encryptedMac,
        'approved_at': DateTime.now().millisecondsSinceEpoch,
      });

      // 2. Remove from pending_requests
      await _db.ref('pending_requests/$macHash/$emailHash').remove();
    } catch (_) {}
  }

  /// Denies/removes pending access request.
  Future<void> rejectNodeRequest(String macHash, String emailHash) async {
    try {
      await _db.ref('pending_requests/$macHash/$emailHash').remove();
    } catch (_) {}
  }

  /// Revokes access of an already approved node from a user profile.
  Future<void> revokeNodeAccess(String emailHash, String macHash) async {
    try {
      await _db.ref('approved_nodes/$emailHash/nodes/$macHash').remove();
    } catch (_) {}
  }

  /// Lists all approved nodes for all users (decrypted details).
  Future<List<Map<String, dynamic>>> getApprovedNodesList() async {
    final List<Map<String, dynamic>> approvedList = [];
    try {
      final snapshot = await _db.ref('approved_nodes').get();
      if (snapshot.exists && snapshot.value != null) {
        final rawValue = snapshot.value;
        if (rawValue is Map) {
          for (final emailEntry in rawValue.entries) {
            final String emailHash = emailEntry.key.toString();

            // Get user details
            final userSnap = await _db.ref('users/$emailHash').get();
            String email = 'Unknown Email';
            if (userSnap.exists && userSnap.value is Map) {
              final uMap = userSnap.value as Map;
              if (uMap['email'] != null) {
                try {
                  email = _encryptionService.decryptField(
                    uMap['email'].toString(),
                  );
                } catch (_) {}
              }
            }

            final emailVal = emailEntry.value;
            if (emailVal is Map) {
              final nodesMap = emailVal['nodes'];
              if (nodesMap is Map) {
                for (final nodeEntry in nodesMap.entries) {
                  final macHash = nodeEntry.key.toString();
                  final details = nodeEntry.value;
                  if (details is Map) {
                    String nodeMac = '';
                    try {
                      if (details['node_id'] != null) {
                        nodeMac = _encryptionService.decryptField(
                          details['node_id'].toString(),
                        );
                      }
                    } catch (_) {}

                    approvedList.add({
                      'emailHash': emailHash,
                      'email': email,
                      'macHash': macHash,
                      'nodeMac': nodeMac.isNotEmpty ? nodeMac : 'Unknown Node',
                    });
                  }
                }
              }
            }
          }
        }
      }
    } catch (e, stack) {
      debugPrint('Exception in getApprovedNodesList: $e');
      debugPrint(stack.toString());
    }
    return approvedList;
  }
}
