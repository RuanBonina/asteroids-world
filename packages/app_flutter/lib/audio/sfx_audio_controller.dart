import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum AudioPlatformProfile { web, mobile, desktop }

enum SfxId { hit, goldDestroy, miss, gameOver, uiClickSoft }

class SfxAudioController {
  SfxAudioController({
    int sfxPoolSize = 6,
    AudioPlatformProfile platformProfile = AudioPlatformProfile.desktop,
  }) : _platformProfile = platformProfile,
       _sfxPlayers = List<AudioPlayer>.generate(
         sfxPoolSize < 1 ? 1 : sfxPoolSize,
         (i) => AudioPlayer(playerId: 'sfx_$i'),
       );

  final AudioPlatformProfile _platformProfile;
  final List<AudioPlayer> _sfxPlayers;

  final AudioPlayer _hitPlayer = AudioPlayer(playerId: 'sfx_hit');
  final AudioPlayer _missPlayer = AudioPlayer(playerId: 'sfx_miss');
  bool _mobileFastPlayersReady = false;

  int _nextSfxPlayer = 0;
  double _sfxVolume = 1.0;
  double _uiVolume = 1.0;
  final Map<SfxId, int> _lastSfxMs = <SfxId, int>{};
  int _sfxBusyUntilMs = 0;

  static const Map<SfxId, String> _sfxAssetById = <SfxId, String>{
    SfxId.hit: 'audio/sfx/hit.wav',
    SfxId.goldDestroy: 'audio/sfx/explosion_gold_asteroid.wav',
    SfxId.miss: 'audio/sfx/miss.wav',
    SfxId.gameOver: 'audio/sfx/game_over.wav',
    SfxId.uiClickSoft: 'audio/sfx/ui_click_soft.wav',
  };

  static const Map<SfxId, double> _sfxGainById = <SfxId, double>{
    SfxId.hit: 0.62,
    SfxId.goldDestroy: 0.9,
    SfxId.miss: 0.54,
    SfxId.gameOver: 0.85,
    SfxId.uiClickSoft: 0.58,
  };

  static const Map<SfxId, int> _sfxMinIntervalWebMs = <SfxId, int>{
    SfxId.hit: 360,
    SfxId.goldDestroy: 220,
    SfxId.miss: 180,
    SfxId.gameOver: 160,
    SfxId.uiClickSoft: 70,
  };

  static const Map<SfxId, int> _sfxMinIntervalDesktopMs = <SfxId, int>{
    SfxId.hit: 120,
    SfxId.goldDestroy: 200,
    SfxId.miss: 90,
    SfxId.gameOver: 160,
    SfxId.uiClickSoft: 70,
  };

  static const Map<SfxId, int> _sfxMinIntervalMobileMs = <SfxId, int>{
    SfxId.hit: 70,
    SfxId.goldDestroy: 150,
    SfxId.miss: 60,
    SfxId.gameOver: 130,
    SfxId.uiClickSoft: 60,
  };

  static const Map<SfxId, int> _sfxDurationMs = <SfxId, int>{
    SfxId.hit: 260,
    SfxId.goldDestroy: 720,
    SfxId.miss: 180,
    SfxId.gameOver: 360,
    SfxId.uiClickSoft: 70,
  };

  Future<void> init() async {
    for (final player in _sfxPlayers) {
      try {
        await player.setAudioContext(
          AudioContext(
            android: const AudioContextAndroid(
              isSpeakerphoneOn: false,
              stayAwake: false,
              contentType: AndroidContentType.sonification,
              usageType: AndroidUsageType.game,
              audioFocus: AndroidAudioFocus.gainTransientMayDuck,
            ),
            iOS: AudioContextIOS(
              category: AVAudioSessionCategory.playback,
              options: <AVAudioSessionOptions>{
                AVAudioSessionOptions.mixWithOthers,
              },
            ),
          ),
        );
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setPlayerMode(
          _platformProfile == AudioPlatformProfile.mobile
              ? PlayerMode.mediaPlayer
              : PlayerMode.lowLatency,
        );
      } catch (_) {
        // Keep app functional if audio backend fails.
      }
    }
    if (_platformProfile == AudioPlatformProfile.mobile) {
      await _prepareMobilePlayers();
    }
  }

  Future<void> setSfxVolume(double value) async {
    _sfxVolume = value.clamp(0, 1).toDouble();
  }

  Future<void> setUiVolume(double value) async {
    _uiVolume = value.clamp(0, 1).toDouble();
  }

  Future<void> playSfx(SfxId id) async {
    final path = _sfxAssetById[id];
    final channelVolume = _volumeFor(id);
    if (path == null || channelVolume <= 0.0001) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_sfxPlayers.length == 1 && now < _sfxBusyUntilMs) {
      return;
    }

