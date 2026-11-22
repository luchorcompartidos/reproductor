import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Datos de una canción leídos del propio archivo (ID3, FLAC, MP4, Ogg).
class TagInfo {
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? year;
  final int? track;
  final int? disc;
  final bool cover;
  final int modified; // del archivo en Drive, para saber si hay que releer

  const TagInfo({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.year,
    this.track,
    this.disc,
    this.cover = false,
    required this.modified,
  });

  Map<String, dynamic> toJson() => {
        if (title != null) 't': title,
        if (artist != null) 'a': artist,
        if (album != null) 'l': album,
        if (albumArtist != null) 'aa': albumArtist,
        if (year != null) 'y': year,
        if (track != null) 'n': track,
        if (disc != null) 'd': disc,
        if (cover) 'c': 1,
        'm': modified,
      };

  factory TagInfo.fromJson(Map<String, dynamic> j) => TagInfo(
        title: j['t'] as String?,
        artist: j['a'] as String?,
        album: j['l'] as String?,
        albumArtist: j['aa'] as String?,
        year: j['y'] as String?,
        track: (j['n'] as num?)?.toInt(),
        disc: (j['d'] as num?)?.toInt(),
        cover: j['c'] == 1,
        modified: (j['m'] as num?)?.toInt() ?? 0,
      );
}

class TagResult {
  final TagInfo info;
  final Uint8List? cover;
  TagResult(this.info, this.cover);
}

/// Pide los bytes [start, end] (inclusive) del archivo.
typedef RangeFetch = Future<Uint8List> Function(int start, int end);

const _maxBytes = 6 * 1024 * 1024; // nunca se leen más de 6 MB por archivo

/// Lee el comienzo (y si hace falta el final) del archivo, de a pedazos.
class _Reader {
  final RangeFetch fetch;
  final int size;
  Uint8List data = Uint8List(0);

  _Reader(this.fetch, this.size);

  /// Asegura tener los bytes hasta [end] (exclusivo) desde el comienzo.
  Future<bool> ensure(int end) async {
    if (end <= data.length) return true;
    if (end > _maxBytes || (size > 0 && end > size)) return false;
    final want = min(max(end, data.length + 128 * 1024), size > 0 ? size : end + 128 * 1024);
    final more = await fetch(data.length, min(want, _maxBytes) - 1);
    if (more.isEmpty) return false;
    final b = BytesBuilder(copy: false)
      ..add(data)
      ..add(more);
    data = b.toBytes();
    return end <= data.length;
  }
}

int _be32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _le32(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
int _syncsafe(Uint8List b, int o) =>
    ((b[o] & 0x7f) << 21) | ((b[o + 1] & 0x7f) << 14) | ((b[o + 2] & 0x7f) << 7) | (b[o + 3] & 0x7f);
String _ascii(Uint8List b, int o, int n) =>
    String.fromCharCodes(b.sublist(o, min(o + n, b.length)));

String? _clean(String? s) {
  if (s == null) return null;
  final t = s.replaceAll('\u0000', ' ').trim();
  return t.isEmpty ? null : t;
}

int? _num(String? s) {
  if (s == null) return null;
  final m = RegExp(r'\d+').firstMatch(s);
  return m == null ? null : int.tryParse(m[0]!);
}

String? _year(String? s) {
  if (s == null) return null;
  final m = RegExp(r'\d{4}').firstMatch(s);
  return m?[0];
}

/// Lee etiquetas y carátula. Devuelve null si el formato no se reconoce.
Future<TagResult?> readTags(RangeFetch fetch, int size, String name, int modified) async {
  final r = _Reader(fetch, size);
  if (!await r.ensure(min(64 * 1024, size > 0 ? size : 64 * 1024))) {
    if (r.data.length < 12) return null;
  }
  final b = r.data;
  if (b.length >= 10 && _ascii(b, 0, 3) == 'ID3') {
    final id3 = await _readId3(r, modified);
    // FLAC con ID3 adelante: se prefiere lo de FLAC si existe.
    return id3;
  }
  if (_ascii(b, 0, 4) == 'fLaC') return _readFlac(r, 4, modified);
  if (_ascii(b, 0, 4) == 'OggS') return _readOgg(r, modified);
  if (b.length >= 12 && _ascii(b, 4, 4) == 'ftyp') return _readMp4(fetch, size, modified);
  if (name.toLowerCase().endsWith('.mp3') && size > 128) {
    return _readId3v1(fetch, size, modified);
  }
  return null;
}

// ---------------------------------------------------------------- ID3v2 / ID3v1

Uint8List _unsync(Uint8List b) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < b.length; i++) {
    out.addByte(b[i]);
    if (b[i] == 0xff && i + 1 < b.length && b[i + 1] == 0x00) i++;
  }
  return out.toBytes();
}

