dynamic _jsonVal(Map<String, dynamic> json, String camel, String snake) =>
    json[camel] ?? json[snake];

String _str(dynamic v, {String fallback = ''}) {
  if (v == null) return fallback;
  if (v is String) return v;
  return v.toString();
}

List<Map<String, dynamic>>? _itemsRawList(Map<String, dynamic> json) {
  final raw = json['items'] ??
      json['lineItems'] ??
      json['line_items'] ??
      json['receiptItems'] ??
      json['receipt_items'];
  if (raw is! List) return null;
  return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
}

class Receipt {
  final String id;
  final String storeName;
  final double amount;
  final DateTime date;
  final String category;
  final String? imagePath;
  final String paidBy; // 결제한 사람 (참여자 이름)
  final String currencyCode; // KRW, USD...
  final String paymentMethod; // card / cash
  final String cardType; // credit / check

  /// 결제자 관점 정보 (OCR로 일부 추출 가능)
  final String? cardIssuer; // 카드사 (예: 신한카드)
  final String? bankName; // 은행 (예: 국민은행)
  final String? cardBrand; // VISA / MASTERCARD ...
  final String? cardLast4; // 카드 끝 4자리
  final double? cardBrandFeeRate;
  final double? cardIssuerFeeRate;
  final String? issuerFeeType;
  final double? issuerFeeFixedUsd;
  final double? cashExchangeFeeRate;
  final double? cashKrwPerUnit;
  final double? paymentCorrectionRate;
  final double? localToUsdRate;
  final double? usdAmount;
  final double? usdToKrwRate;
  final double? baseKrwAmount;
  final double? cardBrandFeeKrw;
  final double? cardIssuerFeeKrw;
  final double? estimatedKrwAmount;
  final double? actualKrwAmount;
  final String? exchangeRateSource;
  final String? rateDateLabel;
  final double? confidence;
  final List<String> warnings;
  final Map<String, dynamic>? recognition;

  /// 품목 목록 (OCR 파싱 + 사용자 편집)
  final List<ReceiptItem> items;

  Receipt({
    required this.id,
    required this.storeName,
    required this.amount,
    required this.date,
    required this.category,
    this.imagePath,
    required this.paidBy,
    this.currencyCode = 'KRW',
    this.paymentMethod = 'card',
    this.cardType = 'credit',
    this.cardIssuer,
    this.bankName,
    this.cardBrand,
    this.cardLast4,
    this.cardBrandFeeRate,
    this.cardIssuerFeeRate,
    this.issuerFeeType,
    this.issuerFeeFixedUsd,
    this.cashExchangeFeeRate,
    this.cashKrwPerUnit,
    this.paymentCorrectionRate,
    this.localToUsdRate,
    this.usdAmount,
    this.usdToKrwRate,
    this.baseKrwAmount,
    this.cardBrandFeeKrw,
    this.cardIssuerFeeKrw,
    this.estimatedKrwAmount,
    this.actualKrwAmount,
    this.exchangeRateSource,
    this.rateDateLabel,
    this.confidence,
    this.warnings = const [],
    this.recognition,
    List<ReceiptItem>? items,
  }) : items = items ?? const [];

