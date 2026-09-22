import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

/// Prompts for a quantity ("stuks") via [QuantityDialog] — shared between
/// [PartsListScreen] and [UsedMaterialsScreen], both of which need to ask
/// "how many?" after a scan or search match.
Future<int?> promptQuantity(
  BuildContext context, {
  required String title,
  required String subtitle,
  required int defaultQty,
  int minimumQty = 1,
}) {
  return showCupertinoDialog<int>(
    context: context,
    barrierDismissible: false,
    builder: (_) => QuantityDialog(
      title: title,
      subtitle: subtitle,
      defaultQty: defaultQty,
      minimumQty: minimumQty,
    ),
  );
}

class QuantityDialog extends StatefulWidget {
  final String title;
  final String subtitle;
  final int defaultQty;
  final int minimumQty;

  const QuantityDialog({
    super.key,
    required this.title,
    required this.subtitle,
    required this.defaultQty,
    required this.minimumQty,
  });

  @override
  State<QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<QuantityDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.defaultQty}');
    _ctrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _ctrl.text.length,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final qty = int.tryParse(_ctrl.text.trim());
    if (qty != null && qty >= widget.minimumQty) {
      Navigator.of(context).pop(qty);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: Text(widget.title),
      content: Column(
        children: [
          if (widget.subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(widget.subtitle, style: const TextStyle(fontSize: 13)),
          ],
          const SizedBox(height: 14),
          CupertinoTextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
            placeholder: '0',
            decoration: BoxDecoration(
              color: CupertinoColors.tertiarySystemBackground,
              borderRadius: BorderRadius.circular(8),
            ),
            onSubmitted: (_) => _confirm(),
          ),
          const SizedBox(height: 4),
          Text(
            'stuks',
            style: TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Annuleren'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: _confirm,
          child: const Text('Bevestigen'),
        ),
      ],
    );
  }
}
