import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_service.dart';

class AuthState {
  final bool isAuthenticated;
  final String? email;
  final String? role;
  final String? error;
  final bool isLoading;

  AuthState({
    required this.isAuthenticated,
    this.email,
    this.role,
    this.error,
    this.isLoading = false,
  });

  AuthState copyWith({
    bool? isAuthenticated,
    String? email,
    String? role,
    String? error,
    bool? isLoading,
  }) {
    return AuthState(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      email: email ?? this.email,
      role: role ?? this.role,
      error: error ?? this.error,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final authService = ref.watch(authServiceProvider);
  return AuthNotifier(authService);
});

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService;

  AuthNotifier(this._authService) : super(AuthState(isAuthenticated: false)) {
    _init();
  }

  void _init() {
    _authService.authStateChanges.listen((user) async {
      if (user != null) {
        final role = await _authService.getUserRole(user.uid);
        state = AuthState(
          isAuthenticated: true,
          email: user.email,
          role: role,
        );
      } else {
        state = AuthState(isAuthenticated: false);
      }
    });
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _authService.signInWithEmailAndPassword(email, password);
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst(RegExp(r'^\[.*\]\s*'), ''), // Strip Firebase error codes
      );
      return false;
    }
  }

  Future<bool> register(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _authService.signUpWithEmailAndPassword(email, password);
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString().replaceFirst(RegExp(r'^\[.*\]\s*'), ''),
      );
      return false;
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
      await _authService.signOut();
    } catch (_) {}
    state = AuthState(isAuthenticated: false);
  }
}
