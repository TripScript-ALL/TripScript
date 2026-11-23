import 'package:intl/intl.dart';

final _commaInt = NumberFormat('#,###', 'ko_KR');
final _commaMan1 = NumberFormat('#,##0.0', 'ko_KR');

/// 앱에서 제공하는 주요 통화 코드.
const supportedCurrencyCodes = <String>[
  'KRW',
  'USD',
  'EUR',
  'JPY',
  'CNY',
  'GBP',
  'CHF',
  'SEK',
  'NOK',
  'DKK',
  'ISK',
  'PLN',
  'CZK',
  'HUF',
];

/// 천 단위 콤마가 들어간 정수 문자열 (부호·음수 지원)
String formatWonInt(num value) => _commaInt.format(value.round());

/// `1,234,567원`
String formatWonLabel(num value) => '${formatWonInt(value)}원';

/// `12.3만` (소수 첫째 자리, 만 단위)
String formatManDecimal1(double value) =>
    '${_commaMan1.format(value / 10000)}만';

int currencyFractionDigits(String currencyCode) {
  switch (currencyCode.toUpperCase()) {
    case 'KRW':
    case 'JPY':
    case 'VND':
      return 0;
    default:
      return 2;
  }
}

double roundCurrencyAmount(num amount, String currencyCode) {
  final digits = currencyFractionDigits(currencyCode);
  final factor = digits == 0 ? 1 : (digits == 2 ? 100 : 10);
  return (amount * factor).round() / factor;
}

String formatMoneyLabel(num amount, String currencyCode) {
  final code =
      supportedCurrencyCodes.contains(currencyCode) ? currencyCode : 'KRW';
  if (code == 'KRW') return formatWonLabel(amount);

  final formatted = (NumberFormat.decimalPattern('ko_KR')
        ..minimumFractionDigits = 0
        ..maximumFractionDigits = currencyFractionDigits(code))
      .format(amount);
  return '${formatted.trim()} $code';
}
