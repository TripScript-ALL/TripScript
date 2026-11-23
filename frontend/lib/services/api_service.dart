import '../models/card_profile.dart';
import '../models/payment_fee_catalog.dart';
import '../models/receipt.dart';
import '../models/settlement_summary.dart';
import '../models/trip.dart';
import '../models/user.dart';
import '../utils/payment_estimator.dart';

/// 백엔드 서버 API 인터페이스 (`RestApiService`, `docs/rest_api.md` 참고).
abstract class ApiService {
  /// `Authorization: Bearer …` 헤더. 없으면 인증 헤더를 보내지 않습니다.
  void setAuthToken(String? token) {}

  void clearAuthToken() {}

  /// 현재 설정된 Bearer 토큰. 없으면 null.
  String? get authToken => null;

  /// 저장된 앱 JWT로 현재 사용자 조회 (`GET /me`).
  Future<User> getCurrentUser();

  /// 카카오 SDK에서 받은 액세스 토큰으로 서버 로그인 (`POST /auth/kakao`).
  Future<User> loginWithKakaoAccessToken(String kakaoAccessToken);

  /// 이름+전화번호로 사용자 조회
  Future<User?> getUserByNameAndPhone(String name, String phoneNumber);

  /// 사용자 등록 (이름, 전화번호)
  Future<User> registerUser({
    required String name,
    required String phoneNumber,
  });

  /// 사용자 정보 수정. [nickname]이 null이면 서버에 보내지 않습니다.
  Future<User> updateUser(
    String userId, {
    required String name,
    required String phoneNumber,
    String? nickname,
    String? settlementBankName,
    String? settlementAccountNumber,
    String? settlementAccountHolder,
  });

  /// 사용자 계정 탈퇴. 서버에서 사용자 세션, 카드, 여행 참여 정보를 정리합니다.
  Future<void> deleteUser(String userId);

  /// 해당 사용자의 여행 목록 조회
  Future<List<Trip>> getTrips(String userId);

  /// 여행 저장 (새 여행 추가)
  Future<Trip> saveTrip(String userId, Trip trip);

  /// 여행 수정
  Future<Trip> updateTrip(String userId, Trip trip);

  /// 여행 삭제
  Future<void> deleteTrip(String userId, String tripId);

  /// 현재 사용자가 여행에서 나가기
  Future<void> leaveTrip(String userId, String tripId);

  /// 초대 코드로 여행 참여
  Future<Trip> joinTripByInviteCode(String userId, String inviteCode);

  /// 여행별 영수증 목록 (품목 `items` 포함 가능, `docs/rest_api.md` §5.1)
  Future<List<Receipt>> getReceipts(String userId, String tripId);

  /// 선택한 이미지 파일을 서버 저장소에 업로드하고 표시 가능한 URL을 반환
  Future<String> uploadMedia(String localPath, {required String kind});

  /// 서버 OCR/LLM 파이프라인으로 업로드된 영수증 이미지를 인식
  Future<Receipt> recognizeReceiptImage(
    String imagePath, {
    required String currencyCode,
  });

  /// 여행 정산 요약. 참여자별 부담액과 송금 목록은 백엔드 계산값을 사용합니다.
  Future<SettlementSummary> getSettlementSummary(String userId, String tripId);

  /// 정산 송금 완료 여부 저장. [mode]는 `net`(최종 상계) 또는 `gross`(원래 흐름).
  Future<void> updateSettlementTransferStatus({
    required String userId,
    required String tripId,
    required String mode,
    required String from,
    required String to,
    required bool completed,
  });

  /// 영수증 생성
  Future<Receipt> createReceipt(String userId, String tripId, Receipt receipt);

  /// 영수증 수정
  Future<Receipt> updateReceipt(String userId, String tripId, Receipt receipt);

  /// 영수증 삭제
  Future<void> deleteReceiptItem(
      String userId, String tripId, String receiptId);

  /// 사용자 본인의 결제 카드 목록
  Future<List<CardProfile>> getCardProfiles(String userId);

  /// 사용자 본인의 결제 카드 목록 저장
  Future<List<CardProfile>> saveCardProfiles(
    String userId,
    List<CardProfile> cards,
  );

  /// 사용자 본인의 결제 카드 1장 추가
  Future<CardProfile> createCardProfile(String userId, CardProfile card);

  /// 여행 대표자가 특정 참여자의 카드 목록을 조회하거나, 참여자가 본인 카드를 조회
  Future<List<CardProfile>> getTripParticipantCardProfiles({
    required String userId,
    required String tripId,
    required String participantName,
  });

  /// 카드사/국제브랜드 대표 해외결제 수수료 카탈로그
  Future<PaymentFeeCatalog> getPaymentFeeCatalog();

  /// 결제/환율/수수료 기준 예상 정산액 계산
  Future<PaymentEstimate> estimateReceiptPayment(Receipt receipt);
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}
