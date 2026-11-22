import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'accounts.dart';
import 'library.dart';

const _localKey = 'rep_playlists';
const _mainKey = 'rep_main_account';
const _remoteName = 'listas.json'; // carpeta oculta de la app (appDataFolder)
const backupName = 'Reproductor - listas (respaldo).json'; // copia visible en Mi unidad

/// Una canción de una lista: cuenta + archivo (y el nombre, por si ya no está).
class PlaylistItem {
  final String email;
  final String id;
  final String name;
  PlaylistItem(this.email, this.id, this.name);

  Map<String, dynamic> toJson() => {'e': email, 'i': id, 'n': name};
  factory PlaylistItem.fromJson(Map<String, dynamic> j) =>
      PlaylistItem(j['e'] as String, j['i'] as String, (j['n'] as String?) ?? '');
}

class Playlist {
  final String id;
  String name;
  List<PlaylistItem> items;
  int updated; // milisegundos: gana la versión más nueva al sincronizar
  bool deleted;

  Playlist(this.id, this.name, this.items, this.updated, {this.deleted = false});

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'u': updated,
        if (deleted) 'del': 1,
        'items': [for (final i in items) i.toJson()],
      };

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        j['id'] as String,
        (j['name'] as String?) ?? 'Lista',
        [
          for (final i in (j['items'] as List? ?? []))
            PlaylistItem.fromJson(i as Map<String, dynamic>)
        ],
        (j['u'] as num?)?.toInt() ?? 0,
        deleted: j['del'] == 1,
      );
}

class _NoPermission implements Exception {}

/// Listas de reproducción: se guardan en el equipo y se sincronizan con la
/// carpeta oculta de la cuenta principal, más una copia visible de respaldo.
class PlaylistStore extends ChangeNotifier {
  final AccountStore store;
  final Map<String, Playlist> _all = {};
  String? _mainEmail;
  Timer? _debounce;
  bool syncing = false;
  DateTime? lastSync;
  String? syncError;
  final _rnd = Random();

  PlaylistStore(this.store);

  List<Playlist> get playlists {
    final out = _all.values.where((p) => !p.deleted).toList()
      ..sort((a, b) => normalizeName(a.name).compareTo(normalizeName(b.name)));
    return out;
  }

  Playlist? byId(String id) {
    final p = _all[id];
    return (p == null || p.deleted) ? null : p;
  }

  Account? get mainAccount {
    for (final a in store.accounts) {
      if (a.email == _mainEmail) return a;
    }
    return store.accounts.isEmpty ? null : store.accounts.first;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _mainEmail = prefs.getString(_mainKey);
    final raw = prefs.getString(_localKey);
    if (raw != null) {
      try {
        _all
          ..clear()
          ..addAll(_decode(raw));
      } catch (_) {}
    }
    notifyListeners();
  }

  Map<String, Playlist> _decode(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return {
      for (final p in (j['playlists'] as List? ?? []))
        (p as Map<String, dynamic>)['id'] as String: Playlist.fromJson(p)
    };
  }

  String _encode() {
    final list = _all.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return jsonEncode({'v': 1, 'playlists': [for (final p in list) p.toJson()]});
  }

  Future<void> _saveLocal() async {
    await (await SharedPreferences.getInstance()).setString(_localKey, _encode());
  }

