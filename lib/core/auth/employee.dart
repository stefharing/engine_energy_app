/// A field engineer from `GET /ServiceRemote/Employee` — what a technician
/// picks on the login screen. `/ServiceRemote/login` doesn't actually
/// authenticate per user on this tenant (it always resolves to the
/// Administrator account — see [AuthService.login]), so this picked
/// [Employee], not that endpoint's response, is what the rest of the app
/// treats as "who's logged in" (see [AuthService.currentMechanicId]) and
/// uses to filter job orders to the technician's own.
class Employee {
  final int id;
  final String name;
  final String code;

  const Employee({required this.id, required this.name, required this.code});

  /// Whether an `/ServiceRemote/Employee` entry is a field technician who
  /// does service work, as opposed to office staff or the Administrator
  /// account — only these show up in the login screen's picker.
  static bool isFieldEngineer(Map<String, dynamic> json) =>
      json['service'] == true;

  factory Employee.fromJson(Map<String, dynamic> json) => Employee(
    id: json['id'] as int,
    name: json['recordTag'] as String? ?? '',
    code: json['code'] as String? ?? '',
  );

  factory Employee.fromStorageJson(Map<String, dynamic> json) => Employee(
    id: json['id'] as int,
    name: json['name'] as String? ?? '',
    code: json['code'] as String? ?? '',
  );

  Map<String, dynamic> toStorageJson() => {
    'id': id,
    'name': name,
    'code': code,
  };
}
