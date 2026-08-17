import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    show
        InputImage,
        InputImageFormat,
        InputImageFormatValue,
        InputImageMetadata,
        InputImageRotation,
        InputImageRotationValue;
import 'package:receipt_recognition/receipt_recognition.dart';

class LiveReceiptScanResult {
  final RecognizedReceipt receipt;
  final File? imageFile;

  const LiveReceiptScanResult({required this.receipt, this.imageFile});
}

class LiveReceiptScannerScreen extends StatefulWidget {
  const LiveReceiptScannerScreen({super.key});

  @override
  State<LiveReceiptScannerScreen> createState() =>
      _LiveReceiptScannerScreenState();
}

class _LiveReceiptScannerScreenState extends State<LiveReceiptScannerScreen> {
  CameraController? _controller;
  CameraDescription? _camera;
  ReceiptRecognizer? _recognizer;
  RecognizedScanProgress _progress = RecognizedScanProgress.empty();
  RecognizedReceipt? _latestReceipt;
  DateTime? _lastFrameAt;
  bool _initializing = true;
  bool _processingFrame = false;
  bool _finishing = false;
  String? _error;

  static const _frameInterval = Duration(milliseconds: 750);
  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  static ReceiptOptions _receiptOptions() => ReceiptOptions.fromLayeredJson({
    'extend': {
      'totalLabels': {
        'Totaal': 'Totaal',
        'Subtotaal': 'Subtotaal',
        'Te betalen': 'Te betalen',
        'Totaalbedrag': 'Totaalbedrag',
        'Pinbedrag': 'Pinbedrag',
        'Totaal incl': 'Totaal incl',
        'Totaal excl': 'Totaal excl',
      },
      'stopKeywords': ['Wisselgeld', 'Teruggave', 'Terug'],
    },
  });

  Future<void> _initialize() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('Geen camera gevonden.');
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();

      final recognizer = ReceiptRecognizer(
        options: _receiptOptions(),
        scanInterval: const Duration(milliseconds: 250),
        scanTimeout: const Duration(seconds: 18),
        onScanUpdate: _handleProgress,
        onScanComplete: (receipt) {
          unawaited(_finish(receipt));
        },
      );

      if (!mounted) {
        await controller.dispose();
        await recognizer.close();
        return;
      }

      setState(() {
        _camera = camera;
        _controller = controller;
        _recognizer = recognizer;
        _initializing = false;
      });

      await controller.startImageStream(_processCameraImage);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _handleProgress(RecognizedScanProgress progress) {
    if (!mounted || _finishing) return;
    setState(() {
      _progress = progress;
      _latestReceipt = progress.mergedReceipt;
    });
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_processingFrame || _finishing) return;
    final now = DateTime.now();
    final last = _lastFrameAt;
    if (last != null && now.difference(last) < _frameInterval) return;
    _lastFrameAt = now;

    final inputImage = _inputImageFromCameraImage(image);
    final recognizer = _recognizer;
    if (inputImage == null || recognizer == null) return;

