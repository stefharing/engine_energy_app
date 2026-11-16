import 'package:flutter/cupertino.dart';
import '../widgets/engine_logo.dart';
import '../widgets/nav_border.dart';
import '../core/theme/app_colors.dart';

class UrenScreen extends StatelessWidget {
  const UrenScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: AppColors.navBar,
        border: null,
        padding: EdgeInsetsDirectional.symmetric(horizontal: 20),
        middle: EngineLogo(),
      ),
      child: SafeArea(
        child: Column(
          children: [
            NavBorder(),
            Expanded(child: Center(child: Text('Uren'))),
          ],
        ),
      ),
    );
  }
}
