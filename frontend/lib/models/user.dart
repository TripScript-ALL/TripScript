/// TripScript 백엔드 `GET/PATCH /users/...`, `POST /auth/kakao`, `GET /me` 응답과 동일한 형태.
///
/// 서버 JSON 키: `id`, `name`, `nickname`, `phoneNumber`, 선택 `kakaoUserId`.
/// `nickname`이 비어 있으면 [displayName]은 [name]과 같습니다.
/// `accessToken`은 [RestApiService]에서 파싱 전 제거되지만, 혹시 포함돼 있어도 무시합니다.
class User {
  const User({
    required this.id,
    required this.name,
    this.nickname = '',
    this.phoneNumber = '',
    this.settlementBankName = '',
    this.settlementAccountNumber = '',
    this.settlementAccountHolder = '',
    this.kakaoUserId,
  });

  /// 앱 사용자 UUID (문자열).
  final String id;

  /// 실명·이름+전화 로그인 조회용 이름, 카카오만 가입 시 서버 기본 이름(`카카오`+숫자 등).
  final String name;

  /// 앱·여행 UI에 쓸 닉네임. 비어 있으면 [displayName]은 [name]을 따릅니다.
  final String nickname;

  /// 숫자만 또는 빈 문자열. 카카오만 가입하면 비어 있을 수 있음.
  final String phoneNumber;

  /// 정산 송금 요청 때 받을 계좌 정보. MVP에서는 사용자가 직접 관리한다.
  final String settlementBankName;
  final String settlementAccountNumber;
  final String settlementAccountHolder;

  /// 카카오 회원번호(문자열). 이름·전화만 쓰는 계정은 null.
  final String? kakaoUserId;

  /// 여행 참여자 이름 등과 비교할 때: [name] 또는 [displayName]과 일치하면 본인으로 간주.
  bool matchesParticipantName(String participant) {
    final p = participant.trim();
    if (p.isEmpty) return false;
    return p == name.trim() || p == displayName.trim();
  }

  /// 앱에 보일 이름 (`nickname`이 있으면 닉네임, 없으면 [name]).
  String get displayName {
    final n = nickname.trim();
    return n.isNotEmpty ? n : name.trim();
  }

  /// 전화번호를 서버에 등록했는지 (UI 검증·표시용).
  bool get hasPhoneNumber => phoneNumber.trim().isNotEmpty;

  bool get hasSettlementAccount =>
      settlementBankName.trim().isNotEmpty &&
      settlementAccountNumber.trim().isNotEmpty &&
      settlementAccountHolder.trim().isNotEmpty;

  /// 카카오 계정과 연동된 사용자인지.
  bool get isKakaoLinked => kakaoUserId != null && kakaoUserId!.isNotEmpty;

  /// [ProfileCompletionScreen]으로 보낼지(카카오인데 서버 `name`이 비어 있는 등 극히 드문 경우).
  bool get needsProfileCompletion => isKakaoLinked && name.trim().isEmpty;

  /// 서버가 카카오 닉네임이 없을 때 [name]에 부여하는 `카카오` + 숫자(회원번호) 패턴.
  static final RegExp kakaoServerGeneratedNamePattern = RegExp(r'^카카오\d+$');

  /// 카카오 연동·닉네임 미설정·기본 [name]이면 마이페이지에서 닉네임 설정을 권장.
  bool get shouldSuggestSettingDisplayName =>
      isKakaoLinked &&
      nickname.trim().isEmpty &&
      kakaoServerGeneratedNamePattern.hasMatch(name.trim());

  bool get needsInitialSetup =>
      isKakaoLinked &&
      (shouldSuggestSettingDisplayName || !hasSettlementAccount);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'nickname': nickname,
      'phoneNumber': phoneNumber,
      'settlementBankName': settlementBankName,
      'settlementAccountNumber': settlementAccountNumber,
      'settlementAccountHolder': settlementAccountHolder,
      if (kakaoUserId != null) 'kakaoUserId': kakaoUserId,
    };
  }

  factory User.fromJson(Map<String, dynamic> json) {
    final idVal = json['id'];
    final id =
        idVal is String ? idVal : (idVal != null ? idVal.toString() : '');

    final rawKakao = json['kakaoUserId'] ?? json['kakao_user_id'];
    final String? kakao = _optionalString(rawKakao);

    return User(
      id: id,
      name: json['name'] as String? ?? '',
      nickname: json['nickname'] as String? ?? '',
      phoneNumber: json['phoneNumber'] as String? ??
          json['phone_number'] as String? ??
          '',
      settlementBankName: json['settlementBankName'] as String? ??
          json['settlement_bank_name'] as String? ??
          '',
      settlementAccountNumber: json['settlementAccountNumber'] as String? ??
          json['settlement_account_number'] as String? ??
          '',
      settlementAccountHolder: json['settlementAccountHolder'] as String? ??
          json['settlement_account_holder'] as String? ??
          '',
      kakaoUserId: kakao,
    );
  }

  static String? _optionalString(Object? value) {
    if (value == null) return null;
    final s = value is String ? value.trim() : value.toString().trim();
    return s.isEmpty ? null : s;
  }

  User copyWith({
    String? id,
    String? name,
    String? nickname,
    String? phoneNumber,
    String? settlementBankName,
    String? settlementAccountNumber,
    String? settlementAccountHolder,
    String? kakaoUserId,
    bool clearKakaoUserId = false,
  }) {
    return User(
      id: id ?? this.id,
      name: name ?? this.name,
      nickname: nickname ?? this.nickname,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      settlementBankName: settlementBankName ?? this.settlementBankName,
      settlementAccountNumber:
          settlementAccountNumber ?? this.settlementAccountNumber,
      settlementAccountHolder:
          settlementAccountHolder ?? this.settlementAccountHolder,
      kakaoUserId: clearKakaoUserId ? null : (kakaoUserId ?? this.kakaoUserId),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is User &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          nickname == other.nickname &&
          phoneNumber == other.phoneNumber &&
          settlementBankName == other.settlementBankName &&
          settlementAccountNumber == other.settlementAccountNumber &&
          settlementAccountHolder == other.settlementAccountHolder &&
          kakaoUserId == other.kakaoUserId;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        nickname,
        phoneNumber,
        settlementBankName,
        settlementAccountNumber,
        settlementAccountHolder,
        kakaoUserId,
      );
}
