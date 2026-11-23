import 'dart:io';

import 'package:flutter/material.dart';

import '../data/reference_lists.dart';
import '../models/trip.dart';
import '../utils/exchange_rates.dart';
import '../utils/format_money.dart';

class TripHeroTileContent extends StatelessWidget {
  final Trip trip;

  /// 0.0 = 그리드 타일(컴팩트), 1.0 = 상세 헤더(확장)
  final double t;

  /// true면 타일/헤더 위에 텍스트를 그린다.
  /// false면 사진+그라데이션만 보여서 "타일 사진에 글자 없음" 요구를 만족한다.
  final bool showText;

  /// 전환(비행) 중에는 텍스트를 숨기고, 전환이 끝난 뒤 짧게 페이드인 시킬 때 사용
  final bool hideText;

  const TripHeroTileContent({
    super.key,
    required this.trip,
    required this.t,
    this.showText = true,
    this.hideText = false,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = trip.dateLabelShort;
    final total = tripTotalInKrw(trip);

    final backgroundColor =
        trip.tileColor != null ? Color(trip.tileColor!) : Colors.grey.shade400;

    final padding = EdgeInsets.lerp(
          const EdgeInsets.fromLTRB(12, 0, 12, 12),
          const EdgeInsets.fromLTRB(16, 0, 16, 16),
          t,
        ) ??
        const EdgeInsets.fromLTRB(12, 0, 12, 12);

    // 폰트 크기는 "타일(터치 전)" 기준으로 고정해 전환 전/후 이질감을 없앤다.
    // 위치/패딩만 애니메이션으로 자연스럽게 이동.
    // 날짜는 범위 문자열이 길어질 수 있어 타일(t≈0)에서만 더 작게(헤더에서는 다른 메타와 맞춤).
    const titleFontSize = 16.0;
    const metaFontSize = 12.0;
    final dateFontSize = lerpDouble(9.5, 12.0, t) ?? 11.0;
    final metaOpacity = lerpDouble(0.74, 0.80, t) ?? 0.76;

    final gradientAlpha = lerpDouble(0.70, 0.72, t) ?? 0.71;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (trip.coverImagePath != null && trip.coverImagePath!.isNotEmpty)
          _TripCoverImage(imagePath: trip.coverImagePath!)
        else
          Container(color: backgroundColor),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: gradientAlpha),
              ],
            ),
          ),
        ),
        Positioned(
          left: padding.left,
          right: padding.right,
          bottom: padding.bottom,
          child: showText
              ? _TripHeroText(
                  trip: trip,
                  dateStr: dateStr,
                  total: total,
                  titleFontSize: titleFontSize,
                  metaFontSize: metaFontSize,
                  dateFontSize: dateFontSize,
                  metaOpacity: metaOpacity,
                  spacing: lerpDouble(6, 8, t) ?? 7,
                  hideText: hideText,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  double? lerpDouble(double a, double b, double t) => a + (b - a) * t;
}

class _TripCoverImage extends StatelessWidget {
  final String imagePath;

  const _TripCoverImage({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    if (imagePath.startsWith('http://') || imagePath.startsWith('https://')) {
      return Image.network(
        imagePath,
        fit: BoxFit.cover,
        cacheWidth: 900,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
    }
    return Image.file(
      File(imagePath),
      fit: BoxFit.cover,
      cacheWidth: 900,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}

class _TripHeroText extends StatefulWidget {
  final Trip trip;
  final String dateStr;
  final double total;
  final double titleFontSize;
  final double metaFontSize;
  final double dateFontSize;
  final double metaOpacity;
  final double spacing;
  final bool hideText;

  const _TripHeroText({
    required this.trip,
    required this.dateStr,
    required this.total,
    required this.titleFontSize,
    required this.metaFontSize,
    required this.dateFontSize,
    required this.metaOpacity,
    required this.spacing,
    required this.hideText,
  });

  @override
  State<_TripHeroText> createState() => _TripHeroTextState();
}

class _TripHeroTextState extends State<_TripHeroText> {
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    if (widget.hideText) {
      _visible = false;
    }
  }

  @override
  void didUpdateWidget(covariant _TripHeroText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hideText != widget.hideText) {
      if (widget.hideText) {
        setState(() => _visible = false);
      } else {
        // 비행이 끝났을 때 아주 짧게 페이드인
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _visible = true);
        });
      }
    }
  }

  TextStyle? _metaStyle(TextTheme tt, double fontSize) {
    return tt.bodySmall?.copyWith(
      fontSize: fontSize,
      color: Colors.white.withValues(alpha: widget.metaOpacity),
      shadows: const [
        Shadow(
          color: Colors.black54,
          offset: Offset(0, 1),
          blurRadius: 2,
        ),
      ],
    );
  }

  Widget _metaLine(TextTheme tt, String text) {
    return ClipRect(
      child: Text(
        text,
        style: _metaStyle(tt, widget.metaFontSize),
        maxLines: 1,
        overflow: TextOverflow.fade,
        softWrap: false,
      ),
    );
  }

  /// 날짜 범위가 길 때 타일 너비에 맞게 한 줄로 축소
  Widget _dateLine(TextTheme tt) {
    return ClipRect(
      child: Align(
        alignment: Alignment.centerLeft,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            widget.dateStr,
            style: _metaStyle(tt, widget.dateFontSize),
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.trip.name,
            style: tt.titleLarge?.copyWith(
              fontSize: widget.titleFontSize,
              color: Colors.white.withValues(alpha: 0.92),
              fontWeight: FontWeight.w700,
              shadows: const [
                Shadow(
                  color: Colors.black54,
                  offset: Offset(0, 1),
                  blurRadius: 2,
                ),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.fade,
            softWrap: false,
          ),
          SizedBox(height: widget.spacing),
          _dateLine(tt),
          if (widget.trip.countries.isNotEmpty) ...[
            const SizedBox(height: 2),
            _metaLine(tt, countryFlags(widget.trip.countries, max: 6)),
          ],
          const SizedBox(height: 2),
          _metaLine(
            tt,
            '${widget.trip.participants.length}명',
          ),
          const SizedBox(height: 2),
          _metaLine(
            tt,
            formatWonLabel(widget.total),
          ),
        ],
      ),
    );
  }
}
