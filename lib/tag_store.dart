import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'accounts.dart';
import 'cover_storage/cover_storage.dart' as covers;
import 'drive_index.dart';
import 'tag_storage/tag_storage.dart' as storage;
import 'tags.dart';

class _FetchError implements Exception {
  final int status;
  _FetchError(this.status);
  @override
  String toString() => 'Drive respondió $status';
}

/// Etiquetas y carátulas de todas las canciones: las lee de a poco (solo el
/// comienzo de cada archivo), las guarda y solo relee lo que cambió.
class TagStore extends ChangeNotifier {
  final Map<String, Map<String, TagInfo>> _tags = {};
  final Map<String, Future<Uint8List?>> _coverCache = {};
  final Set<String> _dirty = {};
  int done = 0;
  int total = 0;
  bool running = false;
  bool _again = false;

  TagInfo? get(String email, String id) => _tags[email]?[id];

  Future<void> load(Iterable<String> emails) async {
    try {
      await covers.initCovers();
    } catch (_) {}
    for (final e in emails) {
      if (_tags.containsKey(e)) continue;
      final m = <String, TagInfo>{};
      try {
        final raw = await storage.loadTags(e);
        if (raw != null) {
          final j = jsonDecode(raw) as Map<String, dynamic>;
          j.forEach((k, v) => m[k] = TagInfo.fromJson(v as Map<String, dynamic>));
        }
      } catch (_) {}
      _tags[e] = m;
    }
  }

  Future<void> forget(String email) async {
    _tags.remove(email);
    _dirty.remove(email);
    try {
      await storage.deleteTags(email);
    } catch (_) {}
  }

  Future<void> _saveDirty() async {
    for (final e in List.of(_dirty)) {
      _dirty.remove(e);
      final m = _tags[e];
      if (m == null) continue;
      try {
        await storage.saveTags(e, jsonEncode(m.map((k, v) => MapEntry(k, v.toJson()))));
      } catch (_) {}
    }
  }

  /// Carátula guardada de una canción (con una memoria chica de las últimas usadas).
  Future<Uint8List?> cover(String id) {
    final f = _coverCache.remove(id) ?? covers.loadCover(id);
    _coverCache[id] = f;
    if (_coverCache.length > 80) _coverCache.remove(_coverCache.keys.first);
    return f;
  }

  /// Archivo de la carátula (Android: notificación y pantalla de bloqueo).
  Uri? coverUri(String id) => covers.coverUri(id);

  /// Lee las canciones nuevas o modificadas. [source] da la lista vigente.
  Future<void> scan(
    List<(Account, DriveItem)> Function() source,
    Future<String> Function(Account) token,
  ) async {
    if (running) {
      _again = true;
      return;
    }
    running = true;
    try {
      do {
        _again = false;
        final jobs = [
          for (final j in source())
            if (_tags.containsKey(j.$1.email) && get(j.$1.email, j.$2.id)?.modified != j.$2.modified)
              j
        ];
        if (jobs.isEmpty) break;
        total = jobs.length;
        done = 0;
        notifyListeners();
        var next = 0;
        Future<void> worker() async {
          while (next < jobs.length) {
            final j = jobs[next++];
            await _readOne(j.$1, j.$2, token);
            done++;
            if (done % 10 == 0 || done == total) notifyListeners();
            if (done % 40 == 0) await _saveDirty();
          }
        }

        await Future.wait([worker(), worker(), worker()]);
        await _saveDirty();
      } while (_again);
    } finally {
      running = false;
      total = 0;
      done = 0;
      notifyListeners();
    }
  }

  Future<void> _readOne(
      Account a, DriveItem it, Future<String> Function(Account) token) async {
    TagInfo info;
    try {
      final tk = await token(a);
      Future<Uint8List> fetch(int s, int e) => _range(tk, it.id, s, e);
      final r = await readTags(fetch, it.size, it.name, it.modified);
      info = r?.info ?? TagInfo(modified: it.modified);
      final c = r?.cover;
      if (c != null && c.isNotEmpty) {
        await covers.saveCover(it.id, c);
        _coverCache.remove(it.id);
      }
    } on NeedsReconnect {
      return; // se reintenta cuando se vuelva a conectar la cuenta
    } on _FetchError {
      return; // error de red o de Drive: se reintenta la próxima vez
    } on http.ClientException {
      return;
    } catch (_) {
      info = TagInfo(modified: it.modified); // formato raro: se usan las carpetas
    }
    final m = _tags[a.email];
    if (m == null) return; // la cuenta se quitó mientras se leía
    m[it.id] = info;
    _dirty.add(a.email);
  }

  static Future<Uint8List> _range(String token, String id, int start, int end) async {
    final res = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$id?alt=media&supportsAllDrives=true'),
      headers: {'Authorization': 'Bearer $token', 'Range': 'bytes=$start-$end'},
    );
    if (res.statusCode == 206) return res.bodyBytes;
    if (res.statusCode == 200) {
      final b = res.bodyBytes;
      if (start >= b.length) return Uint8List(0);
      return Uint8List.sublistView(b, start, min(end + 1, b.length));
    }
    if (res.statusCode == 416) return Uint8List(0);
    if (res.statusCode == 401) throw NeedsReconnect();
    throw _FetchError(res.statusCode);
  }
}
