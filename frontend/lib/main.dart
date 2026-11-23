import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';
import 'package:provider/provider.dart';

import 'config/app_config.dart';
import 'providers/trip_provider.dart';
import 'providers/theme_mode_provider.dart';
import 'providers/trip_list_preferences_provider.dart';
import 'providers/user_provider.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/rest_api_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  if (AppConfig.kakaoNativeAppKey.isNotEmpty) {
    await KakaoSdk.init(nativeAppKey: AppConfig.kakaoNativeAppKey);
    if (kDebugMode &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      debugPrint(
        '[Kakao] 콘솔(앱 설정 -> 플랫폼 -> Android)에 등록할 Key Hash:\n'
        '${KakaoSdk.platformInfo.origin}',
      );
    }
  }
  final ApiService api = RestApiService();
  runApp(MyApp(apiService: api));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.apiService});

  final ApiService apiService;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiService>.value(value: apiService),
        ChangeNotifierProvider(create: (_) => UserProvider(apiService)),
        ChangeNotifierProvider(create: (_) => TripProvider(apiService)),
        ChangeNotifierProvider(create: (_) => ThemeModeProvider()..load()),
        ChangeNotifierProvider(
          create: (_) => TripListPreferencesProvider()..load(),
        ),
      ],
      child: Consumer<ThemeModeProvider>(
        builder: (context, themeModeProvider, _) => MaterialApp(
          title: 'TripScript',
          debugShowCheckedModeBanner: false,
          theme: buildLightAppTheme(),
          darkTheme: buildDarkAppTheme(),
          themeMode: themeModeProvider.themeMode,
          home: const SplashScreen(),
        ),
      ),
    );
  }
}
