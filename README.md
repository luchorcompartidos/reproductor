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

## E3 · v0.0.7 — Segundo plano (Android)
- Sigue sonando con la pantalla apagada o en otra app (servicio de reproducción).
- Controles en la notificación, la pantalla de bloqueo, auriculares y Bluetooth.
- Pausa sola con llamadas o al desconectar los auriculares.
- Si el acceso a Drive vence (pausa larga o corte), vuelve a cargar desde el mismo punto.

## E4 · v0.0.8 — Artista y álbum
- Lee título, artista, álbum, año, número de pista y carátula del propio archivo
  (MP3 con ID3, FLAC, M4A/AAC, OGG/Opus), pidiendo solo el comienzo de cada archivo.
- Sin etiquetas: la carpeta es el álbum y la carpeta de arriba, el artista.
- Vistas Artistas y Álbumes; carátulas en listas, reproductor y pantalla de bloqueo (Android).
- Web: etiquetas guardadas en el navegador; carátulas solo mientras la página está abierta.

## E5 · v0.0.9 — Listas
- Pestaña Listas: crear, renombrar, borrar, ordenar (arrastrando) y quitar canciones.
- "Agregar a lista" desde una canción, un álbum, un artista, una carpeta o lo que está sonando.
- Se guardan en el equipo y se sincronizan con la cuenta principal: carpeta oculta de la app
  + copia visible "Reproductor - listas (respaldo).json" en Mi unidad. Gana la versión más nueva de cada lista.
- La cuenta principal se elige en Cuentas → ⋮ → "Guardar las listas en esta cuenta".

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
