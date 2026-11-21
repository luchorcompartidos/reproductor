import 'dart:convert';

import 'package:http/http.dart' as http;

import 'index_storage/index_storage.dart' as storage;

const folderMime = 'application/vnd.google-apps.folder';
const topId = '__top';
const otherId = '__otros';
const trashId = '__papelera';
const fileFields =
    'id,name,mimeType,size,quotaBytesUsed,parents,modifiedTime,md5Checksum,trashed,ownedByMe';

/// Un archivo o carpeta de Drive (solo metadatos).
class DriveItem {
  final String id;
  final String name;
  final String mime;
  final int size; // tamaño del archivo
  final int quota; // lo que ocupa en TU espacio (0 si no es tuyo)
  final String? parent;
  final int modified; // milisegundos
  final String? md5;
  final bool trashed;
  final bool mine;

  /// Carpetas: espacio que ocupa todo su contenido. Archivos: su quota.
  int total = 0;

  /// Carpetas: cantidad de archivos adentro (a cualquier nivel).
  int files = 0;

  DriveItem(this.id, this.name, this.mime, this.size, this.quota, this.parent, this.modified,
      this.md5, this.trashed, this.mine);

  bool get isFolder => mime == folderMime;
  bool get isVirtual => id.startsWith('__');
  DateTime get modifiedAt => DateTime.fromMillisecondsSinceEpoch(modified);
  int get shownSize => isFolder ? total : size;

  List<Object?> toRow() =>
      [id, name, mime, size, quota, parent, modified, md5, trashed ? 1 : 0, mine ? 1 : 0];

  factory DriveItem.fromRow(List<dynamic> r) => DriveItem(
        r[0] as String,
        r[1] as String,
        r[2] as String,
        (r[3] as num).toInt(),
        (r[4] as num).toInt(),
        r[5] as String?,
        (r[6] as num).toInt(),
        r[7] as String?,
        r[8] == 1,
        r[9] == 1,
      );

  factory DriveItem.fromApi(Map<String, dynamic> j) {
    int n(Object? v) => int.tryParse('${v ?? 0}') ?? 0;
    final parents = j['parents'] as List?;
    return DriveItem(
      j['id'] as String,
      (j['name'] as String?) ?? '(sin nombre)',
      (j['mimeType'] as String?) ?? '',
      n(j['size']),
      n(j['quotaBytesUsed']),
      (parents == null || parents.isEmpty) ? null : parents.first as String,
      DateTime.tryParse('${j['modifiedTime']}')?.millisecondsSinceEpoch ?? 0,
      j['md5Checksum'] as String?,
      j['trashed'] == true,
      j['ownedByMe'] == true,
    );
  }

  DriveItem copyWith({String? parent, bool? trashed}) => DriveItem(id, name, mime, size, quota,
      parent ?? this.parent, modified, md5, trashed ?? this.trashed, mine);

  static DriveItem virtual(String id, String name) =>
      DriveItem(id, name, folderMime, 0, 0, null, 0, null, false, true);
}

/// Índice completo de una cuenta, con el árbol y los tamaños por carpeta.
class AccountIndex {
  final String email;
  final String rootId;
  DateTime date;
  String? changeToken; // para actualizar solo lo que cambió
  final Map<String, DriveItem> items;
  final Map<String, List<DriveItem>> children = {};
  final Map<String, String> parentOf = {};

  AccountIndex(
      {required this.email,
      required this.rootId,
      required this.date,
      required this.items,
      this.changeToken}) {
    _build();
  }

  int get fileCount => items.values.where((i) => !i.isFolder).length;

  DriveItem get root => items[rootId]!;

  /// Recalcula árbol y tamaños después de un cambio.
  void rebuild() {
    children.clear();
    parentOf.clear();
    _build();
  }

  /// Todo lo que hay adentro de una carpeta (a cualquier nivel).
  List<String> descendants(String id) {
    final out = <String>[];
    final pending = [id];
    while (pending.isNotEmpty) {
      for (final c in children[pending.removeLast()] ?? const <DriveItem>[]) {
        out.add(c.id);
        if (c.isFolder) pending.add(c.id);
      }
    }
    return out;
  }

