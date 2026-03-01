import 'package:audioplayers/audioplayers.dart';

class BgmAudioController {
  BgmAudioController({
    this.assetPath = 'audio/bgm/space_ambient.wav',
    double defaultVolume = 0.8,
  }) : _volume = defaultVolume.clamp(0, 1).toDouble();

  final String assetPath;
  final AudioPlayer _player = AudioPlayer(playerId: 'bgm');

  bool _initialized = false;
  bool _playing = false;
  bool _stateListenerAttached = false;
  double _volume;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    try {
      if (!_stateListenerAttached) {
        _stateListenerAttached = true;
        _player.onPlayerStateChanged.listen((state) {
          if (state == PlayerState.playing) {
            _playing = true;
            return;
          }
          _playing = false;
        });
      }
      await _player.setPlayerMode(PlayerMode.mediaPlayer);
      await _player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: false,
            contentType: AndroidContentType.music,
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
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(_volume);
      _initialized = true;
    } catch (_) {
      // Keep the game functional if the audio backend fails.
    }
  }

  Future<void> setMusicVolume(double value) async {
    _volume = value.clamp(0, 1).toDouble();
    if (!_initialized) {
      return;
    }
    try {
      await _player.setVolume(_volume);
    } catch (_) {
      // Ignore backend volume failures.
    }
  }

  Future<void> playLoop() async {
    if (!_initialized) {
      await init();
    }
    if (_volume <= 0.0001) {
      await stop();
      return;
    }
    if (_playing) {
      await setMusicVolume(_volume);
      return;
    }
    try {
      await _player.play(AssetSource(assetPath));
      _playing = true;
      await setMusicVolume(_volume);
    } catch (_) {
      _playing = false;
    }
  }

  Future<void> stop() async {
    if (!_playing) {
      return;
    }
    try {
      await _player.stop();
    } catch (_) {
      // Ignore backend stop failures.
    }
    _playing = false;
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _player.dispose();
    } catch (_) {
      // Ignore backend dispose failures.
    }
  }
}
