import 'package:flutter/material.dart';

class AppInfoScreen extends StatelessWidget {
  const AppInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('서비스 설명')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'TripScript',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '해외여행 영수증을 인식하고, 현지통화·환율·카드 수수료를 반영해 더 현실적인 정산액을 계산하는 플랫폼입니다.',
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _InfoCard(
            icon: Icons.receipt_long_outlined,
            title: '영수증 인식',
            body:
                '영수증 이미지를 서버에 업로드하면 Gemini 기반 인식 파이프라인이 상호명, 금액, 품목, 통화, 날짜를 추출합니다. '
                '총액과 품목 합계를 검증하고 신뢰도와 경고를 함께 표시합니다.',
          ),
          _InfoCard(
            icon: Icons.currency_exchange,
            title: '해외결제 계산',
            body:
                '카드 결제는 현지통화 → USD → KRW 흐름을 기준으로 국제브랜드 수수료와 카드사 해외서비스 수수료를 반영합니다. '
                '실제 청구액을 입력하면 정산에는 실제값이 우선 적용됩니다.',
          ),
          _InfoCard(
            icon: Icons.privacy_tip_outlined,
            title: '개인정보와 외부 AI',
            body:
                'MVP에서는 정확한 인식을 위해 백엔드 서버에서 외부 AI API를 호출합니다. API 키는 앱에 포함하지 않고 서버에만 보관하며, '
                '카드번호 전체, CVC, 유효기간은 수집하지 않습니다.',
          ),
          _InfoCard(
            icon: Icons.dns_outlined,
            title: '서버 연결',
            body:
                '앱은 공개 API 터널을 통해 서버컴의 FastAPI 백엔드와 통신합니다. 관리자 페이지에서는 영수증 인식 로그와 데이터 상태를 확인할 수 있습니다.',
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
