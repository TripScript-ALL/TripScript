import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/card_profile.dart';

class CardProfileStorage {
  static const _cardsKeyPrefix = 'card_profiles';

  String _cardsKey(String? userId) {
    final safeUserId =
        (userId == null || userId.isEmpty) ? 'anonymous' : userId;
    return '${_cardsKeyPrefix}_$safeUserId';
  }

  Future<List<CardProfile>> loadCards({String? userId}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cardsKey(userId));
    if (raw == null || raw.isEmpty) return [];

    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((e) => CardProfile.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.id.isNotEmpty && e.name.isNotEmpty)
        .toList();
  }

  Future<void> saveCards(List<CardProfile> cards, {String? userId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cardsKey(userId),
      jsonEncode(cards.map((e) => e.toJson()).toList()),
    );
  }
}