  void _build() {
    items[rootId] ??= DriveItem.virtual(rootId, 'Mi unidad');
    items[otherId] = DriveItem.virtual(otherId, 'Compartidos conmigo y sin carpeta');
    items[trashId] = DriveItem.virtual(trashId, 'Papelera');
    for (final it in items.values) {
      if (it.id == rootId || it.isVirtual) continue;
      final par = it.parent == null ? null : items[it.parent];
      String p;
      if (it.trashed) {
        p = (par != null && par.trashed) ? par.id : trashId;
      } else {
        p = (par != null && !par.trashed) ? par.id : otherId;
      }
      (children[p] ??= []).add(it);
      parentOf[it.id] = p;
    }
    parentOf[rootId] = topId;
    parentOf[otherId] = topId;
    parentOf[trashId] = topId;
    final seen = <String>{};
    for (final id in [rootId, otherId, trashId]) {
      _sum(items[id]!, seen);
    }
  }

  void _sum(DriveItem f, Set<String> seen) {
    if (!seen.add(f.id)) return;
    if (!f.isFolder) {
      f.total = f.quota;
      f.files = 1;
      return;
    }
    var total = 0, files = 0;
    for (final c in children[f.id] ?? const <DriveItem>[]) {
      _sum(c, seen);
      total += c.total;
      files += c.files;
    }
    f.total = total;
    f.files = files;
  }

  /// Carpetas desde arriba hasta [id] (incluida).
  List<DriveItem> pathTo(String id) {
    final out = <DriveItem>[];
    String? cur = id;
    var guard = 0;
    while (cur != null && cur != topId && guard++ < 200) {
      final it = items[cur];
      if (it == null) break;
      out.insert(0, it);
      cur = parentOf[cur];
    }
    return out;
  }

  String toJson() => jsonEncode({
        'v': 1,
        'email': email,
        'rootId': rootId,
        'date': date.toIso8601String(),
        'changeToken': changeToken,
        'items': [
          for (final i in items.values)
            if (!i.isVirtual) i.toRow()
        ],
      });

  static AccountIndex fromJson(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final items = <String, DriveItem>{};
    for (final r in j['items'] as List) {
      final it = DriveItem.fromRow(r as List);
      items[it.id] = it;
    }
    return AccountIndex(
      email: j['email'] as String,
      rootId: j['rootId'] as String,
      date: DateTime.parse(j['date'] as String),
      items: items,
      changeToken: j['changeToken'] as String?,
    );
  }
}

/// Índices de todas las cuentas: los arma, los guarda y los carga.
class IndexStore {
  /// Reproductor: filtro de Drive (q) para indexar solo carpetas y audio.
  final String? query;

  /// Qué elementos conservar al aplicar cambios (null = todos).
  final bool Function(DriveItem)? keep;

  /// Prefijo del archivo guardado, para no mezclar con otros índices.
  final String keyPrefix;

  IndexStore({this.query, this.keep, this.keyPrefix = ''});

  final Map<String, AccountIndex> loaded = {};
  final Map<String, int> progress = {}; // email → archivos leídos (indexando)

  bool get persists => storage.indexPersists;

  Future<void> loadAll(Iterable<String> emails) async {
    for (final e in emails) {
      if (loaded.containsKey(e)) continue;
      try {
        final raw = await storage.loadIndex('$keyPrefix$e');
        if (raw != null) loaded[e] = AccountIndex.fromJson(raw);
      } catch (_) {}
    }
  }

  Future<void> save(String email) async {
    final idx = loaded[email];
    if (idx != null) await storage.saveIndex('$keyPrefix$email', idx.toJson());
  }

  Future<void> remove(String email) async {
    loaded.remove(email);
    await storage.deleteIndex('$keyPrefix$email');
  }

