import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'auth/auth.dart' as auth;
import 'config.dart';
import 'platform/platform.dart' as platform;
import 'updates.dart';

Future<void> main() async {
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  // Web: al volver de Google, el acceso viene en la dirección.
  final pending = auth.consumeRedirectResult();
  await auth.initAuth();
  final store = AccountStore();
  await store.load();
  runApp(ReproductorApp(store: store, pending: pending));
}

class ReproductorApp extends StatelessWidget {
  final AccountStore store;
  final auth.AuthResult? pending;
  const ReproductorApp({super.key, required this.store, this.pending});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF6A1B9A);
    return MaterialApp(
      title: Config.appName,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(store: store, pending: pending),
    );
  }
}

class HomePage extends StatefulWidget {
  final AccountStore store;
  final auth.AuthResult? pending;
  const HomePage({super.key, required this.store, this.pending});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _busy = false;
  StreamSubscription<auth.AuthResult>? _sub;
  List<ReleaseInfo> _releases = [];

  /// Resultado de "Probar acceso a la música" por cuenta.
  final Map<String, String> _probe = {};

  AccountStore get store => widget.store;

  ReleaseInfo? get _newer {
    if (_releases.isEmpty) return null;
    final latest = _releases.first;
    return Updates.compare(latest.version, Config.appVersion) > 0 ? latest : null;
  }

