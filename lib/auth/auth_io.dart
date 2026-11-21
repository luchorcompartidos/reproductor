import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import 'auth_result.dart';

const bool isWeb = false;

// Android: Google vuelve a la página web de la app, que reenvía el código a la app
// (com.luchorcompartidos.reproductor://oauth). Usa el cliente Web.
// Windows: el navegador vuelve a 127.0.0.1 y la app lo atiende. Usa el cliente Escritorio.

final _results = StreamController<AuthResult>();
const _pkceKey = 'rep_pkce';
StreamSubscription<Uri>? _linkSub;

/// Cuentas que llegan desde el navegador (Android).
Stream<AuthResult> get authResults => _results.stream;

bool configOk() => Platform.isAndroid
    ? Config.webClientId.isNotEmpty && Config.webClientSecret.isNotEmpty
    : Config.desktopClientId.isNotEmpty && Config.desktopClientSecret.isNotEmpty;

String get _clientId => Platform.isAndroid ? Config.webClientId : Config.desktopClientId;
String get _clientSecret =>
    Platform.isAndroid ? Config.webClientSecret : Config.desktopClientSecret;

String _challenge(String verifier) =>
    base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

Future<void> initAuth() async {
  if (!Platform.isAndroid) return;
  final links = AppLinks();
  _linkSub ??= links.uriLinkStream.listen(_handleUri, onError: (_) {});
  try {
    final first = await links.getInitialLink();
    if (first != null) await _handleUri(first);
  } catch (_) {}
}

Future<void> _handleUri(Uri uri) async {
  if (uri.scheme != Config.androidScheme || uri.host != 'oauth') return;
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_pkceKey);
  if (raw == null) return; // ya usado
  final pkce = jsonDecode(raw) as Map<String, dynamic>;
  final q = uri.queryParameters;
  if (q['state'] != pkce['state']) return;
  await prefs.remove(_pkceKey);
  if (q['code'] == null) {
    _results.addError(Exception('Google no autorizó la cuenta (${q['error'] ?? 'sin código'})'));
    return;
  }
  try {
    _results.add(await _exchange(q['code']!, pkce['verifier'] as String, Config.webRedirect));
  } catch (e) {
    _results.addError(e);
  }
}

Future<AuthResult> _exchange(String code, String verifier, String redirect) async {
  final res = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
    'client_id': _clientId,
    'client_secret': _clientSecret,
    'code': code,
    'code_verifier': verifier,
    'grant_type': 'authorization_code',
    'redirect_uri': redirect,
  });
  if (res.statusCode != 200) throw Exception('Google rechazó el código: ${res.body}');
  return AuthResult.fromToken(jsonDecode(res.body) as Map<String, dynamic>);
}

Uri _authUrl(String redirect, String verifier, String state, String scope) =>
    Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': _clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': scope,
      'include_granted_scopes': 'true',
      'code_challenge': _challenge(verifier),
      'code_challenge_method': 'S256',
      'state': state,
      'access_type': 'offline',
      'prompt': 'select_account consent',
    });

/// Abre el navegador para elegir una cuenta de Google.
/// En Windows devuelve la cuenta; en Android llega luego por [authResults].
Future<AuthResult?> signInNewAccount({String scope = Config.scope}) async {
  final verifier = randomString(64);
  if (Platform.isAndroid) {
    final state = 'a_${randomString(24)}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pkceKey, jsonEncode({'state': state, 'verifier': verifier}));
    await launchUrl(_authUrl(Config.webRedirect, verifier, state, scope),
        mode: LaunchMode.externalApplication);
    return null;
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final redirect = 'http://127.0.0.1:${server.port}';
  final state = randomString(24);
  final completer = Completer<Map<String, String>>();

  final sub = server.listen((req) async {
    final q = req.uri.queryParameters;
    if (!q.containsKey('code') && !q.containsKey('error')) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    req.response.headers.contentType = ContentType.html;
    req.response.write('<html><head><meta charset="utf-8"></head>'
        '<body style="font-family:sans-serif;padding:2em">'
        '<h2>Listo, cuenta conectada.</h2><p>Ya podés volver al Reproductor.</p>'
        '</body></html>');
    await req.response.close();
    if (!completer.isCompleted) completer.complete(q);
  });

  try {
    await launchUrl(_authUrl(redirect, verifier, state, scope), mode: LaunchMode.externalApplication);
    final q = await completer.future.timeout(const Duration(minutes: 5));
    if (q['state'] != state || q['code'] == null) return null;
    return await _exchange(q['code']!, verifier, redirect);
  } finally {
    await sub.cancel();
    await server.close(force: true);
  }
}

/// Renueva el acceso de una cuenta ya conectada.
Future<AuthResult?> refresh(String refreshToken) async {
  final res = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
    'client_id': _clientId,
    'client_secret': _clientSecret,
    'refresh_token': refreshToken,
    'grant_type': 'refresh_token',
  });
  if (res.statusCode != 200) return null;
  return AuthResult.fromToken(jsonDecode(res.body) as Map<String, dynamic>,
      keepRefresh: refreshToken);
}

/// Solo aplica a la web.
AuthResult? consumeRedirectResult() => null;
