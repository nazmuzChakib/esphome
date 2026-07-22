import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'secure_storage_provider.dart';

final firebaseEncryptionServiceProvider = Provider<FirebaseEncryptionService>((
  ref,
) {
  final firebaseKey = ref.watch(firebaseKeyProvider);
  return FirebaseEncryptionService(
    firebaseKey ?? 'default_firebase_sec_key_123456',
  );
});

class FirebaseEncryptionService {
  final String _rawKey;
  late final List<int> _keyBytes;

  FirebaseEncryptionService(this._rawKey) {
    // Generate a 16-byte key from the raw key using SHA-256
    final bytes = utf8.encode(_rawKey);
    final digest = sha256.convert(bytes);
    _keyBytes = digest.bytes.sublist(
      0,
      16,
    ); // Take the first 16 bytes for AES-128
  }

  String encryptField(String plainText) {
    if (plainText.isEmpty) return plainText;
    try {
      final key = encrypt.Key(Uint8List.fromList(_keyBytes));
      // Generate a secure random 16-byte IV
      final random = Random.secure();
      final ivBytes = Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)),
      );
      final iv = encrypt.IV(ivBytes);

      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
      );
      final encrypted = encrypter.encrypt(plainText, iv: iv);

      final combined = Uint8List(16 + encrypted.bytes.length);
      combined.setRange(0, 16, ivBytes);
      combined.setRange(16, combined.length, encrypted.bytes);

      return base64.encode(combined);
    } catch (e) {
      return plainText;
    }
  }

  String decryptField(String cipherText) {
    if (cipherText.isEmpty) return cipherText;
    try {
      final combinedBytes = base64.decode(cipherText);
      if (combinedBytes.length < 32) return cipherText;

      final ivBytes = combinedBytes.sublist(0, 16);
      final cipherBytes = combinedBytes.sublist(16);

      final key = encrypt.Key(Uint8List.fromList(_keyBytes));
      final iv = encrypt.IV(Uint8List.fromList(ivBytes));

      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
      );
      return encrypter.decrypt(encrypt.Encrypted(cipherBytes), iv: iv);
    } catch (e) {
      return cipherText;
    }
  }
}
