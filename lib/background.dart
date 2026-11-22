import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'player.dart';

/// Android: servicio de segundo plano con notificación, pantalla de bloqueo,
/// auriculares y Bluetooth. Los botones llaman al mismo reproductor de la app.
class ReproductorAudioHandler extends BaseAudioHandler with SeekHandler {
  final PlayerController c;
  StreamSubscription<PlaybackEvent>? _sub;

  ReproductorAudioHandler(this.c) {
    c.addListener(_broadcast);
    _sub = c.audio.playbackEventStream.listen((_) => _broadcast(), onError: (Object _) {});
    _broadcast();
  }

  void _broadcast() {
    final t = c.current;
    final p = c.audio;
    // Entre una canción y la siguiente se informa "cargando" (y sonando),
    // para que Android no cierre el servicio en ese instante.
    final busy = t != null &&
        (c.loading || (p.processingState == ProcessingState.completed && c.hasNext));
    final AudioProcessingState state;
    if (t == null) {
      state = AudioProcessingState.idle;
    } else if (busy) {
      state = AudioProcessingState.loading;
    } else {
      state = switch (p.processingState) {
        ProcessingState.idle => AudioProcessingState.ready,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };
    }
    final playing = t != null && (p.playing || busy);
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: state,
      playing: playing,
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
      speed: p.speed,
      queueIndex: c.queuePosition < 0 ? null : c.queuePosition,
    ));

    if (t == null) {
      if (mediaItem.value != null) mediaItem.add(null);
      return;
    }
    final old = mediaItem.value;
    if (old == null || old.id != t.item.id || old.duration != p.duration) {
      mediaItem.add(MediaItem(
        id: t.item.id,
        title: t.title,
        album: t.folder.isEmpty ? null : t.folder,
        artist: t.account.title,
        duration: p.duration,
      ));
    }
  }

  @override
  Future<void> play() => c.resume();

  @override
  Future<void> pause() => c.pause();

  @override
  Future<void> skipToNext() => c.next();

  @override
  Future<void> skipToPrevious() => c.previous();

  @override
  Future<void> seek(Duration position) => c.seek(position);

  @override
  Future<void> skipToQueueItem(int index) => c.playAt(index);

  @override
  Future<void> stop() async {
    await c.stop();
    await super.stop();
  }

  void dispose() {
    c.removeListener(_broadcast);
    _sub?.cancel();
  }
}

/// Prepara el audio del sistema. Solo Android: en Windows y en la web
/// la app reproduce igual, pero sin servicio de segundo plano.
Future<void> setupBackgroundAudio(PlayerController player) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    // Pausa sola con llamadas, otras apps de audio o al desconectar los auriculares.
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (_) {}
  try {
    await AudioService.init(
      builder: () => ReproductorAudioHandler(player),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.luchorcompartidos.reproductor.audio',
        androidNotificationChannelName: 'Reproducción',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (e) {
    debugPrint('No se pudo iniciar el servicio de audio: $e');
  }
}
