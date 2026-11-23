import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/reference_lists.dart';
import '../models/trip.dart';
import '../providers/trip_list_preferences_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../utils/exchange_rates.dart';
import '../utils/format_money.dart';
import '../widgets/trip_hero_tile_content.dart';
import '../widgets/trip_hero_tile_shuttle.dart';
import 'add_trip_screen.dart';
import 'app_info_screen.dart';
import 'card_list_screen.dart';
import 'login_screen.dart';
import 'my_page_screen.dart';
import 'settings_screen.dart';
import 'trip_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.showKakaoDisplayNameHint = false});

  final bool showKakaoDisplayNameHint;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  _HomeTripSort _sortMode = _HomeTripSort.nearest;

  @override
  void initState() {
    super.initState();
    if (widget.showKakaoDisplayNameHint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('마이페이지에서 앱에 보일 닉네임을 바꿀 수 있어요.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 6),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _TripScriptMark(size: 24),
            const SizedBox(width: 8),
            Text(
              'TripScript',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      drawer: _HomeDrawer(
        onOpenMyPage: () => _openDrawerScreen(const MyPageScreen()),
        onOpenCards: () => _openDrawerScreen(const CardListScreen()),
        onOpenInfo: () => _openDrawerScreen(const AppInfoScreen()),
        onOpenSettings: () => _openDrawerScreen(const SettingsScreen()),
        onLogout: _logout,
      ),
      body: Consumer<TripProvider>(
        builder: (context, provider, _) {
          Future<void> refreshTrips() =>
              context.read<TripProvider>().loadTrips();

          if (provider.trips.isEmpty) {
            return RefreshIndicator(
              onRefresh: refreshTrips,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight:
                        MediaQuery.sizeOf(context).height -
                            MediaQuery.paddingOf(context).vertical -
                            kToolbarHeight,
                  ),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.receipt_long,
                          size: 80,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '아직 여행이 없습니다',
                          style: TextStyle(
                            fontSize: 18,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '새 여행을 추가해 보세요',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          final trips = _sortedTrips(provider.trips);
          final gridMode =
              context.watch<TripListPreferencesProvider>().gridMode;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: SegmentedButton<_HomeTripSort>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: _HomeTripSort.nearest,
                      label: Text('일정 가까운 순'),
                    ),
                    ButtonSegment(
                      value: _HomeTripSort.farthest,
                      label: Text('일정 먼 순'),
                    ),
                    ButtonSegment(
                      value: _HomeTripSort.added,
                      label: Text('등록 순'),
                    ),
                  ],
                  selected: {_sortMode},
                  onSelectionChanged: (values) =>
                      setState(() => _sortMode = values.first),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: refreshTrips,
                  child: gridMode
                      ? GridView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 1,
                          ),
                          itemCount: trips.length,
                          itemBuilder: (context, index) {
                            final trip = trips[index];
                            return _TripTile(trip: trip);
                          },
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(12),
                          itemCount: trips.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) =>
                              _TripListRow(trip: trips[index]),
                        ),
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showTripActionSheet,
        icon: const Icon(Icons.add),
        label: const Text('여행 생성 / 참여'),
      ),
    );
  }

  List<Trip> _sortedTrips(List<Trip> trips) {
    final sorted = List<Trip>.from(trips);
    if (_sortMode == _HomeTripSort.added) return sorted;
    sorted.sort((a, b) {
      final diffA = _distanceFromToday(a);
      final diffB = _distanceFromToday(b);
      return _sortMode == _HomeTripSort.nearest
          ? diffA.compareTo(diffB)
          : diffB.compareTo(diffA);
    });
    return sorted;
  }

  int _distanceFromToday(Trip trip) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start =
        DateTime(trip.startDate.year, trip.startDate.month, trip.startDate.day);
    final end =
        DateTime(trip.endDate.year, trip.endDate.month, trip.endDate.day);
    if (!today.isBefore(start) && !today.isAfter(end)) return 0;
    final target = today.isBefore(start) ? start : end;
    return target.difference(today).inDays.abs();
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('로그아웃'),
        content: const Text('로그아웃 하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final userProvider = context.read<UserProvider>();
    final tripProvider = context.read<TripProvider>();
    final api = context.read<ApiService>();
    await StorageService().clearUserCredentials();
    api.clearAuthToken();
    userProvider.logout();
    tripProvider.setUserId(null);
    await tripProvider.loadTrips();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  void _openDrawerScreen(Widget screen) {
    Navigator.pop(context);
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  void _navigateToAddTrip() {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (context) => const AddTripScreen(),
      ),
    );
  }

  Future<void> _showTripActionSheet() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_location_alt_outlined),
              title: const Text('여행 생성'),
              subtitle: const Text('새 여행과 정산 공간을 만듭니다'),
              onTap: () => Navigator.pop(ctx, 'create'),
            ),
            ListTile(
              leading: const Icon(Icons.vpn_key_outlined),
              title: const Text('초대 코드로 참여'),
              subtitle: const Text('대표자가 공유한 코드로 여행에 들어갑니다'),
              onTap: () => Navigator.pop(ctx, 'join'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'create') {
      _navigateToAddTrip();
    } else if (action == 'join') {
      _showJoinTripDialog();
    }
  }

  Future<void> _showJoinTripDialog() async {
    final userName =
        context.read<UserProvider>().currentUser?.displayName ?? '';
    final provider = context.read<TripProvider>();

    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _JoinTripDialog(),
    );
    if (code == null || code.trim().isEmpty) return;
    if (!mounted) return;

    try {
      final trip = await provider.joinTripByInviteCode(
        inviteCode: code,
        userName: userName,
      );
      if (!mounted) return;
      if (trip == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${trip.name}에 참여했습니다')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }
}

class _HomeDrawer extends StatelessWidget {
  final VoidCallback onOpenMyPage;
  final VoidCallback onOpenCards;
  final VoidCallback onOpenInfo;
  final VoidCallback onOpenSettings;
  final VoidCallback onLogout;

  const _HomeDrawer({
    required this.onOpenMyPage,
    required this.onOpenCards,
    required this.onOpenInfo,
    required this.onOpenSettings,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final user = context.watch<UserProvider>().currentUser;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const _TripScriptMark(size: 24),
                      const SizedBox(width: 8),
                      Text(
                        'TripScript',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  if (user != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      user.displayName,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    Text(
                      user.phoneNumber,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.luggage_outlined),
              title: const Text('여행목록'),
              selected: true,
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('마이페이지'),
              onTap: onOpenMyPage,
            ),
            ListTile(
              leading: const Icon(Icons.credit_card),
              title: const Text('카드목록'),
              onTap: onOpenCards,
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('서비스 설명'),
              onTap: onOpenInfo,
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('설정'),
              onTap: onOpenSettings,
            ),
            const Spacer(),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.logout, color: colorScheme.error),
              title: Text('로그아웃', style: TextStyle(color: colorScheme.error)),
              onTap: onLogout,
            ),
          ],
        ),
      ),
    );
  }
}

