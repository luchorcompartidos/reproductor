import 'dart:async';

import 'package:flutter/foundation.dart';

import 'accounts.dart';
import 'drive_index.dart';
import 'offline.dart';
import 'playlists.dart';
import 'tag_store.dart';
import 'tags.dart';

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

String? _nz(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

const unknownArtist = 'Artista desconocido';

/// Una canción de una cuenta. Con etiquetas usa título, artista y álbum del archivo;
/// sin etiquetas, el nombre del archivo, la carpeta (álbum) y la carpeta de arriba (artista).
class Track {
  final Account account;
  final DriveItem item;
  final String folder; // carpeta que la contiene
  final String folderId;
  final TagInfo? tag;
  final String? fallbackArtist;

  Track(this.account, this.item, this.folder,
      {this.folderId = '', this.tag, this.fallbackArtist});

  late final String title = _nz(tag?.title) ?? trackTitle(item.name);
  late final String artist =
      _nz(tag?.artist) ?? _nz(tag?.albumArtist) ?? fallbackArtist ?? unknownArtist;
  late final String albumArtist = _nz(tag?.albumArtist) ?? artist;
  late final String album = _nz(tag?.album) ?? (folder.isEmpty ? 'Sin álbum' : folder);
  late final String albumKey = _nz(tag?.album) != null
      ? 'a|${normalize(albumArtist)}|${normalize(album)}'
      : 'f|${account.email}|$folderId';
  late final String sortKey = normalize(title);
  late final String searchKey = normalize('${item.name} $title $artist $album $folder');
  bool get hasCover => tag?.cover == true;
}

class Album {
  final String key;
  final String name;
  final String artist;
  final List<Track> tracks = [];
  Album(this.key, this.name, this.artist);

  Track? get coverTrack {
    for (final t in tracks) {
      if (t.hasCover) return t;
    }
    return null;
  }

  String? get year {
    for (final t in tracks) {
      final y = t.tag?.year;
      if (y != null) return y;
    }
    return null;
  }
}

class Artist {
  final String name;
  final List<Album> albums = [];
  Artist(this.name);

  int get songCount => albums.fold(0, (s, a) => s + a.tracks.length);
  List<Track> get tracks => [for (final a in albums) ...a.tracks];
}

int _trackOrder(Track a, Track b) {
  final d = (a.tag?.disc ?? 0).compareTo(b.tag?.disc ?? 0);
  if (d != 0) return d;
  final n = (a.tag?.track ?? 1 << 20).compareTo(b.tag?.track ?? 1 << 20);
  if (n != 0) return n;
  return a.sortKey.compareTo(b.sortKey);
}

/// La música de todas las cuentas: índices (solo audio), etiquetas, cambios y búsqueda.
class Library extends ChangeNotifier {
  final AccountStore store;
  final IndexStore indexes =
      IndexStore(query: audioQuery, keep: keepItem, keyPrefix: 'audio_');
  final TagStore tags = TagStore();

  /// Listas de reproducción (se asigna al iniciar la app).
  PlaylistStore? lists;

  /// Descargas sin conexión (se asigna al iniciar la app).
  OfflineStore? offline;

  void attachOffline(OfflineStore o) {
    offline = o;
    o.addListener(notifyListeners);
  }
  final Map<String, String> errors = {};
  final Set<String> _running = {}; // cuentas que se están leyendo ahora
  List<Track>? _tracks;
  List<Album>? _albums;
  List<Artist>? _artists;
  Map<String, Track>? _byKey;

  Library(this.store) {
    tags.addListener(_changed);
  }

  bool get busy => indexes.progress.isNotEmpty;
  bool get persists => indexes.persists;

  void _changed() {
    _tracks = null;
    _albums = null;
    _artists = null;
    _byKey = null;
    notifyListeners();
  }

  /// Carga lo guardado y después lo pone al día.
  Future<void> start() async {
    final emails = store.accounts.map((a) => a.email).toList();
    await indexes.loadAll(emails);
    await tags.load(emails);
    _changed();
    await refreshAll();
  }

  Future<void> refreshAll() async {
    for (final a in List.of(store.accounts)) {
      await _refresh(a);
    }
    unawaited(scanTags());
  }

  /// Lee solo los cambios; si no hay índice (o no se puede), lo arma completo.
  Future<void> refresh(Account a) async {
    await _refresh(a);
    unawaited(scanTags());
  }

  Future<void> _refresh(Account a) async {
    if (!_running.add(a.email)) return;
    errors.remove(a.email);
    try {
      await tags.load([a.email]);
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
      await tags.load([a.email]);
      await indexes.build(a.email, () => store.tokenFor(a), notifyListeners);
    } catch (e) {
      errors[a.email] = e is NeedsReconnect ? 'Hay que volver a conectar esta cuenta' : '$e';
    } finally {
      _running.remove(a.email);
    }
    _changed();
    unawaited(scanTags());
  }

  /// Lee etiquetas y carátulas de lo que todavía no se leyó (o cambió).
  Future<void> scanTags() => tags.scan(() {
        final out = <(Account, DriveItem)>[];
        for (final a in store.accounts) {
          final idx = indexes.loaded[a.email];
          if (idx == null) continue;
          for (final it in idx.items.values) {
            if (!it.isVirtual && isAudioItem(it)) out.add((a, it));
          }
        }
        return out;
      }, store.tokenFor);

  Future<void> forget(String email) async {
    await indexes.remove(email);
    await tags.forget(email);
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

  Track trackFor(Account a, DriveItem it) => _make(a, indexOf(a), it);

  Track _make(Account a, AccountIndex? idx, DriveItem it) {
    final p = idx?.parentOf[it.id];
    final folder = p == null ? null : idx?.items[p];
    String? fallbackArtist;
    final gp = p == null ? null : idx?.parentOf[p];
    if (idx != null && gp != null && gp != idx.rootId) {
      final g = idx.items[gp];
      if (g != null && !g.isVirtual) fallbackArtist = g.name;
    }
    final folderName =
        (folder == null || folder.isVirtual || folder.id == idx?.rootId) ? '' : folder.name;
    return Track(
      a,
      it,
      folderName,
      folderId: p ?? '',
      tag: tags.get(a.email, it.id),
      fallbackArtist: fallbackArtist,
    );
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
        if (it.isVirtual || !isAudioItem(it)) continue;
        out.add(_make(a, idx, it));
      }
    }
    out.sort((x, y) => x.sortKey.compareTo(y.sortKey));
    return _tracks = out;
  }

  /// Álbumes (por etiquetas; sin etiquetas, cada carpeta es un álbum).
  List<Album> get albums {
    final cached = _albums;
    if (cached != null) return cached;
    final map = <String, Album>{};
    for (final t in tracks) {
      (map[t.albumKey] ??= Album(t.albumKey, t.album, t.albumArtist)).tracks.add(t);
    }
    final out = map.values.toList();
    for (final al in out) {
      al.tracks.sort(_trackOrder);
    }
    out.sort((a, b) => normalize(a.name).compareTo(normalize(b.name)));
    return _albums = out;
  }

  List<Artist> get artists {
    final cached = _artists;
    if (cached != null) return cached;
    final map = <String, Artist>{};
    for (final al in albums) {
      (map[normalize(al.artist)] ??= Artist(al.artist)).albums.add(al);
    }
    final out = map.values.toList()
      ..sort((a, b) => normalize(a.name).compareTo(normalize(b.name)));
    for (final ar in out) {
      ar.albums.sort((a, b) => (a.year ?? '').compareTo(b.year ?? ''));
    }
    return _artists = out;
  }

  /// Una canción por cuenta y archivo (null si ya no está en la biblioteca).
  Track? trackByKey(String email, String id) {
    final m = _byKey ??= {for (final t in tracks) '${t.account.email}|${t.item.id}': t};
    return m['$email|$id'];
  }

  /// Busca por canción, artista, álbum o carpeta (todas las palabras, sin acentos).
  List<Track> search(String query) {
    final words =
        normalize(query.trim()).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return tracks;
    return tracks.where((t) => words.every(t.searchKey.contains)).toList();
  }

  @override
  void dispose() {
    tags.removeListener(_changed);
    super.dispose();
  }
}
