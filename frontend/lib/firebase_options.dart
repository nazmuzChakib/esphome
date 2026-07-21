// File generated based on google-services.json.
// For web: Register your app in Firebase Console → Project Settings → Add App → Web
// and replace the web section values below with your actual web config.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for ios - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for macos - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.windows:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for windows - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Web Configuration
  // TODO: Replace these placeholder values with your actual Firebase Web App
  // config from: Firebase Console → Project Settings → Your Apps → Web App
  // ─────────────────────────────────────────────────────────────────────────
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBHQg2P86k3c3TD7dGFMHfQeQOQQfXAD6o',
    appId: '1:411704416028:web:ed0a33399763fb0b674cd9',
    messagingSenderId: '411704416028',
    projectId: 'esphome-adacodec',
    authDomain: 'esphome-adacodec.firebaseapp.com',
    databaseURL:
        'https://esphome-adacodec-default-rtdb.asia-southeast1.firebasedatabase.app',
    storageBucket: 'esphome-adacodec.firebasestorage.app',
  );

  // ─────────────────────────────────────────────────────────────────────────
  // Android Configuration (from google-services.json)
  // ─────────────────────────────────────────────────────────────────────────
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBHQg2P86k3c3TD7dGFMHfQeQOQQfXAD6o',
    appId: '1:411704416028:android:a4a24455fcb1ff44674cd9',
    messagingSenderId: '411704416028',
    projectId: 'esphome-adacodec',
    databaseURL:
        'https://esphome-adacodec-default-rtdb.asia-southeast1.firebasedatabase.app',
    storageBucket: 'esphome-adacodec.firebasestorage.app',
  );
}
