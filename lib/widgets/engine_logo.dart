import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';

class EngineLogo extends StatelessWidget {
  final double height;

  const EngineLogo({super.key, this.height = 25});

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return SvgPicture.asset(
      'assets/images/EngineEnergyLOGO_orange.svg',
      height: height,
      colorFilter: isDark
          ? const ColorFilter.mode(CupertinoColors.white, BlendMode.srcIn)
          : null,
    );
  }
}