class _TripScriptMark extends StatelessWidget {
  final double size;

  const _TripScriptMark({required this.size});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Icon(
      Icons.flight_takeoff,
      size: size,
      color: scheme.primary,
    );
  }
}

enum _HomeTripSort { nearest, farthest, added }

class _JoinTripDialog extends StatefulWidget {
  const _JoinTripDialog();

  @override
  State<_JoinTripDialog> createState() => _JoinTripDialogState();
}

class _JoinTripDialogState extends State<_JoinTripDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('초대 코드 입력'),
      content: TextField(
        controller: _controller,
        textCapitalization: TextCapitalization.characters,
        inputFormatters: [UpperCaseTextFormatter()],
        decoration: const InputDecoration(
          labelText: '초대 코드',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('참여'),
        ),
      ],
    );
  }

  void _submit() {
    Navigator.pop(context, _controller.text.trim().toUpperCase());
  }
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

class _TripListRow extends StatelessWidget {
  final Trip trip;

  const _TripListRow({required this.trip});

  @override
  Widget build(BuildContext context) {
    final flags = countryFlags(trip.countries, max: 6);
    final total = tripTotalInKrw(trip);
    return Card(
      child: ListTile(
        leading: SizedBox(
          width: 56,
          height: 56,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TripHeroTileContent(trip: trip, t: 0.0, showText: false),
          ),
        ),
        title: Text(trip.name),
        subtitle: Text(
          [
            trip.dateLabelShort,
            if (flags.isNotEmpty) flags,
            formatWonLabel(total),
          ].join(' · '),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TripDetailScreen(tripId: trip.id),
            ),
          );
        },
      ),
    );
  }
}

class _TripTile extends StatelessWidget {
  final Trip trip;

  const _TripTile({required this.trip});

  @override
  Widget build(BuildContext context) {
    final heroTag = 'trip_tile_${trip.id}';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            PageRouteBuilder(
              transitionDuration: const Duration(milliseconds: 250),
              reverseTransitionDuration: const Duration(milliseconds: 220),
              pageBuilder: (context, animation, secondaryAnimation) =>
                  TripDetailScreen(tripId: trip.id, heroTag: heroTag),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
                final curved = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                return FadeTransition(opacity: curved, child: child);
              },
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Hero(
          tag: heroTag,
          placeholderBuilder: (context, size, child) {
            // Hero 비행 중에도 그리드 레이아웃이 미세하게 변하면서
            // 마지막 프레임에 "움찔"하는 현상을 줄이기 위해, 동일 크기의 투명 placeholder 유지
            return Opacity(opacity: 0, child: child);
          },
          flightShuttleBuilder: (
            flightContext,
            animation,
            flightDirection,
            fromHeroContext,
            toHeroContext,
          ) {
            return TripHeroTileShuttle(
              trip: trip,
              animation: animation,
              flightDirection: flightDirection,
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: TripHeroTileContent(trip: trip, t: 0.0),
          ),
        ),
      ),
    );
  }
}
