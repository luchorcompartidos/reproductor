import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'accounts.dart';
import 'library.dart';
import 'offline_files/offline_files.dart' as files;

const _key = 'rep_offline';

/// Una canción descargada en el equipo.
class OfflineEntry {
  final String email;
  final String id;
  final String name;
  final String path;
  final int size;
  final int modified;

  OfflineEntry(this.email, this.id, this.name, this.path, this.size, this.modified);

  String get key => offlineKey(email, id);

  Map<String, dynamic> toJson() =>
      {'e': email, 'i': id, 'n': name, 'p': path, 's': size, 'm': modified};

  factory OfflineEntry.fromJson(Map<String, dynamic> j) => OfflineEntry(
        j['e'] as String,
        j['i'] as String,
        (j['n'] as String?) ?? '',
        j['p'] as String,
        (j['s'] as num?)?.toInt() ?? 0,
        (j['m'] as num?)?.toInt() ?? 0,
      );
}

String offlineKey(String email, String id) => '$email|$id';

/// Descargas para escuchar sin conexión (Android y Windows).
class OfflineStore extends ChangeNotifier {
  final AccountStore store;
  final Map<String, OfflineEntry> entries = {};

  /// Descargas en curso o pendientes: clave → avance (0 a 1; -1 = pendiente).
  final Map<String, double> progress = {};
  final List<Track> _queue = [];
  bool _running = false;
  bool _cancel = false;
  String? lastError;
  int failed = 0;

  OfflineStore(this.store);

  bool get supported => files.offlineSupported;
  bool get busy => progress.isNotEmpty;
  int get pending => progress.length;
  int get totalBytes => entries.values.fold(0, (s, e) => s + e.size);

  bool isDownloaded(Track t) => entries.containsKey(offlineKey(t.account.email, t.item.id));
  double? progressOf(Track t) => progress[offlineKey(t.account.email, t.item.id)];

  /// Archivo local de la canción, si está descargada.
  String? localPath(Track t) => entries[offlineKey(t.account.email, t.item.id)]?.path;

  Future<void> load() async {
    if (!supported) return;
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return;
    try {
      for (final j in jsonDecode(raw) as List) {
        final e = OfflineEntry.fromJson(j as Map<String, dynamic>);
        entries[e.key] = e;
      }
    } catch (_) {}
    // Si algún archivo ya no está (se borró a mano), se saca de la lista.
    var changed = false;
    for (final e in List.of(entries.values)) {
      if (!await files.fileExists(e.path)) {
        entries.remove(e.key);
        changed = true;
      }
    }
    if (changed) await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode([for (final e in entries.values) e.toJson()]));
  }

  /// Agrega a la cola las que todavía no están descargadas. Devuelve cuántas.
  int enqueue(List<Track> tracks) {
    if (!supported) return 0;
    var n = 0;
    for (final t in tracks) {
      final k = offlineKey(t.account.email, t.item.id);
      if (entries.containsKey(k) || progress.containsKey(k)) continue;
      progress[k] = -1;
      _queue.add(t);
      n++;
    }
    if (n > 0) {
      failed = 0;
      lastError = null;
      notifyListeners();
      unawaited(_run());
    }
    return n;
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    _cancel = false;
    try {
      while (_queue.isNotEmpty && !_cancel) {
        final t = _queue.removeAt(0);
        final k = offlineKey(t.account.email, t.item.id);
        try {
          final token = await store.tokenFor(t.account);
          final path = await files.pathFor(k, trackFormat(t.item));
          var lastNotify = DateTime.now();
          final size = await files.download(
            path,
            Uri.parse('https://www.googleapis.com/drive/v3/files/${t.item.id}'
                '?alt=media&supportsAllDrives=true'),
            {'Authorization': 'Bearer $token'},
            (got, total) {
              final s = total ?? (t.item.size > 0 ? t.item.size : 0);
              progress[k] = s > 0 ? (got / s).clamp(0.0, 1.0) : 0.0;
              if (DateTime.now().difference(lastNotify) > const Duration(milliseconds: 300)) {
                lastNotify = DateTime.now();
                notifyListeners();
              }
            },
            () => _cancel,
          );
          entries[k] = OfflineEntry(
              t.account.email, t.item.id, t.title, path, size, t.item.modified);
          await _save();
        } on files.DownloadCancelled {
          break;
        } catch (e) {
          failed++;
          lastError = e is NeedsReconnect
              ? '${t.account.title}: hay que volver a conectar la cuenta'
              : 'No se pudo descargar "${t.title}": $e';
        } finally {
          progress.remove(k);
          notifyListeners();
        }
      }
    } finally {
      if (_cancel) {
        for (final t in _queue) {
          progress.remove(offlineKey(t.account.email, t.item.id));
        }
        _queue.clear();
      }
      _running = false;
      _cancel = false;
      notifyListeners();
    }
  }

  void cancelAll() {
    _cancel = true;
    for (final t in _queue) {
      progress.remove(offlineKey(t.account.email, t.item.id));
    }
    _queue.clear();
    notifyListeners();
  }

  Future<void> removeKey(String key) async {
    final e = entries.remove(key);
    if (e == null) return;
    try {
      await files.deleteFile(e.path);
    } catch (_) {}
    await _save();
    notifyListeners();
  }

  Future<void> remove(Track t) => removeKey(offlineKey(t.account.email, t.item.id));

  Future<void> removeTracks(List<Track> tracks) async {
    for (final t in tracks) {
      final e = entries.remove(offlineKey(t.account.email, t.item.id));
      if (e != null) {
        try {
          await files.deleteFile(e.path);
        } catch (_) {}
      }
    }
    await _save();
    notifyListeners();
  }

  Future<void> removeAccount(String email) async {
    for (final e in List.of(entries.values)) {
      if (e.email != email) continue;
      entries.remove(e.key);
      try {
        await files.deleteFile(e.path);
      } catch (_) {}
    }
    await _save();
    notifyListeners();
  }

  Future<void> removeAll() async {
    cancelAll();
    for (final e in List.of(entries.values)) {
      try {
        await files.deleteFile(e.path);
      } catch (_) {}
    }
    entries.clear();
    await _save();
    notifyListeners();
  }
}
