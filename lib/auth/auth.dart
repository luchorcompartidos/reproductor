// Windows y Android usan el flujo de escritorio (navegador + 127.0.0.1).
// La web usa el flujo de cliente web (redirección, acceso de ~1 hora).
export 'auth_result.dart';
export 'auth_io.dart' if (dart.library.js_interop) 'auth_web.dart';
