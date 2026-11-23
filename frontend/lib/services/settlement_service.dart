import '../models/trip.dart';
import '../utils/exchange_rates.dart';

/// 참여자별 정산 결과
class SettlementResult {
  final String from; // 돈을 보내는 사람
  final String to; // 돈을 받는 사람
  final double amount;

  SettlementResult({
    required this.from,
    required this.to,
    required this.amount,
  });
}

/// 참여자별 지출/수령 요약
class ParticipantBalance {
  final String name;
  final double paid; // 총 지출액
  final double fairShare; // 부담해야 할 금액
  final double balance; // paid - fairShare (양수: 받아야 함, 음수: 내야 함)

  ParticipantBalance({
    required this.name,
    required this.paid,
    required this.fairShare,
    required this.balance,
  });
}

class SettlementService {
  /// 여행 비용 정산 계산
  static List<SettlementResult> calculate(Trip trip) {
    if (trip.participants.isEmpty || trip.receipts.isEmpty) {
      return [];
    }

    final balances = _getParticipantBalances(trip);
    var debtRemaining = <String, double>{};
    var creditRemaining = <String, double>{};

    for (final b in balances) {
      if (b.balance < -0.01) {
        debtRemaining[b.name] = -b.balance;
      } else if (b.balance > 0.01) {
        creditRemaining[b.name] = b.balance;
      }
    }

    final results = <SettlementResult>[];
    final debtors = debtRemaining.keys.toList();
    final creditors = creditRemaining.keys.toList();
    int d = 0, c = 0;

    while (d < debtors.length && c < creditors.length) {
      final debtor = debtors[d];
      final creditor = creditors[c];
      final debt = debtRemaining[debtor]!;
      final credit = creditRemaining[creditor]!;
      final amount = debt < credit ? debt : credit;

      if (amount > 0.01) {
        results.add(SettlementResult(
          from: debtor,
          to: creditor,
          amount: double.parse(amount.toStringAsFixed(0)),
        ));
      }

      debtRemaining[debtor] = debt - amount;
      creditRemaining[creditor] = credit - amount;

      if (debtRemaining[debtor]! < 0.01) d++;
      if (creditRemaining[creditor]! < 0.01) c++;
    }

    return results;
  }

  static List<ParticipantBalance> getParticipantBalances(Trip trip) {
    return _getParticipantBalances(trip);
  }

  static List<ParticipantBalance> _getParticipantBalances(Trip trip) {
    final owed = _owedByParticipant(trip);

    return trip.participants.map((name) {
      final paid = trip.receipts
          .where((r) => r.paidBy == name)
          .fold(0.0, (sum, r) => sum + receiptAmountInKrw(r));
      final fairShare = owed[name] ?? 0.0;
      return ParticipantBalance(
        name: name,
        paid: paid,
        fairShare: fairShare,
        balance: paid - fairShare,
      );
    }).toList();
  }

  static Map<String, double> _owedByParticipant(Trip trip) {
    final owed = {for (final p in trip.participants) p: 0.0};
    if (trip.participants.isEmpty) return owed;

    void splitEvenly(double amount) {
      final each = amount / trip.participants.length;
      for (final p in trip.participants) {
        owed[p] = (owed[p] ?? 0) + each;
      }
    }

    for (final receipt in trip.receipts) {
      final receiptTotalKrw = receiptAmountInKrw(receipt);
      if (receipt.items.isEmpty) {
        splitEvenly(receiptTotalKrw);
        continue;
      }

      final rawItemOwed = {for (final p in trip.participants) p: 0.0};
      var itemTotalKrw = 0.0;

      for (final item in receipt.items) {
        final itemAmountKrw =
            item.lineTotal * exchangeRateFor(receipt.currencyCode);
        itemTotalKrw += itemAmountKrw;

        final targets = item.quantityByPerson.entries
            .where((e) => e.value > 0 && rawItemOwed.containsKey(e.key))
            .toList();
        if (targets.isEmpty) {
          final each = itemAmountKrw / trip.participants.length;
          for (final p in trip.participants) {
            rawItemOwed[p] = (rawItemOwed[p] ?? 0) + each;
          }
          continue;
        }

        final qtySum = targets.fold(0.0, (sum, e) => sum + e.value);
        if (qtySum <= 0) continue;
        for (final target in targets) {
          rawItemOwed[target.key] = (rawItemOwed[target.key] ?? 0) +
              itemAmountKrw * target.value / qtySum;
        }
      }

      final scale = itemTotalKrw > 0 ? receiptTotalKrw / itemTotalKrw : 1.0;
      for (final p in trip.participants) {
        owed[p] = (owed[p] ?? 0) + (rawItemOwed[p] ?? 0) * scale;
      }
    }

    return owed;
  }
}
