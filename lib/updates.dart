import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// Una Release de GitHub: número, fecha, notas e instaladores.
class ReleaseInfo {
  final String tag;
  final DateTime? date;
  final String notes;
  final String htmlUrl;
  final Map<String, String> assets; // nombre → link de descarga

  ReleaseInfo(this.tag, this.date, this.notes, this.htmlUrl, this.assets);

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  String? assetEndingWith(String ext) {
    for (final e in assets.entries) {
      if (e.key.toLowerCase().endsWith(ext)) return e.value;
    }
    return null;
  }

  factory ReleaseInfo.fromApi(Map<String, dynamic> j) {
    final assets = <String, String>{};
    DateTime? newest;
    for (final a in (j['assets'] as List? ?? [])) {
      final m = a as Map<String, dynamic>;
      assets[m['name'] as String] = m['browser_download_url'] as String;
      final d = DateTime.tryParse('${m['updated_at']}');
      if (d != null && (newest == null || d.isAfter(newest))) newest = d;
    }
    return ReleaseInfo(
      j['tag_name'] as String,
      newest ?? DateTime.tryParse('${j['published_at']}'),
      ((j['body'] as String?) ?? '').trim(),
      j['html_url'] as String,
      assets,
    );
  }
}

class Updates {
  static const _cacheKey = 'rep_releases';

  /// Releases de GitHub (más nueva primero). Sin conexión: la última copia guardada.
  static Future<List<ReleaseInfo>> fetch() async {
    final prefs = await SharedPreferences.getInstance();
    String? raw;
    try {
      final res = await http.get(
        Uri.parse('https://api.github.com/repos/${Config.repoSlug}/releases?per_page=30'),
        headers: {'Accept': 'application/vnd.github+json'},
      );
      if (res.statusCode == 200) {
        raw = res.body;
        await prefs.setString(_cacheKey, raw);
      }
    } catch (_) {}
    raw ??= prefs.getString(_cacheKey);
    if (raw == null) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((j) => ReleaseInfo.fromApi(j as Map<String, dynamic>))
          .where((r) => _parse(r.version) != null)
          .toList();
      list.sort((a, b) => compare(b.version, a.version));
      return list;
    } catch (_) {
      return [];
    }
  }

  static List<int>? _parse(String v) {
    final m = RegExp(r'^(\d+)\.(\d+)(?:\.(\d+))?').firstMatch(v);
    if (m == null) return null;
    return [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3] ?? '0')];
  }

  /// >0 si a es más nueva que b (ignora sufijos como "-prueba").
  static int compare(String a, String b) {
    final x = _parse(a) ?? [0, 0, 0], y = _parse(b) ?? [0, 0, 0];
    for (var i = 0; i < 3; i++) {
      if (x[i] != y[i]) return x[i] - y[i];
    }
    return 0;
  }
}
