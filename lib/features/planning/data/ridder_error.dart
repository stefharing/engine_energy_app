import 'package:dio/dio.dart';

/// Ridder returns validation failures as a Problem-details body with a
/// `columnerrors` map (field -> Dutch message) and/or a `detail` string.
/// Falls back to the raw exception if the response doesn't match that shape.
/// Shared between [PartsListScreen] and [ExtraMaterialsScreen], both of
/// which write extra-part lines to Ridder and want the same failure message.
String friendlyRidderError(Object e) {
  if (e is DioException) {
    final data = e.response?.data;
    if (data is Map) {
      final columnErrors = data['columnerrors'];
      if (columnErrors is Map && columnErrors.isNotEmpty) {
        return columnErrors.values.join('\n');
      }
      final detail = data['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
    }
  }
  return e.toString();
}