    _processingFrame = true;
    try {
      final receipt = await recognizer.processImage(inputImage);
      if (!mounted || _finishing) return;
      if (receipt.isNotEmpty) {
        setState(() => _latestReceipt = receipt);
      }
    } catch (_) {
      // Individual frames can fail because of motion blur or unsupported buffers.
    } finally {
      _processingFrame = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final controller = _controller;
    final camera = _camera;
    if (controller == null || camera == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          _orientations[controller.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }
    if (image.planes.length != 1) return null;

    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> _finish(RecognizedReceipt receipt) async {
    if (_finishing || receipt.isEmpty) return;
    setState(() => _finishing = true);

    File? imageFile;
    final controller = _controller;
    try {
      if (controller != null &&
          controller.value.isInitialized &&
          controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      if (controller != null && controller.value.isInitialized) {
        final shot = await controller.takePicture();
        imageFile = File(shot.path);
      }
    } catch (_) {
      imageFile = null;
    }

    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(LiveReceiptScanResult(receipt: receipt, imageFile: imageFile));
  }

  Future<void> _stop() async {
    final controller = _controller;
    final recognizer = _recognizer;
    _controller = null;
    _recognizer = null;
    try {
      if (controller != null &&
          controller.value.isInitialized &&
          controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    await controller?.dispose();
    await recognizer?.close();
  }

  bool get _canUseScan {
    final receipt = _latestReceipt;
    if (receipt == null || receipt.isEmpty) return false;
    return receipt.total != null || receipt.positions.isNotEmpty;
  }

  String get _statusText {
    if (_finishing) return 'Scan afronden...';
    switch (_progress.validationResult.status) {
      case ReceiptCompleteness.complete:
        return 'Bon compleet';
      case ReceiptCompleteness.nearlyComplete:
        return 'Bijna compleet';
      case ReceiptCompleteness.incomplete:
        return 'Bon wordt opgebouwd';
      case ReceiptCompleteness.invalid:
        return _latestReceipt == null
            ? 'Richt op de kassabon'
            : 'Zoeken naar totaal';
    }
  }

  String get _subtitle {
    final receipt = _latestReceipt;
    final total = receipt?.total?.formattedValue;
    if (total != null) return 'Totaal $total';
    final count = receipt?.positions.length ?? 0;
    if (count > 0) return '$count regels herkend';
    return 'Houd de bon vlak en goed verlicht in beeld';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.black.withValues(alpha: 0.72),
        border: null,
        leading: CupertinoNavigationBarBackButton(
          color: CupertinoColors.white,
          onPressed: () => Navigator.of(context).pop(),
        ),
        middle: const Text(
          'Bon scannen',
          style: TextStyle(
            color: CupertinoColors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: _initializing
                ? const Center(child: CupertinoActivityIndicator(radius: 14))
                : _error != null
                ? _ErrorState(message: _error!)
                : controller != null && controller.value.isInitialized
                ? CameraPreview(controller)
                : const SizedBox.shrink(),
          ),
          if (_error == null) const _ScanFrame(),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
            child: _BottomPanel(
              status: _statusText,
              subtitle: _subtitle,
              progress: _progress.validationResult.matchPercentage / 100,
              lineCount: _latestReceipt?.positions.length ?? 0,
              isFinishing: _finishing,
              canUseScan: _canUseScan,
              onUseScan: () {
                final receipt = _latestReceipt;
                if (receipt != null) unawaited(_finish(receipt));
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: MediaQuery.sizeOf(context).width * 0.72,
        height: MediaQuery.sizeOf(context).height * 0.58,
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFFF9500), width: 2),
          borderRadius: BorderRadius.circular(18),
        ),
      ),
    );
  }
}

class _BottomPanel extends StatelessWidget {
  final String status;
  final String subtitle;
  final double progress;
  final int lineCount;
  final bool isFinishing;
  final bool canUseScan;
  final VoidCallback onUseScan;

  const _BottomPanel({
    required this.status,
    required this.subtitle,
    required this.progress,
    required this.lineCount,
    required this.isFinishing,
    required this.canUseScan,
    required this.onUseScan,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E).withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF38383A)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9500).withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: isFinishing
                    ? const CupertinoActivityIndicator(radius: 9)
                    : const Icon(
                        CupertinoIcons.doc_text_viewfinder,
                        size: 18,
                        color: Color(0xFFFF9500),
                      ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status,
                      style: const TextStyle(
                        color: CupertinoColors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFFB8B8BE),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (lineCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF34C759).withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    '$lineCount',
                    style: const TextStyle(
                      color: Color(0xFF34C759),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: const Color(0xFF3A3A3C)),
                  FractionallySizedBox(
                    widthFactor: clamped == 0 ? 0.08 : clamped,
                    alignment: Alignment.centerLeft,
                    child: Container(color: const Color(0xFFFF9500)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 13),
              color: const Color(0xFF34C759),
              disabledColor: const Color(0xFF3A3A3C),
              borderRadius: BorderRadius.circular(12),
              onPressed: canUseScan && !isFinishing ? onUseScan : null,
              child: const Text(
                'Gebruik scan',
                style: TextStyle(
                  color: CupertinoColors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;

  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              color: CupertinoColors.destructiveRed,
              size: 44,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: CupertinoColors.white),
            ),
          ],
        ),
      ),
    );
  }
}
