import 'package:flutter/cupertino.dart';

/// The app's shared surface colors, as light/dark pairs.
///
/// The light values are exactly what the screens used to hard-code, so
/// light mode looks the same; the dark values follow the pairs the
/// dark-mode-aware screens already used (`isDark ? 0xFF1C1C1E : white`,
/// ...). Cupertino widgets resolve these automatically when passed as e.g.
/// `CupertinoPageScaffold.backgroundColor` or
/// `CupertinoNavigationBar.backgroundColor`; anywhere else (BoxDecoration,
/// TextStyle, Paint, ...) call `.resolveFrom(context)` first — an
/// unresolved dynamic color always paints its light value.
abstract final class AppColors {
  /// Brand orange — the app's accent in both modes.
  static const accent = Color(0xFFFF6B2B);

  /// Grouped page background behind cards.
  static const page = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFF2F2F7),
    darkColor: Color(0xFF000000),
  );

  /// Navigation bar / tab bar background.
  static const navBar = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFFFFFFF),
    darkColor: Color(0xFF1C1C1E),
  );

  /// Nav bar icons, back button and titles.
  static const navForeground = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF000000),
    darkColor: Color(0xFFFFFFFF),
  );

  /// Cards, sheets, footers.
  static const card = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFFFFFFF),
    darkColor: Color(0xFF1C1C1E),
  );

  /// Cards on the (white) detail screens, which sit a shade off-white.
  static const cardSubtle = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFF9F9F9),
    darkColor: Color(0xFF1C1C1E),
  );

  /// A card that's done/locked (e.g. an already-submitted hour card).
  static const cardMuted = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFF2F2F7),
    darkColor: Color(0xFF232324),
  );

  /// Filled search/text field on a card.
  static const field = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFF2F2F7),
    darkColor: Color(0xFF2C2C2E),
  );

  /// Bordered input box on a card.
  static const input = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFFFFFFF),
    darkColor: Color(0xFF2C2C2E),
  );

  /// Card outlines.
  static const border = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFE5E5EA),
    darkColor: Color(0xFF38383A),
  );

  /// Hairlines under the nav bar and between list rows.
  static const separator = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFD1D1D6),
    darkColor: Color(0xFF38383A),
  );

  /// Navy used for document icons — lightened in dark mode, where the
  /// light-mode navy is nearly invisible on a dark card.
  static const navy = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF2C3E6B),
    darkColor: Color(0xFF8FA6D8),
  );

  /// Background of a disabled primary button.
  static const disabledFill = CupertinoDynamicColor.withBrightness(
    color: Color(0xFFD1D1D6),
    darkColor: Color(0xFF3A3A3C),
  );

  /// Text on a disabled primary button.
  static const disabledText = CupertinoDynamicColor.withBrightness(
    color: Color.fromRGBO(60, 60, 67, 0.45),
    darkColor: Color.fromRGBO(235, 235, 245, 0.45),
  );

  /// Toast / snackbar background.
  static const toast = CupertinoDynamicColor.withBrightness(
    color: Color(0xFF1C1C1E),
    darkColor: Color(0xFF3A3A3C),
  );
}
