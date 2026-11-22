import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Android y Windows: las canciones descargadas quedan en la carpeta de la app.
const bool offlineSupported = true;

class DownloadCancelled implements Exception {}

class DownloadHttpError implements Exception {
  final int status;
  DownloadHttpError(this.status);
  @override
  String toString() => 'Drive respondió $status';
}

Future<String> pathFor(String key, String ext) async {
  final dir = Directory('${(await getApplicationSupportDirectory()).path}/offline');
  if (!await dir.exists()) await dir.create(recursive: true);
  final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final e = ext.isEmpty ? '' : '.${ext.toLowerCase()}';
  return '${dir.path}${Platform.pathSeparator}$safe$e';
}

Future<bool> fileExists(String path) => File(path).exists();

Future<void> deleteFile(String path) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
}

/// Descarga a un archivo temporal y lo renombra al terminar.
Future<int> download(
  String path,
  Uri url,
  Map<String, String> headers,
  void Function(int received, int? total) onProgress,
  bool Function() cancelled,
) async {
  final client = http.Client();
  final tmp = File('$path.part');
  try {
    final req = http.Request('GET', url)..headers.addAll(headers);
    final res = await client.send(req);
    if (res.statusCode != 200) throw DownloadHttpError(res.statusCode);
    final sink = tmp.openWrite();
    var got = 0;
    try {
      await for (final chunk in res.stream) {
        if (cancelled()) throw DownloadCancelled();
        sink.add(chunk);
        got += chunk.length;
        onProgress(got, res.contentLength);
      }
    } finally {
      await sink.close();
    }
    final f = File(path);
    if (await f.exists()) await f.delete();
    await tmp.rename(path);
    return got;
  } catch (_) {
    if (await tmp.exists()) await tmp.delete();
    rethrow;
  } finally {
    client.close();
  }
}
