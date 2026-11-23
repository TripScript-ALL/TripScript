import '../models/receipt.dart';
import 'exchange_rates.dart';
import 'format_money.dart';
import 'payment_fee_tables.dart';

const paymentMethodCard = 'card';
const paymentMethodCash = 'cash';

class PaymentEstimate {
  final String paymentMethod;
  final String currencyCode;
  final String cardType;
  final double foreignAmount;
  final double localToUsdRate;
  final double usdAmount;
  final double usdToKrwRate;
  final double baseKrwAmount;
  final double cardBrandFeeRate;
  final double cardIssuerFeeRate;
  final String issuerFeeType;
  final double issuerFeeFixedUsd;
  final double cardBrandFeeKrw;
  final double cardIssuerFeeKrw;
  final double cashExchangeFeeRate;
  final double cashKrwPerUnit;
  final double correctionRate;
  final double estimatedKrwAmount;
  final double? actualKrwAmount;
  final String exchangeRateSource;
  final String rateDateLabel;

  const PaymentEstimate({
    required this.paymentMethod,
    required this.currencyCode,
    required this.cardType,
    required this.foreignAmount,
    required this.localToUsdRate,
    required this.usdAmount,
    required this.usdToKrwRate,
    required this.baseKrwAmount,
    required this.cardBrandFeeRate,
    required this.cardIssuerFeeRate,
    required this.issuerFeeType,
    required this.issuerFeeFixedUsd,
    required this.cardBrandFeeKrw,
    required this.cardIssuerFeeKrw,
    required this.cashExchangeFeeRate,
    required this.cashKrwPerUnit,
    required this.correctionRate,
    required this.estimatedKrwAmount,
    required this.actualKrwAmount,
    required this.exchangeRateSource,
    required this.rateDateLabel,
  });

  double get settlementKrwAmount => actualKrwAmount ?? estimatedKrwAmount;

  double get totalFeeRate => paymentMethod == paymentMethodCash
      ? cashExchangeFeeRate + correctionRate
      : cardBrandFeeRate + cardIssuerFeeRate + correctionRate;

  String get methodLabel => paymentMethod == paymentMethodCash ? '현금' : '카드';

  String get feeSummaryLabel {
    if (paymentMethod == paymentMethodCash) {
      if (cashKrwPerUnit > 0 && currencyCode != 'KRW') {
        return '입력 환율 ${formatMoneyLabel(cashKrwPerUnit, 'KRW')} / $currencyCode';
      }
      return '기준 환율'
          '${correctionRate == 0 ? '' : ' · 보정 ${formatFeeRate(correctionRate)}'}';
    }
    return '브랜드 ${formatFeeRate(cardBrandFeeRate)} · 카드사 ${formatFeeRate(cardIssuerFeeRate)}'
        '${correctionRate == 0 ? '' : ' · 보정 ${formatFeeRate(correctionRate)}'}';
  }

  String get routeLabel {
    if (currencyCode == 'KRW') return formatWonLabel(settlementKrwAmount);
    if (paymentMethod == paymentMethodCash) {
      return '${formatMoneyLabel(foreignAmount, currencyCode)} -> ${formatWonLabel(baseKrwAmount)}';
    }
    return '${formatMoneyLabel(foreignAmount, currencyCode)} -> '
        '${formatMoneyLabel(usdAmount, 'USD')} -> ${formatWonLabel(baseKrwAmount)}';
  }