  @override
  void initState() {
    super.initState();
    // Android: la cuenta vuelve desde el navegador.
    _sub = auth.authResults.listen(
      (r) => _run(() async {
        final a = await store.addFromAuth(r);
        _snack('Cuenta conectada: ${a.email}');
      }),
      onError: (Object e) => _snack('Error: $e'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final p = widget.pending;
      if (p != null) {
        await _run(() async {
          final a = await store.addFromAuth(p);
          _snack('Cuenta conectada: ${a.email}');
        });
      } else {
        await _refreshAll();
      }
    });
    Updates.fetch().then((r) {
      if (mounted) setState(() => _releases = r);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() job) async {
    if (mounted) setState(() => _busy = true);
    try {
      await job();
    } catch (e) {
      _snack('Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Revisa que cada cuenta siga con acceso (renueva el token si hace falta).
  Future<void> _refreshAll() => _run(() async {
        for (final a in List.of(store.accounts)) {
          await store.refreshQuota(a);
        }
      });

  Future<void> _addAccount() => _run(() async {
        final r = await auth.signInNewAccount();
        if (r != null) {
          final a = await store.addFromAuth(r);
          _snack('Cuenta conectada: ${a.email}');
        }
      });

  /// Prueba de E0: busca hasta 100 audios en la cuenta (Mi unidad y compartidos conmigo).
  Future<void> _probeMusic(Account a) => _run(() async {
        try {
          final token = await store.tokenFor(a);
          final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
            'q': "mimeType contains 'audio/' and trashed = false",
            'pageSize': '100',
            'fields': 'nextPageToken,files(id)',
          });
          final res = await http.get(uri, headers: {'Authorization': 'Bearer $token'});
          if (res.statusCode == 401) throw NeedsReconnect();
          if (res.statusCode != 200) {
            throw Exception('Drive respondió ${res.statusCode}');
          }
          final j = jsonDecode(res.body) as Map<String, dynamic>;
          final n = (j['files'] as List? ?? []).length;
          final more = j['nextPageToken'] != null;
          _probe[a.email] = n == 0
              ? 'Acceso OK · no se encontraron audios'
              : 'Acceso OK · ${more ? '$n o más' : '$n'} audios encontrados';
          a.error = null;
        } catch (e) {
          _probe.remove(a.email);
          a.error = '$e';
        }
      });

  Future<void> _rename(Account a) async {
    final ctrl = TextEditingController(text: a.nickname);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Alias de la cuenta'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: a.email),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (value == null) return;
    setState(() => a.nickname = value);
    await store.save();
  }

  Future<void> _remove(Account a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitar cuenta'),
        content: Text('¿Quitar ${a.email} del Reproductor? '
            'No se borra nada de tu Drive.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Quitar')),
        ],
      ),
    );
    if (ok != true) return;
    _probe.remove(a.email);
    await store.remove(a);
    if (mounted) setState(() {});
  }

  void _openUpdate(ReleaseInfo r) {
    final ext = platform.installerExtension();
    if (ext.isEmpty) {
      platform.reloadPage();
      return;
    }
    launchUrl(Uri.parse(r.assetEndingWith(ext) ?? r.htmlUrl),
        mode: LaunchMode.externalApplication);
  }

  void _showVersion() {
    final current = _releases.where((r) => r.version == Config.appVersion).firstOrNull;
    final newer = _newer;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${Config.appName} v${Config.appVersion}'),
        content: SizedBox(
          width: 420,
          child: ListView(shrinkWrap: true, children: [
            if (current != null && current.date != null)
              Text('Publicada: ${_fmtDate(current.date!)}'),
            if (newer != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Hay una versión nueva: v${newer.version}',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.primary)),
              ),
            const SizedBox(height: 16),
            Text('Changelog', style: Theme.of(ctx).textTheme.titleMedium),
            if (_releases.isEmpty) const Text('Sin conexión y sin copia guardada.'),
            for (final r in _releases.take(15)) ...[
              const SizedBox(height: 10),
              Text('v${r.version}${r.date == null ? '' : ' · ${_fmtDate(r.date!)}'}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (r.notes.isNotEmpty) Text(r.notes),
            ],
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => launchUrl(Uri.parse('${Config.repoUrl}/releases')),
            child: const Text('Ver en GitHub'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accounts = store.accounts;
    final newer = _newer;

    return Scaffold(
      appBar: AppBar(
        title: const Text(Config.appName),
        actions: [
          TextButton(onPressed: _showVersion, child: Text('v${Config.appVersion}')),
          IconButton(
            tooltip: 'Revisar cuentas',
            onPressed: _busy ? null : _refreshAll,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: _busy ? const LinearProgressIndicator() : const SizedBox(height: 4),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addAccount,
        icon: const Icon(Icons.person_add),
        label: const Text('Agregar cuenta'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          if (newer != null)
            Card(
              color: scheme.primaryContainer,
              child: ListTile(
                leading: const Icon(Icons.system_update),
                title: Text('Hay una versión nueva (v${newer.version})'),
                trailing: FilledButton(
                  onPressed: () => _openUpdate(newer),
                  child: Text(platform.installerExtension().isEmpty ? 'Recargar' : 'Descargar'),
                ),
              ),
            ),
          if (!auth.configOk())
            const _Banner(
              icon: Icons.warning_amber,
              text: 'Faltan los datos de Google Cloud en esta compilación (Secrets del repo).',
            ),
          if (auth.isWeb)
            const _Banner(
              icon: Icons.info_outline,
              text: 'En la web el acceso de cada cuenta dura cerca de 1 hora; '
                  'después usá "Volver a conectar".',
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text('Cuentas de Google Drive (${accounts.length})',
                style: Theme.of(context).textTheme.titleMedium),
          ),
          if (accounts.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Text('Todavía no hay cuentas. Tocá "Agregar cuenta" para conectar '
                    'la primera; podés sumar todas las que quieras.'),
              ),
            ),
          for (final a in accounts)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(a.color),
                  foregroundColor: Colors.white,
                  child: Text(a.title.isEmpty ? '?' : a.title[0].toUpperCase()),
                ),
                title: Text(a.title),
                subtitle: Text(
                  a.error ?? _probe[a.email] ?? (a.nickname.isNotEmpty ? a.email : 'Conectada'),
                  style: a.error == null ? null : TextStyle(color: scheme.error),
                ),
                onTap: _busy ? null : () => _probeMusic(a),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    switch (v) {
                      case 'probe':
                        _probeMusic(a);
                      case 'alias':
                        _rename(a);
                      case 'reconnect':
                        _addAccount();
                      case 'remove':
                        _remove(a);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'probe', child: Text('Probar acceso a la música')),
                    PopupMenuItem(value: 'alias', child: Text('Cambiar alias')),
                    PopupMenuItem(value: 'reconnect', child: Text('Volver a conectar')),
                    PopupMenuItem(value: 'remove', child: Text('Quitar')),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Card(
            color: scheme.surfaceContainerHighest,
            child: const ListTile(
              leading: Icon(Icons.library_music_outlined),
              title: Text('Biblioteca'),
              subtitle: Text('Próxima entrega (E1): índice de la música de todas las cuentas, '
                  'por carpeta, con búsqueda.'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Banner({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: ListTile(leading: Icon(icon), title: Text(text)),
      );
}

String _two(int n) => n.toString().padLeft(2, '0');

String _fmtDate(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}/${_two(l.month)}/${l.year} ${_two(l.hour)}:${_two(l.minute)}';
}
