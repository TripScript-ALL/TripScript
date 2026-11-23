import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../providers/trip_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import 'home_screen.dart';
import 'initial_setup_screen.dart';
import 'profile_completion_screen.dart';

/// 카카오 또는 게스트 회원가입/로그인(이름·전화)
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _guestFormKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _storage = StorageService();

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  String _normalizePhone(String raw) {
    return raw.replaceAll(RegExp(r'\D'), '');
  }

  bool _kakaoSupportedPlatform() {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
  }

  Future<void> _persistSession(UserProvider userProvider) async {
    final user = userProvider.currentUser;
    if (user == null) return;
    final api = context.read<ApiService>();
    await _storage.saveUserCredentials(
      name: user.name,
      phone: user.phoneNumber,
      userId: user.id,
    );
    await _storage.saveApiAccessToken(api.authToken);
  }

  Future<void> _goHome({bool showKakaoDisplayNameHint = false}) async {
    final user = context.read<UserProvider>().currentUser;
    if (user == null) return;
    final tripProvider = context.read<TripProvider>();
    tripProvider.setUserId(user.id);
    await tripProvider.loadTrips();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => HomeScreen(
          showKakaoDisplayNameHint: showKakaoDisplayNameHint,
        ),
      ),
    );
  }

  Future<void> _goNextAfterLogin() async {
    final user = context.read<UserProvider>().currentUser;
    if (user == null) return;
    if (user.needsProfileCompletion) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ProfileCompletionScreen()),
      );
      return;
    }
    if (user.needsInitialSetup) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const InitialSetupScreen()),
      );
      return;
    }
    await _goHome(
      showKakaoDisplayNameHint: user.shouldSuggestSettingDisplayName,
    );
  }

  /// 사업자 등록 전에는 카카오 이름/전화번호 추가 동의가 막힐 수 있어
  /// 기본 로그인 토큰만 서버로 넘깁니다. 서버는 카카오 프로필 닉네임을 우선 사용합니다.
  Future<OAuthToken> _requestKakaoProfileScopesIfNeeded(
    OAuthToken currentToken,
  ) async {
    return currentToken;
  }

  /// 게스트: 로그인은 기존 회원만, 회원가입은 신규 사용자만 처리합니다.
  Future<bool> _submitGuestLogin({required bool isSignup}) async {
    final name = _nameController.text.trim();
    final phone = _normalizePhone(_phoneController.text.trim());
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('전화번호를 입력하세요')),
      );
      return false;
    }

    final userProvider = context.read<UserProvider>();
    var ok = false;

    if (isSignup) {
      try {
        final existing =
            await context.read<ApiService>().getUserByNameAndPhone(name, phone);
        if (!mounted) return false;
        if (existing != null) {
          context.read<ApiService>().clearAuthToken();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('이미 가입된 정보입니다. 로그인으로 들어가 주세요.')),
          );
          return false;
        }
        await userProvider.register(name: name, phoneNumber: phone);
        ok = true;
      } on ApiException catch (e) {
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: Colors.red.shade700,
          ),
        );
        return false;
      } catch (_) {
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              userProvider.error ?? '가입에 실패했습니다. 잠시 후 다시 시도해 주세요.',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
        return false;
      }
    } else {
      ok = await userProvider.loadUserByNameAndPhone(name, phone);
      if (!mounted) return false;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('가입되지 않은 정보입니다. 회원가입을 먼저 해주세요.'),
            backgroundColor: Colors.red.shade700,
          ),
        );
        return false;
      }
    }

    if (!mounted) return false;
    await _persistSession(userProvider);
    if (!mounted) return false;
    return true;
  }

  Future<void> _openGuestLoginSheet({required bool isSignup}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        final bottomInset = MediaQuery.viewInsetsOf(sheetCtx).bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + bottomInset),
          child: Form(
            key: _guestFormKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isSignup ? '게스트 회원가입' : '게스트 로그인',
                  style: Theme.of(sheetCtx).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  isSignup
                      ? '이름과 전화번호로 계정을 만든 뒤 닉네임, 정산 계좌, 결제 카드 초기 설정을 이어서 진행합니다.'
                      : '회원가입한 이름과 전화번호를 입력하면 기존 계정으로 로그인합니다.',
                  style: TextStyle(
                    color: Theme.of(sheetCtx).colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _nameController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: '이름',
                    hintText: '홍길동',
                    border: const OutlineInputBorder(),
                    hintStyle: TextStyle(
                      color: Theme.of(sheetCtx)
                          .colorScheme
                          .onSurfaceVariant
                          .withValues(alpha: 0.65),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '이름을 입력하세요' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) =>
                      _onGuestSheetSubmit(sheetCtx, isSignup: isSignup),
                  decoration: InputDecoration(
                    labelText: '전화번호',
                    hintText: '010-1234-5678',
                    border: const OutlineInputBorder(),
                    hintStyle: TextStyle(
                      color: Theme.of(sheetCtx)
                          .colorScheme
                          .onSurfaceVariant
                          .withValues(alpha: 0.65),
                    ),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return '전화번호를 입력하세요';
                    }
                    if (_normalizePhone(v).length < 10) {
                      return '올바른 전화번호를 입력하세요';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                Consumer<UserProvider>(
                  builder: (context, userProvider, _) {
                    return FilledButton(
                      onPressed: userProvider.isLoading
                          ? null
                          : () => _onGuestSheetSubmit(
                                sheetCtx,
                                isSignup: isSignup,
                              ),
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
                          : Text(isSignup ? '가입하고 초기 설정하기' : '로그인'),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _onGuestSheetSubmit(
    BuildContext sheetCtx, {
    required bool isSignup,
  }) async {
    if (!_guestFormKey.currentState!.validate()) return;
    FocusScope.of(sheetCtx).unfocus();
    final ok = await _submitGuestLogin(isSignup: isSignup);
    if (!mounted) return;
    if (ok) {
      if (sheetCtx.mounted) {
        Navigator.of(sheetCtx).pop();
      }
      if (isSignup) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const InitialSetupScreen()),
        );
        return;
      }
      await _goNextAfterLogin();
    }
  }

  Future<void> _loginWithKakao() async {
    if (!_kakaoSupportedPlatform()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('카카오 로그인은 Android 또는 iOS에서 이용할 수 있습니다.')),
      );
      return;
    }
    if (AppConfig.kakaoNativeAppKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'KAKAO_NATIVE_APP_KEY가 설정되지 않았습니다.\n'
            'flutter run --dart-define=KAKAO_NATIVE_APP_KEY=네이티브앱키',
          ),
        ),
      );
      return;
    }

    final userProvider = context.read<UserProvider>();
    OAuthToken token;
    try {
      // 졸작 테스트 빌드에서는 브라우저/카카오계정 로그인으로 고정합니다.
      // 카카오톡 앱 리다이렉트는 기기·앱 상태에 따라 로그인 화면 전환이 보이지 않을 수 있습니다.
      token = await UserApi.instance.loginWithKakaoAccount();
      token = await _requestKakaoProfileScopesIfNeeded(token);
    } catch (e, st) {
      debugPrint('Kakao login error: $e\n$st');
      if (!mounted) return;
      final detail = e.toString();
      final isKakaoConfigError = detail.contains('keyHash') ||
          detail.contains('KOE') ||
          detail.contains('misconfigured');
      final keyHash = KakaoSdk.platformInfo.origin;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isKakaoConfigError
                ? '카카오 앱 설정을 확인해 주세요. KeyHash: $keyHash'
                : '로그인에 실패하였습니다.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    final ok = await userProvider.loginWithKakaoAccessToken(token.accessToken);
    if (!mounted) return;

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(userProvider.error ?? '서버 로그인에 실패했습니다.'),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    await _persistSession(userProvider);
    if (!mounted) return;
    await _goNextAfterLogin();
  }

  Future<void> _skipLoginDev() async {
    final user = kLocalDevUser();
    final userProvider = context.read<UserProvider>();
    final tripProvider = context.read<TripProvider>();
    userProvider.applyLocalDevSession(user);
    tripProvider.setUserId(user.id);
    await tripProvider.loadTrips();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  static const Color _kakaoYellow = Color(0xFFFEE500);
  static const Color _kakaoBlack = Color(0xFF191919);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              Icon(
                Icons.flight_takeoff,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'TripScript',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                '카카오 또는 게스트로 시작하세요',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              if (_kakaoSupportedPlatform()) ...[
                Consumer<UserProvider>(
                  builder: (context, userProvider, _) {
                    return _KakaoLoginButton(
                      onPressed:
                          userProvider.isLoading ? null : _loginWithKakao,
                    );
                  },
                ),
                if (AppConfig.enableLegacyLogin) const SizedBox(height: 12),
                if (AppConfig.enableLegacyLogin)
                  Row(
                    children: [
                      Expanded(
                          child:
                              Divider(color: Theme.of(context).dividerColor)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '또는',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                          child:
                              Divider(color: Theme.of(context).dividerColor)),
                    ],
                  ),
                const SizedBox(height: 12),
              ],
              Consumer<UserProvider>(
                builder: (context, userProvider, _) {
                  if (!AppConfig.enableLegacyLogin) {
                    return const SizedBox.shrink();
                  }
                  return Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: userProvider.isLoading
                              ? null
                              : () => _openGuestLoginSheet(isSignup: false),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text('게스트 로그인'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: userProvider.isLoading
                              ? null
                              : () => _openGuestLoginSheet(isSignup: true),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: const Text('게스트 회원가입'),
                        ),
                      ),
                    ],
                  );
                },
              ),
              if (AppConfig.skipLogin) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _skipLoginDev,
                  child: Text(
                    '로그인 생략하고 홈으로',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.tertiary,
                    ),
                  ),
                ),
                Text(
                  'SKIP_LOGIN 빌드 플래그가 켜져 있습니다.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _KakaoLoginButton extends StatelessWidget {
  const _KakaoLoginButton({required this.onPressed});

  final VoidCallback? onPressed;

  static const _height = 52.0;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      label: '카카오 로그인',
      child: Material(
        color: enabled
            ? _LoginScreenState._kakaoYellow
            : _LoginScreenState._kakaoYellow.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: _height,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Positioned(
                  left: 18,
                  child: Icon(
                    Icons.chat_bubble,
                    color: _LoginScreenState._kakaoBlack,
                    size: 21,
                  ),
                ),
                Text(
                  '카카오 로그인',
                  style: TextStyle(
                    color: _LoginScreenState._kakaoBlack.withValues(
                      alpha: enabled ? 1 : 0.55,
                    ),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
