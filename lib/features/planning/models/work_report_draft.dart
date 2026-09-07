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

/// How urgently a [Finding] needs attention.
enum FindingSeverity {
  laag,
  aandacht,
  urgent;

  static FindingSeverity fromName(String? name) => FindingSeverity.values
      .firstWhere((s) => s.name == name, orElse: () => FindingSeverity.laag);
}

/// A single observation recorded in the "Bevindingen" step, tagged with a
/// severity. Findings with empty [text] are kept locally (the technician is
/// still typing) but never count toward step completeness or the overview.
class Finding {
  const Finding({
    required this.id,
    this.text = '',
    this.severity = FindingSeverity.laag,
  });

  final String id;
  final String text;
  final FindingSeverity severity;

  Finding copyWith({String? text, FindingSeverity? severity}) => Finding(
    id: id,
    text: text ?? this.text,
    severity: severity ?? this.severity,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'sev': severity.name,
  };

  factory Finding.fromJson(Map<String, dynamic> json) => Finding(
    id: json['id'] as String,
    text: json['text'] as String? ?? '',
    severity: FindingSeverity.fromName(json['sev'] as String?),
  );
}

enum WorkReportStatus {
  draft,
  saved;

  static WorkReportStatus fromName(String? name) => WorkReportStatus.values
      .firstWhere((s) => s.name == name, orElse: () => WorkReportStatus.draft);
}

/// Local-only draft of a servicebon's work report: three free-text fields,
/// a list of severity-tagged findings, and attached photos/documents.
/// Capture-only for now — see `work_report_screen.dart` for the full scope
/// note; nothing here is ever sent to Ridder.
class WorkReportDraft {
  const WorkReportDraft({
    this.workDescription = '',
    this.startingSituation = '',
    this.findings = const [],
    this.recommendations = '',
    this.photoPaths = const [],
    this.documents = const [],
    this.status = WorkReportStatus.draft,
  });

  final String workDescription;
  final String startingSituation;
  final List<Finding> findings;
  final String recommendations;

  /// Stable, app-owned paths — never the original picker temp/cache paths.
  final List<String> photoPaths;
  final List<WorkReportDocumentRef> documents;
  final WorkReportStatus status;

  WorkReportDraft copyWith({
    String? workDescription,
    String? startingSituation,
    List<Finding>? findings,
    String? recommendations,
    List<String>? photoPaths,
    List<WorkReportDocumentRef>? documents,
    WorkReportStatus? status,
  }) => WorkReportDraft(
    workDescription: workDescription ?? this.workDescription,
    startingSituation: startingSituation ?? this.startingSituation,
    findings: findings ?? this.findings,
    recommendations: recommendations ?? this.recommendations,
    photoPaths: photoPaths ?? this.photoPaths,
    documents: documents ?? this.documents,
    status: status ?? this.status,
  );

  Map<String, dynamic> toJson() => {
    'workDescription': workDescription,
    'startingSituation': startingSituation,
    'findings': findings.map((f) => f.toJson()).toList(),
    'recommendations': recommendations,
    'photoPaths': photoPaths,
    'documents': documents.map((d) => d.toJson()).toList(),
    'status': status.name,
  };

  /// Parses a previously-saved draft. Drafts written by older versions of
  /// this screen (where `findings` was a single free-text string, and there
  /// was no `status`) are intentionally not migrated — any field in an
  /// unexpected shape is treated as absent rather than thrown, so an old
  /// draft just opens empty instead of crashing the screen.
  factory WorkReportDraft.fromJson(Map<String, dynamic> json) {
    final findingsJson = json['findings'];
    return WorkReportDraft(
      workDescription: json['workDescription'] as String? ?? '',
      startingSituation: json['startingSituation'] as String? ?? '',
      findings: findingsJson is List
          ? findingsJson
                .whereType<Map>()
                .map((f) => Finding.fromJson(Map<String, dynamic>.from(f)))
                .toList()
          : const [],
      recommendations: json['recommendations'] as String? ?? '',
      photoPaths:
          (json['photoPaths'] as List<dynamic>?)?.cast<String>() ?? const [],
      documents:
          (json['documents'] as List<dynamic>?)
              ?.whereType<Map>()
              .map((d) => WorkReportDocumentRef.fromJson(
                    Map<String, dynamic>.from(d),
                  ))
              .toList() ??
          const [],
      status: WorkReportStatus.fromName(json['status'] as String?),
    );
  }
}
