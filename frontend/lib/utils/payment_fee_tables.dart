class FeeRule {
  final String label;
  final double rate;

  const FeeRule(this.label, this.rate);
}

const defaultCardBrandFeeRates = <String, FeeRule>{
  'visa': FeeRule('VISA', 0.011),
  'mastercard': FeeRule('Mastercard', 0.010),
  'master': FeeRule('Mastercard', 0.010),
  'maestro': FeeRule('Maestro', 0.010),
  'amex': FeeRule('AMEX', 0.014),
  'americanexpress': FeeRule('AMEX', 0.014),
  'jcb': FeeRule('JCB', 0.000),
  'unionpay': FeeRule('UnionPay', 0.008),
  'up': FeeRule('UnionPay', 0.008),
};

const defaultCardIssuerFeeRates = <String, FeeRule>{
  '신한': FeeRule('신한카드', 0.0018),
  '신한카드': FeeRule('신한카드', 0.0018),
  'kb': FeeRule('KB국민카드', 0.0025),
  '국민': FeeRule('KB국민카드', 0.0025),
  '국민카드': FeeRule('KB국민카드', 0.0025),
  'kb국민': FeeRule('KB국민카드', 0.0025),
  'kb국민카드': FeeRule('KB국민카드', 0.0025),
  '현대': FeeRule('현대카드', 0.0018),
  '현대카드': FeeRule('현대카드', 0.0018),
  '삼성': FeeRule('삼성카드', 0.0020),
  '삼성카드': FeeRule('삼성카드', 0.0020),
  '롯데': FeeRule('롯데카드', 0.0020),
  '롯데카드': FeeRule('롯데카드', 0.0020),
  '하나': FeeRule('하나카드', 0.0020),
  '하나카드': FeeRule('하나카드', 0.0020),
  '우리': FeeRule('우리카드', 0.0030),
  '우리카드': FeeRule('우리카드', 0.0030),
  '농협': FeeRule('NH농협카드', 0.0025),
  'nh농협': FeeRule('NH농협카드', 0.0025),
  'nh농협카드': FeeRule('NH농협카드', 0.0025),
  'bc': FeeRule('BC카드', 0.0035),
  '비씨': FeeRule('BC카드', 0.0035),
  '비씨카드': FeeRule('BC카드', 0.0035),
  '기업': FeeRule('IBK기업은행(BC)', 0.0035),
  'ibk': FeeRule('IBK기업은행(BC)', 0.0035),
  '기업은행': FeeRule('IBK기업은행(BC)', 0.0035),
  'sc제일': FeeRule('SC제일은행(BC)', 0.0035),
  'sc제일은행': FeeRule('SC제일은행(BC)', 0.0035),
  '대구': FeeRule('DGB대구은행(BC)', 0.0035),
  '대구은행': FeeRule('DGB대구은행(BC)', 0.0035),
  '부산': FeeRule('BNK부산은행(BC)', 0.0035),
  '부산은행': FeeRule('BNK부산은행(BC)', 0.0035),
  '경남': FeeRule('BNK경남은행(BC)', 0.0035),
  '경남은행': FeeRule('BNK경남은행(BC)', 0.0035),
  '트래블월렛': FeeRule('트래블월렛', 0),
  'travelwallet': FeeRule('트래블월렛', 0),
};

String normalizeFeeKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9가-힣]'), '');

FeeRule? findIssuerFeeRule(String? issuer) {
  final raw = issuer?.trim();
  if (raw == null || raw.isEmpty) return null;
  final key = normalizeFeeKey(raw);
  return defaultCardIssuerFeeRates[key] ??
      defaultCardIssuerFeeRates.entries
          .where((entry) => key.contains(entry.key) || entry.key.contains(key))
          .map((entry) => entry.value)
          .cast<FeeRule?>()
          .firstWhere((rule) => rule != null, orElse: () => null);
}

FeeRule? findBrandFeeRule(String? brand) {
  final raw = brand?.trim();
  if (raw == null || raw.isEmpty) return null;
  final key = normalizeFeeKey(raw);
  return defaultCardBrandFeeRates[key] ??
      defaultCardBrandFeeRates.entries
          .where((entry) => key.contains(entry.key) || entry.key.contains(key))
          .map((entry) => entry.value)
          .cast<FeeRule?>()
          .firstWhere((rule) => rule != null, orElse: () => null);
}

String formatFeeRate(double rate) =>
    '${(rate * 100).toStringAsFixed(rate == 0 ? 0 : 2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')}%';
