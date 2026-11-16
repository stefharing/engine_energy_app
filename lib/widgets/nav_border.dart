import 'package:flutter/cupertino.dart';

import '../core/theme/app_colors.dart';

/// A hairline separator to place at the top of a screen body,
/// giving the navigation bar a permanent bottom border.
class NavBorder extends StatelessWidget {
  const NavBorder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      color: AppColors.separator.resolveFrom(context),
    );
  }
}
