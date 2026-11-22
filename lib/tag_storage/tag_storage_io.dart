import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Android y Windows: etiquetas guardadas (comprimidas) en la carpeta de la app.
Future<File> _file(String key) async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/tags');
  if (!await dir.exists()) await dir.create(recursive: true);
  final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return File('${dir.path}/$safe.json.gz');
}

Future<void> saveTags(String key, String json) async {
  final f = await _file(key);
  await f.writeAsBytes(gzip.encode(utf8.encode(json)), flush: true);
}

Future<String?> loadTags(String key) async {
  final f = await _file(key);
  if (!await f.exists()) return null;
  try {
    return utf8.decode(gzip.decode(await f.readAsBytes()));
  } catch (_) {
    return null;
  }
}

Future<void> deleteTags(String key) async {
  final f = await _file(key);
  if (await f.exists()) await f.delete();
}
