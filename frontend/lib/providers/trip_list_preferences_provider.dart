import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TripListPreferencesProvider with ChangeNotifier {
  static const _viewModeKey = 'trip_list_view_mode';

  bool _gridMode = true;
  bool get gridMode => _gridMode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _gridMode = prefs.getString(_viewModeKey) != 'list';
    notifyListeners();
  }

  Future<void> setGridMode(bool value) async {
    if (_gridMode == value) return;
    _gridMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_viewModeKey, value ? 'grid' : 'list');
  }
}
