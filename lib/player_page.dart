import 'package:flutter/material.dart';

import 'library.dart';
import 'library_page.dart';
import 'player.dart';
import 'playlists_page.dart';

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Barra chica abajo, sobre las pestañas: canción actual y controles básicos.
class MiniPlayer extends StatelessWidget {
  final PlayerController player;
  const MiniPlayer({super.key, required this.player});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final t = player.current;
        if (t == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          color: scheme.surfaceContainerHigh,
          child: InkWell(
            onTap: () => openNowPlaying(context, player),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (context, snap) {
                    final total = player.duration?.inMilliseconds ?? 0;
                    final pos = snap.data?.inMilliseconds ?? 0;
                    return LinearProgressIndicator(
                      minHeight: 2,
                      value: player.loading
                          ? null
                          : (total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0),
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                  child: Row(
                    children: [
                      CoverImage(library: player.library, track: t, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall),
                            Text(
                              player.error ??
                                  (player.loading
                                      ? 'Cargando…'
                                      : '${t.artist} · ${t.album}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: player.error != null ? scheme.error : null),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: player.playing ? 'Pausa' : 'Reproducir',
                        onPressed: player.togglePlay,
                        icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
                      ),
                      IconButton(
                        tooltip: 'Siguiente',
                        onPressed: () => player.next(),
                        icon: const Icon(Icons.skip_next),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

void openNowPlaying(BuildContext context, PlayerController player) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => NowPlayingPage(player: player)),
  );
}

/// Pantalla completa: canción, barra de avance, controles y cola.
class NowPlayingPage extends StatelessWidget {
  final PlayerController player;
  const NowPlayingPage({super.key, required this.player});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final t = player.current;
        final scheme = Theme.of(context).colorScheme;
        if (t == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('No hay nada sonando.')),
          );
        }
        final queue = player.upcoming;
        final library = player.library;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Reproduciendo'),
            actions: [
              if (library.lists != null)
                IconButton(
                  tooltip: 'Agregar a lista',
                  icon: const Icon(Icons.playlist_add),
                  onPressed: () => addToPlaylist(context, library.lists!, [t]),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Center(child: CoverImage(library: library, track: t, size: 240)),
              const SizedBox(height: 20),
              Text(t.title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('${t.artist} · ${t.album}',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 2),
              Text('${library.pathOf(t)} · ${t.account.title}',
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
              if (player.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(player.error!,
                      textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                ),
              const SizedBox(height: 12),
              StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (context, snap) {
                  final total = player.duration ?? Duration.zero;
                  var pos = snap.data ?? Duration.zero;
                  if (pos > total) pos = total;
                  final max = total.inMilliseconds.toDouble();
                  return Column(
                    children: [
                      Slider(
                        value: max > 0 ? pos.inMilliseconds.toDouble().clamp(0.0, max) : 0.0,
                        max: max > 0 ? max : 1.0,
                        onChanged: max > 0
                            ? (v) => player.seek(Duration(milliseconds: v.round()))
                            : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(fmtDuration(pos)),
                            Text(player.loading ? 'Cargando…' : fmtDuration(total)),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: player.shuffle ? 'Aleatorio: sí' : 'Aleatorio: no',
                    onPressed: player.toggleShuffle,
                    icon: Icon(Icons.shuffle,
                        color: player.shuffle ? scheme.primary : scheme.onSurfaceVariant),
                  ),
                  IconButton(
                    tooltip: 'Anterior',
                    iconSize: 36,
                    onPressed: () => player.previous(),
                    icon: const Icon(Icons.skip_previous),
                  ),
                  IconButton.filled(
                    tooltip: player.playing ? 'Pausa' : 'Reproducir',
                    iconSize: 48,
                    onPressed: player.togglePlay,
                    icon: player.loading
                        ? const SizedBox(
                            width: 48,
                            height: 48,
                            child: Padding(
                              padding: EdgeInsets.all(10),
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                          )
                        : Icon(player.playing ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton(
                    tooltip: 'Siguiente',
                    iconSize: 36,
                    onPressed: () => player.next(),
                    icon: const Icon(Icons.skip_next),
                  ),
                  IconButton(
                    tooltip: switch (player.repeat) {
                      Repeat.off => 'Repetir: no',
                      Repeat.all => 'Repetir: todo',
                      Repeat.one => 'Repetir: esta canción',
                    },
                    onPressed: player.cycleRepeat,
                    icon: Icon(
                      player.repeat == Repeat.one ? Icons.repeat_one : Icons.repeat,
                      color: player.repeat == Repeat.off
                          ? scheme.onSurfaceVariant
                          : scheme.primary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Cola (${queue.length})', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              for (var i = 0; i < queue.length && i < player.queuePosition + 51; i++)
                if (i >= player.queuePosition - 3)
                  _QueueTile(
                    track: queue[i],
                    current: i == player.queuePosition,
                    played: i < player.queuePosition,
                    onTap: () => player.playAt(i),
                  ),
              if (queue.length > player.queuePosition + 51)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('… y ${queue.length - player.queuePosition - 51} más',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueTile extends StatelessWidget {
  final Track track;
  final bool current;
  final bool played;
  final VoidCallback onTap;
  const _QueueTile(
      {required this.track, required this.current, required this.played, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(current ? Icons.equalizer : Icons.music_note_outlined,
          color: current ? scheme.primary : (played ? scheme.outline : null)),
      title: Text(track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontWeight: current ? FontWeight.bold : null,
              color: played ? scheme.outline : null)),
      subtitle: Text('${track.artist} · ${track.album}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }
}