  Receipt copyWith({
    String? id,
    String? storeName,
    double? amount,
    DateTime? date,
    String? category,
    String? imagePath,
    String? paidBy,
    String? currencyCode,
    String? paymentMethod,
    String? cardType,
    String? cardIssuer,
    String? bankName,
    String? cardBrand,
    String? cardLast4,
    double? cardBrandFeeRate,
    double? cardIssuerFeeRate,
    String? issuerFeeType,
    double? issuerFeeFixedUsd,
    double? cashExchangeFeeRate,
    double? cashKrwPerUnit,
    double? paymentCorrectionRate,
    double? localToUsdRate,
    double? usdAmount,
    double? usdToKrwRate,
    double? baseKrwAmount,
    double? cardBrandFeeKrw,
    double? cardIssuerFeeKrw,
    double? estimatedKrwAmount,
    double? actualKrwAmount,
    String? exchangeRateSource,
    String? rateDateLabel,
    double? confidence,
    List<String>? warnings,
    Map<String, dynamic>? recognition,
    List<ReceiptItem>? items,
  }) {
    return Receipt(
      id: id ?? this.id,
      storeName: storeName ?? this.storeName,
      amount: amount ?? this.amount,
      date: date ?? this.date,
      category: category ?? this.category,
      imagePath: imagePath ?? this.imagePath,
      paidBy: paidBy ?? this.paidBy,
      currencyCode: currencyCode ?? this.currencyCode,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      cardType: cardType ?? this.cardType,
      cardIssuer: cardIssuer ?? this.cardIssuer,
      bankName: bankName ?? this.bankName,
      cardBrand: cardBrand ?? this.cardBrand,
      cardLast4: cardLast4 ?? this.cardLast4,
      cardBrandFeeRate: cardBrandFeeRate ?? this.cardBrandFeeRate,
      cardIssuerFeeRate: cardIssuerFeeRate ?? this.cardIssuerFeeRate,
      issuerFeeType: issuerFeeType ?? this.issuerFeeType,
      issuerFeeFixedUsd: issuerFeeFixedUsd ?? this.issuerFeeFixedUsd,
      cashExchangeFeeRate: cashExchangeFeeRate ?? this.cashExchangeFeeRate,
      cashKrwPerUnit: cashKrwPerUnit ?? this.cashKrwPerUnit,
      paymentCorrectionRate:
          paymentCorrectionRate ?? this.paymentCorrectionRate,
      localToUsdRate: localToUsdRate ?? this.localToUsdRate,
      usdAmount: usdAmount ?? this.usdAmount,
      usdToKrwRate: usdToKrwRate ?? this.usdToKrwRate,
      baseKrwAmount: baseKrwAmount ?? this.baseKrwAmount,
      cardBrandFeeKrw: cardBrandFeeKrw ?? this.cardBrandFeeKrw,
      cardIssuerFeeKrw: cardIssuerFeeKrw ?? this.cardIssuerFeeKrw,
      estimatedKrwAmount: estimatedKrwAmount ?? this.estimatedKrwAmount,
      actualKrwAmount: actualKrwAmount ?? this.actualKrwAmount,
      exchangeRateSource: exchangeRateSource ?? this.exchangeRateSource,
      rateDateLabel: rateDateLabel ?? this.rateDateLabel,
      confidence: confidence ?? this.confidence,
      warnings: warnings ?? this.warnings,
      recognition: recognition ?? this.recognition,
      items: items ?? this.items,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'storeName': storeName,
      'amount': amount,
      'date': date.toIso8601String(),
      'category': category,
      'imagePath': imagePath,
      'paidBy': paidBy,
      'currencyCode': currencyCode,
      'paymentMethod': paymentMethod,
      'cardType': cardType,
      'cardIssuer': cardIssuer,
      'bankName': bankName,
      'cardBrand': cardBrand,
      'cardLast4': cardLast4,
      'cardBrandFeeRate': cardBrandFeeRate,
      'cardIssuerFeeRate': cardIssuerFeeRate,
      'issuerFeeType': issuerFeeType,
      'issuerFeeFixedUsd': issuerFeeFixedUsd,
      'cashExchangeFeeRate': cashExchangeFeeRate,
      'cashKrwPerUnit': cashKrwPerUnit,
      'paymentCorrectionRate': paymentCorrectionRate,
      'localToUsdRate': localToUsdRate,
      'usdAmount': usdAmount,
      'usdToKrwRate': usdToKrwRate,
      'baseKrwAmount': baseKrwAmount,
      'cardBrandFeeKrw': cardBrandFeeKrw,
      'cardIssuerFeeKrw': cardIssuerFeeKrw,
      'estimatedKrwAmount': estimatedKrwAmount,
      'actualKrwAmount': actualKrwAmount,
      'exchangeRateSource': exchangeRateSource,
      'rateDateLabel': rateDateLabel,
      'confidence': confidence,
      'warnings': warnings,
      'recognition': recognition,
      'items': items.map((e) => e.toJson()).toList(),
    };
  }

