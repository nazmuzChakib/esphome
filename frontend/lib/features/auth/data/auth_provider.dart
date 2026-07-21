import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth, User;
import '../../../core/cache/cache_keys.dart';
import '../../../core/utils/email_helper.dart';
import '../../../core/security/secure_storage_provider.dart';
import 'auth_service.dart';

class AuthState {
  final bool isAuthenticated;
  final String? email;
  final String? firstName;
  final String? lastName;
  final String? name;
  final String? role;
  final String? error;
  final bool isLoading;
  final String? photoUrl;
  final bool requiresReload;

  AuthState({
    required this.isAuthenticated,
    this.email,
    this.firstName,
    this.lastName,
    this.name,
    this.role,
    this.error,
    this.isLoading = false,
    this.photoUrl,
    this.requiresReload = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? email,
    String? firstName,
    String? lastName,
    String? name,
    String? role,
    String? error,
    bool? isLoading,
    String? photoUrl,
    bool? requiresReload,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      email: email ?? this.email,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      name: name ?? this.name,
      role: role ?? this.role,
      error: error ?? this.error,
      isLoading: isLoading ?? this.isLoading,
      photoUrl: photoUrl ?? this.photoUrl,
      requiresReload: requiresReload ?? this.requiresReload,
    );
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final authService = ref.watch(authServiceProvider);
  return AuthNotifier(authService, ref);
});

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService;
  final Ref ref;

  AuthNotifier(this._authService, this.ref)
    : super(
        AuthState(
          isAuthenticated:
              Hive.box(
                    CacheKeys.userProfileBox,
                  ).get(CacheKeys.authStatusKey, defaultValue: false)
                  as bool,
          email:
              Hive.box(CacheKeys.userProfileBox).get(CacheKeys.emailKey)
                  as String?,
          firstName:
              Hive.box(CacheKeys.userProfileBox).get('first_name') as String?,
          lastName:
              Hive.box(CacheKeys.userProfileBox).get('last_name') as String?,
          name:
              Hive.box(CacheKeys.userProfileBox).get('display_name') as String?,
          role:
              Hive.box(CacheKeys.userProfileBox).get(CacheKeys.roleKey)
                  as String?,
          photoUrl:
              Hive.box(CacheKeys.userProfileBox).get('photo_url') as String?,
        ),
      ) {
    _init();
  }

  Map<String, dynamic>? _pendingNewData;

  void _init() {
    _authService.authStateChanges.listen((user) async {
      if (user != null) {
        final box = Hive.box(CacheKeys.userProfileBox);

        // Load cache in parallel / immediately
        final cachedFirstName = box.get('first_name') as String?;
        final cachedLastName = box.get('last_name') as String?;
        final cachedDisplayName = box.get('display_name') as String?;
        final cachedRole = box.get(CacheKeys.roleKey) as String?;
        final cachedPhotoUrl = box.get('photo_url') as String?;

        if (cachedRole == null ||
            cachedFirstName == null ||
            cachedLastName == null) {
          state = AuthState(
            isAuthenticated: true,
            email: user.email,
            isLoading: true,
          );
          // Block/wait for Firebase sync
          await _syncUserProfileAndRole(user, box);
        } else {
          state = AuthState(
            isAuthenticated: true,
            email: user.email,
            firstName: cachedFirstName,
            lastName: cachedLastName,
            name: cachedDisplayName,
            role: cachedRole,
            photoUrl: cachedPhotoUrl,
          );
          // Async background update (non-blocking)
          _syncUserProfileAndRole(user, box);
        }
      } else {
        final box = Hive.box(CacheKeys.userProfileBox);
        await box.put(CacheKeys.authStatusKey, false);
        await box.put(CacheKeys.emailKey, null);
        await box.put('first_name', null);
        await box.put('last_name', null);
        await box.put('display_name', null);
        await box.put(CacheKeys.roleKey, null);
        await box.put('photo_url', null);
        state = AuthState(isAuthenticated: false);
      }
    });
  }

  Future<void> _syncUserProfileAndRole(User user, Box box) async {
    final hasInternet = await _checkInternetConnection();
    if (!hasInternet) {
      state = state.copyWith(isLoading: false);
      return;
    }

    // Fetch the database encryption key first, BEFORE any decryption
    try {
      final keySnap = await FirebaseDatabase.instance
          .ref('system/config/encryption_key')
          .get()
          .timeout(const Duration(seconds: 5));
      if (keySnap.exists && keySnap.value != null) {
        final dbKey = keySnap.value.toString();
        await ref.read(firebaseKeyProvider.notifier).saveKey(dbKey);
      }
    } catch (_) {}

    // After saving key, grab the updated service instance
    final svc = ref.read(authServiceProvider);

    // Helper: safely decrypt - returns empty string on failure
    String safeDecrypt(dynamic raw) {
      if (raw == null) return '';
      try {
        return svc.decrypt(raw as String);
      } catch (_) {
        return '';
      }
    }

    String? updatedRole;
    String? firstName;
    String? lastName;
    String? displayName;
    String? syncedPhotoUrl;

    // Single network call: read the entire user node
    try {
      final hash = EmailHelper.hashEmail(user.email ?? '');
      final snap = await FirebaseDatabase.instance
          .ref('users/$hash')
          .get()
          .timeout(const Duration(seconds: 5));

      if (snap.exists && snap.value is Map) {
        final data = snap.value as Map;

        // Role lives in users/$hash/role
        final rawRole = safeDecrypt(data['role']);
        if (rawRole.isNotEmpty) updatedRole = rawRole;

        // Names
        final rawFirst = safeDecrypt(data['first_name']);
        if (rawFirst.isNotEmpty) firstName = rawFirst;

        final rawLast = safeDecrypt(data['last_name']);
        if (rawLast.isNotEmpty) lastName = rawLast;

        final rawName = safeDecrypt(data['name']);
        if (rawName.isNotEmpty) displayName = rawName;

        final rawPhoto = safeDecrypt(data['photo_url']);
        if (rawPhoto.isNotEmpty) {
          syncedPhotoUrl = rawPhoto;
        } else if (data['photo_url'] is String &&
            (data['photo_url'] as String).isNotEmpty) {
          syncedPhotoUrl = data['photo_url'] as String;
        }
      }
    } catch (_) {}

    // Ensure active device is registered/updated in Firebase for this user profile
    await svc.registerCurrentDevice(user);

    // Fallback: use Firebase Auth displayName when first/last absent

    if ((firstName == null || firstName.isEmpty) && user.displayName != null) {
      final parts = user.displayName!.split(' ');
      firstName = parts.first;
      lastName = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    }

    // --- Account-switch detection (only different email, NOT role changes) ---
    final cachedEmail = box.get(CacheKeys.emailKey) as String?;
    if (cachedEmail != null &&
        cachedEmail.isNotEmpty &&
        cachedEmail != user.email) {
      // A different user logged in: queue pending data and ask for reload
      _pendingNewData = {
        'email': user.email,
        'role': updatedRole ?? 'user',
        'first_name': firstName,
        'last_name': lastName,
        'display_name': displayName,
        'photo_url': syncedPhotoUrl ?? user.photoURL,
      };
      state = state.copyWith(requiresReload: true, isLoading: false);
      return;
    }

    // Persist fresh data to cache
    await box.put(CacheKeys.emailKey, user.email);
    if (updatedRole != null && updatedRole.isNotEmpty) {
      await box.put(CacheKeys.roleKey, updatedRole);
    }
    if (firstName != null && firstName.isNotEmpty) {
      await box.put('first_name', firstName);
    }
    if (lastName != null && lastName.isNotEmpty) {
      await box.put('last_name', lastName);
    }
    if (displayName != null && displayName.isNotEmpty) {
      await box.put('display_name', displayName);
    }
    if (syncedPhotoUrl != null && syncedPhotoUrl.isNotEmpty) {
      await box.put('photo_url', syncedPhotoUrl);
    } else if (user.photoURL != null && user.photoURL!.isNotEmpty) {
      await box.put('photo_url', user.photoURL);
    }

    // Always update UI state with the latest resolved values
    final finalRole = box.get(CacheKeys.roleKey) as String? ?? 'user';
    final finalFirstName = box.get('first_name') as String?;
    final finalLastName = box.get('last_name') as String?;
    final finalDisplayName = box.get('display_name') as String?;
    final finalPhotoUrl = box.get('photo_url') as String?;

    state = state.copyWith(
      email: user.email,
      role: finalRole,
      firstName: finalFirstName,
      lastName: finalLastName,
      name: finalDisplayName,
      photoUrl: finalPhotoUrl,
      isLoading: false,
      requiresReload: false,
    );
  }

  Future<void> applyNewDataAndRender() async {
    if (_pendingNewData != null) {
      final box = Hive.box(CacheKeys.userProfileBox);
      await box.put(CacheKeys.emailKey, _pendingNewData!['email']);
      await box.put(CacheKeys.roleKey, _pendingNewData!['role']);
      await box.put('first_name', _pendingNewData!['first_name']);
      await box.put('last_name', _pendingNewData!['last_name']);
      await box.put('display_name', _pendingNewData!['display_name']);
      await box.put('photo_url', _pendingNewData!['photo_url']);
      await box.put(CacheKeys.authStatusKey, true);

      state = AuthState(
        isAuthenticated: true,
        email: _pendingNewData!['email'] as String?,
        role: _pendingNewData!['role'] as String?,
        firstName: _pendingNewData!['first_name'] as String?,
        lastName: _pendingNewData!['last_name'] as String?,
        name: _pendingNewData!['display_name'] as String?,
        photoUrl: _pendingNewData!['photo_url'] as String?,
        requiresReload: false,
      );
      _pendingNewData = null;
    }
  }

  Future<bool> _checkInternetConnection() async {
    // Web cannot use dart:io socket-level checks; assume connected
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

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _authService.signInWithEmailAndPassword(email, password);
      return true;
    } catch (e) {
      String errMsg = e.toString().replaceFirst(RegExp(r'^\[.*\]\s*'), '');
      final lowerMsg = errMsg.toLowerCase();
      if (lowerMsg.contains('user-not-found') ||
          lowerMsg.contains('invalid-login-credentials') ||
          lowerMsg.contains('invalid-credential') ||
          lowerMsg.contains('wrong-password')) {
        errMsg = 'Invalid credentials or user does not exist.';
      }
      state = state.copyWith(isLoading: false, error: errMsg);
      return false;
    }
  }

  Future<bool> register(
    String email,
    String password,
    String firstName,
    String lastName,
  ) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final box = Hive.box(CacheKeys.userProfileBox);
      await box.put('first_name', firstName);
      await box.put('last_name', lastName);
      await box.put('display_name', '$firstName $lastName');
      await box.put(CacheKeys.roleKey, 'user');
      await box.put(CacheKeys.emailKey, email);
      await box.put(CacheKeys.authStatusKey, true);

      await _authService.signUpWithEmailAndPassword(
        email,
        password,
        firstName,
        lastName,
      );
      return true;
    } catch (e) {
      String errMsg = e.toString().replaceFirst(RegExp(r'^\[.*\]\s*'), '');
      final lowerMsg = errMsg.toLowerCase();
      if (lowerMsg.contains('email-already-in-use')) {
        errMsg = 'This email address is already in use by another user.';
      } else if (lowerMsg.contains('weak-password')) {
        errMsg = 'The password provided is too weak.';
      }
      state = state.copyWith(isLoading: false, error: errMsg);
      return false;
    }
  }

  Future<void> updateProfile({
    required String firstName,
    required String lastName,
    required String name,
    String? photoUrl,
  }) async {
    state = state.copyWith(isLoading: true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final fullName = name.isNotEmpty ? name : '$firstName $lastName';
        await user.updateDisplayName(fullName);
        if (photoUrl != null && photoUrl.isNotEmpty) {
          try {
            await user.updateProfile(photoURL: photoUrl);
          } catch (_) {}
        }
        final email = user.email;
        if (email != null) {
          final activeAuthService = ref.read(authServiceProvider);
          final emailHash = EmailHelper.hashEmail(email);
          final Map<String, Object?> updates = {
            'first_name': activeAuthService.encrypt(firstName),
            'last_name': activeAuthService.encrypt(lastName),
            'name': activeAuthService.encrypt(name),
          };
          if (photoUrl != null && photoUrl.isNotEmpty) {
            updates['photo_url'] = activeAuthService.encrypt(photoUrl);
          }
          await FirebaseDatabase.instance
              .ref('users/$emailHash')
              .update(updates);
        }
        final box = Hive.box(CacheKeys.userProfileBox);
        await box.put('first_name', firstName);
        await box.put('last_name', lastName);
        await box.put('display_name', name);
        if (photoUrl != null && photoUrl.isNotEmpty) {
          await box.put('photo_url', photoUrl);
        }
        state = state.copyWith(
          firstName: firstName,
          lastName: lastName,
          name: name,
          photoUrl: photoUrl ?? state.photoUrl,
          isLoading: false,
        );
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<bool> loginWithGoogle() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final cred = await _authService.signInWithGoogle();
      return cred != null;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst(RegExp(r'^\[.*\]\s*'), ''),
      );
      return false;
    }
  }

  Future<void> logout() async {
    state = state.copyWith(isLoading: true);
    try {
      await _authService.unregisterCurrentDevice();
    } catch (_) {}
    try {
      await _authService.signOut();
    } catch (_) {}
    state = AuthState(isAuthenticated: false);
  }


  void clearError() {
    state = state.copyWith(error: null);
  }
}
