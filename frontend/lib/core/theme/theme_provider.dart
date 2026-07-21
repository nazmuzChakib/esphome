import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.dark) {
    _loadTheme();
  }

  void _loadTheme() async {
    final box = await Hive.openBox('settings');
    final isDark = box.get('isDark', defaultValue: true);
    state = isDark ? ThemeMode.dark : ThemeMode.light;
  }

  void toggleTheme() async {
    final box = await Hive.openBox('settings');
    if (state == ThemeMode.dark) {
      state = ThemeMode.light;
      await box.put('isDark', false);
    } else {
      state = ThemeMode.dark;
      await box.put('isDark', true);
    }
  }
}
