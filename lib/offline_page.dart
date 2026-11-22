import 'package:flutter/material.dart';

import 'accounts.dart';
import 'library.dart';
import 'library_page.dart';
import 'offline.dart';
import 'player.dart';

/// Descarga las que faltan; si ya están todas, ofrece quitarlas.
Future<void> downloadAll(BuildContext context, Library library, List<Track> tracks) async {
  final off = library.offline;
  if (off == null || !off.supported || tracks.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final missing = tracks.where((t) => !off.isDownloaded(t)).toList();
  if (missing.isEmpty) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitar descargas'),
        content: Text('Ya están descargadas (${tracks.length}). '
            '¿Las quitás del equipo? Siguen en Drive.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quitar')),
        ],
      ),
    );
    if (ok == true) {
      await off.removeTracks(tracks);
      messenger.showSnackBar(SnackBar(content: Text('Descargas quitadas: ${tracks.length}')));
    }
    return;
  }
  final size = missing.fold<int>(0, (s, t) => s + t.item.size);
  final n = off.enqueue(missing);
  messenger.showSnackBar(SnackBar(
      content: Text(n == 0
          ? 'Ya se están descargando'
          : 'Descargando $n ${n == 1 ? 'canción' : 'canciones'} (${formatBytes(size)})')));
}

/// Botón "descargar todo" para las barras de arriba (solo Android y Windows).
Widget? downloadAllButton(BuildContext context, Library library, List<Track> tracks) {
  final off = library.offline;
  if (off == null || !off.supported) return null;
  final all = tracks.isNotEmpty && tracks.every(off.isDownloaded);
  return IconButton(
    tooltip: all ? 'Descargadas (tocá para quitarlas)' : 'Descargar para escuchar sin conexión',
    icon: Icon(all ? Icons.download_done : Icons.download_for_offline_outlined),
    onPressed: tracks.isEmpty ? null : () => downloadAll(context, library, tracks),
  );
}

/// Marca chica: descargada o descargándose.
class OfflineBadge extends StatelessWidget {
  final Library library;
  final Track track;
  const OfflineBadge({super.key, required this.library, required this.track});

  @override
  Widget build(BuildContext context) {
    final off = library.offline;
    if (off == null || !off.supported) return const SizedBox.shrink();
    final p = off.progressOf(track);
    if (p != null) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, value: p < 0 ? null : p),
      );
    }
    if (off.isDownloaded(track)) {
      return Icon(Icons.offline_pin, size: 18, color: Theme.of(context).colorScheme.primary);
    }
    return const SizedBox.shrink();
  }
}

/// Pantalla Descargas: espacio usado, cola, reproducir y quitar.
class DownloadsPage extends StatelessWidget {
  final Library library;
  final PlayerController player;
  const DownloadsPage({super.key, required this.library, required this.player});

  @override
  Widget build(BuildContext context) {
    final off = library.offline!;
    return AnimatedBuilder(
      animation: Listenable.merge([library, off]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final list = off.entries.values.toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        final tracks = [for (final e in list) library.trackByKey(e.email, e.id)];
        final playable = tracks.whereType<Track>().toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Descargas'),
            actions: [
              IconButton(
                tooltip: 'Reproducir todas',
                icon: const Icon(Icons.play_arrow),
                onPressed: playable.isEmpty ? null : () => player.playList(playable, 0),
              ),
              IconButton(
                tooltip: 'Aleatorio',
                icon: const Icon(Icons.shuffle),
                onPressed: playable.isEmpty ? null : () => player.playShuffled(playable),
              ),
              IconButton(
                tooltip: 'Quitar todas las descargas',
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: list.isEmpty
                    ? null
                    : () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Quitar todas las descargas'),
                            content: Text('Se liberan ${formatBytes(off.totalBytes)} del equipo. '
                                'Las canciones siguen en Drive.'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancelar')),
                              FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Quitar')),
                            ],
                          ),
                        );
                        if (ok == true) await off.removeAll();
                      },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              ListTile(
                leading: const Icon(Icons.sd_storage_outlined),
                title: Text('${list.length} ${list.length == 1 ? 'canción' : 'canciones'} · '
                    '${formatBytes(off.totalBytes)}'),
                subtitle: const Text('Suenan desde el equipo, aunque no haya conexión.'),
              ),
              if (off.busy)
                ListTile(
                  leading: const SizedBox(
                      width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                  title: Text('Descargando… faltan ${off.pending}'),
                  trailing: TextButton(onPressed: off.cancelAll, child: const Text('Cancelar')),
                ),
              if (off.lastError != null)
                ListTile(
                  leading: Icon(Icons.error_outline, color: scheme.error),
                  title: Text(off.failed > 1
                      ? 'No se pudieron descargar ${off.failed} canciones'
                      : 'No se pudo descargar una canción'),
                  subtitle: Text(off.lastError!),
                ),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Todavía no hay descargas. Usá el botón de descarga en un álbum, artista, '
                    'carpeta o lista, o "Descargar" en el detalle de una canción.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (var i = 0; i < list.length; i++)
                ListTile(
                  leading: CoverImage(library: library, track: tracks[i], size: 40),
                  title: Text(tracks[i]?.title ?? list[i].name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      tracks[i] == null
                          ? 'Ya no está en la biblioteca · ${formatBytes(list[i].size)}'
                          : '${tracks[i]!.artist} · ${formatBytes(list[i].size)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onTap: tracks[i] == null
                      ? null
                      : () => player.playList(playable, playable.indexOf(tracks[i]!)),
                  trailing: IconButton(
                    tooltip: 'Quitar descarga',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => off.removeKey(list[i].key),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