String _decodeText(int enc, Uint8List b) {
  if (b.isEmpty) return '';
  switch (enc) {
    case 0:
      return String.fromCharCodes(b);
    case 1:
    case 2:
      var bigEndian = enc == 2;
      var o = 0;
      if (b.length >= 2 && b[0] == 0xff && b[1] == 0xfe) {
        bigEndian = false;
        o = 2;
      } else if (b.length >= 2 && b[0] == 0xfe && b[1] == 0xff) {
        bigEndian = true;
        o = 2;
      }
      final units = <int>[];
      for (; o + 1 < b.length; o += 2) {
        final u = bigEndian ? (b[o] << 8) | b[o + 1] : b[o] | (b[o + 1] << 8);
        units.add(u);
      }
      return String.fromCharCodes(units);
    default:
      return utf8.decode(b, allowMalformed: true);
  }
}

/// Primer valor de un texto ID3 (en v2.4 puede haber varios separados por nulos).
String? _firstValue(int enc, Uint8List b) {
  final s = _decodeText(enc, b);
  final i = s.indexOf('\u0000');
  return _clean(i >= 0 ? s.substring(0, i) : s);
}

/// Fin de un texto terminado en nulo (1 o 2 bytes según la codificación).
int _textEnd(Uint8List b, int o, int enc) {
  if (enc == 1 || enc == 2) {
    for (var i = o; i + 1 < b.length; i += 2) {
      if (b[i] == 0 && b[i + 1] == 0) return i;
    }
    return b.length;
  }
  for (var i = o; i < b.length; i++) {
    if (b[i] == 0) return i;
  }
  return b.length;
}

Future<TagResult?> _readId3(_Reader r, int modified) async {
  final h = r.data;
  final ver = h[3];
  final flags = h[5];
  final size = _syncsafe(h, 6);
  final total = 10 + size;
  if (!await r.ensure(min(total, _maxBytes))) {
    if (r.data.length <= 10) return null;
  }
  var tag = r.data.sublist(10, min(total, r.data.length));
  if (ver <= 3 && (flags & 0x80) != 0) tag = _unsync(tag);
  var o = 0;
  if ((flags & 0x40) != 0 && tag.length >= 4) {
    o = ver >= 4 ? _syncsafe(tag, 0) : _be32(tag, 0) + 4;
  }
  final text = <String, String>{};
  Uint8List? cover;
  var coverType = -1;
  final idLen = ver == 2 ? 3 : 4;
  final headLen = ver == 2 ? 6 : 10;
  while (o + headLen <= tag.length) {
    final id = _ascii(tag, o, idLen);
    if (id.codeUnits.first == 0) break;
    int fsize;
    var fflags = 0;
    if (ver == 2) {
      fsize = (tag[o + 3] << 16) | (tag[o + 4] << 8) | tag[o + 5];
    } else {
      fsize = ver >= 4 ? _syncsafe(tag, o + 4) : _be32(tag, o + 4);
      fflags = (tag[o + 8] << 8) | tag[o + 9];
    }
    final start = o + headLen;
    final end = start + fsize;
    if (fsize <= 0 || end > tag.length) break;
    var f = tag.sublist(start, end);
    o = end;
    if (ver >= 4) {
      if ((fflags & 0x0002) != 0) f = _unsync(f);
      if ((fflags & 0x0001) != 0 && f.length > 4) f = f.sublist(4);
    }
    if ((fflags & 0x000C) != 0 && ver >= 4) continue; // comprimido o cifrado
    if (ver == 3 && (fflags & 0x00C0) != 0) continue;
    if (f.isEmpty) continue;

    if (id == 'APIC' || id == 'PIC') {
      final enc = f[0];
      var p = 1;
      if (id == 'APIC') {
        p = _textEnd(f, 1, 0) + 1; // tipo MIME (latin1)
      } else {
        p = 4; // formato de 3 letras
      }
      if (p >= f.length) continue;
      final picType = f[p];
      p++;
      final descEnd = _textEnd(f, p, enc);
      p = descEnd + ((enc == 1 || enc == 2) ? 2 : 1);
      if (p >= f.length) continue;
      // Se prefiere la tapa (tipo 3); si no hay, la primera imagen.
      if (cover == null || (picType == 3 && coverType != 3)) {
        cover = f.sublist(p);
        coverType = picType;
      }
      continue;
    }
    if (id.startsWith('T')) {
      final v = _firstValue(f[0], f.sublist(1));
      if (v != null) text[id] = v;
    }
  }
  String? t(String a, String b) => text[a] ?? text[b];
  final info = TagInfo(
    title: t('TIT2', 'TT2'),
    artist: t('TPE1', 'TP1'),
    album: t('TALB', 'TAL'),
    albumArtist: t('TPE2', 'TP2'),
    year: _year(text['TDRC'] ?? text['TYER'] ?? text['TYE']),
    track: _num(t('TRCK', 'TRK')),
    disc: _num(t('TPOS', 'TPA')),
    cover: cover != null,
    modified: modified,
  );
  return TagResult(info, cover);
}

