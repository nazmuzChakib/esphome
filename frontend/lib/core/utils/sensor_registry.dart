import 'package:flutter/material.dart';

// ============================================================================
// SENSOR REGISTRY — Universal Sensor Metadata
// Add new sensor definitions here to support any new sensor without app update.
// Firebase node data just needs a 'sensorReadings' map with matching keys.
// ============================================================================

class SensorDefinition {
  final String key;
  final String label;
  final String unit;
  final IconData icon;
  final Color color;
  final double? min;
  final double? max;
  final int decimalPlaces;

  const SensorDefinition({
    required this.key,
    required this.label,
    required this.unit,
    required this.icon,
    required this.color,
    this.min,
    this.max,
    this.decimalPlaces = 1,
  });

  /// Format a reading value for display
  String formatValue(dynamic raw) {
    if (raw == null) return '--';
    final num val = (raw is num) ? raw : num.tryParse(raw.toString()) ?? 0;
    return '${val.toStringAsFixed(decimalPlaces)} $unit';
  }

  /// Returns a normalized 0.0–1.0 progress value (for gauges), clamped.
  double normalizeValue(dynamic raw) {
    if (raw == null || min == null || max == null) return 0.0;
    final double val = (raw is num) ? raw.toDouble() : double.tryParse(raw.toString()) ?? 0.0;
    return ((val - min!) / (max! - min!)).clamp(0.0, 1.0);
  }
}

class SensorRegistry {
  SensorRegistry._();

  /// Known sensor definitions, keyed by sensor key string.
  static const Map<String, SensorDefinition> _sensors = {
    'temperature': SensorDefinition(
      key: 'temperature',
      label: 'Temperature',
      unit: '°C',
      icon: Icons.thermostat_rounded,
      color: Color(0xFFFF7849),
      min: -10,
      max: 60,
      decimalPlaces: 1,
    ),
    'humidity': SensorDefinition(
      key: 'humidity',
      label: 'Humidity',
      unit: '%',
      icon: Icons.water_drop_rounded,
      color: Color(0xFF38BDF8),
      min: 0,
      max: 100,
      decimalPlaces: 1,
    ),
    'current': SensorDefinition(
      key: 'current',
      label: 'Current',
      unit: 'A',
      icon: Icons.bolt_rounded,
      color: Color(0xFFFACC15),
      min: 0,
      max: 20,
      decimalPlaces: 2,
    ),
    'voltage': SensorDefinition(
      key: 'voltage',
      label: 'Voltage',
      unit: 'V',
      icon: Icons.electrical_services_rounded,
      color: Color(0xFFFF6B6B),
      min: 0,
      max: 250,
      decimalPlaces: 1,
    ),
    'power': SensorDefinition(
      key: 'power',
      label: 'Power',
      unit: 'W',
      icon: Icons.power_rounded,
      color: Color(0xFFE879F9),
      min: 0,
      max: 5000,
      decimalPlaces: 1,
    ),
    'gas': SensorDefinition(
      key: 'gas',
      label: 'Gas Level',
      unit: 'ppm',
      icon: Icons.air_rounded,
      color: Color(0xFFA16207),
      min: 0,
      max: 1000,
      decimalPlaces: 0,
    ),
    'smoke': SensorDefinition(
      key: 'smoke',
      label: 'Smoke',
      unit: 'ppm',
      icon: Icons.cloud_rounded,
      color: Color(0xFF78716C),
      min: 0,
      max: 1000,
      decimalPlaces: 0,
    ),
    'pressure': SensorDefinition(
      key: 'pressure',
      label: 'Pressure',
      unit: 'hPa',
      icon: Icons.compress_rounded,
      color: Color(0xFF2DD4BF),
      min: 870,
      max: 1085,
      decimalPlaces: 1,
    ),
    'light': SensorDefinition(
      key: 'light',
      label: 'Light',
      unit: 'lux',
      icon: Icons.wb_sunny_rounded,
      color: Color(0xFFFDE047),
      min: 0,
      max: 100000,
      decimalPlaces: 0,
    ),
    'uv': SensorDefinition(
      key: 'uv',
      label: 'UV Index',
      unit: 'UV',
      icon: Icons.light_mode_rounded,
      color: Color(0xFFD946EF),
      min: 0,
      max: 11,
      decimalPlaces: 1,
    ),
    'co2': SensorDefinition(
      key: 'co2',
      label: 'CO₂',
      unit: 'ppm',
      icon: Icons.co2_rounded,
      color: Color(0xFF4ADE80),
      min: 400,
      max: 5000,
      decimalPlaces: 0,
    ),
    'motion': SensorDefinition(
      key: 'motion',
      label: 'Motion',
      unit: '',
      icon: Icons.directions_run_rounded,
      color: Color(0xFFF97316),
      decimalPlaces: 0,
    ),
    'distance': SensorDefinition(
      key: 'distance',
      label: 'Distance',
      unit: 'cm',
      icon: Icons.straighten_rounded,
      color: Color(0xFF818CF8),
      min: 0,
      max: 500,
      decimalPlaces: 1,
    ),
    'soil': SensorDefinition(
      key: 'soil',
      label: 'Soil Moisture',
      unit: '%',
      icon: Icons.grass_rounded,
      color: Color(0xFF4ADE80),
      min: 0,
      max: 100,
      decimalPlaces: 1,
    ),
    'ph': SensorDefinition(
      key: 'ph',
      label: 'pH Level',
      unit: 'pH',
      icon: Icons.science_rounded,
      color: Color(0xFF22D3EE),
      min: 0,
      max: 14,
      decimalPlaces: 2,
    ),
    'wind_speed': SensorDefinition(
      key: 'wind_speed',
      label: 'Wind Speed',
      unit: 'm/s',
      icon: Icons.wind_power_rounded,
      color: Color(0xFF94A3B8),
      min: 0,
      max: 50,
      decimalPlaces: 1,
    ),
  };

  /// Fallback definition for unknown sensor keys
  static SensorDefinition _fallback(String key) => SensorDefinition(
    key: key,
    label: key.replaceAll('_', ' ').toUpperCase(),
    unit: '',
    icon: Icons.sensors_rounded,
    color: const Color(0xFF94A3B8),
    decimalPlaces: 2,
  );

  /// Get a SensorDefinition by key — falls back gracefully if unknown
  static SensorDefinition get(String key) =>
      _sensors[key] ?? _fallback(key);

  /// Returns true if the sensor key is a known registered sensor
  static bool isKnown(String key) => _sensors.containsKey(key);

  /// Returns all known sensor keys
  static List<String> get allKeys => _sensors.keys.toList();
}
