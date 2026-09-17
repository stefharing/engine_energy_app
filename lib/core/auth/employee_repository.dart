import '../api/api_client.dart';
import 'employee.dart';

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
}
