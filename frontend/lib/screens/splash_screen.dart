import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../providers/trip_provider.dart';
import '../providers/user_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import 'home_screen.dart';
import 'initial_setup_screen.dart';
import 'login_screen.dart';
import 'profile_completion_screen.dart';

/// 앱 시작 시 사용자 확인 후 적절한 화면으로 이동
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _storage = StorageService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FlutterNativeSplash.remove();
      _checkAndNavigate();
    });
  }

  Future<void> _checkAndNavigate() async {
    final navigator = Navigator.of(context);
    final userProvider = context.read<UserProvider>();
    final tripProvider = context.read<TripProvider>();
    final api = context.read<ApiService>();

    if (AppConfig.skipLogin) {
      userProvider.applyLocalDevSession(kLocalDevUser());
      tripProvider.setUserId(kLocalDevUser().id);
      await tripProvider.loadTrips();
      if (!mounted) return;
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
      return;
    }

    final hasSession = await _storage.hasStoredSession();
    if (!mounted) return;

    if (!hasSession) {
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }

    final savedToken = await _storage.getApiAccessToken();
    if (!mounted) return;

    if (savedToken != null && savedToken.isNotEmpty) {
      api.setAuthToken(savedToken);
      final restored = await userProvider.restoreFromApiToken();
      if (!mounted) return;

      if (restored) {
        final user = userProvider.currentUser;
        if (user != null) {
          await _storage.saveUserCredentials(
            name: user.name,
            phone: user.phoneNumber,
            userId: user.id,
          );
          await _storage.saveApiAccessToken(api.authToken);
        }
        if (user != null && user.needsProfileCompletion) {
          if (!mounted) return;
          navigator.pushReplacement(
            MaterialPageRoute(builder: (_) => const ProfileCompletionScreen()),
          );
          return;
        }
        if (user != null && user.needsInitialSetup) {
          if (!mounted) return;
          navigator.pushReplacement(
            MaterialPageRoute(builder: (_) => const InitialSetupScreen()),
          );
          return;
        }
        final userId =
            userProvider.currentUser?.id ?? await _storage.getUserId();
        if (!mounted) return;
        tripProvider.setUserId(userId);
        await tripProvider.loadTrips();
        if (!mounted) return;
        final hint = user?.shouldSuggestSettingDisplayName ?? false;
        navigator.pushReplacement(
          MaterialPageRoute(
            builder: (_) => HomeScreen(showKakaoDisplayNameHint: hint),
          ),
        );
        return;
      }

      await _storage.clearUserCredentials();
      api.clearAuthToken();
      if (!mounted) return;
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }

    final name = await _storage.getUserName();
    final phone = await _storage.getUserPhone();
    if (!mounted) return;
    if (name == null || phone == null) {
      await _storage.clearUserCredentials();
      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }

    final loaded = await userProvider.loadUserByNameAndPhone(name, phone);
    if (!mounted) return;

    if (loaded) {
      final user = userProvider.currentUser;
      final userId = user?.id ?? await _storage.getUserId();
      if (!mounted) return;
      if (user != null) {
        await _storage.saveUserCredentials(
          name: user.name,
          phone: user.phoneNumber,
          userId: user.id,
        );
        await _storage.saveApiAccessToken(api.authToken);
      }
      if (user != null && user.needsProfileCompletion) {
        if (!mounted) return;
        navigator.pushReplacement(
          MaterialPageRoute(builder: (_) => const ProfileCompletionScreen()),
        );
        return;
      }
      if (user != null && user.needsInitialSetup) {
        if (!mounted) return;
        navigator.pushReplacement(
          MaterialPageRoute(builder: (_) => const InitialSetupScreen()),
        );
        return;
      }
      tripProvider.setUserId(userId);
      await tripProvider.loadTrips();
      if (!mounted) return;

      final hint = user?.shouldSuggestSettingDisplayName ?? false;
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => HomeScreen(showKakaoDisplayNameHint: hint),
        ),
      );
    } else {
      await _storage.clearUserCredentials();
      api.clearAuthToken();
      if (!mounted) return;

      navigator.pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = Color(0xFFF7F8FC);
    return Scaffold(
      backgroundColor: bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.flight_takeoff,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'TripScript',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w300,
                  ),
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
