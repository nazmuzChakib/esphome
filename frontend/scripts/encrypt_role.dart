// ignore_for_file: avoid_print
// This is a standalone CLI utility script, not production app code.
// Printing to stdout is intentional and appropriate here.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    print('ESPHome Auth Role Encryption Utility');
    print('====================================');
    print(
      'Usage: dart scripts/encrypt_role.dart <value_to_encrypt> [encryption_key]',
    );
    print('Example: dart scripts/encrypt_role.dart admin');
    print('Example: dart scripts/encrypt_role.dart user some_custom_key');
    exit(1);
  }

  final value = arguments[0];
  final rawKey = arguments.length > 1
      ? arguments[1]
      : 'default_firebase_sec_key_123456';

  try {
    // Generate a 16-byte key from the raw key using SHA-256 (matching FirebaseEncryptionService)
    final keyBytes = sha256.convert(utf8.encode(rawKey)).bytes.sublist(0, 16);
    final key = encrypt.Key(Uint8List.fromList(keyBytes));

    // Generate a secure random 16-byte IV
    final random = Random.secure();
    final ivBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final iv = encrypt.IV(ivBytes);

    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
    );
    final encrypted = encrypter.encrypt(value, iv: iv);

    final combined = Uint8List(16 + encrypted.bytes.length);
    combined.setRange(0, 16, ivBytes);
    combined.setRange(16, combined.length, encrypted.bytes);

    final cipherText = base64.encode(combined);

    print('\n----------------------------------------');
    print('Original Value: $value');
    print('Encryption Key: $rawKey');
    print('Encrypted Ciphertext (Paste into Firebase Realtime Database):');
    print(cipherText);
    print('----------------------------------------\n');
  } catch (e) {
    print('Error during encryption: $e');
    exit(1);
  }
}
