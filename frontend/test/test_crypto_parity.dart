import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

List<int> deriveSessionKey(String apiKey, String timestamp) {
  final keyBytes = utf8.encode(apiKey);
  final msgBytes = utf8.encode(timestamp);
  final hmac = Hmac(sha256, keyBytes);
  final digest = hmac.convert(msgBytes);
  return digest.bytes.sublist(0, 16); // Extract first 16 bytes for AES-128 Key
}

String decryptPayload(String base64Payload, List<int> keyBytes) {
  final combinedBytes = base64.decode(base64Payload);
  if (combinedBytes.length < 32) throw Exception("Invalid payload length");

  final ivBytes = combinedBytes.sublist(0, 16);
  final cipherBytes = combinedBytes.sublist(16);

  final key = encrypt.Key(Uint8List.fromList(keyBytes));
  final iv = encrypt.IV(Uint8List.fromList(ivBytes));

  final encrypter = encrypt.Encrypter(encrypt.AES(key, mode: encrypt.AESMode.cbc, padding: 'PKCS7'));
  return encrypter.decrypt(encrypt.Encrypted(cipherBytes), iv: iv);
}

void main() {
  const apiKey = "ESPHome_sec_node";
  const timestamp = "1716900000";
  const payload = "4gdv6Cct+oS5ufPNhABS55JU6qSW2sXuu+Ea7LleVlQSafuqmL/GkUNU3TtFPGpWyq/FHSJ9axUVOy+DTwUBkw==";

  try {
    final keyBytes = deriveSessionKey(apiKey, timestamp);
    print("Derived Key (Hex): ${keyBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}");
    final decrypted = decryptPayload(payload, keyBytes);
    print("Decrypted Plaintext: $decrypted");
  } catch (e) {
    print("Decryption Failed: $e");
  }
}
