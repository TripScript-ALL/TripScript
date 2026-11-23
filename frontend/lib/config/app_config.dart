import 'package:flutter/foundation.dart';

/// 빌드 시 `--dart-define=...` 으로 동작을 바꿉니다.
///
/// **로그인 생략 (UI·프론트 작업용)**
/// `flutter run --dart-define=SKIP_LOGIN=true`
/// → 스플래시에서 API 없이 더미 사용자로 홈 진입. 실서버 복구 후 이 플래그만 빼면 됩니다.
class AppConfig {
  AppConfig._();

  static const bool enableLegacyLogin = !kReleaseMode &&
      bool.fromEnvironment('ENABLE_LEGACY_LOGIN', defaultValue: false);

  static const bool skipLogin =
      !kReleaseMode && bool.fromEnvironment('SKIP_LOGIN', defaultValue: false);

  /// 카카오 네이티브 앱 키. `flutter run --dart-define=KAKAO_NATIVE_APP_KEY=...`
  static const String kakaoNativeAppKey = String.fromEnvironment(
    'KAKAO_NATIVE_APP_KEY',
    defaultValue: '',
  );

  /// 로그인 생략 빌드: UI 작업용으로 여행 시드 등 개발 편의를 켭니다.
  static bool get isDeveloperMode => skipLogin;
}
