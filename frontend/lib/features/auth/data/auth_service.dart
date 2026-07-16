import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/security/firebase_encryption_service.dart';

final authServiceProvider = Provider<AuthService>((ref) {
  final encryptionService = ref.watch(firebaseEncryptionServiceProvider);
  return AuthService(encryptionService);
});

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final FirebaseEncryptionService _encryptionService;

  AuthService(this._encryptionService);

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<UserCredential> signInWithEmailAndPassword(String email, String password) async {
    final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
    if (cred.user != null) {
      await _syncUserProfile(cred.user!, email, 'user');
    }
    return cred;
  }

  Future<UserCredential> signUpWithEmailAndPassword(String email, String password) async {
    final cred = await _auth.createUserWithEmailAndPassword(email: email, password: password);
    if (cred.user != null) {
      await _syncUserProfile(cred.user!, email, 'user');
    }
    return cred;
  }

  Future<UserCredential?> signInWithGoogle() async {
    final GoogleSignIn googleSignIn = GoogleSignIn();
    final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
    
    if (googleUser == null) return null;

    final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
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

  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (_) {}
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
  }

  Future<void> _syncUserProfile(User user, String email, String defaultRole) async {
    final uid = user.uid;
    final userRef = _db.ref('users/$uid');
    
    // Check if user profile already exists to prevent overwriting roles
    final snapshot = await userRef.get();
    if (!snapshot.exists) {
      // Encrypt the fields client-side before storing
      final encryptedEmail = _encryptionService.encryptField(email);
      final encryptedRole = _encryptionService.encryptField(defaultRole);
      
      await userRef.set({
        'email': encryptedEmail,
        'role': encryptedRole,
      });
    }
  }

  Future<String> getUserRole(String uid) async {
    try {
      final snapshot = await _db.ref('users/$uid/role').get();
      if (snapshot.exists && snapshot.value is String) {
        final decryptedRole = _encryptionService.decryptField(snapshot.value as String);
        return decryptedRole;
      }
    } catch (_) {}
    return 'user'; // Default fallback
  }
}
