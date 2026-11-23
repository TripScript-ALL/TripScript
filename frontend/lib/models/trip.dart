import 'receipt.dart';

class Trip {
  final String id;
  final String name;
  final DateTime startDate;
  final DateTime endDate;
  final List<String> participants;
  final List<String> countries;

  /// 방장(여행 주최). 보통 [participants] 중 한 사람의 이름과 맞춘다.
  final String hostName;

  /// 초대 참여용 코드. 백엔드 값이 없으면 id 기반으로 표시용 코드를 만든다.
  final String inviteCode;

  final List<Receipt> receipts;

  /// 타일 배경 색상 (Color.value). null이면 기본색 또는 커버 사진 사용.
  final int? tileColor;

  /// 타일 커버 사진 경로. 있으면 색상 대신 이 이미지를 표시.
  final String? coverImagePath;

  Trip({
    required this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.participants,
    required this.hostName,
    List<String>? countries,
    String? inviteCode,
    List<Receipt>? receipts,
    this.tileColor,
    this.coverImagePath,
  })  : inviteCode = (inviteCode == null || inviteCode.isEmpty)
            ? _fallbackInviteCode(id)
            : inviteCode,
        countries = countries ?? const [],
        receipts = receipts ?? [];

  /// `YYYY.MM.DD` 또는 `시작 ~ 종료` (한 줄 표시용)
  static String formatDateRange(DateTime start, DateTime end) {
    String fmt(DateTime d) =>
        '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
    final a = fmt(start);
    final b = fmt(end);
    return a == b ? a : '$a ~ $b';
  }

  String get dateLabelShort => Trip.formatDateRange(startDate, endDate);

  Trip copyWith({
    String? id,
    String? name,
    DateTime? startDate,
    DateTime? endDate,
    List<String>? participants,
    List<String>? countries,
    String? hostName,
    String? inviteCode,
    List<Receipt>? receipts,
    int? tileColor,
    String? coverImagePath,
    bool clearTileColor = false,
    bool clearCoverImagePath = false,
  }) {
    return Trip(
      id: id ?? this.id,
      name: name ?? this.name,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      participants: participants ?? this.participants,
      countries: countries ?? this.countries,
      hostName: hostName ?? this.hostName,
      inviteCode: inviteCode ?? this.inviteCode,
      receipts: receipts ?? this.receipts,
      tileColor: clearTileColor ? null : (tileColor ?? this.tileColor),
      coverImagePath:
          clearCoverImagePath ? null : (coverImagePath ?? this.coverImagePath),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'participants': participants,
      'countries': countries,
      'hostName': hostName,
      'inviteCode': inviteCode,
      'receipts': receipts.map((r) => r.toJson()).toList(),
      'tileColor': tileColor,
      'coverImagePath': coverImagePath,
    };
  }

  factory Trip.fromJson(Map<String, dynamic> json) {
    final DateTime start;
    final DateTime end;
    if (json['startDate'] != null && json['endDate'] != null) {
      start = DateTime.parse(json['startDate'] as String);
      end = DateTime.parse(json['endDate'] as String);
    } else {
      final legacy = DateTime.parse(json['date'] as String);
      start = legacy;
      end = legacy;
    }

    final participantsRaw = json['participants'];
    final participants = participantsRaw is List
        ? List<String>.from(participantsRaw)
        : <String>[];
    final hostFromJson = json['hostName'] as String?;
    final host = (hostFromJson != null && hostFromJson.isNotEmpty)
        ? hostFromJson
        : (participants.isNotEmpty ? participants.first : '');

    return Trip(
      id: json['id'] as String,
      name: json['name'] as String,
      startDate: start,
      endDate: end,
      participants: participants,
      countries: (json['countries'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList() ??
          const [],
      hostName: host,
      inviteCode:
          json['inviteCode'] as String? ?? json['invite_code'] as String?,
      receipts: (json['receipts'] as List?)
              ?.map((r) => Receipt.fromJson(r as Map<String, dynamic>))
              .toList() ??
          [],
      tileColor: json['tileColor'] as int?,
      coverImagePath: json['coverImagePath'] as String?,
    );
  }

  double get totalAmount => receipts.fold(0, (sum, r) => sum + r.amount);
}

String _fallbackInviteCode(String id) {
  final compact = id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  if (compact.length >= 6) return compact.substring(0, 6);
  return compact.padRight(6, '0');
}