Future<TagResult?> _readId3v1(RangeFetch fetch, int size, int modified) async {
  final b = await fetch(size - 128, size - 1);
  if (b.length < 128 || _ascii(b, 0, 3) != 'TAG') return null;
  String? s(int o, int n) => _clean(String.fromCharCodes(b.sublist(o, o + n)));
  final track = (b[125] == 0 && b[126] != 0) ? b[126] : null;
  return TagResult(
    TagInfo(
      title: s(3, 30),
      artist: s(33, 30),
      album: s(63, 30),
      year: _year(s(93, 4)),
      track: track,
      modified: modified,
    ),
    null,
  );
}

// ---------------------------------------------------------------- FLAC / Vorbis

class _Vorbis {
  final Map<String, String> v = {};
  Uint8List? cover;
  int coverType = -1;

  void parse(Uint8List b, int o) {
    if (o + 4 > b.length) return;
    final vendor = _le32(b, o);
    o += 4 + vendor;
    if (o + 4 > b.length) return;
    final count = _le32(b, o);
    o += 4;
    for (var i = 0; i < count && o + 4 <= b.length; i++) {
      final len = _le32(b, o);
      o += 4;
      if (len < 0 || o + len > b.length) break;
      final s = utf8.decode(b.sublist(o, o + len), allowMalformed: true);
      o += len;
      final eq = s.indexOf('=');
      if (eq <= 0) continue;
      final key = s.substring(0, eq).toUpperCase();
      final value = s.substring(eq + 1);
      if (key == 'METADATA_BLOCK_PICTURE') {
        try {
          picture(base64.decode(value.trim()), 0);
        } catch (_) {}
        continue;
      }
      v.putIfAbsent(key, () => value);
    }
  }

  /// Bloque PICTURE de FLAC (también va en base64 dentro de Ogg).
  void picture(Uint8List b, int o) {
    if (o + 32 > b.length) return;
    final type = _be32(b, o);
    o += 4;
    final mimeLen = _be32(b, o);
    o += 4 + mimeLen;
    if (o + 4 > b.length) return;
    final descLen = _be32(b, o);
    o += 4 + descLen + 16;
    if (o + 4 > b.length) return;
    final len = _be32(b, o);
    o += 4;
    if (len <= 0 || o + len > b.length) return;
    if (cover == null || (type == 3 && coverType != 3)) {
      cover = b.sublist(o, o + len);
      coverType = type;
    }
  }

  TagResult result(int modified) {
    String? g(String k) => _clean(v[k]);
    return TagResult(
      TagInfo(
        title: g('TITLE'),
        artist: g('ARTIST'),
        album: g('ALBUM'),
        albumArtist: g('ALBUMARTIST') ?? g('ALBUM ARTIST'),
        year: _year(g('DATE') ?? g('YEAR')),
        track: _num(g('TRACKNUMBER')),
        disc: _num(g('DISCNUMBER')),
        cover: cover != null,
        modified: modified,
      ),
      cover,
    );
  }
}

Future<TagResult?> _readFlac(_Reader r, int start, int modified) async {
  final vb = _Vorbis();
  var o = start;
  for (var guard = 0; guard < 64; guard++) {
    if (!await r.ensure(o + 4)) break;
    final h = r.data[o];
    final last = (h & 0x80) != 0;
    final type = h & 0x7f;
    final len = (r.data[o + 1] << 16) | (r.data[o + 2] << 8) | r.data[o + 3];
    o += 4;
    if (type == 4 || type == 6) {
      if (!await r.ensure(o + len)) break;
      final block = r.data.sublist(o, o + len);
      if (type == 4) vb.parse(block, 0);
      if (type == 6) vb.picture(block, 0);
    }
    o += len;
    if (last) break;
  }
  return vb.result(modified);
}

Future<TagResult?> _readOgg(_Reader r, int modified) async {
  // Junta el contenido de las páginas hasta encontrar los comentarios.
  final payload = BytesBuilder(copy: false);
  var o = 0;
  for (var page = 0; page < 200; page++) {
    if (!await r.ensure(o + 27)) break;
    final b = r.data;
    if (_ascii(b, o, 4) != 'OggS') break;
    final segs = b[o + 26];
    if (!await r.ensure(o + 27 + segs)) break;
    var len = 0;
    for (var i = 0; i < segs; i++) {
      len += r.data[o + 27 + i];
    }
    final dataStart = o + 27 + segs;
    if (!await r.ensure(dataStart + len)) break;
    if (page > 0) payload.add(r.data.sublist(dataStart, dataStart + len));
    o = dataStart + len;
    final p = payload.toBytes();
    // Se corta cuando el paquete de comentarios ya está completo (aprox.).
    final at = _commentStart(p);
    if (at >= 0 && _vorbisComplete(p, at)) break;
    if (payload.length > _maxBytes) break;
  }
  final p = payload.toBytes();
  final at = _commentStart(p);
  if (at < 0) return null;
  final vb = _Vorbis()..parse(p, at);
  return vb.result(modified);
}

