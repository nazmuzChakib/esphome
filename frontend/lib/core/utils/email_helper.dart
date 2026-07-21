import 'dart:convert';
import 'package:crypto/crypto.dart';

class EmailHelper {
  /// Normalizes an email address to handle casing, spaces, and Gmail variations
  /// (dots and plus aliases) so that different aliases of the same Gmail address
  /// resolve to the same user profile.
  static String normalizeEmail(String email) {
    String clean = email.trim().toLowerCase();
    if (clean.isEmpty) return clean;

    final parts = clean.split('@');
    if (parts.length != 2) return clean;

    String local = parts[0];
    String domain = parts[1];

    // Standardize googlemail.com to gmail.com
    if (domain == 'googlemail.com') {
      domain = 'gmail.com';
    }

    if (domain == 'gmail.com') {
      // Remove plus aliases (e.g., user+alias -> user)
      final plusIndex = local.indexOf('+');
      if (plusIndex != -1) {
        local = local.substring(0, plusIndex);
      }
      // Remove all dots in the local part (e.g., u.s.e.r -> user)
      local = local.replaceAll('.', '');
    }

    return '$local@$domain';
  }

  /// Hashes a normalized email address using SHA-256.
  static String hashEmail(String email) {
    final normalized = normalizeEmail(email);
    return sha256.convert(utf8.encode(normalized)).toString();
  }
}
