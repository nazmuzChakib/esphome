import 'dart:convert';
import 'dart:io' show File;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

class AvatarHelper {
  /// Renders a profile image from Base64 string, HTTP/HTTPS URL, or local file path.
  static Widget buildAvatarImage({
    required String? photoUrl,
    required double width,
    required double height,
    required Widget Function() placeholderBuilder,
  }) {
    if (photoUrl == null || photoUrl.trim().isEmpty) {
      return placeholderBuilder();
    }

    final trimmed = photoUrl.trim();

    // 1. Data URL Base64 format: data:image/jpeg;base64,...
    if (trimmed.startsWith('data:image')) {
      try {
        final base64Str = trimmed.split(',').last;
        final bytes = base64Decode(base64Str);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          width: width,
          height: height,
          errorBuilder: (context, error, stackTrace) => placeholderBuilder(),
        );
      } catch (_) {
        return placeholderBuilder();
      }
    }

    // 2. HTTP / HTTPS Network URL
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return Image.network(
        trimmed,
        fit: BoxFit.cover,
        width: width,
        height: height,
        errorBuilder: (context, error, stackTrace) => placeholderBuilder(),
      );
    }

    // 3. Raw Base64 string (without data URL header)
    if (!trimmed.contains('/') && !trimmed.contains('\\') && trimmed.length > 50) {
      try {
        final bytes = base64Decode(trimmed);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          width: width,
          height: height,
          errorBuilder: (context, error, stackTrace) => placeholderBuilder(),
        );
      } catch (_) {}
    }

    // 4. Local File Path (Mobile / Desktop)
    if (!kIsWeb) {
      try {
        final file = File(trimmed);
        if (file.existsSync()) {
          return Image.file(
            file,
            fit: BoxFit.cover,
            width: width,
            height: height,
            errorBuilder: (context, error, stackTrace) => placeholderBuilder(),
          );
        }
      } catch (_) {}
    }

    return placeholderBuilder();
  }
}
