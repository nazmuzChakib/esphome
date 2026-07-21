import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/security/firebase_encryption_service.dart';
import '../../../core/security/secure_storage_provider.dart';
import '../../../core/utils/device_info_helper.dart';
import '../../../core/utils/email_helper.dart';

final authServiceProvider = Provider<AuthService>((ref) {
  final encryptionService = ref.watch(firebaseEncryptionServiceProvider);
  final service = AuthService(encryptionService);
  service.listenToEncryptionKeyPropagation(ref);
  return service;
});

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final FirebaseEncryptionService _encryptionService;

  AuthService(this._encryptionService);

  String decrypt(String cipherText) =>
      _encryptionService.decryptField(cipherText);
  String encrypt(String plainText) =>
      _encryptionService.encryptField(plainText);

  void listenToEncryptionKeyPropagation(Ref ref) {
    try {
      _db.ref('system/config/encryption_key').onValue.listen((event) async {
        final newKey = event.snapshot.value?.toString();
        if (newKey != null && newKey.isNotEmpty) {
          final currentKey = ref.read(firebaseKeyProvider);
          if (currentKey != newKey) {
            await ref.read(firebaseKeyProvider.notifier).saveKey(newKey);
          }
        }
      });
    } catch (_) {}
  }

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> signInWithEmailAndPassword(
    String email,
    String password,
  ) async {
    final cred = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    if (cred.user != null) {
      await _syncUserProfile(cred.user!, email, 'user');
    }
    return cred;
  }

  Future<UserCredential> signUpWithEmailAndPassword(
    String email,
    String password,
    String firstName,
    String lastName,
  ) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    if (cred.user != null) {
      final fullName = '$firstName $lastName';
      await cred.user!.updateDisplayName(fullName);
      await _syncUserProfile(
        cred.user!,
        email,
        'user',
        firstName: firstName,
        lastName: lastName,
      );
    }
    return cred;
  }

  Future<UserCredential?> signInWithGoogle() async {
    final GoogleSignIn googleSignIn = GoogleSignIn();
    final GoogleSignInAccount? googleUser = await googleSignIn.signIn();

    if (googleUser == null) return null;

    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;
    final AuthCredential credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final cred = await _auth.signInWithCredential(credential);
    if (cred.user != null) {
      await _syncUserProfile(cred.user!, cred.user!.email ?? '', 'user');
    }
    return cred;
  }

  /// Unregisters/removes the current device from Firebase Realtime Database upon logout
  Future<void> unregisterCurrentDevice() async {
    try {
      final user = _auth.currentUser;
      if (user != null && user.email != null) {
        final emailHash = EmailHelper.hashEmail(user.email!);
        final deviceId = await DeviceInfoHelper.getStableDeviceId();
        await _db.ref('users/$emailHash/devices/$deviceId').remove();
      }
    } catch (_) {}
  }

  /// Removes a specific device for a user profile
  Future<void> removeUserDevice(String email, String deviceId) async {
    try {
      final emailHash = EmailHelper.hashEmail(email);
      await _db.ref('users/$emailHash/devices/$deviceId').remove();
    } catch (_) {}
  }

  Future<void> signOut() async {
    try {
      await unregisterCurrentDevice();
    } catch (_) {}
    try {
      await _auth.signOut();
    } catch (_) {}
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
  }

  // Device identification is now handled by DeviceInfoHelper for stable IDs.

  /// Register current device under the user profile with stable ID and display name
  Future<void> registerCurrentDevice(User user) async {
    try {
      final emailHash = EmailHelper.hashEmail(user.email ?? '');
      final deviceId = await DeviceInfoHelper.getStableDeviceId();
      final deviceName = await DeviceInfoHelper.getDeviceDisplayName();
      final deviceRef = _db.ref('users/$emailHash/devices/$deviceId');
      final deviceSnap = await deviceRef.get();
      if (!deviceSnap.exists) {
        // First time this device registers: set status as approved with display name
        final encryptedStatus = _encryptionService.encryptField('approved');
        final encryptedName = _encryptionService.encryptField(deviceName);
        await deviceRef.set({'status': encryptedStatus, 'name': encryptedName});
      } else {
        // Device exists: update display name in case it updated (e.g., OS/browser upgrade)
        final encryptedName = _encryptionService.encryptField(deviceName);
        await _db
            .ref('users/$emailHash/devices/$deviceId/name')
            .set(encryptedName);
      }
    } catch (_) {}
  }


  Future<void> _syncUserProfile(
    User user,
    String email,
    String defaultRole, {
    String? firstName,
    String? lastName,
    String? name,
  }) async {
    final emailHash = EmailHelper.hashEmail(email);
    final userRef = _db.ref('users/$emailHash');

    // Check if user profile already exists to prevent overwriting roles
    final snapshot = await userRef.get();
    if (!snapshot.exists) {
      // Encrypt the fields client-side before storing
      final encryptedEmail = _encryptionService.encryptField(email);
      final encryptedRole = _encryptionService.encryptField(defaultRole);
      final encryptedFirst = _encryptionService.encryptField(firstName ?? '');
      final encryptedLast = _encryptionService.encryptField(lastName ?? '');
      final encryptedName = _encryptionService.encryptField(name ?? '');

      await userRef.set({
        'email': encryptedEmail,
        'role': encryptedRole,
        'first_name': encryptedFirst,
        'last_name': encryptedLast,
        'name': encryptedName,
      });
    } else {
      final updates = <String, Object>{};
      if (firstName != null && firstName.isNotEmpty) {
        updates['first_name'] = _encryptionService.encryptField(firstName);
      }
      if (lastName != null && lastName.isNotEmpty) {
        updates['last_name'] = _encryptionService.encryptField(lastName);
      }
      if (name != null) {
        updates['name'] = _encryptionService.encryptField(name);
      }
      if (updates.isNotEmpty) {
        await userRef.update(updates);
      }
    }

    await registerCurrentDevice(user);

    // Sync admin record: if this user's role is admin, write to admins/ collection
    await _syncAdminRecord(emailHash);
  }

  /// Writes or removes the admin record under `admins/$emailHash`.
  /// The value is a plain-text marker "admin" so it can be checked fast
  /// without needing to decrypt, while the actual role field stays encrypted.
  Future<void> _syncAdminRecord(String emailHash) async {
    try {
      final roleSnap = await _db.ref('users/$emailHash/role').get();
      if (roleSnap.exists && roleSnap.value is String) {
        final role = _encryptionService.decryptField(roleSnap.value as String);
        final adminRef = _db.ref('admins/$emailHash');
        if (role == 'admin') {
          // Write admin marker — value is plain-text intentionally (not sensitive)
          await adminRef.set({
            'role': 'admin',
            'grantedAt': DateTime.now().millisecondsSinceEpoch,
          });
        } else {
          // Remove admin record if role changed back to user
          final adminSnap = await adminRef.get();
          if (adminSnap.exists) {
            await adminRef.remove();
          }
        }
      }
    } catch (_) {}
  }

  Future<String> getUserRole(String uid) async {
    final email = _auth.currentUser?.email;
    if (email == null) return 'user';

    final emailHash = EmailHelper.hashEmail(email);
    try {
      final snapshot = await _db.ref('users/$emailHash/role').get();
      if (snapshot.exists && snapshot.value is String) {
        final decryptedRole = _encryptionService.decryptField(
          snapshot.value as String,
        );
        return decryptedRole;
      }
    } catch (_) {}
    return 'user'; // Default fallback
  }

  Future<String> getDeviceStatus(String email, String deviceId) async {
    try {
      final emailHash = EmailHelper.hashEmail(email);
      final snapshot = await _db
          .ref('users/$emailHash/devices/$deviceId')
          .get();
      if (snapshot.exists) {
        final val = snapshot.value;
        // New structure: Map with status & name
        if (val is Map && val['status'] != null) {
          return _encryptionService.decryptField(val['status'] as String);
        }
        // Legacy structure: plain encrypted string
        if (val is String) {
          return _encryptionService.decryptField(val);
        }
      }
    } catch (_) {}
    return 'unknown';
  }

  Future<List<Map<String, String>>> getUserDevices(String email) async {
    final List<Map<String, String>> list = [];
    try {
      final emailHash = EmailHelper.hashEmail(email);
      final snapshot = await _db.ref('users/$emailHash/devices').get();
      if (snapshot.exists && snapshot.value is Map) {
        final map = snapshot.value as Map;
        map.forEach((key, val) {
          final deviceId = key.toString();
          // New structure: Map with status + name
          if (val is Map) {
            final status = val['status'] != null
                ? _encryptionService.decryptField(val['status'] as String)
                : 'unknown';
            final name = val['name'] != null
                ? _encryptionService.decryptField(val['name'] as String)
                : deviceId;
            list.add({'id': deviceId, 'status': status, 'name': name});
          } else if (val is String) {
            // Legacy: plain encrypted status string
            final status = _encryptionService.decryptField(val);
            list.add({'id': deviceId, 'status': status, 'name': deviceId});
          }
        });
      }
    } catch (_) {}
    return list;
  }
}
