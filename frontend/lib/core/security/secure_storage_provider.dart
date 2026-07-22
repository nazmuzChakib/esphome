import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
});

final apiKeyProvider = StateNotifierProvider<ApiKeyNotifier, String?>((ref) {
  final secureStorage = ref.watch(secureStorageProvider);
  return ApiKeyNotifier(secureStorage);
});

class ApiKeyNotifier extends StateNotifier<String?> {
  final FlutterSecureStorage _storage;
  static const String _key = 'node_api_key';

  ApiKeyNotifier(this._storage) : super(null) {
    loadApiKey();
  }

  Future<void> loadApiKey() async {
    final value = await _storage.read(key: _key);
    state = value;
  }

  Future<void> saveApiKey(String apiKey) async {
    await _storage.write(key: _key, value: apiKey);
    state = apiKey;
  }

  Future<void> deleteApiKey() async {
    await _storage.delete(key: _key);
    state = null;
  }
}

final firebaseKeyProvider = StateNotifierProvider<FirebaseKeyNotifier, String?>(
  (ref) {
    final secureStorage = ref.watch(secureStorageProvider);
    return FirebaseKeyNotifier(secureStorage);
  },
);

class FirebaseKeyNotifier extends StateNotifier<String?> {
  final FlutterSecureStorage _storage;
  static const String _key = 'firebase_encryption_key';

  FirebaseKeyNotifier(this._storage) : super(null) {
    loadKey();
  }

  Future<void> loadKey() async {
    final value = await _storage.read(key: _key);
    if (value == null) {
      // Default fallback encryption key for Firebase
      const fallback = String.fromEnvironment(
        'FIREBASE_KEY',
        defaultValue: 'default_firebase_sec_key_123456',
      );
      state = fallback;
    } else {
      state = value;
    }
  }

  Future<void> saveKey(String key) async {
    await _storage.write(key: _key, value: key);
    state = key;
  }

  Future<void> deleteKey() async {
    await _storage.delete(key: _key);
    state = null;
  }
}
