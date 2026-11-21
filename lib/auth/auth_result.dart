import 'dart:math';

class AuthResult {
  final String accessToken;
  final String? refreshToken;
  final DateTime expiry;

  AuthResult({required this.accessToken, this.refreshToken, required this.expiry});

  factory AuthResult.fromToken(Map<String, dynamic> j, {String? keepRefresh}) {
    final secs = (j['expires_in'] as num?)?.toInt() ?? 3600;
    return AuthResult(
      accessToken: j['access_token'] as String,
      refreshToken: (j['refresh_token'] as String?) ?? keepRefresh,
      expiry: DateTime.now().add(Duration(seconds: secs)),
    );
  }
}

String randomString(int length) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final r = Random.secure();
  return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
}
