import 'package:shared_preferences/shared_preferences.dart';

/// Web: etiquetas en el navegador (sin carátulas, para no llenar el espacio).
String _k(String key) => 'rep_tags_$key';

Future<void> saveTags(String key, String json) async {
  try {
    await (await SharedPreferences.getInstance()).setString(_k(key), json);
  } catch (_) {}
}

Future<String?> loadTags(String key) async =>
    (await SharedPreferences.getInstance()).getString(_k(key));

Future<void> deleteTags(String key) async =>
    (await SharedPreferences.getInstance()).remove(_k(key));
