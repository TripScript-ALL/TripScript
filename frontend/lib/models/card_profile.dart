class CardProfile {
  final String id;
  final String name;
  final String company;
  final String brand;
  final String cardType;
  final String? last4;
  final double? issuerFeeRate;
  final String? issuerFeeType;
  final double? issuerFeeFixedUsd;
  final double? brandFeeRate;
  final bool networkFeeWaived;
  final bool issuerFeeWaived;
  final String? productOverrideNote;
  final String feeResearchStatus;
  final String? feeResearchSummary;
  final List<Map<String, dynamic>> feeResearchSources;
  final String? feeResearchCheckedAt;
  final String? feeResearchError;

  const CardProfile({
    required this.id,
    required this.name,
    required this.company,
    required this.brand,
    this.cardType = 'credit',
    this.last4,
    this.issuerFeeRate,
    this.issuerFeeType,
    this.issuerFeeFixedUsd,
    this.brandFeeRate,
    this.networkFeeWaived = false,
    this.issuerFeeWaived = false,
    this.productOverrideNote,
    this.feeResearchStatus = 'idle',
    this.feeResearchSummary,
    this.feeResearchSources = const [],
    this.feeResearchCheckedAt,
    this.feeResearchError,
  });

  String get displayName {
    final parts = [
      name,
      switch (cardType) {
        'check' => '체크',
        'prepaid' => '외화/선불',
        _ => '신용',
      },
      if (company.isNotEmpty) company,
      if (brand.isNotEmpty) brand,
      if (last4 != null && last4!.isNotEmpty) '끝 ${last4!}',
    ];
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'company': company,
        'brand': brand,
        'cardType': cardType,
        'last4': last4,
        'issuerFeeRate': issuerFeeRate,
        'issuerFeeType': issuerFeeType,
        'issuerFeeFixedUsd': issuerFeeFixedUsd,
        'brandFeeRate': brandFeeRate,
        'networkFeeWaived': networkFeeWaived,
        'issuerFeeWaived': issuerFeeWaived,
        'productOverrideNote': productOverrideNote,
        'feeResearchStatus': feeResearchStatus,
        'feeResearchSummary': feeResearchSummary,
        'feeResearchSources': feeResearchSources,
        'feeResearchCheckedAt': feeResearchCheckedAt,
        'feeResearchError': feeResearchError,
      };

  factory CardProfile.fromJson(Map<String, dynamic> json) {
    final legacyIssuer = json['issuer'] as String?;
    final legacyType = json['cardType'] as String?;
    bool boolValue(dynamic value) =>
        value == true || value == 1 || value == '1' || value == 'true';

    return CardProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? legacyType ?? legacyIssuer ?? '',
      company: json['company'] as String? ?? legacyIssuer ?? '',
      brand: json['brand'] as String? ?? '',
      cardType: _normalizeCardType(json['cardType'] ?? json['card_type']),
      last4: json['last4'] as String?,
      issuerFeeRate: (json['issuerFeeRate'] as num?)?.toDouble() ??
          (json['issuer_fee_rate'] as num?)?.toDouble(),
      issuerFeeType: json['issuerFeeType'] as String? ??
          json['issuer_fee_type'] as String?,
      issuerFeeFixedUsd: (json['issuerFeeFixedUsd'] as num?)?.toDouble() ??
          (json['issuer_fee_fixed_usd'] as num?)?.toDouble(),
      brandFeeRate: (json['brandFeeRate'] as num?)?.toDouble() ??
          (json['brand_fee_rate'] as num?)?.toDouble(),
      networkFeeWaived: boolValue(json['networkFeeWaived']) ||
          boolValue(json['network_fee_waived']),
      issuerFeeWaived: boolValue(json['issuerFeeWaived']) ||
          boolValue(json['issuer_fee_waived']),
      productOverrideNote: json['productOverrideNote'] as String? ??
          json['product_override_note'] as String?,
      feeResearchStatus: json['feeResearchStatus'] as String? ??
          json['fee_research_status'] as String? ??
          'idle',
      feeResearchSummary: json['feeResearchSummary'] as String? ??
          json['fee_research_summary'] as String?,
      feeResearchSources: _sourceList(
        json['feeResearchSources'] ?? json['fee_research_sources'],
      ),
      feeResearchCheckedAt: json['feeResearchCheckedAt'] as String? ??
          json['fee_research_checked_at'] as String?,
      feeResearchError: json['feeResearchError'] as String? ??
          json['fee_research_error'] as String?,
    );
  }
}

List<Map<String, dynamic>> _sourceList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
}

String _normalizeCardType(dynamic value) {
  final raw = value?.toString().toLowerCase() ?? '';
  if (raw == 'prepaid' ||
      raw == 'wallet' ||
      raw == 'foreign_wallet' ||
      raw == '선불' ||
      raw == '외화' ||
      raw == '외화선불' ||
      raw == '외화머니') {
    return 'prepaid';
  }
  if (raw == 'check' || raw == 'debit' || raw == '체크' || raw == '체크카드') {
    return 'check';
  }
  return 'credit';
}
