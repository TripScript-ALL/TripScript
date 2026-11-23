import '../models/trip.dart';

/// [AppConfig.isDeveloperMode] 일 때 목록이 비어 있으면 넣는 샘플 여행 (로컬 전용, API 없음).
Trip kDefaultDevTrip() {
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day);
  final end = start.add(const Duration(days: 2));
  return Trip(
    id: '00000000-0000-4000-8000-000000000002',
    name: '개발용 샘플 여행',
    startDate: start,
    endDate: end,
    participants: const ['로컬개발', '동행1'],
    hostName: '로컬개발',
  );
}
