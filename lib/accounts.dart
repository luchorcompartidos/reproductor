import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth/auth.dart' as auth;

/// Colores para identificar cada cuenta.
const accountColors = <int>[
  0xFF1A73E8, 0xFFD93025, 0xFF188038, 0xFFF29900,
  0xFF9334E6, 0xFF00897B, 0xFFE8710A, 0xFF5F6368,
];

/// Una cuenta de Google conectada y su cuota (about.get).
class Account {
  String email;
  String name;
  String nickname;
  int color;
  String accessToken;
  String? refreshToken;
  DateTime expiry;
  Quota? quota;
  String? error;

  Account({
    required this.email,
    required this.name,
    this.nickname = '',
    required this.color,
    this.accessToken = '',
    this.refreshToken,
    required this.expiry,
    this.quota,
  });

  String get title => nickname.isNotEmpty ? nickname : email;

  /// Datos visibles (sin tokens): van al almacenamiento común.
  Map<String, dynamic> toJson() => {
        'email': email,
        'name': name,
        'nickname': nickname,
        'color': color,
        'quota': quota?.toJson(),
      };

  Map<String, dynamic> tokensJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiry': expiry.toIso8601String(),
      };

  void applyTokens(Map<String, dynamic>? t) {
    if (t == null) return;
    accessToken = (t['accessToken'] as String?) ?? '';
    refreshToken = t['refreshToken'] as String?;
    expiry = DateTime.tryParse('${t['expiry']}') ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  factory Account.fromJson(Map<String, dynamic> j, int index) {
    final a = Account(
      email: j['email'] as String,
      name: (j['name'] as String?) ?? '',
      nickname: (j['nickname'] as String?) ?? '',
      color: (j['color'] as int?) ?? accountColors[index % accountColors.length],
      expiry: DateTime.fromMillisecondsSinceEpoch(0),
      quota: j['quota'] == null ? null : Quota.fromJson(j['quota'] as Map<String, dynamic>),
    );
    // Formato de v0.0.x: los tokens estaban junto con los datos.
    if (j.containsKey('accessToken')) a.applyTokens(j);
    return a;
  }
}

class Quota {
  final int? limit; // null = sin límite
  final int usage; // todo: Drive + Gmail + Fotos
  final int inDrive;
  final int inTrash;

  Quota({this.limit, required this.usage, required this.inDrive, required this.inTrash});

  int get driveWithoutTrash => max(0, inDrive - inTrash);
  int get others => max(0, usage - inDrive); // Gmail y Fotos
  int? get free => limit == null ? null : max(0, limit! - usage);
  double? get ratio => (limit == null || limit == 0) ? null : usage / limit!;

  static int _n(Object? v) => int.tryParse('${v ?? 0}') ?? 0;

  factory Quota.fromApi(Map<String, dynamic> q) => Quota(
        limit: q['limit'] == null ? null : _n(q['limit']),
        usage: _n(q['usage']),
        inDrive: _n(q['usageInDrive']),
        inTrash: _n(q['usageInDriveTrash']),
      );

  Map<String, dynamic> toJson() =>
      {'limit': limit, 'usage': usage, 'usageInDrive': inDrive, 'usageInDriveTrash': inTrash};

  factory Quota.fromJson(Map<String, dynamic> j) => Quota.fromApi(j);

  /// Suma de varias cuentas (sin límite si alguna no lo tiene).
  static Quota sum(Iterable<Quota> qs) {
    int? limit = 0;
    var usage = 0, inDrive = 0, inTrash = 0;
    for (final q in qs) {
      limit = (limit == null || q.limit == null) ? null : limit + q.limit!;
      usage += q.usage;
      inDrive += q.inDrive;
      inTrash += q.inTrash;
    }
    return Quota(limit: limit, usage: usage, inDrive: inDrive, inTrash: inTrash);
  }
}

class NeedsReconnect implements Exception {
  @override
  String toString() => 'Hay que volver a conectar esta cuenta';
}

/// Tokens: almacenamiento seguro del sistema en Android y Windows.
/// En la web quedan en el navegador (duran ~1 hora).
class _TokenStore {
  static const _secure =
      FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const _key = 'rep_tokens';

