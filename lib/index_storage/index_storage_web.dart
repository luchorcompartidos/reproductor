/// Web (limitada): el índice vive solo mientras la página está abierta.
const bool indexPersists = false;

final _mem = <String, String>{};

Future<void> saveIndex(String key, String json) async => _mem[key] = json;

Future<String?> loadIndex(String key) async => _mem[key];

Future<void> deleteIndex(String key) async => _mem.remove(key);
