import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_config.dart';

/// Coördinaten + kaartafbeelding van een adres.
class MapSnapshot {
  final double lat;
  final double lon;
  final Uint8List? image;
  const MapSnapshot({required this.lat, required this.lon, this.image});
}

/// Zoekt de coördinaten van een adres op (Geoapify Geocoding) en haalt een
/// statisch kaartje op (Geoapify Static Maps). Beide worden lokaal
/// gecachet, zodat het kaartje offline blijft werken en we het dagelijkse
/// gratis tegoed niet onnodig gebruiken.
///
/// Gebruikt bewust een eigen, kale [Dio] — nooit de Ridder-client, anders
/// lekt de Ridder `X-API-KEY` naar een externe partij.
class MapSnapshotService {
  MapSnapshotService._();
  static final instance = MapSnapshotService._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
    ),
  );

  static const _zoom = 15;
  static const _breedte = 600;
  static const _hoogte = 220;

  Future<MapSnapshot?> laad(String adres, {required bool donker}) async {
    final zoek = adres.trim();
    if (zoek.isEmpty) return null;
    try {
      final coord = await _coordinaten(zoek);
      if (coord == null) return null;
      final img = await _afbeelding(coord.$1, coord.$2, donker);
      return MapSnapshot(lat: coord.$1, lon: coord.$2, image: img);
    } catch (e) {
      debugPrint('[kaart] mislukt: $e');
      return null;
    }
  }

  String _sleutel(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  Future<(double, double)?> _coordinaten(String adres) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'geo_${_sleutel(adres)}';
    final bewaard = prefs.getString(key);
    if (bewaard != null) {
      final d = jsonDecode(bewaard) as Map<String, dynamic>;
      return ((d['lat'] as num).toDouble(), (d['lon'] as num).toDouble());
    }
    final res = await _dio.get<Map<String, dynamic>>(
      'https://api.geoapify.com/v1/geocode/search',
      queryParameters: {
        'text': adres,
        'limit': 1,
        'format': 'json',
        'apiKey': ApiConfig.geoapifyApiKey,
      },
    );
    final lijst = res.data?['results'] as List?;
    if (lijst == null || lijst.isEmpty) return null;
    final r = lijst.first as Map<String, dynamic>;
    final lat = (r['lat'] as num?)?.toDouble();
    final lon = (r['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;
    await prefs.setString(key, jsonEncode({'lat': lat, 'lon': lon}));
    return (lat, lon);
  }

  Future<Uint8List?> _afbeelding(double lat, double lon, bool donker) async {
    final stijl = donker ? 'dark-matter' : 'osm-bright';
    final naam =
        'kaart_${lat.toStringAsFixed(5)}_${lon.toStringAsFixed(5)}_$stijl.png';
    File? bestand;
    try {
      final dir = await getApplicationSupportDirectory();
      bestand = File('${dir.path}/$naam');
      if (await bestand.exists()) return await bestand.readAsBytes();
    } catch (_) {}
    try {
      final res = await _dio.get<List<int>>(
        'https://maps.geoapify.com/v1/staticmap',
        queryParameters: {
          'style': stijl,
          'width': _breedte,
          'height': _hoogte,
          'center': 'lonlat:$lon,$lat',
          'zoom': _zoom,
          'scaleFactor': 2,
          'format': 'png',
          'apiKey': ApiConfig.geoapifyApiKey,
        },
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = Uint8List.fromList(res.data ?? const []);
      if (bytes.isEmpty) return null;
      try {
        await bestand?.writeAsBytes(bytes);
      } catch (_) {}
      return bytes;
    } catch (e) {
      debugPrint('[kaart] afbeelding mislukt: $e');
      return null;
    }
  }
}
