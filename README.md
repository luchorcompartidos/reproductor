# Reproductor

Música de todas tus cuentas de Google Drive, en una sola app.
Un solo código Flutter → **APK** (Android 7.0 o superior), **.exe** (Windows) y **web** en GitHub Pages.
Basado en el núcleo de [multigdrive](https://github.com/luchorcompartidos/multigdrive) (ver su `NUCLEO.md`).

## E0 · v0.0.1 — Base
- Conectar varias cuentas de Google (Android, web y Windows), con alias y color.
- Permisos: música en **solo lectura**; la app solo puede escribir sus propios archivos (listas, en E5).
- "Probar acceso a la música": busca audios en cada cuenta.
- Número de versión en el encabezado, Changelog y aviso de versión nueva.

## E1 · v0.0.5 — Biblioteca
- Lee solo carpetas y audio de todas las cuentas (Mi unidad y compartidos conmigo).
- Vista por carpetas (cuenta → carpeta → canciones) y lista de todas las canciones.
- Búsqueda por canción o carpeta, sin importar acentos.
- Se actualiza leyendo solo los cambios (en Android y Windows el índice queda guardado).

## E2 · v0.0.6 — Reproducir
- Toca una canción para escucharla; "Todo" y "Aleatorio" en la lista y en cada carpeta (con subcarpetas).
- Barra de reproducción abajo y pantalla completa con avance, anterior/siguiente, aleatorio, repetir y cola.
- Android y Windows: streaming desde Drive. Web: descarga la canción completa y después suena.

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
