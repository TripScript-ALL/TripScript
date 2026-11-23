import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import '../config/dev_seed.dart';
import '../models/receipt.dart';
import '../models/trip.dart';
import '../models/user.dart';
import '../services/api_service.dart';

/// 원격 영수증에 `items`가 비어 있으면, 동일 id의 로컬 품목을 유지합니다.
List<Receipt> _mergeReceiptItemsPreserveLocal(
  List<Receipt> previous,
  List<Receipt> next,
) {
  return next.map((r) {
    for (final x in previous) {
      if (x.id != r.id) continue;
      if (r.items.isNotEmpty) return r;
      if (x.items.isNotEmpty) return r.copyWith(items: x.items);
      break;
    }
    return r;
  }).toList();
}

class TripProvider with ChangeNotifier {
  TripProvider(this._api);

  final ApiService _api;
  final _uuid = const Uuid();

  List<Trip> _trips = [];
  List<Trip> get trips => List.unmodifiable(_trips);

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  String? _userId;

  /// 사용자 ID 설정 후 여행 목록 로드
  void setUserId(String? userId) {
    _userId = userId;
  }

  Future<void> loadTrips() async {
    if (_userId == null || _userId!.isEmpty) {
      _trips = [];
      notifyListeners();
      return;
    }

    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _trips = await _api.getTrips(_userId!);
      if (AppConfig.isDeveloperMode && _trips.isEmpty) {
        _trips = [kDefaultDevTrip()];
      }
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> addTrip({
    required String name,
    required DateTime startDate,
    required DateTime endDate,
    required List<String> participants,
    required String hostName,
    List<String> countries = const [],
    int? tileColor,
    String? coverImagePath,
  }) async {
    if (_userId == null) return;

    final trip = Trip(
      id: _uuid.v4(),
      name: name,
      startDate: startDate,
      endDate: endDate,
      participants: participants,
      countries: countries,
      hostName: hostName,
      inviteCode: _uuid.v4().replaceAll('-', '').substring(0, 6).toUpperCase(),
      tileColor: tileColor,
      coverImagePath: coverImagePath,
    );
    try {
      final saved = await _api.saveTrip(_userId!, trip);
      _trips.insert(0, saved);
      notifyListeners();
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateTrip(Trip trip) async {
    if (_userId == null) return;

    try {
      final updated = await _api.updateTrip(_userId!, trip);
      final i = _trips.indexWhere((t) => t.id == trip.id);
      if (i >= 0) {
        _trips[i] = updated;
      }
      notifyListeners();
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteTrip(String id) async {
    if (_userId == null) return;

    try {
      await _api.deleteTrip(_userId!, id);
      _trips.removeWhere((t) => t.id == id);
      notifyListeners();
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  Trip? getTrip(String id) {
    for (final trip in _trips) {
      if (trip.id == id) return trip;
    }
    return null;
  }

  void replaceParticipantAliases(Set<String> oldNames, String newName) {
    final aliases =
        oldNames.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    final target = newName.trim();
    if (aliases.isEmpty || target.isEmpty) return;

    String replaceName(String value) {
      final text = value.trim();
      return aliases.contains(text) ? target : value;
    }

    Map<String, double> replaceQuantityMap(Map<String, double> values) {
      final out = <String, double>{};
      for (final entry in values.entries) {
        final key = replaceName(entry.key);
        out[key] = (out[key] ?? 0) + entry.value;
      }
      return out;
    }

    _trips = _trips.map((trip) {
      final receipts = trip.receipts.map((receipt) {
        final items = receipt.items
            .map((item) => item.copyWith(
                  quantityByPerson: replaceQuantityMap(item.quantityByPerson),
                ))
            .toList();
        return receipt.copyWith(
          paidBy: replaceName(receipt.paidBy),
          items: items,
        );
      }).toList();
      return trip.copyWith(
        hostName: replaceName(trip.hostName),
        participants: trip.participants.map(replaceName).toSet().toList(),
        receipts: receipts,
      );
    }).toList();
    notifyListeners();
  }

  Future<void> addParticipant(String tripId, String name) async {
    final trip = getTrip(tripId);
    final trimmed = name.trim();
    if (trip == null ||
        trimmed.isEmpty ||
        trip.participants.contains(trimmed)) {
      return;
    }
    await updateTrip(
      trip.copyWith(participants: [...trip.participants, trimmed]),
    );
  }

  Future<void> removeParticipant(String tripId, String name) async {
    final trip = getTrip(tripId);
    if (trip == null || name == trip.hostName) return;
    final next = trip.participants.where((p) => p != name).toList();
    await updateTrip(trip.copyWith(participants: next));
  }

  Future<void> leaveTrip(String tripId, User user) async {
    final trip = getTrip(tripId);
    if (trip == null ||
        user.matchesParticipantName(trip.hostName) ||
        _userId == null) {
      return;
    }
    try {
      await _api.leaveTrip(_userId!, tripId);
      _trips.removeWhere((t) => t.id == tripId);
      notifyListeners();
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
      rethrow;
    }
  }

  Future<Trip?> joinTripByInviteCode({
    required String inviteCode,
    required String userName,
  }) async {
    final code = inviteCode.trim().toUpperCase();
    final trimmedName = userName.trim();
    if (code.isEmpty || trimmedName.isEmpty || _userId == null) return null;

    try {
      final saved = await _api.joinTripByInviteCode(_userId!, code);
      final i = _trips.indexWhere((t) => t.id == saved.id);
      if (i >= 0) {
        _trips[i] = saved;
      } else {
        _trips.insert(0, saved);
      }
      notifyListeners();
      return saved;
    } on ApiException {
      rethrow;
    }
  }

  /// 백엔드 `GET .../trips/{tripId}/receipts`로 품목까지 포함한 영수증 목록을 받아 반영합니다.
  Future<void> loadReceiptsForTrip(String tripId) async {
    if (_userId == null || _userId!.isEmpty) return;

    final i = _trips.indexWhere((t) => t.id == tripId);
    if (i < 0) return;

    try {
      final previous = _trips[i].receipts;
      final receipts = await _api.getReceipts(_userId!, tripId);
      final merged = _mergeReceiptItemsPreserveLocal(previous, receipts);
      _trips[i] = _trips[i].copyWith(receipts: merged);
      notifyListeners();
    } on ApiException {
      // 목록 전용 API가 없거나 오류면 기존(여행 임베드) 데이터 유지
    }
  }

  Future<Receipt?> addReceipt(String tripId, Receipt receipt) async {
    final trip = getTrip(tripId);
    if (trip == null || _userId == null) return null;

    final newReceipt =
        receipt.id.isEmpty ? receipt.copyWith(id: _uuid.v4()) : receipt;
    final saved = await _api.createReceipt(_userId!, tripId, newReceipt);
    final i = _trips.indexWhere((t) => t.id == tripId);
    if (i >= 0) {
      _trips[i] = trip.copyWith(receipts: [...trip.receipts, saved]);
      notifyListeners();
    }
    return saved;
  }

  Future<void> updateReceipt(String tripId, Receipt receipt) async {
    final trip = getTrip(tripId);
    if (trip == null || _userId == null) return;

    final saved = await _api.updateReceipt(_userId!, tripId, receipt);
    final receipts = trip.receipts.map((r) {
      return r.id == receipt.id ? saved : r;
    }).toList();
    final i = _trips.indexWhere((t) => t.id == tripId);
    if (i >= 0) {
      _trips[i] = trip.copyWith(receipts: receipts);
      notifyListeners();
    }
  }

  Future<void> deleteReceipt(String tripId, String receiptId) async {
    final trip = getTrip(tripId);
    if (trip == null || _userId == null) return;

    await _api.deleteReceiptItem(_userId!, tripId, receiptId);
    final receipts = trip.receipts.where((r) => r.id != receiptId).toList();
    final i = _trips.indexWhere((t) => t.id == tripId);
    if (i >= 0) {
      _trips[i] = trip.copyWith(receipts: receipts);
      notifyListeners();
    }
  }
}
