import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Copies picked work-report photos/documents into a stable, app-owned
/// directory, namespaced per bon:
/// `<ApplicationDocumentsDirectory>/work_reports/<orderId>/{photos,documents}`.
///
/// image_picker/file_picker results are often temporary or cache paths the
/// OS can clear at any time — a [WorkReportDraft] must only ever reference
/// paths returned from here, never a picker's original path. Each stored
/// file gets a fresh, collision-proof name (its original name/extension is
/// preserved separately where it matters — see [WorkReportDocumentRef]).
class WorkReportStorage {
  WorkReportStorage._();

  static const _uuid = Uuid();

  static Future<Directory> _dir(String orderId, String subfolder) async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/work_reports/$orderId/$subfolder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<String> copyPhoto(String orderId, String sourcePath) =>
      _copyInto(orderId, 'photos', sourcePath);

  static Future<String> copyDocument(String orderId, String sourcePath) =>
      _copyInto(orderId, 'documents', sourcePath);

  static Future<String> _copyInto(
    String orderId,
    String subfolder,
    String sourcePath,
  ) async {
    final dir = await _dir(orderId, subfolder);
    final dest = File('${dir.path}/${_uuid.v4()}${_extensionOf(sourcePath)}');
    await File(sourcePath).copy(dest.path);
    return dest.path;
  }

  /// Deletes a previously-copied file. Safe to call even if the file is
  /// already gone.
  static Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf('/');
    if (dot == -1 || dot < slash) return '';
    return path.substring(dot);
  }
}
