import 'dart:io';

/// Extensión del instalador que corresponde a este equipo.
String installerExtension() => Platform.isAndroid ? '.apk' : '.exe';

/// Solo aplica a la web.
void reloadPage() {}

/// Solo la web reproduce desde un archivo descargado en memoria.
String blobUrl(List<int> bytes, String mime) =>
    throw UnsupportedError('Solo disponible en la web');

void revokeBlobUrl(String url) {}
