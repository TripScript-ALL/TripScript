class ParticipantSettlementBalance {
  final String name;
  final double paid;
  final double fairShare;
  final double balance;

  const ParticipantSettlementBalance({
    required this.name,
    required this.paid,
    required this.fairShare,
    required this.balance,
  });

  factory ParticipantSettlementBalance.fromJson(Map<String, dynamic> json) {
    return ParticipantSettlementBalance(
      name: json['name'] as String? ?? '',
      paid: (json['paid'] as num?)?.toDouble() ?? 0,
      fairShare: (json['fairShare'] as num?)?.toDouble() ?? 0,
      balance: (json['balance'] as num?)?.toDouble() ?? 0,
    );
  }
}

class SettlementTransfer {
  final String from;
  final String to;
  final double amount;
  final bool completed;
  final String? statusUpdatedAt;
  final String? statusUpdatedByUserId;

  const SettlementTransfer({
    required this.from,
    required this.to,
    required this.amount,
    this.completed = false,
    this.statusUpdatedAt,
    this.statusUpdatedByUserId,
  });

  factory SettlementTransfer.fromJson(Map<String, dynamic> json) {
    return SettlementTransfer(
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      completed: json['completed'] == true,
      statusUpdatedAt: json['statusUpdatedAt'] as String?,
      statusUpdatedByUserId: json['statusUpdatedByUserId'] as String?,
    );
  }
}

class SettlementAccountInfo {
  final String bankName;
  final String accountNumber;
  final String accountHolder;

  const SettlementAccountInfo({
    this.bankName = '',
    this.accountNumber = '',
    this.accountHolder = '',
  });

  factory SettlementAccountInfo.fromJson(Map<String, dynamic> json) {
    return SettlementAccountInfo(
      bankName:
          json['bankName'] as String? ?? json['bank_name'] as String? ?? '',
      accountNumber: json['accountNumber'] as String? ??
          json['account_number'] as String? ??
          '',
      accountHolder: json['accountHolder'] as String? ??
          json['account_holder'] as String? ??
          '',
    );
  }
}

class SettlementItemBreakdown {
  final String name;
  final double lineTotal;
  final Map<String, double> participantShares;

  const SettlementItemBreakdown({
    required this.name,
    required this.lineTotal,
    required this.participantShares,
  });

  factory SettlementItemBreakdown.fromJson(Map<String, dynamic> json) {
    final rawShares = json['participantShares'];
    return SettlementItemBreakdown(
      name: json['name'] as String? ?? '',
      lineTotal: (json['lineTotal'] as num?)?.toDouble() ?? 0,
      participantShares: rawShares is Map
          ? rawShares.map(
              (key, value) => MapEntry(
                key.toString(),
                (value as num?)?.toDouble() ?? 0,
              ),
            )
          : const {},
    );
  }
}

class ReceiptSettlementBreakdown {
  final String receiptId;
  final String storeName;
  final String paidBy;
  final double amount;
  final String currencyCode;
  final double settlementKrwAmount;
  final int itemCount;
  final String splitBasis;
  final Map<String, double> participantShares;
  final List<SettlementItemBreakdown> itemShares;

  const ReceiptSettlementBreakdown({
    required this.receiptId,
    required this.storeName,
    required this.paidBy,
    required this.amount,
    required this.currencyCode,
    required this.settlementKrwAmount,
    required this.itemCount,
    required this.splitBasis,
    required this.participantShares,
    this.itemShares = const [],
  });

  factory ReceiptSettlementBreakdown.fromJson(Map<String, dynamic> json) {
    final rawShares = json['participantShares'];
    return ReceiptSettlementBreakdown(
      receiptId: json['receiptId'] as String? ?? '',
      storeName: json['storeName'] as String? ?? '',
      paidBy: json['paidBy'] as String? ?? '',
      amount: (json['amount'] as num?)?.toDouble() ?? 0,
      currencyCode: json['currencyCode'] as String? ?? 'KRW',
      settlementKrwAmount:
          (json['settlementKrwAmount'] as num?)?.toDouble() ?? 0,
      itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
      splitBasis: json['splitBasis'] as String? ?? '',
      participantShares: rawShares is Map
          ? rawShares.map(
              (key, value) => MapEntry(
                key.toString(),
                (value as num?)?.toDouble() ?? 0,
              ),
            )
          : const {},
      itemShares: (json['itemShares'] as List?)
              ?.whereType<Map>()
              .map((item) => SettlementItemBreakdown.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList() ??
          const [],
    );
  }
}

class SettlementSummary {
  final double totalKrw;
  final Map<String, double> totalsByCurrency;
  final List<ParticipantSettlementBalance> balances;
  final List<SettlementTransfer> grossTransfers;
  final List<SettlementTransfer> transfers;
  final Map<String, SettlementAccountInfo> participantAccounts;
  final List<ReceiptSettlementBreakdown> receiptBreakdown;
  final List<String> calculationNotes;

  const SettlementSummary({
    required this.totalKrw,
    required this.totalsByCurrency,
    required this.balances,
    this.grossTransfers = const [],
    required this.transfers,
    this.participantAccounts = const {},
    this.receiptBreakdown = const [],
    this.calculationNotes = const [],
  });

  factory SettlementSummary.fromJson(Map<String, dynamic> json) {
    final rawTotals = json['totalsByCurrency'];
    final rawAccounts = json['participantAccounts'];
    return SettlementSummary(
      totalKrw: (json['totalKrw'] as num?)?.toDouble() ?? 0,
      totalsByCurrency: rawTotals is Map
          ? rawTotals.map(
              (key, value) => MapEntry(
                key.toString(),
                (value as num?)?.toDouble() ?? 0,
              ),
            )
          : const {},
      balances: (json['balances'] as List?)
              ?.whereType<Map>()
              .map((item) => ParticipantSettlementBalance.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .where((item) => item.name.isNotEmpty)
              .toList() ??
          const [],
      grossTransfers: (json['grossTransfers'] as List?)
              ?.whereType<Map>()
              .map((item) => SettlementTransfer.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .where((item) => item.from.isNotEmpty && item.to.isNotEmpty)
              .toList() ??
          const [],
      transfers: (json['transfers'] as List?)
              ?.whereType<Map>()
              .map((item) => SettlementTransfer.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .where((item) => item.from.isNotEmpty && item.to.isNotEmpty)
              .toList() ??
          const [],
      participantAccounts: rawAccounts is Map
          ? rawAccounts.map(
              (key, value) => MapEntry(
                key.toString(),
                value is Map
                    ? SettlementAccountInfo.fromJson(
                        Map<String, dynamic>.from(value),
                      )
                    : const SettlementAccountInfo(),
              ),
            )
          : const {},
      receiptBreakdown: (json['receiptBreakdown'] as List?)
              ?.whereType<Map>()
              .map((item) => ReceiptSettlementBreakdown.fromJson(
                    Map<String, dynamic>.from(item),
                  ))
              .toList() ??
          const [],
      calculationNotes: (json['calculationNotes'] as List?)
              ?.map((e) => e.toString())
              .where((e) => e.trim().isNotEmpty)
              .toList() ??
          const [],
    );
  }
}