  static Future<Map<String, dynamic>> readAll() async {
    String? raw;
    if (kIsWeb) {
      raw = (await SharedPreferences.getInstance()).getString(_key);
    } else {
      try {
        raw = await _secure.read(key: _key);
      } catch (_) {
        raw = null;
      }
    }
    if (raw == null) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<void> writeAll(Map<String, dynamic> tokens) async {
    final raw = jsonEncode(tokens);
    if (kIsWeb) {
      await (await SharedPreferences.getInstance()).setString(_key, raw);
    } else {
      await _secure.write(key: _key, value: raw);
    }
  }
}

class AccountStore {
  static const _key = 'rep_accounts';
  static const _alertKey = 'rep_alert_percent';
  final List<Account> accounts = [];
  int alertPercent = 85;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    alertPercent = prefs.getInt(_alertKey) ?? 85;
    final raw = prefs.getString(_key);
    accounts.clear();
    var migrate = false;
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      for (var i = 0; i < list.length; i++) {
        final j = list[i] as Map<String, dynamic>;
        if (j.containsKey('accessToken')) migrate = true;
        accounts.add(Account.fromJson(j, i));
      }
    }
    final tokens = await _TokenStore.readAll();
    for (final a in accounts) {
      a.applyTokens(tokens[a.email] as Map<String, dynamic>?);
    }
    if (migrate) await save(); // saca los tokens del almacenamiento común
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(accounts.map((a) => a.toJson()).toList()));
    await _TokenStore.writeAll({for (final a in accounts) a.email: a.tokensJson()});
  }

  Future<void> setAlertPercent(int v) async {
    alertPercent = v;
    await (await SharedPreferences.getInstance()).setInt(_alertKey, v);
  }

  bool overAlert(Account a) {
    final r = a.quota?.ratio;
    return r != null && r * 100 >= alertPercent;
  }

  /// Agrega (o actualiza, si ya estaba) la cuenta de este acceso.
  Future<Account> addFromAuth(auth.AuthResult r) async {
    final about = await _about(r.accessToken);
    final user = about['user'] as Map<String, dynamic>;
    final email = user['emailAddress'] as String;
    final quota = Quota.fromApi(about['storageQuota'] as Map<String, dynamic>);
    final i = accounts.indexWhere((a) => a.email == email);
    if (i >= 0) {
      final a = accounts[i]
        ..accessToken = r.accessToken
        ..expiry = r.expiry
        ..quota = quota
        ..error = null;
      if (r.refreshToken != null) a.refreshToken = r.refreshToken;
      await save();
      return a;
    }
    final acc = Account(
      email: email,
      name: (user['displayName'] as String?) ?? '',
      color: accountColors[accounts.length % accountColors.length],
      accessToken: r.accessToken,
      refreshToken: r.refreshToken,
      expiry: r.expiry,
      quota: quota,
    );
    accounts.add(acc);
    await save();
    return acc;
  }

  Future<void> remove(Account a) async {
    accounts.remove(a);
    await save();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final a = accounts.removeAt(oldIndex);
    accounts.insert(newIndex, a);
    await save();
  }

  /// Vuelve a pedir la cuota de una cuenta, renovando el acceso si hace falta.
  Future<void> refreshQuota(Account a) async {
    a.error = null;
    try {
      await _ensureToken(a);
      final about = await _about(a.accessToken);
      a.quota = Quota.fromApi(about['storageQuota'] as Map<String, dynamic>);
    } catch (e) {
      a.error = '$e';
    }
    await save();
  }

  /// Token vigente de la cuenta (lo renueva si hace falta).
  Future<String> tokenFor(Account a) async {
    final before = a.accessToken;
    await _ensureToken(a);
    if (a.accessToken != before) await save();
    return a.accessToken;
  }

  Future<void> _ensureToken(Account a) async {
    if (a.accessToken.isNotEmpty &&
        a.expiry.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return;
    }
    final rt = a.refreshToken;
    if (rt == null) throw NeedsReconnect();
    final r = await auth.refresh(rt);
    if (r == null) throw NeedsReconnect();
    a.accessToken = r.accessToken;
    a.expiry = r.expiry;
    if (r.refreshToken != null) a.refreshToken = r.refreshToken;
  }

  static Future<Map<String, dynamic>> _about(String token) async {
    final res = await http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/about'
          '?fields=user(emailAddress,displayName),storageQuota'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode == 401) throw NeedsReconnect();
    if (res.statusCode != 200) throw Exception('Drive respondió ${res.statusCode}: ${res.body}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}

String formatBytes(int? b) {
  if (b == null) return 'sin límite';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 || i == 0 ? 0 : 1)} ${units[i]}';
}
