/// Valores que llegan en la compilación (GitHub Actions → --dart-define).
/// Mismo proyecto de Google Cloud y mismos IDs de cliente que Multi G-DRIVE.
/// Los IDs de cliente no son secretos y quedan acá; los secretos son Secrets del repo.
class Config {
  static const appName = 'Reproductor';
  static const webClientId = String.fromEnvironment('WEB_CLIENT_ID',
      defaultValue: '414410842048-ac53pi41embhn1k8e004dnr99m20fqao.apps.googleusercontent.com');
  static const desktopClientId = String.fromEnvironment('DESKTOP_CLIENT_ID',
      defaultValue: '414410842048-2j5f3pa1gb4ajf4v5g6965pjekt2qk5a.apps.googleusercontent.com');
  static const desktopClientSecret = String.fromEnvironment('DESKTOP_CLIENT_SECRET');
  static const webClientSecret = String.fromEnvironment('WEB_CLIENT_SECRET');
  static const webRedirect = 'https://luchorcompartidos.github.io/reproductor/';
  static const androidScheme = 'com.luchorcompartidos.reproductor';
  static const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
  static const repoSlug = 'luchorcompartidos/reproductor';
  static const repoUrl = 'https://github.com/$repoSlug';

  /// Música en solo lectura. Además, acceso únicamente a los archivos que crea la app:
  /// carpeta oculta (drive.appdata) y copia visible (drive.file) para las listas de E5.
  /// Se piden desde ahora para no tener que volver a conectar las cuentas más adelante.
  static const scope = 'https://www.googleapis.com/auth/drive.readonly '
      'https://www.googleapis.com/auth/drive.appdata '
      'https://www.googleapis.com/auth/drive.file';
}
