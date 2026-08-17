import 'package:flutter/cupertino.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Multi-scan scanner that stays open and calls [onDetect] for each detected barcode.
/// A 1.2s cooldown prevents duplicate scans of the same label.
class BarcodeScannerScreen extends StatefulWidget {
  final void Function(String barcode) onDetect;

  const BarcodeScannerScreen({super.key, required this.onDetect});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  late final MobileScannerController _controller;
  bool _cooldown = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      facing: CameraFacing.back,
      torchEnabled: false,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_cooldown) return;
    final barcode = capture.barcodes.firstOrNull?.rawValue;
    if (barcode == null || barcode.isEmpty) return;

    setState(() => _cooldown = true);
    widget.onDetect(barcode);

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _cooldown = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: const Color(0xFF1C1C1E),
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.white,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: const Text('Scannen', style: TextStyle(color: CupertinoColors.white)),
      ),
      child: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 260,
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _cooldown ? const Color(0xFF34C759) : const Color(0xFFFF9500),
                  width: 2.5,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 60,
            left: 0,
            right: 0,
            child: Text(
              _cooldown ? 'Gescand!' : 'Richt de camera op een barcode',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: CupertinoColors.white.withValues(alpha: 0.85),
                fontSize: 14,
                fontWeight: _cooldown ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
