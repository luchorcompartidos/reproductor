import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

String installerExtension() => '';

void reloadPage() => web.window.location.reload();

/// Dirección local (blob:) para reproducir una canción ya descargada.
String blobUrl(List<int> bytes, String mime) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final blob = web.Blob(<JSAny>[data.toJS].toJS, web.BlobPropertyBag(type: mime));
  return web.URL.createObjectURL(blob);
}

void revokeBlobUrl(String url) => web.URL.revokeObjectURL(url);
