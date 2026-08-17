import 'package:flutter/cupertino.dart';

/// A hairline separator to place at the top of a screen body,
/// giving the navigation bar a permanent bottom border.
class NavBorder extends StatelessWidget {
  const NavBorder({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Container(
      height: 0.5,
      color: isDark ? const Color(0xFF38383A) : const Color(0xFFD1D1D6),
    );
  }
}
