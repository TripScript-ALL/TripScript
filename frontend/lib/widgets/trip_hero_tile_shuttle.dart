import 'package:flutter/material.dart';

import '../models/trip.dart';
import 'trip_hero_tile_content.dart';

/// 홈 타일 ↔ 여행 상세 Hero 비행 중 보여줄 셔틀 (중복 제거)
class TripHeroTileShuttle extends StatelessWidget {
  final Trip trip;
  final Animation<double> animation;
  final HeroFlightDirection flightDirection;

  /// 상세 헤더는 사진만 쓰는 경우 `false`
  final bool showText;

  const TripHeroTileShuttle({
    super.key,
    required this.trip,
    required this.animation,
    required this.flightDirection,
    this.showText = true,
  });

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) {
        final t = flightDirection == HeroFlightDirection.push
            ? curved.value
            : 1.0 - curved.value;

        return RepaintBoundary(
          child: Material(
            color: Colors.transparent,
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: TripHeroTileContent(
                  trip: trip,
                  t: t,
                  showText: showText,
                  hideText: true,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
