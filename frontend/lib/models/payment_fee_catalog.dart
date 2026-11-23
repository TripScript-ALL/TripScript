class PaymentFeeOption {
  final String id;
  final String label;
  final double rate;

  const PaymentFeeOption({
    required this.id,
    required this.label,
    required this.rate,
  });

  factory PaymentFeeOption.fromJson(Map<String, dynamic> json) {
    return PaymentFeeOption(
      id: json['id'] as String? ?? json['label'] as String? ?? '',
      label: json['label'] as String? ?? '',
      rate: (json['rate'] as num?)?.toDouble() ?? 0,
    );
  }
}

class PaymentFeeCatalog {
  final List<PaymentFeeOption> issuers;
  final List<PaymentFeeOption> brands;
  final List<CardProductOption> products;

  const PaymentFeeCatalog({
    required this.issuers,
    required this.brands,
    this.products = const [],
  });

  factory PaymentFeeCatalog.fromJson(Map<String, dynamic> json) {
    List<PaymentFeeOption> parseOptions(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((e) => PaymentFeeOption.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.label.isNotEmpty)
          .toList();
    }

    return PaymentFeeCatalog(
      issuers: parseOptions(json['issuers']),
      brands: parseOptions(json['brands']),
      products: CardProductOption.listFromJson(json['products']),
    );
  }
}

class CardProductOption {
  final String name;
  final String company;
  final String brand;
  final String cardType;
  final String category;

  const CardProductOption({
    required this.name,
    required this.company,
    required this.brand,
    required this.cardType,
    required this.category,
  });

  factory CardProductOption.fromJson(Map<String, dynamic> json) {
    return CardProductOption(
      name: json['name'] as String? ?? '',
      company: json['company'] as String? ?? '',
      brand: json['brand'] as String? ?? '',
      cardType: json['cardType'] as String? ?? 'credit',
      category: json['category'] as String? ?? '',
    );
  }

  static List<CardProductOption> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => CardProductOption.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.name.isNotEmpty)
        .toList();
  }
}
