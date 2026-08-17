/// Vaste configuratiewaarden voor inkoopfacturen (declaraties).
/// Stel deze in op de juiste IDs uit jouw RidderIQ-omgeving.
class DeclarationsConfig {
  static const int? daybookId = null;
  static const int? currencyId = null; // bijv. 1 voor EUR
  static const double exchangeRate = 1.0;
  static const int? paymentTermId = null;
  static const int? paymentMethodId = null;
  static const int? vatCompanyGroupId = null;
  static const int? incotermId = null;
  static const int? purchaseUnitId = null; // bijv. "stuk"
}
