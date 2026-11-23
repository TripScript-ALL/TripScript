import '../models/receipt.dart';
import '../models/trip.dart';
import 'format_money.dart';
import 'payment_fee_tables.dart';

/// 2026-05-06 기준 임시 KRW 환산율.
/// 실서비스에서는 결제일/통화별 환율 API 응답으로 대체할 값입니다.
const exchangeRateAsOfLabel = '2026.05.06';

const krwPerCurrencyUnit = <String, double>{
  'KRW': 1,
  'USD': 1471.20,
  'EUR': 1722.48,
  'JPY': 9.368,
  'CNY': 216.54,
  'GBP': 1994.51,
  'CHF': 1884.16,
  'SEK': 157.0,
  'NOK': 146.0,
  'DKK': 231.0,
  'ISK': 11.4,
  'PLN': 404.0,
  'CZK': 70.0,
  'HUF': 4.35,
};

double exchangeRateFor(String currencyCode) =>
    krwPerCurrencyUnit[currencyCode.toUpperCase()] ?? 1;

double receiptAmountInKrw(Receipt receipt) {
  if (receipt.actualKrwAmount != null) return receipt.actualKrwAmount!;
  if (receipt.estimatedKrwAmount != null) return receipt.estimatedKrwAmount!;
  final code = receipt.currencyCode.toUpperCase();
  if (code == 'KRW') return receipt.amount;
  final method = receipt.paymentMethod == 'cash' ? 'cash' : 'card';
  if (method == 'cash') {
    final cashRate = receipt.cashKrwPerUnit;
    final fee = receipt.cashExchangeFeeRate ?? 0;
    final correction = receipt.paymentCorrectionRate ?? 0;
    return roundCurrencyAmount(
      receipt.amount *
          ((cashRate != null && cashRate > 0)
              ? cashRate
              : exchangeRateFor(code)) *
          (1 + fee + correction),
      'KRW',
    );
  }
  final usdToKrw = exchangeRateFor('USD');
  final usdAmount = receipt.amount * exchangeRateFor(code) / usdToKrw;
  final brandRate = receipt.cardBrandFeeRate ??
      findBrandFeeRule(receipt.cardBrand)?.rate ??
      0;
  final issuerRate = receipt.cardIssuerFeeRate ??
      findIssuerFeeRule(receipt.cardIssuer)?.rate ??
      0;
  final correction = receipt.paymentCorrectionRate ?? 0;
  return roundCurrencyAmount(
    usdAmount * usdToKrw * (1 + brandRate + issuerRate + correction),
    'KRW',
  );
}

double tripTotalInKrw(Trip trip) =>
    trip.receipts.fold(0, (sum, r) => sum + receiptAmountInKrw(r));

Map<String, double> tripTotalsByCurrency(Trip trip) {
  final totals = <String, double>{};
  for (final r in trip.receipts) {
    final code = r.currencyCode.toUpperCase();
    totals[code] = (totals[code] ?? 0) + r.amount;
  }
  final entries = totals.entries.toList()
    ..sort((a, b) {
      if (a.key == 'KRW') return -1;
      if (b.key == 'KRW') return 1;
      return a.key.compareTo(b.key);
    });
  return Map.fromEntries(entries);
}
