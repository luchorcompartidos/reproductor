import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Android y Windows: carátulas como archivos en la carpeta de la app.
const bool coversPersist = true;

String? _dirPath;

Future<String> _dir() async {
  final cached = _dirPath;
  if (cached != null) return cached;
  final d = Directory('${(await getApplicationSupportDirectory()).path}/covers');
  if (!await d.exists()) await d.create(recursive: true);
  return _dirPath = d.path;
}

String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

Future<void> initCovers() async => _dir();

Future<void> saveCover(String id, Uint8List bytes) async {
  final f = File('${await _dir()}/${_safe(id)}');
  await f.writeAsBytes(bytes, flush: true);
}

Future<Uint8List?> loadCover(String id) async {
  final f = File('${await _dir()}/${_safe(id)}');
  if (!await f.exists()) return null;
  return f.readAsBytes();
}

/// Para la notificación y la pantalla de bloqueo (Android).
Uri? coverUri(String id) {
  final d = _dirPath;
  if (d == null) return null;
  final f = File('$d/${_safe(id)}');
  return f.existsSync() ? Uri.file(f.path) : null;
}
