import 'dart:typed_data';

/// Web: carátulas solo en memoria mientras la página está abierta.
const bool coversPersist = false;

final _mem = <String, Uint8List>{};

Future<void> initCovers() async {}

Future<void> saveCover(String id, Uint8List bytes) async {
  if (_mem.length > 150) _mem.remove(_mem.keys.first);
  _mem[id] = bytes;
}

Future<Uint8List?> loadCover(String id) async => _mem[id];

Uri? coverUri(String id) => null;
