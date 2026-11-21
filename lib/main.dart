import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'accounts.dart';
import 'auth/auth.dart' as auth;
import 'config.dart';
import 'library.dart';
import 'library_page.dart';
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
  int _tab = 0; // 0 = Biblioteca, 1 = Cuentas
  late final Library _library = Library(store);

  /// Android: se abrió el navegador y se espera la vuelta de Google.
  bool _waiting = false;
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
      (r) {
        setState(() => _waiting = false);
        _connect(r);
      },
      onError: (Object e) {
        setState(() => _waiting = false);
        _showError(e);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final p = widget.pending;
      if (p != null) {
        await _connect(p);
      } else {
        await _refreshAll();
      }
      await _library.start();
    });
    Updates.fetch().then((r) {
      if (mounted) setState(() => _releases = r);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _library.dispose();
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

  /// Agrega la cuenta que volvió de Google; si falla, lo explica en un cartel.
  Future<void> _connect(auth.AuthResult r) async {
    setState(() => _busy = true);
    try {
      final a = await store.addFromAuth(r);
      _snack('Cuenta conectada: ${a.email}. Leyendo su música…');
      if (mounted) setState(() => _busy = false);
      unawaited(_library.refresh(a));
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addAccount() async {
    setState(() => _busy = true);
    try {
      final r = await auth.signInNewAccount();
      if (r != null) {
        await _connect(r);
      } else if (!auth.isWeb) {
        // Android: la cuenta llega después, cuando el navegador vuelve a la app.
        setState(() => _waiting = true);
      }
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Traduce los errores conocidos de Google a una explicación clara.
  String _explain(Object e) {
    final t = '$e';
    if (t.contains('invalid_client')) {
      final android = defaultTargetPlatform == TargetPlatform.android;
      final name = android ? 'WEB_CLIENT_SECRET (cliente Web)' : 'DESKTOP_CLIENT_SECRET (cliente Escritorio)';
      return 'Google rechazó el secreto del cliente de esta compilación. '
          'Hay que corregir el Secret $name del repo y volver a compilar.\n\n'
          'Secreto en esta compilación: '
          '${_secretHint(android ? Config.webClientSecret : Config.desktopClientSecret)}. '
          'Comparalo con el final que muestra Google Cloud en "Secretos del cliente".';
    }
    if (t.contains('access_denied')) {
      return 'No se autorizó el acceso en Google. Volvé a intentarlo y aceptá '
          'al menos el permiso para ver y descargar los archivos de Drive.';
    }
    if (t.contains('invalid_grant')) {
      return 'La autorización venció o ya se había usado. Tocá "Agregar cuenta" otra vez.';
    }
    if (e is NeedsReconnect) {
      return 'Hay que volver a conectar esta cuenta.';
    }
    if (t.contains('403')) {
      return 'Google no dio permiso para leer los archivos de Drive. Volvé a conectar '
          'la cuenta y aceptá el permiso para ver y descargar los archivos.';
    }
    return 'No se pudo conectar la cuenta.';
  }

  void _showError(Object e) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.error_outline, color: Theme.of(ctx).colorScheme.error),
        title: const Text('No se pudo conectar'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_explain(e)),
              const SizedBox(height: 12),
              Text('Detalle técnico:', style: Theme.of(ctx).textTheme.labelMedium),
              SelectableText('$e', style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
        ],
      ),
    );
  }

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
    await _library.forget(a.email);
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
    final newer = _newer;

    final banners = <Widget>[
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
      if (_waiting)
        Card(
          color: scheme.tertiaryContainer,
          child: ListTile(
            leading: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            title: const Text('Esperando la autorización de Google…'),
            subtitle: const Text('Completá los pasos en el navegador. Al terminar, '
                'tocá "Volver al Reproductor" y la cuenta aparece acá.'),
            trailing: TextButton(
              onPressed: () => setState(() => _waiting = false),
              child: const Text('Cancelar'),
            ),
          ),
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text(Config.appName),
        actions: [
          TextButton(onPressed: _showVersion, child: Text('v${Config.appVersion}')),
          IconButton(
            tooltip: _tab == 0 ? 'Actualizar la biblioteca' : 'Revisar cuentas',
            onPressed: _busy
                ? null
                : (_tab == 0 ? () => _library.refreshAll() : _refreshAll),
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: _busy ? const LinearProgressIndicator() : const SizedBox(height: 4),
        ),
      ),
      floatingActionButton: _tab == 1
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _addAccount,
              icon: const Icon(Icons.person_add),
              label: const Text('Agregar cuenta'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              selectedIcon: Icon(Icons.library_music),
              label: 'Biblioteca'),
          NavigationDestination(
              icon: Icon(Icons.manage_accounts_outlined),
              selectedIcon: Icon(Icons.manage_accounts),
              label: 'Cuentas'),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (banners.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(children: banners),
            ),
          Expanded(
            child: _tab == 0 ? LibraryView(library: _library) : _accountsView(scheme),
          ),
        ],
      ),
    );
  }

  Widget _accountsView(ColorScheme scheme) {
    return AnimatedBuilder(
      animation: _library,
      builder: (context, _) {
        final accounts = store.accounts;
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            if (auth.isWeb)
              const _Banner(
                icon: Icons.info_outline,
                text: 'En la web el acceso de cada cuenta dura cerca de 1 hora; '
                    'después usá "Volver a conectar".',
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
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
                    a.error ?? _probe[a.email] ?? _accountInfo(a),
                    style: a.error == null ? null : TextStyle(color: scheme.error),
                  ),
                  onTap: _busy ? null : () => _probeMusic(a),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      switch (v) {
                        case 'probe':
                          _probeMusic(a);
                        case 'reread':
                          _library.rebuild(a);
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
                      PopupMenuItem(value: 'reread', child: Text('Volver a leer su música')),
                      PopupMenuItem(value: 'alias', child: Text('Cambiar alias')),
                      PopupMenuItem(value: 'reconnect', child: Text('Volver a conectar')),
                      PopupMenuItem(value: 'remove', child: Text('Quitar')),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  String _accountInfo(Account a) {
    final prefix = a.nickname.isNotEmpty ? '${a.email} · ' : '';
    final p = _library.progressOf(a);
    if (p != null) return '${prefix}Leyendo su música… $p elementos';
    final e = _library.errors[a.email];
    if (e != null) return '$prefix$e';
    if (_library.indexOf(a) == null) return '${prefix}Conectada';
    return '$prefix${_library.countFor(a)} canciones';
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

/// Solo el final del secreto, para compararlo con Google Cloud sin mostrarlo entero.
String _secretHint(String s) {
  if (s.isEmpty) return 'vacío';
  final end = s.length > 4 ? s.substring(s.length - 4) : s;
  return 'termina en …$end (${s.length} caracteres)';
}

String _two(int n) => n.toString().padLeft(2, '0');

String _fmtDate(DateTime d) {
  final l = d.toLocal();
  return '${_two(l.day)}/${_two(l.month)}/${l.year} ${_two(l.hour)}:${_two(l.minute)}';
}
