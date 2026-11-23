import 'package:dio/dio.dart';

import '../models/card_profile.dart';
import '../models/payment_fee_catalog.dart';
import '../models/receipt.dart';
import '../models/settlement_summary.dart';
import '../models/trip.dart';
import '../models/user.dart';
import 'api_service.dart';
import '../utils/payment_estimator.dart';

/// `docs/rest_api.md` 기준 실제 REST 백엔드 클라이언트.
///
/// Base URL 빌드 시:
/// `flutter run --dart-define=API_BASE_URL=https://xxx.ngrok-free.dev/api/v1`
/// 인증 토큰은 로그인 응답으로만 받습니다. 빌드 설정에 넣지 마세요.
class RestApiService extends ApiService {
  RestApiService({
    String? baseUrl,
    String? accessToken,
    Duration connectTimeout = const Duration(seconds: 15),
    Duration receiveTimeout = const Duration(seconds: 30),
  }) : _dio = Dio(
          BaseOptions(
            baseUrl: _normalizeBaseUrl(baseUrl ?? _baseUrlFromEnvironment()),
            connectTimeout: connectTimeout,
            receiveTimeout: receiveTimeout,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'ngrok-skip-browser-warning': 'true',
            },
          ),
        ) {
    if (accessToken != null && accessToken.isNotEmpty) {
      setAuthToken(accessToken);
    }
  }

  static String _baseUrlFromEnvironment() {
    const raw = String.fromEnvironment('API_BASE_URL');
    if (raw.isNotEmpty) {
      return raw;
    }
    return 'http://127.0.0.1:8000/api/v1';
  }

  /// 항상 끝에 `/` 두어 Dio가 `users/lookup` 과 올바르게 결합하게 함.
  static String _normalizeBaseUrl(String raw) =>
      raw.endsWith('/') ? raw : '$raw/';

  final Dio _dio;
  String? _authToken;

  @override
  void setAuthToken(String? token) {
    _authToken = token == null || token.isEmpty
        ? null
        : token.trim().isEmpty
            ? null
            : token.trim();
    if (_authToken != null) {
      _dio.options.headers['Authorization'] = 'Bearer $_authToken';
    } else {
      _dio.options.headers.remove('Authorization');
    }
  }

  @override
  void clearAuthToken() => setAuthToken(null);

  @override
  String? get authToken => _authToken;

  void _consumeAuthPayload(dynamic data) {
    if (data is! Map) return;
    final map = Map<String, dynamic>.from(data);
    final nested = map['data'];
    final dataMap = nested is Map<String, dynamic> ? nested : null;
    final t = map['accessToken'] as String? ??
        map['token'] as String? ??
        dataMap?['accessToken'] as String?;
    if (t != null && t.isNotEmpty) setAuthToken(t);
  }

  User _userFromResponseMap(Map<String, dynamic> map) {
    final filtered = Map<String, dynamic>.from(map)
      ..remove('accessToken')
      ..remove('token');
    return User.fromJson(filtered);
  }

  ApiException _fromDio(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      final msg = err['message'] as String?;
      if (msg != null && msg.isNotEmpty) {
        return ApiException(_friendlyApiMessage(msg));
      }
      final code = err['code']?.toString();
      if (code != null) {
        return ApiException(_friendlyApiMessage(code));
      }
    }
    if (data is Map && data['detail'] != null) {
      return ApiException(_friendlyApiMessage(data['detail'].toString()));
    }
    final statusCode = e.response?.statusCode;
    if (statusCode == 401) {
      return ApiException('로그인 세션이 만료되었습니다. 다시 로그인해 주세요.');
    }
    if (statusCode == 403) {
      return ApiException('이 작업을 수행할 권한이 없습니다.');
    }
    if (statusCode == 408 || statusCode == 504) {
      return ApiException('서버 응답이 지연되고 있습니다. 잠시 뒤 다시 시도해 주세요.');
    }
    if (statusCode == 429) {
      return ApiException('요청 한도에 잠시 걸렸습니다. 잠시 뒤 다시 시도해 주세요.');
    }
    if (statusCode == 503) {
      return ApiException('서버가 잠시 응답하지 않습니다. ngrok 또는 백엔드 서버 상태를 확인해 주세요.');
    }
    if (statusCode != null) {
      return ApiException('서버 오류 ($statusCode)');
    }
    final dioType = e.type;
    if (dioType == DioExceptionType.connectionTimeout ||
        dioType == DioExceptionType.receiveTimeout ||
        dioType == DioExceptionType.sendTimeout) {
      return ApiException('서버 응답이 지연되고 있습니다. 네트워크 상태를 확인해 주세요.');
    }
    if (dioType == DioExceptionType.connectionError) {
      return ApiException('서버에 연결할 수 없습니다. ngrok 또는 백엔드 서버 상태를 확인해 주세요.');
    }
    if (e.message != null && e.message!.isNotEmpty) {
      return ApiException(_friendlyApiMessage(e.message!));
    }
    return ApiException('네트워크 오류');
  }

  String _friendlyApiMessage(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('resource_exhausted') ||
        lower.contains('quota exceeded') ||
        lower.contains('free_tier_requests') ||
        lower.contains('gemini receipt parser failed: http 429')) {
      final retryMatch = RegExp(
        r'retry in\s+([0-9.]+)s',
        caseSensitive: false,
      ).firstMatch(raw);
      if (retryMatch != null) {
        final seconds = double.tryParse(retryMatch.group(1) ?? '');
        if (seconds != null) {
          return 'Gemini 무료 인식 한도에 잠시 걸렸습니다. 약 ${seconds.ceil()}초 뒤 다시 시도해 주세요.';
        }
      }
      return 'Gemini 무료 인식 한도를 초과했습니다. 잠시 뒤 다시 시도해 주세요.';
    }
    return raw;
  }

  bool _isRetryableNetworkError(DioException e) {
    final statusCode = e.response?.statusCode;
    if (statusCode == null) return true;
    return statusCode == 408 || statusCode == 429 || statusCode >= 500;
  }

  List<Trip> _parseTripList(dynamic data) {
    late final List<dynamic> raw;
    if (data is List) {
      raw = List<dynamic>.from(data);
    } else if (data is Map<String, dynamic> && data['items'] is List) {
      raw = List<dynamic>.from(data['items'] as List<dynamic>);
    } else {
      throw ApiException('여행 목록 형식을 해석할 수 없습니다.');
    }
    return raw.map((e) => Trip.fromJson(e as Map<String, dynamic>)).toList();
  }

  List<Receipt> _parseReceiptList(dynamic data) {
    late final List<dynamic> raw;
    if (data is List) {
      raw = List<dynamic>.from(data);
    } else if (data is Map<String, dynamic> && data['items'] is List) {
      raw = List<dynamic>.from(data['items'] as List<dynamic>);
    } else {
      throw ApiException('영수증 목록 형식을 해석할 수 없습니다.');
    }
    return raw.map((e) => Receipt.fromJson(e as Map<String, dynamic>)).toList();
  }

  List<CardProfile> _parseCardProfileList(dynamic data) {
    late final List<dynamic> raw;
    if (data is List) {
      raw = List<dynamic>.from(data);
    } else if (data is Map<String, dynamic> && data['items'] is List) {
      raw = List<dynamic>.from(data['items'] as List<dynamic>);
    } else {
      throw ApiException('카드 목록 형식을 해석할 수 없습니다.');
    }
    return raw
        .map((e) => CardProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<User> getCurrentUser() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('me');
      if (response.statusCode == 200 && response.data != null) {
        _consumeAuthPayload(response.data);
        return _userFromResponseMap(response.data!);
      }
      throw ApiException('사용자 정보를 불러오지 못했습니다.');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<User> loginWithKakaoAccessToken(String kakaoAccessToken) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'auth/kakao',
        data: {'accessToken': kakaoAccessToken},
      );
      if (response.statusCode == 200 && response.data != null) {
        _consumeAuthPayload(response.data);
        return _userFromResponseMap(response.data!);
      }
      throw ApiException('카카오 로그인에 실패했습니다.');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<User?> getUserByNameAndPhone(String name, String phoneNumber) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'users/lookup',
        queryParameters: {'name': name, 'phoneNumber': phoneNumber},
      );
      if (response.statusCode == 404) return null;
      if (response.statusCode == 200 && response.data != null) {
        _consumeAuthPayload(response.data);
        return _userFromResponseMap(response.data!);
      }
      return null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw _fromDio(e);
    }
  }

  @override
  Future<User> registerUser({
    required String name,
    required String phoneNumber,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'users',
        data: {'name': name, 'phoneNumber': phoneNumber},
      );
      if (response.statusCode == 201 && response.data != null) {
        _consumeAuthPayload(response.data);
        return _userFromResponseMap(response.data!);
      }
      if (response.statusCode == 409) {
        throw ApiException('이미 등록된 사용자일 수 있습니다.');
      }
      throw ApiException('등록 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<User> updateUser(
    String userId, {
    required String name,
    required String phoneNumber,
    String? nickname,
    String? settlementBankName,
    String? settlementAccountNumber,
    String? settlementAccountHolder,
  }) async {
    try {
      final data = <String, dynamic>{
        'name': name,
        'phoneNumber': phoneNumber,
      };
      if (nickname != null) {
        data['nickname'] = nickname;
      }
      if (settlementBankName != null) {
        data['settlementBankName'] = settlementBankName;
      }
      if (settlementAccountNumber != null) {
        data['settlementAccountNumber'] = settlementAccountNumber;
      }
      if (settlementAccountHolder != null) {
        data['settlementAccountHolder'] = settlementAccountHolder;
      }
      final response = await _dio.patch<Map<String, dynamic>>(
        'users/$userId',
        data: data,
      );
      if (response.statusCode == 200 && response.data != null) {
        return _userFromResponseMap(response.data!);
      }
      throw ApiException('수정 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<void> deleteUser(String userId) async {
    try {
      final response = await _dio.delete<void>('users/$userId');
      if (response.statusCode != 204 && response.statusCode != 200) {
        throw ApiException('회원탈퇴 실패');
      }
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<List<Trip>> getTrips(String userId) async {
    try {
      final response = await _dio.get<dynamic>('users/$userId/trips');
      if (response.statusCode == 200 && response.data != null) {
        return _parseTripList(response.data);
      }
      return [];
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<Trip> saveTrip(String userId, Trip trip) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'users/$userId/trips',
        data: trip.toJson(),
      );
      if (response.statusCode == 201 && response.data != null) {
        return Trip.fromJson(response.data!);
      }
      throw ApiException('저장 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<Trip> updateTrip(String userId, Trip trip) async {
    try {
      final data = trip.toJson()..remove('receipts');
      final response = await _dio.put<Map<String, dynamic>>(
        'users/$userId/trips/${trip.id}',
        data: data,
      );
      if (response.statusCode == 200 && response.data != null) {
        return Trip.fromJson(response.data!);
      }
      throw ApiException('수정 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<void> deleteTrip(String userId, String tripId) async {
    try {
      final response = await _dio.delete<void>('users/$userId/trips/$tripId');
      if (response.statusCode != 204 && response.statusCode != 200) {
        throw ApiException('삭제 실패');
      }
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<void> leaveTrip(String userId, String tripId) async {
    try {
      final response =
          await _dio.post<void>('users/$userId/trips/$tripId/leave');
      if (response.statusCode != 204 && response.statusCode != 200) {
        throw ApiException('나가기 실패');
      }
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<Trip> joinTripByInviteCode(String userId, String inviteCode) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'users/$userId/trips/join',
        data: {'inviteCode': inviteCode},
      );
      if (response.statusCode == 200 && response.data != null) {
        return Trip.fromJson(response.data!);
      }
      throw ApiException('참여 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<List<Receipt>> getReceipts(String userId, String tripId) async {
    try {
      final response = await _dio.get<dynamic>(
        'users/$userId/trips/$tripId/receipts',
      );
      if (response.statusCode == 200 && response.data != null) {
        return _parseReceiptList(response.data);
      }
      return [];
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<String> uploadMedia(String localPath, {required String kind}) async {
    try {
      final data = FormData.fromMap({
        'kind': kind,
        'file': await MultipartFile.fromFile(
          localPath,
          contentType: DioMediaType.parse(_imageContentType(localPath)),
        ),
      });
      final response = await _dio.post<Map<String, dynamic>>(
        'media/upload',
        data: data,
        options: Options(contentType: 'multipart/form-data'),
      );
      final url = response.data?['url'] as String?;
      final path = response.data?['path'] as String?;
      if (response.statusCode == 200 && url != null && url.isNotEmpty) {
        return url;
      }
      if (response.statusCode == 200 && path != null && path.isNotEmpty) {
        return '${_dio.options.baseUrl.replaceFirst(RegExp(r'/$'), '')}$path';
      }
      throw ApiException('이미지 업로드 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  String _imageContentType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  @override
  Future<Receipt> recognizeReceiptImage(
    String imagePath, {
    required String currencyCode,
  }) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'receipts/recognize',
        data: {
          'imagePath': imagePath,
          'currencyCode': currencyCode,
        },
        options: Options(receiveTimeout: const Duration(seconds: 180)),
      );
      if (response.statusCode == 200 && response.data != null) {
        return Receipt.fromJson(response.data!);
      }
      throw ApiException('영수증 인식 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<SettlementSummary> getSettlementSummary(
    String userId,
    String tripId,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'users/$userId/trips/$tripId/settlement',
      );
      if (response.statusCode == 200 && response.data != null) {
        return SettlementSummary.fromJson(response.data!);
      }
      throw ApiException('정산 계산 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<void> updateSettlementTransferStatus({
    required String userId,
    required String tripId,
    required String mode,
    required String from,
    required String to,
    required bool completed,
  }) async {
    try {
      await _dio.put<Map<String, dynamic>>(
        'users/$userId/trips/$tripId/settlement/status',
        data: {
          'mode': mode,
          'from': from,
          'to': to,
          'completed': completed,
        },
      );
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Future<Receipt?> _findReceiptById(
      String userId, String tripId, String id) async {
    try {
      final receipts = await getReceipts(userId, tripId);
      for (final receipt in receipts) {
        if (receipt.id == id) return receipt;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Options get _receiptWriteOptions => Options(
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 8),
      );

  dynamic _compactJson(dynamic value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (entry.value != null) entry.key: _compactJson(entry.value),
      };
    }
    if (value is List) {
      return value.map(_compactJson).toList();
    }
    return value;
  }

  Map<String, dynamic> _receiptMetadataJson(Receipt receipt) {
    final data = Map<String, dynamic>.from(receipt.toJson());
    data['items'] = <dynamic>[];
    data.remove('estimatedKrwAmount');
    data.remove('localToUsdRate');
    data.remove('usdAmount');
    data.remove('usdToKrwRate');
    data.remove('baseKrwAmount');
    data.remove('exchangeRateSource');
    data.remove('rateDateLabel');
    return Map<String, dynamic>.from(_compactJson(data) as Map);
  }

  Future<Receipt> _saveReceiptInChunks(
    String userId,
    String tripId,
    Receipt receipt,
  ) async {
    await _dio.put<Map<String, dynamic>>(
      'users/$userId/trips/$tripId/receipts/${receipt.id}',
      data: _receiptMetadataJson(receipt),
      options: _receiptWriteOptions,
    );

    final items = receipt.items.map((item) => item.toJson()).toList();
    for (var index = 0; index < items.length; index++) {
      await _dio.put<Map<String, dynamic>>(
        'users/$userId/trips/$tripId/receipts/${receipt.id}/items/$index',
        data: _compactJson(items[index]),
        options: _receiptWriteOptions,
      );
    }

    final saved = await _findReceiptById(userId, tripId, receipt.id);
    if (saved != null && saved.items.length == receipt.items.length) {
      return saved;
    }
    throw ApiException('영수증 저장 확인 실패');
  }

  @override
  Future<Receipt> createReceipt(
    String userId,
    String tripId,
    Receipt receipt,
  ) async {
    try {
      return await _saveReceiptInChunks(userId, tripId, receipt);
    } on DioException catch (e) {
      if (_isRetryableNetworkError(e)) {
        final saved = await _findReceiptById(userId, tripId, receipt.id);
        if (saved != null && saved.items.length == receipt.items.length) {
          return saved;
        }
        try {
          return await _saveReceiptInChunks(userId, tripId, receipt);
        } on DioException catch (retryError) {
          final recovered = await _findReceiptById(userId, tripId, receipt.id);
          if (recovered != null &&
              recovered.items.length == receipt.items.length) {
            return recovered;
          }
          throw _fromDio(retryError);
        }
      }
      throw _fromDio(e);
    }
  }

  @override
  Future<Receipt> updateReceipt(
    String userId,
    String tripId,
    Receipt receipt,
  ) async {
    try {
      return await _saveReceiptInChunks(userId, tripId, receipt);
    } on DioException catch (e) {
      if (_isRetryableNetworkError(e)) {
        final saved = await _findReceiptById(userId, tripId, receipt.id);
        if (saved != null && saved.items.length == receipt.items.length) {
          return saved;
        }
        try {
          return await _saveReceiptInChunks(userId, tripId, receipt);
        } on DioException catch (retryError) {
          final recovered = await _findReceiptById(userId, tripId, receipt.id);
          if (recovered != null &&
              recovered.items.length == receipt.items.length) {
            return recovered;
          }
          throw _fromDio(retryError);
        }
      }
      throw _fromDio(e);
    }
  }

  @override
  Future<void> deleteReceiptItem(
    String userId,
    String tripId,
    String receiptId,
  ) async {
    try {
      final response = await _dio.delete<void>(
        'users/$userId/trips/$tripId/receipts/$receiptId',
      );
      if (response.statusCode != 204 && response.statusCode != 200) {
        throw ApiException('영수증 삭제 실패');
      }
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<List<CardProfile>> getCardProfiles(String userId) async {
    try {
      final response = await _dio.get<dynamic>('users/$userId/cards');
      if (response.statusCode == 200 && response.data != null) {
        return _parseCardProfileList(response.data);
      }
      return [];
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<List<CardProfile>> saveCardProfiles(
    String userId,
    List<CardProfile> cards,
  ) async {
    try {
      final response = await _dio.put<dynamic>(
        'users/$userId/cards',
        data: {'items': cards.map((e) => e.toJson()).toList()},
      );
      if (response.statusCode == 200 && response.data != null) {
        return _parseCardProfileList(response.data);
      }
      throw ApiException('카드 저장 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<CardProfile> createCardProfile(String userId, CardProfile card) async {
    try {
      final response = await _dio.post<dynamic>(
        'users/$userId/cards',
        data: card.toJson(),
      );
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          response.data is Map) {
        final data = Map<String, dynamic>.from(response.data as Map);
        final item = data['item'];
        if (item is Map) {
          return CardProfile.fromJson(Map<String, dynamic>.from(item));
        }
        return CardProfile.fromJson(data);
      }
      throw ApiException('카드 추가 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<List<CardProfile>> getTripParticipantCardProfiles({
    required String userId,
    required String tripId,
    required String participantName,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        'users/$userId/trips/$tripId/cards',
        queryParameters: {'participantName': participantName},
      );
      if (response.statusCode == 200 && response.data != null) {
        return _parseCardProfileList(response.data);
      }
      return [];
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<PaymentFeeCatalog> getPaymentFeeCatalog() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'payment/fee-catalog',
      );
      if (response.statusCode == 200 && response.data != null) {
        return PaymentFeeCatalog.fromJson(response.data!);
      }
      throw ApiException('수수료 카탈로그 조회 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  @override
  Future<PaymentEstimate> estimateReceiptPayment(Receipt receipt) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'payment/estimate',
        data: receipt.toJson(),
      );
      if (response.statusCode == 200 && response.data != null) {
        return PaymentEstimate.fromJson(response.data!);
      }
      throw ApiException('예상 정산액 계산 실패');
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }
}
