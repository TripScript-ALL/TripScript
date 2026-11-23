import '../models/trip.dart';
import 'exchange_rates.dart';

/// 여행 기간 안의 각 날짜별 일일 지출과 그날까지의 누적 지출
class TripDaySpending {
  final DateTime day;
  final double daily;
  final double cumulative;

  const TripDaySpending({
    required this.day,
    required this.daily,
    required this.cumulative,
  });
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// [trip.startDate]~[trip.endDate]의 각 날짜에 대해, 영수증 날짜가 해당 일에 속하면 합산합니다.
/// 영수증 날짜가 여행 기간 밖이면 해당 항목은 제외합니다.
List<TripDaySpending> computeTripDailySpending(Trip trip) {
  final start = _dateOnly(trip.startDate);
  final end = _dateOnly(trip.endDate);
  if (start.isAfter(end)) {
    return const [];
  }

  final byDay = <DateTime, double>{};
  for (final r in trip.receipts) {
    final d = _dateOnly(r.date);
    if (d.isBefore(start) || d.isAfter(end)) {
      continue;
    }
    byDay[d] = (byDay[d] ?? 0) + receiptAmountInKrw(r);
  }

  final out = <TripDaySpending>[];
  var cumulative = 0.0;
  for (var d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
    final daily = byDay[d] ?? 0;
    cumulative += daily;
    out.add(TripDaySpending(day: d, daily: daily, cumulative: cumulative));
  }
  return out;
}