  factory Receipt.fromJson(Map<String, dynamic> json) {
    final datePrim = json['date'] ?? json['paidAt'] ?? json['paid_at'];
    final dateStr = _str(datePrim);
    final itemsList = _itemsRawList(json);
    return Receipt(
      id: _str(json['id']),
      storeName: _str(_jsonVal(json, 'storeName', 'store_name')),
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      date: DateTime.parse(dateStr),
      category: _str(json['category'], fallback: '기타'),
      imagePath: _jsonVal(json, 'imagePath', 'image_path') as String?,
      paidBy: _str(_jsonVal(json, 'paidBy', 'paid_by'), fallback: ''),
      currencyCode: _str(_jsonVal(json, 'currencyCode', 'currency_code'),
          fallback: 'KRW'),
      paymentMethod: _str(
        _jsonVal(json, 'paymentMethod', 'payment_method'),
        fallback: 'card',
      ),
      cardType:
          _str(_jsonVal(json, 'cardType', 'card_type'), fallback: 'credit'),
      cardIssuer: _jsonVal(json, 'cardIssuer', 'card_issuer') as String?,
      bankName: _jsonVal(json, 'bankName', 'bank_name') as String?,
      cardBrand: _jsonVal(json, 'cardBrand', 'card_brand') as String?,
      cardLast4: _jsonVal(json, 'cardLast4', 'card_last4') as String?,
      cardBrandFeeRate:
          (_jsonVal(json, 'cardBrandFeeRate', 'card_brand_fee_rate') as num?)
              ?.toDouble(),
      cardIssuerFeeRate:
          (_jsonVal(json, 'cardIssuerFeeRate', 'card_issuer_fee_rate') as num?)
              ?.toDouble(),
      issuerFeeType:
          _jsonVal(json, 'issuerFeeType', 'issuer_fee_type') as String?,
      issuerFeeFixedUsd:
          (_jsonVal(json, 'issuerFeeFixedUsd', 'issuer_fee_fixed_usd') as num?)
              ?.toDouble(),
      cashExchangeFeeRate:
          (_jsonVal(json, 'cashExchangeFeeRate', 'cash_exchange_fee_rate')
                  as num?)
              ?.toDouble(),
      cashKrwPerUnit:
          (_jsonVal(json, 'cashKrwPerUnit', 'cash_krw_per_unit') as num?)
              ?.toDouble(),
      paymentCorrectionRate:
          (_jsonVal(json, 'paymentCorrectionRate', 'payment_correction_rate')
                  as num?)
              ?.toDouble(),
      localToUsdRate:
          (_jsonVal(json, 'localToUsdRate', 'local_to_usd_rate') as num?)
              ?.toDouble(),
      usdAmount:
          (_jsonVal(json, 'usdAmount', 'usd_amount') as num?)?.toDouble(),
      usdToKrwRate: (_jsonVal(json, 'usdToKrwRate', 'usd_to_krw_rate') as num?)
          ?.toDouble(),
      baseKrwAmount:
          (_jsonVal(json, 'baseKrwAmount', 'base_krw_amount') as num?)
              ?.toDouble(),
      cardBrandFeeKrw:
          (_jsonVal(json, 'cardBrandFeeKrw', 'card_brand_fee_krw') as num?)
              ?.toDouble(),
      cardIssuerFeeKrw:
          (_jsonVal(json, 'cardIssuerFeeKrw', 'card_issuer_fee_krw') as num?)
              ?.toDouble(),
      estimatedKrwAmount:
          (_jsonVal(json, 'estimatedKrwAmount', 'estimated_krw_amount') as num?)
              ?.toDouble(),
      actualKrwAmount:
          (_jsonVal(json, 'actualKrwAmount', 'actual_krw_amount') as num?)
              ?.toDouble(),
      exchangeRateSource:
          _jsonVal(json, 'exchangeRateSource', 'exchange_rate_source')
              as String?,
      rateDateLabel:
          _jsonVal(json, 'rateDateLabel', 'rate_date_label') as String?,
      confidence:
          (_jsonVal(json, 'confidence', 'confidence') as num?)?.toDouble(),
      warnings: _stringList(_jsonVal(json, 'warnings', 'warnings')),
      recognition: _mapValue(json['recognition']),
      items: itemsList?.map(ReceiptItem.fromJson).toList() ?? const [],
    );
  }
}

Map<String, dynamic>? _mapValue(dynamic raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return null;
}

List<String> _stringList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

class ReceiptItem {
  final String name;
  final String? translatedName;
  final double quantity;
  final double unitPrice;
  final double lineTotal;

  /// 참여자별 정산 수량 (사용자 입력)
  final Map<String, double> quantityByPerson;

  const ReceiptItem({
    required this.name,
    this.translatedName,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.quantityByPerson,
  });

  ReceiptItem copyWith({
    String? name,
    String? translatedName,
    double? quantity,
    double? unitPrice,
    double? lineTotal,
    Map<String, double>? quantityByPerson,
  }) {
    return ReceiptItem(
      name: name ?? this.name,
      translatedName: translatedName ?? this.translatedName,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      lineTotal: lineTotal ?? this.lineTotal,
      quantityByPerson: quantityByPerson ?? this.quantityByPerson,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'translatedName': translatedName,
        'quantity': quantity,
        'unitPrice': unitPrice,
        'lineTotal': lineTotal,
        'quantityByPerson': quantityByPerson,
      };

  factory ReceiptItem.fromJson(Map<String, dynamic> json) {
    final qbRaw = json['quantityByPerson'] ?? json['quantity_by_person'];
    Map<String, double>? qb;
    if (qbRaw is Map) {
      qb = qbRaw.map((k, v) {
        final n = v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0;
        return MapEntry(k.toString(), n);
      });
    }
    final qty = (json['quantity'] as num?)?.toDouble() ?? 0;
    final unit =
        (_jsonVal(json, 'unitPrice', 'unit_price') as num?)?.toDouble() ?? 0;
    var total =
        (_jsonVal(json, 'lineTotal', 'line_total') as num?)?.toDouble() ?? 0;
    if (total == 0 && qty > 0 && unit > 0) {
      total = qty * unit;
    }
    return ReceiptItem(
      name: _str(
        json['name'] ??
            json['itemName'] ??
            json['item_name'] ??
            json['productName'] ??
            json['product_name'],
      ),
      translatedName: _optionalStr(
        json['translatedName'] ??
            json['translated_name'] ??
            json['koreanName'] ??
            json['korean_name'],
      ),
      quantity: qty,
      unitPrice: unit,
      lineTotal: total,
      quantityByPerson: qb ?? const {},
    );
  }

  static String? _optionalStr(dynamic value) {
    final text = _str(value).trim();
    return text.isEmpty ? null : text;
  }
}
