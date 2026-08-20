/// A locally-added document reference in a [WorkReportDraft]: the stable,
/// app-owned copy's path, plus the original filename (kept separately since
/// the stored path is a generated, opaque name — see
/// `WorkReportStorage.copyDocument`).
class WorkReportDocumentRef {
  const WorkReportDocumentRef({required this.path, required this.fileName});

  final String path;
  final String fileName;

  Map<String, dynamic> toJson() => {'path': path, 'fileName': fileName};

  factory WorkReportDocumentRef.fromJson(Map<String, dynamic> json) =>
      WorkReportDocumentRef(
        path: json['path'] as String,
        fileName: json['fileName'] as String,
      );
}

/// Local-only draft of a servicebon's work report: four free-text fields
/// plus attached photos/documents. Capture-only for now — see
/// `work_report_screen.dart` for the full scope note; nothing here is ever
/// sent to Ridder.
class WorkReportDraft {
  const WorkReportDraft({
    this.workDescription = '',
    this.startingSituation = '',
    this.findings = '',
    this.recommendations = '',
    this.photoPaths = const [],
    this.documents = const [],
  });

  final String workDescription;
  final String startingSituation;
  final String findings;
  final String recommendations;

  /// Stable, app-owned paths — never the original picker temp/cache paths.
  final List<String> photoPaths;
  final List<WorkReportDocumentRef> documents;

  WorkReportDraft copyWith({
    String? workDescription,
    String? startingSituation,
    String? findings,
    String? recommendations,
    List<String>? photoPaths,
    List<WorkReportDocumentRef>? documents,
  }) => WorkReportDraft(
    workDescription: workDescription ?? this.workDescription,
    startingSituation: startingSituation ?? this.startingSituation,
    findings: findings ?? this.findings,
    recommendations: recommendations ?? this.recommendations,
    photoPaths: photoPaths ?? this.photoPaths,
    documents: documents ?? this.documents,
  );

  Map<String, dynamic> toJson() => {
    'workDescription': workDescription,
    'startingSituation': startingSituation,
    'findings': findings,
    'recommendations': recommendations,
    'photoPaths': photoPaths,
    'documents': documents.map((d) => d.toJson()).toList(),
  };

  factory WorkReportDraft.fromJson(Map<String, dynamic> json) =>
      WorkReportDraft(
        workDescription: json['workDescription'] as String? ?? '',
        startingSituation: json['startingSituation'] as String? ?? '',
        findings: json['findings'] as String? ?? '',
        recommendations: json['recommendations'] as String? ?? '',
        photoPaths:
            (json['photoPaths'] as List<dynamic>?)?.cast<String>() ?? const [],
        documents:
            (json['documents'] as List<dynamic>?)
                ?.map(
                  (d) => WorkReportDocumentRef.fromJson(
                    Map<String, dynamic>.from(d as Map),
                  ),
                )
                .toList() ??
            const [],
      );
}
