import 'package:flutter/material.dart';

import 'library.dart';
import 'library_page.dart';
import 'player.dart';
import 'playlists.dart';

String _two(int n) => n.toString().padLeft(2, '0');

Future<String?> _askName(BuildContext context, {String title = 'Lista nueva', String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Nombre de la lista'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Guardar')),
      ],
    ),
  );
}

/// Elegir (o crear) una lista y agregarle [tracks].
Future<void> addToPlaylist(
    BuildContext context, PlaylistStore lists, List<Track> tracks) async {
  if (tracks.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
                tracks.length == 1
                    ? 'Agregar "${tracks.first.title}" a…'
                    : 'Agregar ${tracks.length} canciones a…',
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Lista nueva…'),
            onTap: () => Navigator.pop(ctx, 'new'),
          ),
          for (final p in lists.playlists)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(p.name),
              subtitle: Text('${p.items.length} canciones'),
              onTap: () => Navigator.pop(ctx, p),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  Playlist? target;
  if (choice == 'new') {
    final name = await _askName(context);
    if (name == null) return;
    target = lists.create(name);
  } else if (choice is Playlist) {
    target = choice;
  }
  if (target == null) return;
  final n = lists.addTracks(target, tracks);
  messenger.showSnackBar(SnackBar(
      content: Text(n == 0
          ? 'Ya estaban en "${target.name}"'
          : 'Agregadas a "${target.name}": $n')));
}

/// Pestaña Listas.
class PlaylistsView extends StatelessWidget {
  final PlaylistStore lists;
  final Library library;
  final PlayerController player;
  const PlaylistsView(
      {super.key, required this.lists, required this.library, required this.player});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([lists, library]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final main = lists.mainAccount;
        final l = lists.lastSync;
        final status = main == null
            ? 'Conectá una cuenta para guardar las listas en Drive.'
            : lists.syncing
                ? 'Sincronizando con ${main.title}…'
                : (lists.syncError ??
                    'Se guardan en ${main.title} (carpeta oculta + "$backupName")'
                        '${l == null ? '' : ' · sincronizado ${_two(l.hour)}:${_two(l.minute)}'}');
        final all = lists.playlists;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            Row(children: [
              Icon(lists.syncError != null ? Icons.sync_problem : Icons.cloud_done_outlined,
                  size: 18,
                  color: lists.syncError != null ? scheme.error : scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(status,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: lists.syncError != null ? scheme.error : null)),
              ),
            ]),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  final name = await _askName(context);
                  if (name == null) return;
                  lists.create(name);
                },
                icon: const Icon(Icons.playlist_add),
                label: const Text('Nueva lista'),
              ),
            ),
            const SizedBox(height: 8),
            if (all.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Todavía no hay listas. Creá una acá, o desde cualquier canción, álbum o '
                  'carpeta con "Agregar a lista".',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final p in all)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(p.name),
                  subtitle: Text('${p.items.length} '
                      '${p.items.length == 1 ? 'canción' : 'canciones'}'),
                  trailing: IconButton(
                    tooltip: 'Reproducir',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () {
                      final tracks = resolve(library, p);
                      if (tracks.isNotEmpty) player.playList(tracks, 0);
                    },
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => PlaylistPage(
                          lists: lists, library: library, player: player, playlistId: p.id),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Canciones de la lista que siguen en la biblioteca.
List<Track> resolve(Library library, Playlist p) => [
      for (final i in p.items) library.trackByKey(i.email, i.id),
    ].whereType<Track>().toList();

class PlaylistPage extends StatelessWidget {
  final PlaylistStore lists;
  final Library library;
  final PlayerController player;
  final String playlistId;
  const PlaylistPage(
      {super.key,
      required this.lists,
      required this.library,
      required this.player,
      required this.playlistId});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([lists, library]),
      builder: (context, _) {
        final p = lists.byId(playlistId);
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Esta lista ya no existe.')),
          );
        }
        final items = p.items;
        final tracks = [for (final i in items) library.trackByKey(i.email, i.id)];
        final playable = tracks.whereType<Track>().toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: 'Reproducir',
                icon: const Icon(Icons.play_arrow),
                onPressed: playable.isEmpty ? null : () => player.playList(playable, 0),
              ),
              IconButton(
                tooltip: 'Aleatorio',
                icon: const Icon(Icons.shuffle),
                onPressed: playable.isEmpty ? null : () => player.playShuffled(playable),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final name = await _askName(context, title: 'Renombrar', initial: p.name);
                    if (name != null) lists.rename(p, name);
                  } else if (v == 'delete') {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Borrar lista'),
                        content: Text('¿Borrar "${p.name}"? Las canciones no se borran de Drive.'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancelar')),
                          FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Borrar')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      lists.delete(p);
                      if (context.mounted) Navigator.pop(context);
                    }
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Renombrar')),
                  PopupMenuItem(value: 'delete', child: Text('Borrar lista')),
                ],
              ),
            ],
          ),
          body: items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Lista vacía. Agregá canciones desde la Biblioteca con '
                      '"Agregar a lista" (en el detalle de una canción, un álbum o una carpeta).',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: items.length,
                  buildDefaultDragHandles: false,
                  onReorder: (a, b) => lists.move(p, a, b),
                  itemBuilder: (context, i) {
                    final t = tracks[i];
                    final key = ValueKey('${items[i].email}|${items[i].id}|$i');
                    if (t == null) {
                      return ListTile(
                        key: key,
                        enabled: false,
                        leading: const Icon(Icons.music_off_outlined),
                        title: Text(items[i].name.isEmpty ? 'Canción' : items[i].name),
                        subtitle: Text('No disponible (${items[i].email})'),
                        trailing: IconButton(
                          tooltip: 'Quitar de la lista',
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => lists.removeAt(p, i),
                        ),
                      );
                    }
                    final pos = playable.indexOf(t);
                    return ListTile(
                      key: key,
                      leading: CoverImage(library: library, track: t, size: 40),
                      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${t.artist} · ${t.album}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => player.playList(playable, pos < 0 ? 0 : pos),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Quitar de la lista',
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => lists.removeAt(p, i),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ]),
                    );
                  },
                ),
        );
      },
    );
  }
}