    final minInterval = _sfxMinIntervalMs(id);
    final last = _lastSfxMs[id];
    if (last != null && now - last < minInterval) {
      return;
    }
    _lastSfxMs[id] = now;

    final gain = _sfxGain(id);
    final targetVolume = (channelVolume * gain).clamp(0.0, 1.0).toDouble();

    if (_platformProfile == AudioPlatformProfile.mobile &&
        (id == SfxId.hit || id == SfxId.miss)) {
      await _playMobileFastSfx(
        id: id,
        path: path,
        targetVolume: targetVolume,
        nowMs: now,
      );
      return;
    }

    await _playOnSfxPool(id: id, path: path, volume: targetVolume, nowMs: now);
  }

  Future<void> _prepareMobilePlayers() async {
    var ready = true;
    final hitPath = _sfxAssetById[SfxId.hit];
    final missPath = _sfxAssetById[SfxId.miss];

    try {
      await _hitPlayer.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.game,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: <AVAudioSessionOptions>{
              AVAudioSessionOptions.mixWithOthers,
            },
          ),
        ),
      );
      await _hitPlayer.setReleaseMode(ReleaseMode.stop);
      await _hitPlayer.setPlayerMode(PlayerMode.mediaPlayer);
      if (hitPath != null) {
        await _hitPlayer.setSource(AssetSource(hitPath));
      } else {
        ready = false;
      }
    } catch (e) {
      ready = false;
      if (kDebugMode) {
        debugPrint('SfxAudioController mobile hit prepare failed: $e');
      }
    }

    try {
      await _missPlayer.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.game,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: <AVAudioSessionOptions>{
              AVAudioSessionOptions.mixWithOthers,
            },
          ),
        ),
      );
      await _missPlayer.setReleaseMode(ReleaseMode.stop);
      await _missPlayer.setPlayerMode(PlayerMode.mediaPlayer);
      if (missPath != null) {
        await _missPlayer.setSource(AssetSource(missPath));
      } else {
        ready = false;
      }
    } catch (e) {
      ready = false;
      if (kDebugMode) {
        debugPrint('SfxAudioController mobile miss prepare failed: $e');
      }
    }

    _mobileFastPlayersReady = ready;
  }

  Future<void> _playMobileFastSfx({
    required SfxId id,
    required String path,
    required double targetVolume,
    required int nowMs,
  }) async {
    if (!_mobileFastPlayersReady) {
      await _playOnSfxPool(
        id: id,
        path: path,
        volume: targetVolume,
        nowMs: nowMs,
      );
      return;
    }

    final player = id == SfxId.hit ? _hitPlayer : _missPlayer;
    try {
      await player.setVolume(targetVolume);
      await player.stop();
      await player.seek(Duration.zero);
      await player.resume();
      return;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SfxAudioController mobile fast path failed for $id: $e');
      }
    }

    try {
      await player.play(AssetSource(path), volume: targetVolume);
      return;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SfxAudioController mobile direct play failed for $id: $e');
      }
    }

    await _playOnSfxPool(
      id: id,
      path: path,
      volume: targetVolume,
      nowMs: nowMs,
    );
  }

  Future<void> _playOnSfxPool({
    required SfxId id,
    required String path,
    required double volume,
    required int nowMs,
  }) async {
    final player = _sfxPlayers[_nextSfxPlayer];
    _nextSfxPlayer = (_nextSfxPlayer + 1) % _sfxPlayers.length;
    final duration = _sfxDurationMs[id] ?? 140;
    if (_sfxPlayers.length == 1) {
      _sfxBusyUntilMs = nowMs + duration;
    }
    try {
      await player.play(AssetSource(path), volume: volume);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SfxAudioController pool play failed for $id: $e');
      }
    }
  }

  int _sfxMinIntervalMs(SfxId id) {
    final table = switch (_platformProfile) {
      AudioPlatformProfile.web => _sfxMinIntervalWebMs,
      AudioPlatformProfile.mobile => _sfxMinIntervalMobileMs,
      AudioPlatformProfile.desktop => _sfxMinIntervalDesktopMs,
    };
    return table[id] ?? 0;
  }

  double _sfxGain(SfxId id) {
    final base = _sfxGainById[id] ?? 1.0;
    if (_platformProfile != AudioPlatformProfile.mobile) {
      return base;
    }
    final boosted = switch (id) {
      SfxId.hit => base * 1.25,
      SfxId.miss => base * 1.15,
      _ => base,
    };
    return boosted.clamp(0.0, 1.0).toDouble();
  }

  double _volumeFor(SfxId id) {
    if (id == SfxId.uiClickSoft) {
      return _uiVolume;
    }
    return _sfxVolume;
  }

  Future<void> dispose() async {
    await _hitPlayer.dispose();
    await _missPlayer.dispose();
    for (final player in _sfxPlayers) {
      await player.dispose();
    }
  }
}