  /// Recorre todo el Drive de la cuenta (solo metadatos) y guarda el índice.
  Future<AccountIndex> build(
    String email,
    Future<String> Function() token,
    void Function() onProgress,
  ) async {
    progress[email] = 0;
    onProgress();
    try {
      final rootJ = await _get(
          Uri.parse('https://www.googleapis.com/drive/v3/files/root?fields=id'), token);
      final rootId = rootJ['id'] as String;
      final startJ = await _get(
          Uri.parse('https://www.googleapis.com/drive/v3/changes/startPageToken'), token);
      final changeToken = startJ['startPageToken'] as String?;
      final items = <String, DriveItem>{};
      String? page;
      do {
        final j = await _get(
          Uri.https('www.googleapis.com', '/drive/v3/files', {
            'pageSize': '1000',
            'spaces': 'drive',
            'corpora': 'user',
            'fields': 'nextPageToken,files($fileFields)',
            if (query != null) 'q': query!,
            if (page != null) 'pageToken': page,
          }),
          token,
        );
        for (final f in (j['files'] as List? ?? [])) {
          final it = DriveItem.fromApi(f as Map<String, dynamic>);
          items[it.id] = it;
        }
        page = j['nextPageToken'] as String?;
        progress[email] = items.length;
        onProgress();
      } while (page != null);
      final idx = AccountIndex(
          email: email,
          rootId: rootId,
          date: DateTime.now(),
          items: items,
          changeToken: changeToken);
      await storage.saveIndex('$keyPrefix$email', idx.toJson());
      loaded[email] = idx;
      return idx;
    } finally {
      progress.remove(email);
      onProgress();
    }
  }

  /// Actualiza el índice leyendo solo los cambios desde la última vez.
  /// Devuelve cuántos elementos cambiaron, o null si hace falta reindexar completo.
  Future<int?> update(String email, Future<String> Function() token, void Function() onProgress) async {
    final idx = loaded[email];
    if (idx == null || idx.changeToken == null) return null;
    progress[email] = 0;
    onProgress();
    try {
      var page = idx.changeToken!;
      var changed = 0;
      while (true) {
        final j = await _get(
          Uri.https('www.googleapis.com', '/drive/v3/changes', {
            'pageToken': page,
            'pageSize': '1000',
            'spaces': 'drive',
            'includeRemoved': 'true',
            'fields': 'nextPageToken,newStartPageToken,'
                'changes(fileId,removed,file($fileFields))',
          }),
          token,
        );
        for (final c in (j['changes'] as List? ?? [])) {
          final m = c as Map<String, dynamic>;
          final id = m['fileId'] as String?;
          if (id == null) continue;
          final f = m['file'] as Map<String, dynamic>?;
          if (m['removed'] == true || f == null) {
            idx.items.remove(id);
          } else {
            final it = DriveItem.fromApi(f);
            if (keep != null && !keep!(it)) {
              idx.items.remove(id);
            } else {
              idx.items[id] = it;
            }
          }
          changed++;
        }
        progress[email] = changed;
        onProgress();
        final next = j['nextPageToken'] as String?;
        if (next != null) {
          page = next;
          continue;
        }
        idx.changeToken = (j['newStartPageToken'] as String?) ?? page;
        break;
      }
      idx.date = DateTime.now();
      if (changed > 0) idx.rebuild();
      await storage.saveIndex('$keyPrefix$email', idx.toJson());
      return changed;
    } on Exception {
      return null;
    } finally {
      progress.remove(email);
      onProgress();
    }
  }

  static Future<Map<String, dynamic>> _get(Uri url, Future<String> Function() token) async {
    for (var attempt = 0;; attempt++) {
      final res = await http.get(url, headers: {'Authorization': 'Bearer ${await token()}'});
      if (res.statusCode == 200) return jsonDecode(res.body) as Map<String, dynamic>;
      final retry = res.statusCode == 429 || res.statusCode >= 500 || res.statusCode == 403;
      if (!retry || attempt >= 4) {
        throw Exception('Drive respondió ${res.statusCode}: ${res.body}');
      }
      await Future<void>.delayed(Duration(seconds: 2 << attempt));
    }
  }
}

/// Minúsculas y sin acentos, para buscar.
String normalize(String s) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}
