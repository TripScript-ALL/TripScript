import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';

import '../config/app_config.dart';
import '../models/settlement_summary.dart';
import 'format_money.dart';

/// 카카오 기본 템플릿 텍스트 길이 과다 방지 (서버/클라 제한 대비)
const _maxShareTextLength = 1800;
const _tripScriptShareChannel = MethodChannel('tripscript/share');

/// 정산 요약을 카카오톡 공유 메시지 문자열로 만듭니다.
String buildSettlementShareText(String tripName, SettlementSummary summary) {
  final buf = StringBuffer();
  buf.writeln('[TripScript] $tripName 정산');
  buf.writeln('');
  buf.writeln('■ 총액(추정 KRW): ${formatWonLabel(summary.totalKrw)}');
  if (summary.totalsByCurrency.isNotEmpty) {
    buf.writeln('■ 통화별');
    for (final e in summary.totalsByCurrency.entries) {
      buf.writeln(
        '  · ${e.key}: ${formatMoneyLabel(e.value, e.key)}',
      );
    }
    buf.writeln('');
  }
  buf.writeln('■ 참여자별');
  for (final b in summary.balances) {
    final bal = b.balance > 0
        ? '+${formatWonLabel(b.balance)}'
        : formatWonLabel(b.balance);
    buf.writeln(
      '  · ${b.name}: 지출 ${formatWonLabel(b.paid)} / 정산 $bal',
    );
  }
  buf.writeln('');
  if (summary.transfers.isEmpty) {
    buf.writeln('■ 송금: 추가 정산 없음');
  } else {
    buf.writeln('■ 송금 안내');
    for (final t in summary.transfers) {
      buf.writeln(
        '  · ${t.from} → ${t.to}: ${formatWonLabel(t.amount)}',
      );
    }
  }
  if (summary.receiptBreakdown.isNotEmpty) {
    buf.writeln('');
    buf.writeln('■ 계산 기준');
    for (final r in summary.receiptBreakdown.take(4)) {
      buf.writeln(
        '  · ${r.storeName}: ${formatWonLabel(r.settlementKrwAmount)} / ${r.splitBasis}',
      );
    }
    if (summary.receiptBreakdown.length > 4) {
      buf.writeln('  · 외 ${summary.receiptBreakdown.length - 4}건');
    }
  }
  if (summary.calculationNotes.isNotEmpty) {
    buf.writeln('');
    buf.writeln('■ 안내');
    for (final note in summary.calculationNotes.take(2)) {
      buf.writeln('  · $note');
    }
  }
  buf.writeln('');
  buf.writeln('※ TripScript에서 생성된 정산 요약입니다.');

  var text = buf.toString();
  if (text.length > _maxShareTextLength) {
    text = '${text.substring(0, _maxShareTextLength)}\n…(이하 생략)';
  }
  return text;
}

/// [카카오톡 공유](https://developers.kakao.com/docs/ko/kakaotalk-share/flutter-link) 기본 템플릿 전송.
///
/// 웹·데스크톱에서는 미지원 안내만 합니다.
Future<void> shareSettlementViaKakaoTalk({
  required BuildContext context,
  required String tripName,
  required SettlementSummary summary,
}) async {
  if (kIsWeb) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('카카오톡 공유는 모바일 앱에서만 지원됩니다.')),
      );
    }
    return;
  }

  if (AppConfig.kakaoNativeAppKey.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'KAKAO_NATIVE_APP_KEY가 필요합니다. (--dart-define 으로 설정)',
          ),
        ),
      );
    }
    return;
  }

  final text = buildSettlementShareText(tripName, summary);
  await shareSettlementTextViaKakaoTalk(context: context, text: text);
}

Future<void> shareSettlementTextViaKakaoTalk({
  required BuildContext context,
  required String text,
}) async {
  if (kIsWeb) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('카카오톡 공유는 모바일 앱에서만 지원됩니다.')),
      );
    }
    return;
  }

  if (AppConfig.kakaoNativeAppKey.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'KAKAO_NATIVE_APP_KEY가 필요합니다. (--dart-define 으로 설정)',
          ),
        ),
      );
    }
    return;
  }

  final template = TextTemplate(
    text: text,
    link: Link(
      webUrl: Uri.parse('https://developers.kakao.com'),
      mobileWebUrl: Uri.parse('https://developers.kakao.com'),
    ),
  );

  try {
    final available = await ShareClient.instance.isKakaoTalkSharingAvailable();
    if (available) {
      await ShareClient.instance.shareDefault(template: template);
    } else {
      final uri = await WebSharerClient.instance.makeDefaultUrl(
        template: template,
      );
      await launchBrowser(uri);
    }
  } catch (e, st) {
    debugPrint('shareSettlementTextViaKakaoTalk: $e\n$st');
    final detail = e.toString();
    final isKeyHashMismatch =
        detail.contains('keyHash') || detail.contains('keyhash');
    final keyHash = KakaoSdk.platformInfo.origin;
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isKeyHashMismatch
              ? '카카오 키 해시 등록이 필요합니다. KeyHash: $keyHash 정산문은 복사했습니다.'
              : '카카오톡 공유에 실패했습니다. 정산문은 복사했습니다.',
        ),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}

Future<void> shareSettlementTextViaSms({
  required BuildContext context,
  required String text,
}) async {
  if (kIsWeb) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('문자 전송은 모바일 앱에서만 지원됩니다.')),
      );
    }
    return;
  }

  try {
    await _tripScriptShareChannel.invokeMethod<void>(
      'openSmsComposer',
      {'text': text},
    );
  } catch (e, st) {
    debugPrint('shareSettlementTextViaSms: $e\n$st');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('문자 앱을 열지 못해 정산 문구를 복사했습니다.')),
    );
  }
}