  factory PaymentEstimate.fromJson(Map<String, dynamic> json) {
    double number(String key) => (json[key] as num?)?.toDouble() ?? 0;
    double? optionalNumber(String key) => (json[key] as num?)?.toDouble();
    final method = json['paymentMethod'] == paymentMethodCash
        ? paymentMethodCash
        : paymentMethodCard;
    final currency = (json['currencyCode'] as String? ?? 'KRW').toUpperCase();
    final estimated = number('estimatedKrwAmount');
    return PaymentEstimate(
      paymentMethod: method,
      currencyCode: currency,
      cardType: json['cardType'] as String? ?? 'credit',
      foreignAmount: number('amount'),
      localToUsdRate: number('localToUsdRate'),
      usdAmount: number('usdAmount'),
      usdToKrwRate: number('usdToKrwRate'),
      baseKrwAmount: number('baseKrwAmount'),
      cardBrandFeeRate: optionalNumber('cardBrandFeeRate') ?? 0,
      cardIssuerFeeRate: optionalNumber('cardIssuerFeeRate') ?? 0,
      issuerFeeType: json['issuerFeeType'] as String? ?? 'rate',
      issuerFeeFixedUsd: optionalNumber('issuerFeeFixedUsd') ?? 0,
      cardBrandFeeKrw: optionalNumber('cardBrandFeeKrw') ?? 0,
      cardIssuerFeeKrw: optionalNumber('cardIssuerFeeKrw') ?? 0,
      cashExchangeFeeRate: optionalNumber('cashExchangeFeeRate') ?? 0,
      cashKrwPerUnit: optionalNumber('cashKrwPerUnit') ?? 0,
      correctionRate: optionalNumber('paymentCorrectionRate') ?? 0,
      estimatedKrwAmount: estimated,
      actualKrwAmount: optionalNumber('actualKrwAmount'),
      exchangeRateSource: json['exchangeRateSource'] as String? ?? '서버 계산',
      rateDateLabel: json['rateDateLabel'] as String? ?? '',
    );
  }
}

double _parseRate(dynamic value, double fallback) {
  if (value == null) return fallback;
  if (value is num) return value.toDouble();
  final raw = value.toString().replaceAll('%', '').trim();
  final parsed = double.tryParse(raw);
  if (parsed == null) return fallback;
  return parsed > 1 ? parsed / 100 : parsed;
}

PaymentEstimate estimatePayment({
  required double amount,
  required String currencyCode,
  required String paymentMethod,
  String cardType = 'credit',
  String? cardIssuer,
  String? cardBrand,
  double? cardIssuerFeeRate,
  double? cardBrandFeeRate,
  String? issuerFeeType,
  double? issuerFeeFixedUsd,
  double? cashExchangeFeeRate,
  double? cashKrwPerUnit,
  double? correctionRate,
  double? actualKrwAmount,
}) {
  final code = currencyCode.toUpperCase();
  final method = paymentMethod == paymentMethodCash
      ? paymentMethodCash
      : paymentMethodCard;
  final usdToKrw = exchangeRateFor('USD');
  final krwPerUnit = exchangeRateFor(code);
  final cashRate = cashKrwPerUnit ?? 0;
  final isKrw = code == 'KRW';
  final localToUsd = isKrw ? 0.0 : krwPerUnit / usdToKrw;
  final usdAmount = method == paymentMethodCard && !isKrw
      ? roundCurrencyAmount(amount * localToUsd, 'USD')
      : 0.0;
  final baseKrw = isKrw
      ? amount
      : method == paymentMethodCard
          ? usdAmount * usdToKrw
          : amount * (cashRate > 0 ? cashRate : krwPerUnit);
  final brandRule = findBrandFeeRule(cardBrand);
  final issuerRule = findIssuerFeeRule(cardIssuer);
  final double brandRate = method == paymentMethodCard && !isKrw
      ? cardBrandFeeRate ?? brandRule?.rate ?? 0
      : 0;
  final double issuerRate = method == paymentMethodCard && !isKrw
      ? cardIssuerFeeRate ?? issuerRule?.rate ?? 0
      : 0;
  final feeType = method == paymentMethodCard && !isKrw
      ? (issuerFeeType ?? 'rate')
      : 'none';
  final fixedUsd = feeType == 'fixed_usd' ? issuerFeeFixedUsd ?? 0.0 : 0.0;
  final brandFeeKrw = baseKrw * brandRate;
  final issuerFeeKrw =
      feeType == 'fixed_usd' ? fixedUsd * usdToKrw : baseKrw * issuerRate;
  final double cashFee =
      method == paymentMethodCash && !isKrw ? cashExchangeFeeRate ?? 0 : 0;
  final correction = correctionRate ?? 0;
  final estimated = roundCurrencyAmount(
    baseKrw + brandFeeKrw + issuerFeeKrw + baseKrw * (cashFee + correction),
    'KRW',
  );
  return PaymentEstimate(
    paymentMethod: method,
    currencyCode: code,
    cardType: cardType,
    foreignAmount: amount,
    localToUsdRate: localToUsd,
    usdAmount: usdAmount,
    usdToKrwRate: usdToKrw,
    baseKrwAmount: baseKrw,
    cardBrandFeeRate: brandRate,
    cardIssuerFeeRate: issuerRate,
    issuerFeeType: feeType,
    issuerFeeFixedUsd: fixedUsd,
    cardBrandFeeKrw: brandFeeKrw,
    cardIssuerFeeKrw: issuerFeeKrw,
    cashExchangeFeeRate: cashFee,
    cashKrwPerUnit: method == paymentMethodCash && !isKrw ? cashRate : 0,
    correctionRate: correction,
    estimatedKrwAmount: estimated,
    actualKrwAmount: actualKrwAmount,
    exchangeRateSource: '임시 환율',
    rateDateLabel: exchangeRateAsOfLabel,
  );
}

