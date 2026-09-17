import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// One continuous pen stroke — a lift-and-redraw starts a new [_Stroke]
/// rather than appending to this one, so gaps between strokes never get
/// connected by a stray line.
class _Stroke {
  final List<Offset> points = [];
}

/// Full-screen, landscape-locked signature capture. Draw with a finger,
/// wipe and start over, or confirm to return the drawing as PNG bytes.
/// Pushed directly from the "Klant laten tekenen" task; forces landscape
/// for the duration of this screen only — [dispose] restores all
/// orientations.
///
/// If [initialSignature] is given (an already-saved signature for this
/// bon), it's shown as the starting canvas content so re-opening this
/// screen doesn't look like the signature was lost — "Wissen" drops it
/// and starts a blank pad, or "Gebruiken" re-confirms it as-is together
/// with any new strokes drawn on top.
class SignaturePadScreen extends StatefulWidget {
  final Uint8List? initialSignature;

  const SignaturePadScreen({super.key, this.initialSignature});

  @override
  State<SignaturePadScreen> createState() => _SignaturePadScreenState();
}

class _SignaturePadScreenState extends State<SignaturePadScreen> {
  final List<_Stroke> _strokes = [];
  final _boundaryKey = GlobalKey();
  bool _capturing = false;
  late bool _hasInitial = widget.initialSignature != null;

  bool get _isEmpty => _strokes.isEmpty && !_hasInitial;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    setState(() => _strokes.add(_Stroke()..points.add(details.localPosition)));
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() => _strokes.last.points.add(details.localPosition));
  }

  void _clear() => setState(() {
    _strokes.clear();
    _hasInitial = false;
  });

  Future<void> _confirm() async {
    if (_isEmpty || _capturing) return;
    setState(() => _capturing = true);
    try {
      final boundary =
          _boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null || !mounted) return;
      Navigator.of(context).pop(byteData.buffer.asUint8List());
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.white,
      child: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annuleren'),
                  ),
                  const Spacer(),
                  const Text(
                    'Handtekening klant',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _isEmpty ? null : _clear,
                    child: const Text('Wissen'),
                  ),
                  const SizedBox(width: 4),
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    color: const Color(0xFFFF6B2B),
                    borderRadius: BorderRadius.circular(10),
                    onPressed: _isEmpty || _capturing ? null : _confirm,
                    child: _capturing
                        ? const CupertinoActivityIndicator(
                            color: CupertinoColors.white,
                          )
                        : const Text(
                            'Gebruiken',
                            style: TextStyle(color: CupertinoColors.white),
                          ),
                  ),
                ],
              ),
            ),
            // ── Signing area ─────────────────────────────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFD1D1D6),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        RepaintBoundary(
                          key: _boundaryKey,
                          child: ColoredBox(
                            color: CupertinoColors.white,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_hasInitial)
                                  Image.memory(
                                    widget.initialSignature!,
                                    fit: BoxFit.contain,
                                  ),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: _onPanStart,
                                  onPanUpdate: _onPanUpdate,
                                  child: CustomPaint(
                                    painter: _SignaturePainter(_strokes),
                                    size: Size.infinite,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_isEmpty)
                          IgnorePointer(
                            child: Center(
                              child: Text(
                                'Teken hier de handtekening',
                                style: TextStyle(
                                  fontSize: 15,
                                  color: CupertinoColors.tertiaryLabel
                                      .resolveFrom(context),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<_Stroke> strokes;
  const _SignaturePainter(this.strokes);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = CupertinoColors.black
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    for (final stroke in strokes) {
      for (var i = 0; i < stroke.points.length - 1; i++) {
        canvas.drawLine(stroke.points[i], stroke.points[i + 1], paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) => true;
}
