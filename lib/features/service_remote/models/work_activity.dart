/// A selectable "werksoort" (uursoort) for an hours entry.
class WorkActivity {
  const WorkActivity({
    required this.id,
    required this.code,
    required this.label,
  });

  final int id;
  final String code;
  final String label;
}

/// Hardcoded until the phase-0 stamdata (reference-data) endpoint is wired
/// up. Only the activities that have actually been verified against the API
/// are listed — don't add more without confirming their id first.
const defaultWorkActivities = [
  WorkActivity(id: 23, code: 'SRV-ABR', label: 'Service Engineer Abroad'),
  WorkActivity(id: 20, code: 'SRV-NL', label: 'Service Engineer NL'),
  WorkActivity(id: 24, code: 'TRAV-H', label: 'Reisuren'),
];

/// Call sites should read `workActivitiesProvider()` rather than
/// [defaultWorkActivities] directly, so swapping in an API-backed list later
/// is a one-line change here instead of touching every call site.
List<WorkActivity> Function() workActivitiesProvider =
    () => defaultWorkActivities;