  void _touch(Playlist p) {
    p.updated = DateTime.now().millisecondsSinceEpoch;
    _saveLocal();
    notifyListeners();
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), sync);
  }

  String _newId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_rnd.nextInt(1 << 30).toRadixString(36)}';

  Playlist create(String name) {
    final p = Playlist(_newId(), name.trim().isEmpty ? 'Lista nueva' : name.trim(), [], 0);
    _all[p.id] = p;
    _touch(p);
    return p;
  }

  void rename(Playlist p, String name) {
    if (name.trim().isEmpty) return;
    p.name = name.trim();
    _touch(p);
  }

  void delete(Playlist p) {
    p.deleted = true;
    p.items = [];
    _touch(p);
  }

  /// Agrega canciones (sin repetir las que ya están). Devuelve cuántas agregó.
  int addTracks(Playlist p, List<Track> tracks) {
    final have = {for (final i in p.items) '${i.email}|${i.id}'};
    var n = 0;
    for (final t in tracks) {
      final k = '${t.account.email}|${t.item.id}';
      if (have.add(k)) {
        p.items.add(PlaylistItem(t.account.email, t.item.id, t.title));
        n++;
      }
    }
    if (n > 0) _touch(p);
    return n;
  }

  void removeAt(Playlist p, int index) {
    if (index < 0 || index >= p.items.length) return;
    p.items.removeAt(index);
    _touch(p);
  }

  void move(Playlist p, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final it = p.items.removeAt(oldIndex);
    p.items.insert(newIndex, it);
    _touch(p);
  }

  Future<void> setMain(Account a) async {
    _mainEmail = a.email;
    await (await SharedPreferences.getInstance()).setString(_mainKey, a.email);
    notifyListeners();
    await sync();
  }

  // ------------------------------------------------------------------ sincronización

  /// Trae lo guardado en Drive (carpeta oculta y respaldo), combina por lista
  /// (gana la más nueva) y sube el resultado si cambió.
  Future<void> sync() async {
    final a = mainAccount;
    if (a == null || syncing) return;
    syncing = true;
    syncError = null;
    notifyListeners();
    try {
      final token = await store.tokenFor(a);
      final appId = await _find(token, "name = '$_remoteName'", appData: true);
      final backupId = await _find(token, "name = '$backupName' and trashed = false");
      String? remote;
      for (final id in [appId, backupId]) {
        if (id == null) continue;
        final raw = await _download(token, id);
        if (raw == null) continue;
        try {
          for (final p in _decode(raw).values) {
            final mine = _all[p.id];
            if (mine == null || p.updated > mine.updated) _all[p.id] = p;
          }
          remote ??= raw;
        } catch (_) {}
      }
      final merged = _encode();
      await _saveLocal();
      notifyListeners();
      if (appId == null || remote == null || remote != merged) {
        await _upload(token, appId, merged, appData: true);
      }
      final backupRaw = backupId == null ? null : await _download(token, backupId);
      if (backupId == null || backupRaw != merged) {
        await _upload(token, backupId, merged, appData: false);
      }
      lastSync = DateTime.now();
    } on NeedsReconnect {
      syncError = '${a.title}: hay que volver a conectar la cuenta';
    } on _NoPermission {
      syncError = '${a.title} no tiene permiso para guardar las listas. Volvé a conectarla '
          'aceptando todos los permisos (solo toca los archivos de esta app).';
    } catch (e) {
      syncError = 'No se pudieron sincronizar las listas: $e';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  static void _check(http.Response res) {
    if (res.statusCode == 401) throw NeedsReconnect();
    if (res.statusCode == 403 && res.body.contains('insufficient')) throw _NoPermission();
    if (res.statusCode >= 300) {
      throw Exception('Drive respondió ${res.statusCode}');
    }
  }

  static Future<String?> _find(String token, String q, {bool appData = false}) async {
    final res = await http.get(
      Uri.https('www.googleapis.com', '/drive/v3/files', {
        'q': q,
        'spaces': appData ? 'appDataFolder' : 'drive',
        'fields': 'files(id,modifiedTime)',
        'orderBy': 'modifiedTime desc',
        'pageSize': '1',
      }),
      headers: {'Authorization': 'Bearer $token'},
    );
    _check(res);
    final files = (jsonDecode(res.body) as Map<String, dynamic>)['files'] as List? ?? [];
    return files.isEmpty ? null : (files.first as Map<String, dynamic>)['id'] as String;
  }

  static Future<String?> _download(String token, String id) async {
    final res = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/$id?alt=media'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode == 404) return null;
    _check(res);
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }

  /// Actualiza el archivo [id] o, si no existe, lo crea.
  static Future<void> _upload(String token, String? id, String content,
      {required bool appData}) async {
    if (id != null) {
      final res = await http.patch(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$id?uploadType=media'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json; charset=UTF-8',
        },
        body: utf8.encode(content),
      );
      if (res.statusCode != 404) {
        _check(res);
        return;
      }
    }
    final boundary = 'rep${DateTime.now().microsecondsSinceEpoch}';
    final meta = {
      'name': appData ? _remoteName : backupName,
      'mimeType': 'application/json',
      if (appData) 'parents': ['appDataFolder'],
    };
    final body = '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '${jsonEncode(meta)}\r\n'
        '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$content\r\n'
        '--$boundary--';
    final res = await http.post(
      Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'multipart/related; boundary=$boundary',
      },
      body: utf8.encode(body),
    );
    _check(res);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

String normalizeName(String s) => s.toLowerCase();
