/// Gedeelde pickstatus van de door kantoor geplande onderdelen van een bon
/// (`servicebonnen/{bon}/picking/status`), zodat alle monteurs op de bon
/// zien wat er al gepakt is.
///
/// Sleutels zijn de ids van de `joborderdetails`-regels (als tekst).
class PickingStatus {
  const PickingStatus({
    this.aantallen = const {},
    this.gepakt = const {},
    this.bevestigd = false,
    this.bijgewerktDoor,
  });

  /// Gepickt aantal per onderdeel.
  final Map<String, int> aantallen;

  /// Onderdelen die bij "Bevestigen" als meegenomen zijn gemarkeerd.
  final Set<String> gepakt;

  /// Is het picken voor deze bon bevestigd?
  final bool bevestigd;

  /// Naam van de monteur die het laatst iets wijzigde.
  final String? bijgewerktDoor;

  factory PickingStatus.fromMap(Map<String, dynamic> m) => PickingStatus(
    aantallen: {
      for (final e in ((m['aantallen'] as Map?) ?? const {}).entries)
        if ((e.value as num).toInt() > 0)
          e.key.toString(): (e.value as num).toInt(),
    },
    gepakt: {
      for (final e in ((m['gepakt'] as Map?) ?? const {}).entries)
        if (e.value == true) e.key.toString(),
    },
    bevestigd: m['bevestigd'] as bool? ?? false,
    bijgewerktDoor: m['bijgewerktDoorNaam'] as String?,
  );
}
