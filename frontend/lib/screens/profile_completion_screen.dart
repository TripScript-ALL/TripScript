import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/trip_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import 'home_screen.dart';
import 'login_screen.dart';

class ProfileCompletionScreen extends StatefulWidget {
  const ProfileCompletionScreen({super.key});

  @override
  State<ProfileCompletionScreen> createState() =>
      _ProfileCompletionScreenState();
}

class _ProfileCompletionScreenState extends State<ProfileCompletionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _storage = StorageService();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;

  @override
  void initState() {
    super.initState();
    final user = context.read<UserProvider>().currentUser;
    _nameController = TextEditingController(text: user?.name ?? '');
    _phoneController = TextEditingController(text: user?.phoneNumber ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  String _normalizePhone(String raw) => raw.replaceAll(RegExp(r'\D'), '');

  Future<void> _logout() async {
    final userProvider = context.read<UserProvider>();
    final tripProvider = context.read<TripProvider>();
    await _storage.clearUserCredentials();
    userProvider.logout();
    tripProvider.setUserId(null);
    await tripProvider.loadTrips();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    final phone = _normalizePhone(_phoneController.text.trim());
    final userProvider = context.read<UserProvider>();
    final tripProvider = context.read<TripProvider>();
    final api = context.read<ApiService>();

    try {
      await userProvider.updateProfile(name: name, phoneNumber: phone);
      if (!mounted) return;

      final user = userProvider.currentUser;
      if (user == null) return;

      await _storage.saveUserCredentials(
        name: user.name,
        phone: user.phoneNumber,
        userId: user.id,
      );
      await _storage.saveApiAccessToken(api.authToken);

      tripProvider.setUserId(user.id);
      await tripProvider.loadTrips();
      if (!mounted) return;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => HomeScreen(
            showKakaoDisplayNameHint: user.shouldSuggestSettingDisplayName,
          ),
        ),
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(userProvider.error ?? '프로필 저장에 실패했습니다'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final user = context.watch<UserProvider>().currentUser;
    final kakao = user?.isKakaoLinked ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('프로필 확인'),
        actions: [
          TextButton(
            onPressed: _logout,
            child: const Text('로그아웃'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 32),
                Icon(
                  Icons.account_circle_outlined,
                  size: 64,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  kakao
                      ? 'TripScript에서 사용할 이름을 확인해 주세요'
                      : 'TripScript에서 사용할 정보를 확인해 주세요',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  kakao
                      ? '전화번호는 나중에 마이페이지에서 넣어도 됩니다.'
                      : '정산 참여자와 결제자를 정확히 구분하려면 이름과 전화번호가 필요합니다.',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 28),
                TextFormField(
                  controller: _nameController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '이름',
                    hintText: '홍길동',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '이름을 입력하세요' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _save(),
                  decoration: InputDecoration(
                    labelText: '전화번호',
                    hintText: '01012345678',
                    border: const OutlineInputBorder(),
                    helperText: kakao ? '선택 사항입니다' : null,
                  ),
                  validator: (v) {
                    if (kakao) {
                      if (v == null || v.trim().isEmpty) return null;
                      if (_normalizePhone(v).length < 10) {
                        return '올바른 전화번호를 입력하세요';
                      }
                      return null;
                    }
                    if (v == null || v.trim().isEmpty) {
                      return '전화번호를 입력하세요';
                    }
                    if (_normalizePhone(v).length < 10) {
                      return '올바른 전화번호를 입력하세요';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 28),
                Consumer<UserProvider>(
                  builder: (context, userProvider, _) {
                    return FilledButton(
                      onPressed: userProvider.isLoading ? null : _save,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: userProvider.isLoading
                          ? const SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('저장하고 시작하기'),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
