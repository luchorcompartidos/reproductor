import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'accounts.dart';
import 'library.dart';
import 'platform/platform.dart' as platform;

enum Repeat { off, all, one }

/// Reproductor: cola propia (para pedir un token vigente en cada canción),
/// aleatorio y repetir.
/// Android y Windows: streaming desde Drive con el token de la cuenta.
/// Web: el navegador no puede mandar el token al reproductor, así que primero
/// descarga la canción completa y después la reproduce.
class PlayerController extends ChangeNotifier {
  final Library library;
  final AudioPlayer _player = AudioPlayer();
  final _rnd = Random();

  List<Track> _queue = [];
  List<int> _order = []; // orden de reproducción (índices de _queue)
  int _pos = -1;
  int _seq = 0; // para descartar cargas viejas si se cambia de canción rápido
  String? _blobUrl;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlaybackEvent>? _eventSub;
  DateTime _loadedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _retried = false; // un reintento con acceso nuevo si falla la conexión

  bool shuffle = false;
  Repeat repeat = Repeat.off;
  bool loading = false;
  String? error;

  PlayerController(this.library) {
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _onCompleted();
      }
      notifyListeners();
    });
    _durSub = _player.durationStream.listen((_) => notifyListeners());
    // Error de conexión a mitad de canción (por ejemplo, acceso vencido):
    // se vuelve a cargar una vez, con acceso nuevo, desde el mismo punto.
    _eventSub = _player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace _) {
      if (current == null || loading) return;
      if (!_retried) {
        _retried = true;
        _load(at: _player.position);
      } else {
        error = 'Se cortó la conexión con Drive: $e';
        notifyListeners();
      }
    });
  }

  /// El reproductor de audio (lo usa el servicio de segundo plano de Android).
  AudioPlayer get audio => _player;

  /// Hay una canción después de la actual (o se repite la cola).
  bool get hasNext => _pos < _order.length - 1 || repeat == Repeat.all;

  Track? get current =>
      (_pos >= 0 && _pos < _order.length) ? _queue[_order[_pos]] : null;
  bool get playing => _player.playing;
  Duration? get duration => _player.duration;
  Duration get position => _player.position;
  Stream<Duration> get positionStream => _player.positionStream;
  int get queuePosition => _pos;

  /// La cola en el orden en que va a sonar.
  List<Track> get upcoming => [for (final i in _order) _queue[i]];

  /// Reproduce [tracks] empezando por [start].
  /// Con aleatorio activado, empieza por [start] y el resto se mezcla.
  Future<void> playList(List<Track> tracks, int start) async {
    if (tracks.isEmpty) return;
    _queue = List.of(tracks);
    final first = start.clamp(0, tracks.length - 1);
    if (shuffle) {
      final rest = [for (var i = 0; i < _queue.length; i++) if (i != first) i]..shuffle(_rnd);
      _order = [first, ...rest];
      _pos = 0;
    } else {
      _order = [for (var i = 0; i < _queue.length; i++) i];
      _pos = first;
    }
    await _load();
  }

  /// Toda la lista en orden aleatorio.
  Future<void> playShuffled(List<Track> tracks) async {
    if (tracks.isEmpty) return;
    shuffle = true;
    _queue = List.of(tracks);
    _order = [for (var i = 0; i < _queue.length; i++) i]..shuffle(_rnd);
    _pos = 0;
    await _load();
  }

  Future<void> playAt(int orderPosition) async {
    if (orderPosition < 0 || orderPosition >= _order.length) return;
    _pos = orderPosition;
    await _load();
  }

  Future<void> togglePlay() => _player.playing ? pause() : resume();

  Future<void> pause() async {
    await _player.pause();
    notifyListeners();
  }

  Future<void> resume() async {
    if (current == null) return;
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    // Sin fuente cargada, o cargada hace mucho (el acceso a Drive dura ~1 hora):
    // se vuelve a cargar con acceso nuevo desde el mismo punto.
    final stale = !kIsWeb &&
        DateTime.now().difference(_loadedAt) > const Duration(minutes: 45);
    if (_player.processingState == ProcessingState.idle || stale) {
      await _load(at: _player.position);
      return;
    }
    unawaited(_player.play());
    notifyListeners();
  }

  Future<void> next({bool auto = false}) async {
    if (_order.isEmpty) return;
    if (_pos < _order.length - 1) {
      _pos++;
    } else if (repeat == Repeat.all) {
      if (shuffle) _order.shuffle(_rnd);
      _pos = 0;
    } else {
      if (auto) {
        await _player.pause();
        await _player.seek(Duration.zero);
        notifyListeners();
      }
      return;
    }
    await _load();
  }

  Future<void> previous() async {
    if (_order.isEmpty) return;
    if (_player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_pos > 0) {
      _pos--;
    } else if (repeat == Repeat.all) {
      _pos = _order.length - 1;
    } else {
      await _player.seek(Duration.zero);
      return;
    }
    await _load();
  }

  Future<void> seek(Duration d) => _player.seek(d);

  void toggleShuffle() {
    shuffle = !shuffle;
    if (_order.isNotEmpty && _pos >= 0) {
      final cur = _order[_pos];
      if (shuffle) {
        final rest = [for (var i = 0; i < _queue.length; i++) if (i != cur) i]..shuffle(_rnd);
        _order = [cur, ...rest];
        _pos = 0;
      } else {
        _order = [for (var i = 0; i < _queue.length; i++) i];
        _pos = cur;
      }
    }
    notifyListeners();
  }

  void cycleRepeat() {
    repeat = Repeat.values[(repeat.index + 1) % Repeat.values.length];
    notifyListeners();
  }

  Future<void> stop() async {
    _seq++;
    await _player.stop();
    _queue = [];
    _order = [];
    _pos = -1;
    loading = false;
    error = null;
    _freeBlob();
    notifyListeners();
  }

  Future<void> _onCompleted() async {
    if (repeat == Repeat.one) {
      await _player.seek(Duration.zero);
      unawaited(_player.play());
      return;
    }
    await next(auto: true);
  }

  void _freeBlob() {
    final b = _blobUrl;
    if (b != null) platform.revokeBlobUrl(b);
    _blobUrl = null;
  }

  Future<void> _load({Duration? at}) async {
    final t = current;
    if (t == null) return;
    final seq = ++_seq;
    if (at == null) _retried = false;
    loading = true;
    error = null;
    notifyListeners();
    try {
      // Sin stop(): así el servicio de segundo plano no se corta entre canciones.
      await _player.pause();
      final token = await library.store.tokenFor(t.account);
      if (seq != _seq) return;
      final url = Uri.parse(
          'https://www.googleapis.com/drive/v3/files/${t.item.id}?alt=media&supportsAllDrives=true');
      if (kIsWeb) {
        final res = await http.get(url, headers: {'Authorization': 'Bearer $token'});
        if (seq != _seq) return;
        if (res.statusCode == 401) throw NeedsReconnect();
        if (res.statusCode != 200) throw Exception('Drive respondió ${res.statusCode}');
        _freeBlob();
        final blob = platform.blobUrl(res.bodyBytes, t.item.mime);
        _blobUrl = blob;
        await _player.setAudioSource(AudioSource.uri(Uri.parse(blob)), initialPosition: at);
      } else {
        await _player.setAudioSource(
            AudioSource.uri(url, headers: {'Authorization': 'Bearer $token'}),
            initialPosition: at);
      }
      if (seq != _seq) return;
      _loadedAt = DateTime.now();
      loading = false;
      notifyListeners();
      unawaited(_player.play());
    } catch (e) {
      if (seq != _seq) return;
      loading = false;
      error = e is NeedsReconnect
          ? '${t.account.title}: hay que volver a conectar la cuenta'
          : 'No se pudo reproducir "${t.title}": $e';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _durSub?.cancel();
    _eventSub?.cancel();
    _player.dispose();
    _freeBlob();
    super.dispose();
  }
}
