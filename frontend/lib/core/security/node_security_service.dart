import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_riverpod/flutter_riverpod.dart';

const String kDefaultApiKey = 'esphome_secure_default_key_2026';

final nodeSecurityServiceProvider = Provider<NodeSecurityService>((ref) {
  return NodeSecurityService();
});

class NodeSecurityService {
  /// Derive Session Key K1 (16 bytes) using HMAC-SHA256(api_key, timestamp_str)
  Uint8List deriveSessionKey(String apiKey, String timestamp) {
    final keyBytes = utf8.encode(apiKey.isEmpty ? kDefaultApiKey : apiKey);
    final msgBytes = utf8.encode(timestamp);
    final hmac = Hmac(sha256, keyBytes);
    final digest = hmac.convert(msgBytes);
    return Uint8List.fromList(digest.bytes.sublist(0, 16));
  }

  /// Encrypt JSON payload string into formatted WebSocket frame: "[Timestamp]:[Base64(IV || Ciphertext)]"
  String createEncryptedFrame({
    required Map<String, dynamic> payload,
    required String targetMac,
    String? apiKey,
    int? customTimestamp,
  }) {
    final nowSeconds =
        customTimestamp ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final timestampStr = nowSeconds.toString();
    final effectiveApiKey = (apiKey != null && apiKey.isNotEmpty)
        ? apiKey
        : kDefaultApiKey;

    // Inject mac4 identifier if targetMac is provided
    final enrichedPayload = Map<String, dynamic>.from(payload);
    if (targetMac.isNotEmpty) {
      final cleanMac = targetMac.replaceAll(':', '').toUpperCase();
      final mac4 = cleanMac.length >= 4
          ? cleanMac.substring(cleanMac.length - 4)
          : cleanMac;
      enrichedPayload['mac4'] = mac4;
    }
    enrichedPayload['ts'] = nowSeconds;

    final plainText = jsonEncode(enrichedPayload);
    final keyBytes = deriveSessionKey(effectiveApiKey, timestampStr);

    // Generate secure random 16-byte IV
    final random = Random.secure();
    final ivBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    final iv = encrypt.IV(ivBytes);
    final key = encrypt.Key(keyBytes);

    final encrypter = encrypt.Encrypter(
      encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
    );
    final encrypted = encrypter.encrypt(plainText, iv: iv);

    final combined = Uint8List(16 + encrypted.bytes.length);
    combined.setRange(0, 16, ivBytes);
    combined.setRange(16, combined.length, encrypted.bytes);

    final base64Payload = base64.encode(combined);
    return '$timestampStr:$base64Payload';
  }

  /// Decrypt formatted frame "[Timestamp]:[Base64(IV || Ciphertext)]" back into `Map<String, dynamic>`

  Map<String, dynamic>? decryptEncryptedFrame({
    required String frame,
    String? apiKey,
    bool checkReplayWindow = true,
  }) {
    final colonIdx = frame.indexOf(':');
    if (colonIdx == -1) return null;

    final timestampStr = frame.substring(0, colonIdx);
    final base64Payload = frame.substring(colonIdx + 1);

    final msgTimestamp = int.tryParse(timestampStr);
    if (msgTimestamp == null) return null;

    // Replay Protection: Check ±30 seconds time window
    if (checkReplayWindow) {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if ((nowSeconds - msgTimestamp).abs() > 30) {
        return null; // Rejected due to replay window expiry
      }
    }

    final effectiveApiKey = (apiKey != null && apiKey.isNotEmpty)
        ? apiKey
        : kDefaultApiKey;
    final keyBytes = deriveSessionKey(effectiveApiKey, timestampStr);

    try {
      final combinedBytes = base64.decode(base64Payload);
      if (combinedBytes.length < 32) return null;

      final ivBytes = combinedBytes.sublist(0, 16);
      final cipherBytes = combinedBytes.sublist(16);

      final key = encrypt.Key(keyBytes);
      final iv = encrypt.IV(Uint8List.fromList(ivBytes));

      final encrypter = encrypt.Encrypter(
        encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'),
      );
      final decryptedStr = encrypter.decrypt(
        encrypt.Encrypted(cipherBytes),
        iv: iv,
      );
      final decoded = jsonDecode(decryptedStr);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
