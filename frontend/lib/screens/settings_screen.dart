import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/trip_provider.dart';
import '../providers/trip_list_preferences_provider.dart';
import '../providers/theme_mode_provider.dart';
import '../providers/user_provider.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _refreshTrips(BuildContext context) async {
    final tripProvider = context.read<TripProvider>();
    await tripProvider.loadTrips();
    if (!context.mounted) return;
    final message =
        tripProvider.error == null ? '여행 데이터를 새로고침했습니다' : tripProvider.error!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final user = context.watch<UserProvider>().currentUser;
    final trips = context.watch<TripProvider>().trips;
    final themeModeProvider = context.watch<ThemeModeProvider>();
    final listPrefs = context.watch<TripListPreferencesProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('TripScript'),
              subtitle: Text(
                '해외결제 영수증 정산 플랫폼',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.palette_outlined),
                    title: Text('화면 테마'),
                    subtitle: Text('휴대폰 설정을 따르거나 앱에서 직접 고정합니다'),
                  ),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.phone_android),
                        label: Text('시스템'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('밝게'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined),
                        label: Text('어둡게'),
                      ),
                    ],
                    selected: {themeModeProvider.themeMode},
                    onSelectionChanged: (values) => context
                        .read<ThemeModeProvider>()
                        .setThemeMode(values.first),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.view_module_outlined),
                    title: Text('여행 목록 보기'),
                    subtitle: Text('메인 화면의 여행 목록 표시 방식을 선택합니다'),
                  ),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.grid_view_outlined),
                        label: Text('타일'),
                      ),
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.view_list_outlined),
                        label: Text('리스트'),
                      ),
                    ],
                    selected: {listPrefs.gridMode},
                    onSelectionChanged: (values) => context
                        .read<TripListPreferencesProvider>()
                        .setGridMode(values.first),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.account_circle_outlined),
                  title: const Text('현재 계정'),
                  subtitle: Text(
                    user == null
                        ? '로그인 정보 없음'
                        : '${user.displayName} · ${user.isKakaoLinked ? '카카오' : '전화번호'} 로그인',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cloud_sync_outlined),
                  title: const Text('여행 데이터 새로고침'),
                  subtitle: Text(
                    '현재 ${trips.length}개 여행이 앱에 로드됨',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                  onTap: () => _refreshTrips(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
