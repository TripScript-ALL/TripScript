import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/reference_lists.dart';
import '../providers/trip_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import 'login_screen.dart';

class MyPageScreen extends StatefulWidget {
  const MyPageScreen({super.key});

  @override
  State<MyPageScreen> createState() => _MyPageScreenState();
}

class _MyPageScreenState extends State<MyPageScreen> {
  final _formKey = GlobalKey<FormState>();
  final _storage = StorageService();
  late final TextEditingController _nameController;
  late final TextEditingController _nicknameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _settlementBankController;
  late final TextEditingController _settlementAccountController;
  late final TextEditingController _settlementHolderController;
  String? _settlementBankName;

  @override
  void initState() {
    super.initState();
    final user = context.read<UserProvider>().currentUser;
    _nameController = TextEditingController(text: user?.name ?? '');
    _nicknameController = TextEditingController(text: user?.nickname ?? '');
    _phoneController = TextEditingController(text: user?.phoneNumber ?? '');
    _settlementBankController =
        TextEditingController(text: user?.settlementBankName ?? '');
    _settlementBankName = bankOptions.contains(user?.settlementBankName)
        ? user?.settlementBankName
        : null;
    _settlementAccountController =
        TextEditingController(text: user?.settlementAccountNumber ?? '');
    _settlementHolderController =
        TextEditingController(text: user?.settlementAccountHolder ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nicknameController.dispose();
    _phoneController.dispose();
    _settlementBankController.dispose();
    _settlementAccountController.dispose();
    _settlementHolderController.dispose();
    super.dispose();
  }

  String _normalizePhone(String raw) => raw.replaceAll(RegExp(r'\D'), '');

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final userProvider = context.read<UserProvider>();
    final user = userProvider.currentUser;
    if (user == null) return;
    final oldAliases = {
      user.name.trim(),
      user.displayName.trim(),
    };

    final phone = _normalizePhone(_phoneController.text.trim());

    if (!user.isKakaoLinked && phone.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('전화번호를 입력하세요')),
      );
      return;
    }

    try {
      if (user.isKakaoLinked) {
        await userProvider.updateProfile(
          name: user.name,
          phoneNumber: phone,
          nickname: _nicknameController.text.trim(),
          settlementBankName: _settlementBankController.text.trim(),
          settlementAccountNumber: _settlementAccountController.text.trim(),
          settlementAccountHolder: _settlementHolderController.text.trim(),
        );
      } else {
        await userProvider.updateProfile(
          name: _nameController.text.trim(),
          phoneNumber: phone,
          nickname: null,
          settlementBankName: _settlementBankController.text.trim(),
          settlementAccountNumber: _settlementAccountController.text.trim(),
          settlementAccountHolder: _settlementHolderController.text.trim(),
        );
      }

      if (!mounted) return;

      final u = userProvider.currentUser!;
      context.read<TripProvider>().replaceParticipantAliases(
            oldAliases,
            u.displayName,
          );
      await _storage.saveUserCredentials(
        name: u.name,
        phone: phone,
        userId: u.id,
      );

      if (!mounted) return;
      final tripProvider = context.read<TripProvider>();
      tripProvider.setUserId(u.id);
      await tripProvider.loadTrips();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장되었습니다')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.read<UserProvider>().error ?? '저장에 실패했습니다',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _deleteAccount() async {
    final userProvider = context.read<UserProvider>();
    final tripProvider = context.read<TripProvider>();
    final api = context.read<ApiService>();
    final user = userProvider.currentUser;
    if (user == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('회원탈퇴'),
        content: const Text(
          '계정, 카드 목록, 여행 참여 정보가 삭제됩니다. '
          '내가 대표자인 여행은 함께 삭제되고, 다른 여행의 기존 영수증 기록은 정산 내역 보존을 위해 남을 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('탈퇴'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await userProvider.deleteAccount();
      await _storage.clearUserCredentials();
      api.clearAuthToken();
      tripProvider.setUserId(null);
      await tripProvider.loadTrips();

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(userProvider.error ?? '회원탈퇴에 실패했습니다'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('마이페이지'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('저장'),
          ),
        ],
      ),
      body: Consumer<UserProvider>(
        builder: (context, userProvider, _) {
          final user = userProvider.currentUser;
          if (user == null) {
            return const Center(child: Text('사용자 정보를 불러올 수 없습니다'));
          }

          final kakao = user.isKakaoLinked;
          final trips = context.watch<TripProvider>().trips;
          final bankItems = [
            ...bankOptions,
            if (_settlementBankController.text.trim().isNotEmpty &&
                !bankOptions.contains(_settlementBankController.text.trim()))
              _settlementBankController.text.trim(),
          ];
          final ownedTripCount = trips
              .where((trip) => user.matchesParticipantName(trip.hostName))
              .length;

          return Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.displayName,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          kakao ? '카카오 계정으로 로그인 중' : '전화번호 계정으로 로그인 중',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: _ProfileMetric(
                                label: '참여 여행',
                                value: '${trips.length}',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _ProfileMetric(
                                label: '대표 여행',
                                value: '$ownedTripCount',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (user.shouldSuggestSettingDisplayName)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Material(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.edit_outlined,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '계정 이름은 서버에서 자동으로 붙은 값이에요. '
                                '아래 닉네임을 정하면 앱·여행 화면에 그 이름이 보여요.',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '계정 정보',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 12),
                        if (kakao) ...[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '계정 이름',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            subtitle: Text(
                              user.name,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _nicknameController,
                            decoration: const InputDecoration(
                              labelText: '닉네임',
                              hintText: '앱에 보일 이름',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ] else ...[
                          TextFormField(
                            controller: _nameController,
                            decoration: const InputDecoration(
                              labelText: '이름',
                              hintText: '홍길동',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? '이름을 입력하세요'
                                : null,
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _phoneController,
                          decoration: InputDecoration(
                            labelText: '전화번호',
                            hintText: '010-1234-5678',
                            border: const OutlineInputBorder(),
                            helperText: kakao ? '선택 사항입니다. 비워 두어도 됩니다.' : null,
                          ),
                          keyboardType: TextInputType.phone,
                          validator: (v) {
                            if (kakao) return null;
                            if (v == null || v.trim().isEmpty) {
                              return '전화번호를 입력하세요';
                            }
                            return null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '정산 받을 계좌',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '여행 정산 요청 메시지와 송금 안내에 사용할 계좌입니다.',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: _settlementBankName,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '은행',
                                  border: OutlineInputBorder(),
                                ),
                                hint: const Text('은행 선택'),
                                items: bankItems
                                    .map(
                                      (bank) => DropdownMenuItem(
                                        value: bank,
                                        child: Text(bank),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (value) {
                                  setState(() => _settlementBankName = value);
                                  _settlementBankController.text = value ?? '';
                                },
                                validator: (value) =>
                                    value == null ? '은행을 선택하세요' : null,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextFormField(
                                controller: _settlementHolderController,
                                decoration: const InputDecoration(
                                  labelText: '예금주',
                                  hintText: '홍길동',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _settlementAccountController,
                          decoration: const InputDecoration(
                            labelText: '계좌번호',
                            hintText: '숫자와 하이픈 입력 가능',
                            border: OutlineInputBorder(),
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                if (userProvider.isLoading)
                  const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: const Text('회원탈퇴'),
                    subtitle: const Text('계정과 개인 카드 정보를 삭제합니다'),
                    onTap: userProvider.isLoading ? null : _deleteAccount,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ProfileMetric extends StatelessWidget {
  const _ProfileMetric({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}
