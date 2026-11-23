import 'package:flutter/material.dart';

/// Gmarket Sans (Light 300 / Medium 500 / Bold 700)
const String kAppFontFamily = 'GmarketSans';

ThemeData buildLightAppTheme() => _buildAppTheme(Brightness.light);

ThemeData buildDarkAppTheme() => _buildAppTheme(Brightness.dark);

/// Backward-compatible alias for code that still expects the old dark theme.
ThemeData buildAppTheme() => buildDarkAppTheme();

ThemeData _buildAppTheme(Brightness brightness) {
  const seed = Color.fromARGB(255, 21, 32, 113);
  final isDark = brightness == Brightness.dark;
  final scaffoldColor =
      isDark ? const Color(0xFF1A1B1E) : const Color(0xFFF7F8FC);

  final baseScheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: brightness,
  );

  final colorScheme = isDark
      ? baseScheme.copyWith(
          surface: scaffoldColor,
          surfaceContainerLowest: const Color(0xFF131418),
          surfaceContainerLow: const Color(0xFF1E1F24),
          surfaceContainer: const Color(0xFF25262C),
          surfaceContainerHigh: const Color(0xFF2C2D34),
          surfaceContainerHighest: const Color(0xFF33343C),
        )
      : baseScheme.copyWith(
          surface: scaffoldColor,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: Colors.white,
          surfaceContainer: const Color(0xFFEFF1F7),
          surfaceContainerHigh: const Color(0xFFE7EAF3),
          surfaceContainerHighest: const Color(0xFFDDE1EE),
          outline: const Color(0xFF7D8294),
          outlineVariant: const Color(0xFFC8CCDA),
        );

  final base = ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    fontFamily: kAppFontFamily,
    brightness: brightness,
  );

  final t = base.textTheme;
  return base.copyWith(
    scaffoldBackgroundColor: scaffoldColor,
    textTheme: t.copyWith(
      displayLarge: t.displayLarge?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
      ),
      displayMedium: t.displayMedium?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
      ),
      displaySmall: t.displaySmall?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
      ),
      headlineLarge: t.headlineLarge?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
      ),
      headlineMedium: t.headlineMedium?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
      ),
      headlineSmall: t.headlineSmall?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
      ),
      titleLarge: t.titleLarge?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
      ),
      titleMedium: t.titleMedium?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
      ),
      titleSmall: t.titleSmall?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
      ),
      bodyLarge: t.bodyLarge?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
      ),
      bodyMedium: t.bodyMedium?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
      ),
      bodySmall: t.bodySmall?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w300,
      ),
      labelLarge: t.labelLarge?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
      ),
      labelMedium: t.labelMedium?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
      ),
      labelSmall: t.labelSmall?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w300,
      ),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: t.titleLarge?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
        color: colorScheme.onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: t.bodyMedium?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
      ),
      hintStyle: t.bodyMedium?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w300,
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor:
          isDark ? colorScheme.inverseSurface : const Color(0xFF20222A),
      contentTextStyle: TextStyle(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
        color: isDark ? colorScheme.onInverseSurface : Colors.white,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      titleTextStyle: t.titleLarge?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w700,
        color: colorScheme.onSurface,
      ),
      contentTextStyle: t.bodyMedium?.copyWith(
        fontFamily: kAppFontFamily,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      color: colorScheme.surfaceContainerLow,
      elevation: 0,
    ),
  );
}
