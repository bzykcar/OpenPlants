import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TemperatureUnit { celsius, fahrenheit }

class SettingsController with ChangeNotifier {
  static const String _prefsKey = 'app_settings_json_v1';

  final SharedPreferences _prefs;
  Settings _settings;

  SettingsController._(this._prefs, this._settings);

  static Future<SettingsController> load({SharedPreferences? prefs}) async {
    final preferences = prefs ?? await SharedPreferences.getInstance();

    final raw = preferences.getString(_prefsKey);
    Settings settings = const Settings();

    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        settings = Settings.fromJson(Map<String, dynamic>.from(decoded as Map));
      } catch (_) {
        settings = const Settings();
      }
    }

    return SettingsController._(preferences, settings);
  }

  Settings get settings => _settings;

  Future<void> update(Settings newSettings) async {
    final raw = jsonEncode(newSettings.toJson());
    final saved = await _prefs.setString(_prefsKey, raw);
    if (!saved) throw StateError('Failed to persist "$_prefsKey" to SharedPreferences.');

    _settings = newSettings;
    notifyListeners();
  }
}

class Settings {
  static const Object _noChange = Object();

  final bool useSystemDarkmode;
  final bool useDarkmode;
  final bool useSystemTextScaling;
  final bool didCompleteOnboarding;
  final String? localeCode;
  final TemperatureUnit temperatureUnit;
  final bool notificationsEnabled;
  final bool notifyDueTasks;
  final bool notifyOverdueTasks;

  /// AI diagnosis provider: `gemini`, `claude`, or null when AI is not configured.
  final String? aiProvider;

  /// API key for the selected AI provider. Stored locally on the device only.
  final String? aiApiKey;

  /// Optional model override. When null or empty, the provider default is used.
  final String? aiModel;

  const Settings({
    this.useSystemDarkmode = true,
    this.useDarkmode = false,
    this.useSystemTextScaling = true,
    this.didCompleteOnboarding = false,
    this.localeCode,
    this.temperatureUnit = TemperatureUnit.celsius,
    this.notificationsEnabled = true,
    this.notifyDueTasks = true,
    this.notifyOverdueTasks = true,
    this.aiProvider,
    this.aiApiKey,
    this.aiModel,
  });

  Settings copyWith({
    bool? useSystemDarkmode,
    bool? useDarkmode,
    bool? useSystemTextScaling,
    bool? didCompleteOnboarding,
    Object? localeCode = _noChange,
    TemperatureUnit? temperatureUnit,
    bool? notificationsEnabled,
    bool? notifyDueTasks,
    bool? notifyOverdueTasks,
    Object? aiProvider = _noChange,
    Object? aiApiKey = _noChange,
    Object? aiModel = _noChange,
  }) {
    return Settings(
      useSystemDarkmode: useSystemDarkmode ?? this.useSystemDarkmode,
      useDarkmode: useDarkmode ?? this.useDarkmode,
      useSystemTextScaling: useSystemTextScaling ?? this.useSystemTextScaling,
      didCompleteOnboarding: didCompleteOnboarding ?? this.didCompleteOnboarding,
      localeCode: identical(localeCode, _noChange) ? this.localeCode : localeCode as String?,
      temperatureUnit: temperatureUnit ?? this.temperatureUnit,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      notifyDueTasks: notifyDueTasks ?? this.notifyDueTasks,
      notifyOverdueTasks: notifyOverdueTasks ?? this.notifyOverdueTasks,
      aiProvider: identical(aiProvider, _noChange) ? this.aiProvider : aiProvider as String?,
      aiApiKey: identical(aiApiKey, _noChange) ? this.aiApiKey : aiApiKey as String?,
      aiModel: identical(aiModel, _noChange) ? this.aiModel : aiModel as String?,
    );
  }

  factory Settings.fromJson(Map<String, dynamic> json) {
    return Settings(
      useSystemDarkmode: json['useSystemDarkmode'] ?? true,
      useDarkmode: json['useDarkmode'] ?? false,
      useSystemTextScaling: json['useSystemTextScaling'] ?? true,
      didCompleteOnboarding: json['didCompleteOnboarding'] ?? false,
      localeCode: json['localeCode'],
      temperatureUnit: json['temperatureUnit'] == 'fahrenheit' ? TemperatureUnit.fahrenheit : TemperatureUnit.celsius,
      notificationsEnabled: json['notificationsEnabled'] ?? true,
      notifyDueTasks: json['notifyDueTasks'] ?? true,
      notifyOverdueTasks: json['notifyOverdueTasks'] ?? true,
      aiProvider: json['aiProvider'] as String?,
      aiApiKey: json['aiApiKey'] as String?,
      aiModel: json['aiModel'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'useSystemDarkmode': useSystemDarkmode,
      'useDarkmode': useDarkmode,
      'useSystemTextScaling': useSystemTextScaling,
      'didCompleteOnboarding': didCompleteOnboarding,
      'localeCode': localeCode,
      'temperatureUnit': temperatureUnit == TemperatureUnit.fahrenheit ? 'fahrenheit' : 'celsius',
      'notificationsEnabled': notificationsEnabled,
      'notifyDueTasks': notifyDueTasks,
      'notifyOverdueTasks': notifyOverdueTasks,
      'aiProvider': aiProvider,
      'aiApiKey': aiApiKey,
      'aiModel': aiModel,
    };
  }
}
