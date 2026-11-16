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

/// Wat de monteur in de scanner koos.
enum BonScanBron { scan, galerij, handmatig }

class LiveReceiptScanResult {
  /// Wat live is herkend; `null` bij een foto zonder herkenning, of als de
  /// monteur voor het fotoarchief of handmatig invullen koos.
  final RecognizedReceipt? receipt;
  final File? imageFile;
  final BonScanBron bron;

  const LiveReceiptScanResult({
    this.receipt,
    this.imageFile,
    this.bron = BonScanBron.scan,
  });
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
          if (receipt.isEmpty) return;
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

  Future<void> _finish(RecognizedReceipt? receipt) async {
    if (_finishing) return;
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
    ).pop(
      LiveReceiptScanResult(
        receipt: (receipt == null || receipt.isEmpty) ? null : receipt,
        imageFile: imageFile,
      ),
    );
  }

  void _kies(BonScanBron bron) {
    if (_finishing) return;
    unawaited(_stop());
    Navigator.of(context).pop(LiveReceiptScanResult(bron: bron));
  }

  Future<void> _flits() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      final aan = c.value.flashMode == FlashMode.torch;
      await c.setFlashMode(aan ? FlashMode.off : FlashMode.torch);
      if (mounted) setState(() {});
    } catch (_) {
      // Niet elk toestel heeft een zaklamp.
    }
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

  String get _herkend {
    final receipt = _latestReceipt;
    final totaal = receipt?.total?.formattedValue;
    final datum = receipt?.purchaseDate?.value;
    if (totaal == null && datum == null) return _statusText;
    const m = ['jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];
    return [
      ?totaal,
      if (datum != null) '${datum.day} ${m[datum.month - 1]}',
    ].join(' · ') + ' herkend';
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final top = MediaQuery.paddingOf(context).top;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final herkend = _canUseScan;
    final fakkel = controller?.value.flashMode == FlashMode.torch;

    return CupertinoPageScaffold(
      backgroundColor: const Color(0xFF0B0B0C),
      child: Stack(
        children: [
          Positioned.fill(
            child: _initializing
                ? const Center(child: CupertinoActivityIndicator(radius: 14))
                : _error != null
                ? _ErrorState(message: _error!)
                : controller != null && controller.value.isInitialized
                ? ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: controller.value.previewSize?.height ?? 1,
                        height: controller.value.previewSize?.width ?? 1,
                        child: CameraPreview(controller),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          if (_error == null) const _ScanFrame(),
          // Bovenbalk.
          Positioned(
            left: 16,
            right: 16,
            top: top + 8,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _RondeKnop(
                  icoon: CupertinoIcons.xmark,
                  label: 'Sluiten',
                  onTap: () => Navigator.of(context).pop(),
                ),
                const Text(
                  'Scan bon',
                  style: TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _RondeKnop(
                  icoon: fakkel ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt,
                  label: 'Flits',
                  onTap: _flits,
                ),
              ],
            ),
          ),
          // Wat er herkend is.
          Positioned(
            left: 24,
            right: 24,
            top: top + 64,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: CupertinoColors.white,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_finishing)
                      const CupertinoActivityIndicator(radius: 8)
                    else
                      Icon(
                        herkend
                            ? CupertinoIcons.checkmark_circle
                            : CupertinoIcons.doc_text_viewfinder,
                        size: 18,
                        color: herkend
                            ? const Color(0xFF248A3D)
                            : const Color(0xFF6C6C70),
                      ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _finishing ? 'Scan afronden...' : _herkend,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF1C1C1E),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 190,
            child: Text(
              'Houd de bon vlak in het kader',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xCCFFFFFF), fontSize: 15),
            ),
          ),
          // Onderbalk: fotoarchief, sluiter, handmatig.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: const Color(0xFF0B0B0C),
              padding: EdgeInsets.fromLTRB(28, 14, 28, 14 + bottom),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _OnderKnop(
                    icoon: CupertinoIcons.photo,
                    label: 'Fotoarchief',
                    onTap: () => _kies(BonScanBron.galerij),
                  ),
                  Semantics(
                    button: true,
                    label: 'Foto maken',
                    child: GestureDetector(
                      onTap: _finishing || controller == null
                          ? null
                          : () => unawaited(_finish(_latestReceipt)),
                      child: Container(
                        width: 78,
                        height: 78,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: CupertinoColors.white, width: 4),
                        ),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFFFF6B2B),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _OnderKnop(
                    icoon: CupertinoIcons.pencil,
                    label: 'Handmatig',
                    onTap: () => _kies(BonScanBron.handmatig),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RondeKnop extends StatelessWidget {
  final IconData icoon;
  final String label;
  final VoidCallback onTap;

  const _RondeKnop({
    required this.icoon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0x29FFFFFF),
          ),
          child: Icon(icoon, size: 20, color: CupertinoColors.white),
        ),
      ),
    );
  }
}

class _OnderKnop extends StatelessWidget {
  final IconData icoon;
  final String label;
  final VoidCallback onTap;

  const _OnderKnop({
    required this.icoon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 84,
        height: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icoon, size: 26, color: CupertinoColors.white),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(color: CupertinoColors.white, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScanFrame extends StatelessWidget {
  const _ScanFrame();

  @override
  Widget build(BuildContext context) {
    const kleur = Color(0xFFFF6B2B);
    Widget hoek({bool links = true, bool boven = true}) {
      final zijde = BorderSide(color: kleur, width: 4);
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          border: Border(
            left: links ? zijde : BorderSide.none,
            right: links ? BorderSide.none : zijde,
            top: boven ? zijde : BorderSide.none,
            bottom: boven ? BorderSide.none : zijde,
          ),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(links && boven ? 14 : 0),
            topRight: Radius.circular(!links && boven ? 14 : 0),
            bottomLeft: Radius.circular(links && !boven ? 14 : 0),
            bottomRight: Radius.circular(!links && !boven ? 14 : 0),
          ),
        ),
      );
    }

    final size = MediaQuery.sizeOf(context);
    return Center(
      child: SizedBox(
        width: size.width * 0.82,
        height: size.height * 0.5,
        child: Stack(
          children: [
            Positioned(left: 0, top: 0, child: hoek()),
            Positioned(right: 0, top: 0, child: hoek(links: false)),
            Positioned(left: 0, bottom: 0, child: hoek(boven: false)),
            Positioned(
              right: 0,
              bottom: 0,
              child: hoek(links: false, boven: false),
            ),
          ],
        ),
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
            Icon(
              CupertinoIcons.exclamationmark_circle,
              color: CupertinoColors.destructiveRed.resolveFrom(context),
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
