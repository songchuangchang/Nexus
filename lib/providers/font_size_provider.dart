import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FontSizeProvider extends ChangeNotifier {
  static const String _prefsKey = 'font_scale';
  static const double minScale = 0.8;
  static const double maxScale = 2.0;
  static const double defaultScale = 1.0;

  double _scale = defaultScale;

  double get scale => _scale;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _scale = prefs.getDouble(_prefsKey) ?? defaultScale;
    _scale = _scale.clamp(minScale, maxScale);
    notifyListeners();
  }

  Future<void> setScale(double value) async {
    _scale = value.clamp(minScale, maxScale);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsKey, _scale);
    notifyListeners();
  }
}
