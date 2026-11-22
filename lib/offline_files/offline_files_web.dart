/// Web: no se guardan canciones (el navegador no tiene dónde dejarlas de forma segura).
const bool offlineSupported = false;

class DownloadCancelled implements Exception {}

class DownloadHttpError implements Exception {
  final int status;
  DownloadHttpError(this.status);
}

Future<String> pathFor(String key, String ext) async => throw UnsupportedError('web');

Future<bool> fileExists(String path) async => false;

Future<void> deleteFile(String path) async {}

Future<int> download(
  String path,
  Uri url,
  Map<String, String> headers,
  void Function(int received, int? total) onProgress,
  bool Function() cancelled,
) async =>
    throw UnsupportedError('web');
