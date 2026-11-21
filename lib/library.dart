import 'package:flutter/foundation.dart';

import 'accounts.dart';
import 'drive_index.dart';

/// Solo carpetas y audio (no se leen fotos, documentos, etc.).
const audioQuery = "trashed = false and (mimeType = '$folderMime' or "
    "mimeType contains 'audio/' or mimeType = 'application/ogg')";

bool isAudioItem(DriveItem it) =>
    !it.isFolder && (it.mime.startsWith('audio/') || it.mime == 'application/ogg');

bool keepItem(DriveItem it) => !it.trashed && (it.isFolder || isAudioItem(it));

/// Nombre sin la extensión (".mp3", ".flac", …).
String trackTitle(String name) {
  final i = name.lastIndexOf('.');
  return (i > 0 && name.length - i <= 5) ? name.substring(0, i) : name;
}

/// Extensión en mayúsculas (MP3, FLAC, …) o el tipo de audio.
String trackFormat(DriveItem it) {
  final i = it.name.lastIndexOf('.');
  if (i > 0 && it.name.length - i <= 5) return it.name.substring(i + 1).toUpperCase();
  final m = it.mime.split('/');
  return m.length == 2 ? m[1].toUpperCase() : it.mime;
}

/// Una canción de una cuenta.
class Track {
  final Account account;
  final DriveItem item;
  final String folder; // carpeta que la contiene
  final String sortKey;
  final String searchKey;

  Track(this.account, this.item, this.folder)
      : sortKey = normalize(trackTitle(item.name)),
        searchKey = normalize('${item.name} $folder');

  String get title => trackTitle(item.name);
}

/// La música de todas las cuentas: índices (solo audio), cambios y búsqueda.
class Library extends ChangeNotifier {
  final AccountStore store;
  final IndexStore indexes =
      IndexStore(query: audioQuery, keep: keepItem, keyPrefix: 'audio_');
  final Map<String, String> errors = {};
  List<Track>? _tracks;
  final Set<String> _running = {}; // cuentas que se están leyendo ahora

  Library(this.store);

  bool get busy => indexes.progress.isNotEmpty;
  bool get persists => indexes.persists;

  void _changed() {
    _tracks = null;
    notifyListeners();
  }

  /// Carga lo guardado y después lo pone al día.
  Future<void> start() async {
    await indexes.loadAll(store.accounts.map((a) => a.email));
    _changed();
    await refreshAll();
  }

  Future<void> refreshAll() async {
    for (final a in List.of(store.accounts)) {
      await refresh(a);
    }
  }

  /// Lee solo los cambios; si no hay índice (o no se puede), lo arma completo.
  Future<void> refresh(Account a) async {
    if (!_running.add(a.email)) return;
    errors.remove(a.email);
    try {
      final n = await indexes.update(a.email, () => store.tokenFor(a), notifyListeners);
      if (n == null) {
        await indexes.build(a.email, () => store.tokenFor(a), notifyListeners);
      }
    } catch (e) {
      errors[a.email] = e is NeedsReconnect ? 'Hay que volver a conectar esta cuenta' : '$e';
    } finally {
      _running.remove(a.email);
    }
    _changed();
  }

  /// Vuelve a leer toda la música de la cuenta.
  Future<void> rebuild(Account a) async {
    if (!_running.add(a.email)) return;
    errors.remove(a.email);
    try {
      await indexes.build(a.email, () => store.tokenFor(a), notifyListeners);
    } catch (e) {
      errors[a.email] = e is NeedsReconnect ? 'Hay que volver a conectar esta cuenta' : '$e';
    } finally {
      _running.remove(a.email);
    }
    _changed();
  }

  Future<void> forget(String email) async {
    await indexes.remove(email);
    errors.remove(email);
    _changed();
  }

  AccountIndex? indexOf(Account a) => indexes.loaded[a.email];

  int? progressOf(Account a) => indexes.progress[a.email];

  int countFor(Account a) => indexOf(a)?.fileCount ?? 0;

  /// Carpetas desde arriba hasta la que contiene la canción.
  String pathOf(Track t) {
    final idx = indexOf(t.account);
    final p = idx?.parentOf[t.item.id];
    if (idx == null || p == null) return t.folder;
    return idx.pathTo(p).map((f) => f.name).join(' / ');
  }

  Track trackFor(Account a, DriveItem it) {
    final idx = indexOf(a);
    final p = idx?.parentOf[it.id];
    return Track(a, it, p == null ? '' : (idx?.items[p]?.name ?? ''));
  }

  /// Todas las canciones de todas las cuentas, por nombre.
  List<Track> get tracks {
    final cached = _tracks;
    if (cached != null) return cached;
    final out = <Track>[];
    for (final a in store.accounts) {
      final idx = indexes.loaded[a.email];
      if (idx == null) continue;
      for (final it in idx.items.values) {
        if (it.isVirtual || it.isFolder || !isAudioItem(it)) continue;
        final p = idx.parentOf[it.id];
        out.add(Track(a, it, p == null ? '' : (idx.items[p]?.name ?? '')));
      }
    }
    out.sort((x, y) => x.sortKey.compareTo(y.sortKey));
    return _tracks = out;
  }

  /// Busca por nombre de canción o de carpeta (todas las palabras, sin acentos).
  List<Track> search(String query) {
    final words =
        normalize(query.trim()).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return tracks;
    return tracks.where((t) => words.every(t.searchKey.contains)).toList();
  }
}
