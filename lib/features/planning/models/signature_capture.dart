import 'dart:typed_data';

/// A customer signature captured on [SignaturePadScreen]: a rendered PNG
/// (used for the on-device thumbnail in [BonDetailScreen] and
/// [WorkCompletionScreen]) alongside the raw pen strokes as `paths` — a list
/// of strokes, each a list of `[x, y]` points — which is the shape Ridder's
/// `JobOrderServiceRegistration.signature.paths` field expects. The PNG
/// alone can't be submitted: there is no image field on that schema, only
/// vector `paths`.
///
/// `paths` is `int32[][][]` in the Swagger schema (`ServiceRemoteSignature`)
/// — a fractional coordinate gets a 400 ("... is not a valid integer"), so
/// coordinates are rounded to whole canvas pixels.
class SignatureCapture {
  final Uint8List png;
  final List<List<List<int>>> paths;

  const SignatureCapture({required this.png, required this.paths});

  /// Normalizes decoded JSON (or any nested list of numbers) into
  /// Ridder-ready `paths`: coordinates rounded to ints, malformed points
  /// (anything but exactly `[x, y]`) and empty strokes dropped. Also reads
  /// drafts saved before rounding existed, which stored doubles.
  static List<List<List<int>>> pathsFromJson(Object? json) {
    if (json is! List) return const [];
    final result = <List<List<int>>>[];
    for (final stroke in json) {
      if (stroke is! List) continue;
      final points = <List<int>>[
        for (final point in stroke)
          if (point is List &&
              point.length == 2 &&
              point.every((v) => v is num))
            [(point[0] as num).round(), (point[1] as num).round()],
      ];
      if (points.isNotEmpty) result.add(points);
    }
    return result;
  }
}
