import '../api/api_client.dart';
import 'employee.dart';
import 'employee_matcher.dart';

/// Fetches the tenant's field engineers from `GET /ServiceRemote/Employee`,
/// for the login screen's picker — see [Employee].
class EmployeeRepository {
  EmployeeRepository._();
  static final instance = EmployeeRepository._();

  Future<List<Employee>> fetchFieldEngineers() async {
    final response = await ApiClient.instance.serviceRemoteDio.get(
      '/ServiceRemote/Employee',
    );
    final data = (response.data as List).cast<Map<String, dynamic>>();
    return data.where(Employee.isFieldEngineer).map(Employee.fromJson).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Zoekt de monteur bij een Microsoft-account op e-mailadres: Ridder
  /// (`/hours/employees`) is de bron van de adressen, de monteurslijst van de
  /// app levert de uiteindelijke [Employee]. Zie [matchEmployeeByEmail].
  Future<Employee?> findByEmails(Iterable<String> emails) async {
    final ridder = await _fetchRidderEmployees();
    final engineers = await fetchFieldEngineers();
    return matchEmployeeByEmail(
      emails: emails,
      ridderEmployees: ridder,
      fieldEngineers: engineers,
    );
  }

  Future<List<Map<String, dynamic>>> _fetchRidderEmployees() async {
    const pageSize = 200;
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= 10; page++) {
      final resp = await ApiClient.instance.dio.get(
        '/hours/employees',
        queryParameters: {'page': page, 'size': pageSize},
      );
      final data = resp.data;
      final list = (data is Map ? (data['items'] ?? data['data']) : data);
      final items = (list as List? ?? const []).cast<Map<String, dynamic>>();
      all.addAll(items);
      if (items.length < pageSize) break;
    }
    return all;
  }
}
