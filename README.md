# Reproductor

Música de todas tus cuentas de Google Drive, en una sola app.
Un solo código Flutter → **APK** (Android 7.0 o superior), **.exe** (Windows) y **web** en GitHub Pages.
Basado en el núcleo de [multigdrive](https://github.com/luchorcompartidos/multigdrive) (ver su `NUCLEO.md`).

## E0 · v0.0.1 — Base
- Conectar varias cuentas de Google (Android, web y Windows), con alias y color.
- Permisos: música en **solo lectura**; la app solo puede escribir sus propios archivos (listas, en E5).
- "Probar acceso a la música": busca audios en cada cuenta.
- Número de versión en el encabezado, Changelog y aviso de versión nueva.

## Plan
E1 Biblioteca · E2 Reproducir · E3 Segundo plano · E4 Artista y álbum · E5 Listas · E6 Sin conexión (MVP).

## Configuración (una vez)
1. Google Cloud (mismo proyecto que Multi G-DRIVE) → cliente **Web** → *URIs de redireccionamiento autorizados*:
   agregar `https://luchorcompartidos.github.io/reproductor/`.
2. Secrets del repo: `WEB_CLIENT_SECRET`, `DESKTOP_CLIENT_SECRET`, `ANDROID_KEYSTORE_BASE64`,
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`.
3. Después del primer build: *Settings → Pages* → **Deploy from a branch** → `gh-pages` / root.

## Versiones
Commit con `[patch]`, `[minor]` o `[major]` → Release con APK y .exe.
Sin marca → web publicada + APK/.exe de prueba en *Artifacts* (sin Release).

## Descargas
- Web: https://luchorcompartidos.github.io/reproductor/
- APK e instalador de Windows: sección *Releases*.
