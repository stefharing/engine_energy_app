import 'package:flutter/cupertino.dart';
import '../widgets/engine_logo.dart';
import '../widgets/nav_border.dart';

class UrenScreen extends StatelessWidget {
  const UrenScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.white,
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