int _commentStart(Uint8List p) {
  for (var i = 0; i + 8 <= p.length && i < 64; i++) {
    if (_ascii(p, i, 8) == 'OpusTags') return i + 8;
    if (p[i] == 3 && _ascii(p, i + 1, 6) == 'vorbis') return i + 7;
  }
  return -1;
}

bool _vorbisComplete(Uint8List b, int o) {
  if (o + 4 > b.length) return false;
  o += 4 + _le32(b, o);
  if (o + 4 > b.length) return false;
  final count = _le32(b, o);
  o += 4;
  for (var i = 0; i < count; i++) {
    if (o + 4 > b.length) return false;
    o += 4 + _le32(b, o);
    if (o > b.length) return false;
  }
  return true;
}

// ---------------------------------------------------------------- MP4 / M4A

Future<TagResult?> _readMp4(RangeFetch fetch, int size, int modified) async {
  // Busca el átomo 'moov' recorriendo los de primer nivel (puede estar al final).
  var o = 0;
  for (var guard = 0; guard < 64 && (size <= 0 || o + 8 <= size); guard++) {
    final h = await fetch(o, o + 15);
    if (h.length < 8) return null;
    var len = _be32(h, 0);
    final type = _ascii(h, 4, 4);
    var head = 8;
    if (len == 1 && h.length >= 16) {
      len = (_be32(h, 8) << 32) | _be32(h, 12);
      head = 16;
    } else if (len == 0) {
      len = size - o;
    }
    if (len < head) return null;
    if (type == 'moov') {
      if (len > _maxBytes) return null;
      final moov = await fetch(o + head, o + len - 1);
      return _parseMoov(moov, modified);
    }
    o += len;
  }
  return null;
}

TagResult? _parseMoov(Uint8List b, int modified) {
  final ilst = _findPath(b, 0, b.length, ['udta', 'meta', 'ilst']) ??
      _findPath(b, 0, b.length, ['meta', 'ilst']);
  if (ilst == null) return null;
  final values = <String, String>{};
  Uint8List? cover;
  int? track, disc;
  var o = ilst.$1;
  while (o + 8 <= ilst.$2) {
    final len = _be32(b, o);
    if (len < 8 || o + len > ilst.$2) break;
    final key = String.fromCharCodes(b.sublist(o + 4, o + 8));
    final data = _child(b, o + 8, o + len, 'data');
    if (data != null && data.$2 - data.$1 >= 8) {
      final payloadStart = data.$1 + 8; // tipo (4) + idioma (4)
      final payload = b.sublist(payloadStart, data.$2);
      switch (key) {
        case '©nam':
        case '©ART':
        case '©alb':
        case 'aART':
        case '©day':
          values[key] = utf8.decode(payload, allowMalformed: true);
        case 'trkn':
          if (payload.length >= 4) track = (payload[2] << 8) | payload[3];
        case 'disk':
          if (payload.length >= 4) disc = (payload[2] << 8) | payload[3];
        case 'covr':
          cover ??= payload;
      }
    }
    o += len;
  }
  return TagResult(
    TagInfo(
      title: _clean(values['©nam']),
      artist: _clean(values['©ART']),
      album: _clean(values['©alb']),
      albumArtist: _clean(values['aART']),
      year: _year(values['©day']),
      track: (track ?? 0) > 0 ? track : null,
      disc: (disc ?? 0) > 0 ? disc : null,
      cover: cover != null,
      modified: modified,
    ),
    cover,
  );
}

/// Contenido (inicio, fin) del hijo [type] dentro de [start, end).
(int, int)? _child(Uint8List b, int start, int end, String type) {
  var o = start;
  while (o + 8 <= end) {
    final len = _be32(b, o);
    if (len < 8 || o + len > end) return null;
    if (String.fromCharCodes(b.sublist(o + 4, o + 8)) == type) {
      var s = o + 8;
      if (type == 'meta') s += 4; // 'meta' es un "full box": versión y flags
      return (s, o + len);
    }
    o += len;
  }
  return null;
}

(int, int)? _findPath(Uint8List b, int start, int end, List<String> path) {
  (int, int)? cur = (start, end);
  for (final p in path) {
    cur = _child(b, cur!.$1, cur.$2, p);
    if (cur == null) return null;
  }
  return cur;
}