PaymentEstimate estimateReceiptPayment(Receipt receipt) {
  final fallback = estimatePayment(
    amount: receipt.amount,
    currencyCode: receipt.currencyCode,
    paymentMethod: receipt.paymentMethod,
    cardType: receipt.cardType,
    cardIssuer: receipt.cardIssuer,
    cardBrand: receipt.cardBrand,
    cardIssuerFeeRate: receipt.cardIssuerFeeRate,
    cardBrandFeeRate: receipt.cardBrandFeeRate,
    issuerFeeType: receipt.issuerFeeType,
    issuerFeeFixedUsd: receipt.issuerFeeFixedUsd,
    cashExchangeFeeRate: receipt.cashExchangeFeeRate,
    cashKrwPerUnit: receipt.cashKrwPerUnit,
    correctionRate: receipt.paymentCorrectionRate,
    actualKrwAmount: receipt.actualKrwAmount,
  );
  return PaymentEstimate(
    paymentMethod: fallback.paymentMethod,
    currencyCode: fallback.currencyCode,
    cardType: fallback.cardType,
    foreignAmount: fallback.foreignAmount,
    localToUsdRate: receipt.localToUsdRate ?? fallback.localToUsdRate,
    usdAmount: receipt.usdAmount ?? fallback.usdAmount,
    usdToKrwRate: receipt.usdToKrwRate ?? fallback.usdToKrwRate,
    baseKrwAmount: receipt.baseKrwAmount ?? fallback.baseKrwAmount,
    cardBrandFeeRate: fallback.cardBrandFeeRate,
    cardIssuerFeeRate: fallback.cardIssuerFeeRate,
    issuerFeeType: fallback.issuerFeeType,
    issuerFeeFixedUsd: fallback.issuerFeeFixedUsd,
    cardBrandFeeKrw: receipt.cardBrandFeeKrw ?? fallback.cardBrandFeeKrw,
    cardIssuerFeeKrw: receipt.cardIssuerFeeKrw ?? fallback.cardIssuerFeeKrw,
    cashExchangeFeeRate: fallback.cashExchangeFeeRate,
    cashKrwPerUnit: fallback.cashKrwPerUnit,
    correctionRate: fallback.correctionRate,
    estimatedKrwAmount:
        receipt.estimatedKrwAmount ?? fallback.estimatedKrwAmount,
    actualKrwAmount: receipt.actualKrwAmount,
    exchangeRateSource:
        receipt.exchangeRateSource ?? fallback.exchangeRateSource,
    rateDateLabel: receipt.rateDateLabel ?? fallback.rateDateLabel,
  );
}

double parseOptionalRate(String text) => _parseRate(text, 0);
