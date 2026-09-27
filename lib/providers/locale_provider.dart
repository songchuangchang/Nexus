import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocaleProvider extends ChangeNotifier {
  Locale? _locale;
  static const String _prefsKey = 'app_locale';
  static const String _onboardingKey = 'onboarding_completed';

  Locale? get locale => _locale;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefsKey);
    if (code != null && (code == 'zh' || code == 'en')) {
      _locale = Locale(code);
    } else {
      _locale = null; // use system default until user chooses
    }
    notifyListeners();
  }

  bool get hasChosen => _locale != null;

  Future<bool> get isOnboardingCompleted async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_onboardingKey) ?? false;
  }

  Future<void> setLocale(Locale locale) async {
    _locale = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, locale.languageCode);
    notifyListeners();
  }

  /// v1.6.5：设置页语言切换的「跟随系统」选项——清空已选语言，回落系统语言
  Future<void> setSystemLocale() async {
    _locale = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingKey, true);
  }
}
