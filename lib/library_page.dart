import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'drive_index.dart';
import 'library.dart';

int _byName(DriveItem a, DriveItem b) => normalize(a.name).compareTo(normalize(b.name));

String _two(int n) => n.toString().padLeft(2, '0');

String _date(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}/${_two(l.month)}/${l.year}';
}

/// Pestaña Biblioteca: búsqueda, vista por carpetas y lista de todas las canciones.
class LibraryView extends StatefulWidget {
  final Library library;
  const LibraryView({super.key, required this.library});

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  final _search = TextEditingController();
  String _query = '';
  int _mode = 0; // 0 = carpetas, 1 = todas las canciones

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lib = widget.library;
    return AnimatedBuilder(
      animation: lib,
      builder: (context, _) {
        final accounts = lib.store.accounts;
        final searching = _query.trim().isNotEmpty;
        final status = <Widget>[
          for (final a in accounts)
            if (lib.progressOf(a) != null)
              _StatusLine(
                icon: const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                text: 'Leyendo la música de ${a.title}… ${lib.progressOf(a)} elementos',
              )
            else if (lib.errors[a.email] != null)
              _StatusLine(
                icon: Icon(Icons.error_outline, size: 18, color: Theme.of(context).colorScheme.error),
                text: '${a.title}: ${lib.errors[a.email]}',
              ),
        ];

        Widget content;
        if (accounts.isEmpty) {
          content = const _Empty(
              text: 'Todavía no hay cuentas. Conectá una en la pestaña "Cuentas" '
                  'y su música aparece acá.');
        } else if (searching || _mode == 1) {
          final list = searching ? lib.search(_query) : lib.tracks;
          content = list.isEmpty
              ? _Empty(
                  text: searching
                      ? 'No hay canciones que coincidan con "$_query".'
                      : (lib.busy ? 'Leyendo la música…' : 'No se encontraron canciones.'))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: list.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: Text('${list.length} canciones',
                            style: Theme.of(context).textTheme.labelLarge),
                      );
                    }
                    return TrackTile(library: lib, track: list[i - 1], showAccount: true);
                  },
                );
        } else {
          content = ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final a in accounts)
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Color(a.color),
                    foregroundColor: Colors.white,
                    child: Text(a.title.isEmpty ? '?' : a.title[0].toUpperCase()),
                  ),
                  title: Text(a.title),
                  subtitle: Text(lib.indexOf(a) == null
                      ? (lib.progressOf(a) != null ? 'Leyendo…' : 'Sin leer todavía')
                      : '${lib.countFor(a)} canciones'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: lib.indexOf(a) == null
                      ? null
                      : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) =>
                                    FolderPage(library: lib, account: a, folderId: null)),
                          ),
                ),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Buscar canción o carpeta',
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Borrar',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _search.clear();
                            _query = '';
                          }),
                        ),
                ),
              ),
            ),
            if (!searching && accounts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                        value: 0, icon: Icon(Icons.folder_outlined), label: Text('Carpetas')),
                    ButtonSegment(
                        value: 1, icon: Icon(Icons.queue_music), label: Text('Todas')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
              ),
            ...status,
            if (!lib.persists && accounts.isNotEmpty)
              const _StatusLine(
                icon: Icon(Icons.info_outline, size: 18),
                text: 'En la web la música se vuelve a leer cada vez que abrís la página.',
              ),
            Expanded(child: content),
          ],
        );
      },
    );
  }
}

/// Una carpeta de una cuenta (folderId null = las dos de arriba de todo).
class FolderPage extends StatelessWidget {
  final Library library;
  final Account account;
  final String? folderId;
  const FolderPage({super.key, required this.library, required this.account, this.folderId});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: library,
      builder: (context, _) {
        final idx = library.indexOf(account);
        if (idx == null) {
          return Scaffold(
            appBar: AppBar(title: Text(account.title)),
            body: const _Empty(text: 'La música de esta cuenta no está disponible.'),
          );
        }
        final id = folderId;
        final entries = id == null
            ? [idx.items[idx.rootId], idx.items[otherId]].whereType<DriveItem>().toList()
            : List<DriveItem>.of(idx.children[id] ?? const <DriveItem>[]);
        final folders = entries.where((e) => e.isFolder && e.files > 0).toList()..sort(_byName);
        final songs = entries.where(isAudioItem).toList()..sort(_byName);
        final title = id == null ? account.title : (idx.items[id]?.name ?? '');
        final path = id == null
            ? account.email
            : '${account.title} / ${idx.pathTo(id).map((f) => f.name).join(' / ')}';

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          body: (folders.isEmpty && songs.isEmpty)
              ? const _Empty(text: 'No hay canciones en esta carpeta.')
              : ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    for (final f in folders)
                      ListTile(
                        leading: Icon(Icons.folder, color: Color(account.color)),
                        title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${f.files} ${f.files == 1 ? 'canción' : 'canciones'}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                              builder: (_) =>
                                  FolderPage(library: library, account: account, folderId: f.id)),
                        ),
                      ),
                    if (folders.isNotEmpty && songs.isNotEmpty) const Divider(),
                    for (final s in songs)
                      TrackTile(
                          library: library,
                          track: library.trackFor(account, s),
                          showAccount: false),
                  ],
                ),
        );
      },
    );
  }
}

class TrackTile extends StatelessWidget {
  final Library library;
  final Track track;
  final bool showAccount;
  const TrackTile(
      {super.key, required this.library, required this.track, required this.showAccount});

  @override
  Widget build(BuildContext context) {
    final it = track.item;
    final details = '${trackFormat(it)} · ${formatBytes(it.size)}';
    return ListTile(
      leading: showAccount
          ? CircleAvatar(
              radius: 16,
              backgroundColor: Color(track.account.color),
              child: const Icon(Icons.music_note, size: 18, color: Colors.white),
            )
          : const Icon(Icons.music_note_outlined),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        showAccount
            ? '${track.folder.isEmpty ? track.account.title : track.folder} · ${track.account.title}'
            : details,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => showTrackSheet(context, library, track),
    );
  }
}

/// Detalle de una canción (la reproducción llega en E2).
void showTrackSheet(BuildContext context, Library library, Track t) {
  final it = t.item;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.title, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            _Row(label: 'Cuenta', value: '${t.account.title} (${t.account.email})'),
            _Row(label: 'Carpeta', value: library.pathOf(t)),
            _Row(label: 'Archivo', value: it.name),
            _Row(label: 'Formato', value: '${trackFormat(it)} · ${formatBytes(it.size)}'),
            if (it.modified > 0) _Row(label: 'Modificado', value: _date(it.modifiedAt)),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => launchUrl(
                      Uri.parse('https://drive.google.com/file/d/${it.id}/view'),
                      mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Abrir en Drive'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('La reproducción llega en la próxima entrega (E2).',
                style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 96,
                child: Text(label, style: Theme.of(context).textTheme.labelMedium)),
            Expanded(child: Text(value)),
          ],
        ),
      );
}

class _StatusLine extends StatelessWidget {
  final Widget icon;
  final String text;
  const _StatusLine({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(children: [
          icon,
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}
