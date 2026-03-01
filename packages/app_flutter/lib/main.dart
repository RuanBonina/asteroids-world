import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:asteroids_core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'audio/bgm_audio_controller.dart';
import 'audio/sfx_audio_controller.dart';
import 'src/browser_fullscreen_stub.dart'
    if (dart.library.html) 'src/browser_fullscreen_web.dart'
    as browser_fullscreen;
import 'src/browser_close_stub.dart'
    if (dart.library.html) 'src/browser_close_web.dart'
    as browser_close;

const Color _bg = Color(0xFF000000);
const Color _panel = Color(0xFF0D0E11);
const Color _panelSoft = Color(0xFF121317);
const Color _stroke = Color(0xFF2B2E36);
const Color _text = Color(0xFFE5E7EB);
const Color _muted = Color(0xFFB7BDC8);
const double _overlayPanelMaxWidth = 560;
const double _overlayPanelHeight = 430;
const EdgeInsets _overlayPanelMargin = EdgeInsets.symmetric(horizontal: 18);
const EdgeInsets _overlayPanelPadding = EdgeInsets.all(18);

String _formatGameClock(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

bool _supportsDesktopWindowManager() {
  if (kIsWeb) {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_supportsDesktopWindowManager()) {
    await windowManager.ensureInitialized();
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Asteroids World',
      theme: ThemeData(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          surface: _panel,
          primary: _text,
          onPrimary: _bg,
        ),
      ),
      home: const ShellScreen(),
    );
  }
}

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen>
    with WindowListener, WidgetsBindingObserver {
  static const bool _useFixedSeed = bool.fromEnvironment(
    'FIXED_SEED',
    defaultValue: false,
  );
  static const int _fixedSeedValue = int.fromEnvironment(
    'FIXED_SEED_VALUE',
    defaultValue: 42,
  );

  static const String _settingsKey = 'classic.settings';
  static const int _audioSettingsVersion = 3;
  static const int _goldParticleColorArgb = 0xFFFFD700;
  static const int _defaultParticleColorArgb = 0xFFF0F0F0;

  late final Clock _clock;
  late final LocalEventBus _eventBus;
  late final SfxAudioController _audio;
  late final BgmAudioController _bgmAudio;
  final List<SubscriptionToken> _subscriptions = <SubscriptionToken>[];

  GameEngine? _engine;
  ClassicMode? _classicMode;
  Timer? _loopTimer;
  int _seed = 0;
  bool _ready = false;

  GameLifecycleState _state = GameLifecycleState.idle;
  RenderFrame _frame = const RenderFrame(
    timestampMs: 0,
    shapes: <ShapeModel>[],
    hud: HudModel(destroyed: 0, misses: 0, time: Duration.zero, paused: false),
    uiState: UiState(
      showStartScreen: true,
      showPauseModal: false,
      showQuitModal: false,
    ),
  );
  RunStatsSnapshot _stats = const RunStatsSnapshot(
    spawned: 0,
    escaped: 0,
    hits: 0,
    misses: 0,
    score: 0,
    difficultyMultiplier: 1,
    speedLevelAtStart: 3,
    difficultyAdaptiveAtStart: true,
    time: Duration.zero,
    paused: false,
  );
  RunStatsSnapshot? _lastResult;
  RunStatsSnapshot? _bestResult;
  DateTime? _bestRecordedAt;

  double _uiOpacity = 1;
  int _speedLevel = 3;
  bool _difficultyProgression = true;
  double _audioMusicVolume = 0.8;
  double _audioSfxVolume = 1.0;
  double _audioSystemVolume = 1.0;
  bool _showCustomize = false;
  bool _showQuitConfirm = false;
  Size? _lastViewportSent;
  Size? _starfieldSize;
  List<_Star> _stars = const <_Star>[];
  List<_MissPulse> _missPulses = const <_MissPulse>[];
  List<_UiParticle> _hitParticles = const <_UiParticle>[];
  Timer? _fxTimer;
  int _lastFxTickMs = 0;
  bool _isPausedUi = false;
  bool _isFullscreen = false;
  final ScrollController _settingsScrollController = ScrollController();
  Object? _browserFullscreenListenerToken;
  Timer? _sfxPreviewDebounceTimer;
  Timer? _audioSyncDebounceTimer;
  Timer? _startCountdownTimer;
  _HelpDialogData? _helpDialog;
  bool _showBestDetailsModal = false;
  bool _showExitAppConfirm = false;
  bool _isExitingApp = false;
  bool _isStarting = false;
  int _startCountdown = 0;
  bool get _disableGameplaySfxOnWeb => kIsWeb;
  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  Object? _browserCloseListenerToken;

  bool _isDesktopContext(MediaQueryData media) {
    if (_supportsDesktopWindowManager()) {
      return true;
    }
    if (kIsWeb) {
      return media.size.shortestSide >= 700;
    }
    return false;
  }

  double _settingsRightColumnWidth(double maxWidth) =>
      (maxWidth * 0.22).clamp(84.0, 112.0).toDouble();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = _StopwatchClock();
    _eventBus = LocalEventBus();
    final audioProfile = kIsWeb
        ? AudioPlatformProfile.web
        : switch (defaultTargetPlatform) {
            TargetPlatform.android ||
            TargetPlatform.iOS => AudioPlatformProfile.mobile,
            _ => AudioPlatformProfile.desktop,
          };
    _audio = SfxAudioController(
      platformProfile: audioProfile,
      sfxPoolSize: audioProfile == AudioPlatformProfile.web
          ? 1
          : audioProfile == AudioPlatformProfile.mobile
          ? 4
          : 6,
    );
    _bgmAudio = BgmAudioController(defaultVolume: _audioMusicVolume);
    unawaited(_audio.init());
    unawaited(_bgmAudio.init());
    if (_supportsDesktopWindowManager()) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    if (kIsWeb) {
      _browserFullscreenListenerToken = browser_fullscreen
          .addBrowserFullscreenListener((isFullscreen) {
            if (!mounted || _isFullscreen == isFullscreen) {
              return;
            }
            setState(() => _isFullscreen = isFullscreen);
          });
      _browserCloseListenerToken = browser_close.addBrowserCloseListener();
    }
    if (_isMobilePlatform) {
      unawaited(_applyMobileImmersiveMode());
      SystemChrome.setSystemUIChangeCallback((systemOverlaysAreVisible) async {
        if (systemOverlaysAreVisible && mounted) {
          await _applyMobileImmersiveMode();
        }
      });
    }
    unawaited(_initEngine());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isMobilePlatform && state == AppLifecycleState.resumed) {
      unawaited(_applyMobileImmersiveMode());
    }
  }

  Future<void> _initEngine() async {
    Storage storage;
    try {
      final prefs = await SharedPreferences.getInstance();
      storage = _SharedPrefsStorage(prefs);
    } catch (_) {
      storage = _MemoryStorage();
    }
    var shouldResetLegacyAudioSettings = false;
    final savedSettings = await storage.read(_settingsKey);
    if (savedSettings is Map) {
      _uiOpacity = ((savedSettings['uiOpacity'] as num?) ?? 1).toDouble().clamp(
        0.2,
        1,
      );
      _speedLevel = ((savedSettings['speedLevel'] as num?) ?? 3).toInt().clamp(
        1,
        5,
      );
      _difficultyProgression =
          (savedSettings['difficultyProgression'] as bool?) ?? true;
      final savedAudioVersion =
          (savedSettings['audioSettingsVersion'] as num?)?.toInt() ?? 0;
      _audioMusicVolume = ((savedSettings['audioMusicVolume'] as num?) ?? 0.8)
          .toDouble()
          .clamp(0, 1);
      _audioSfxVolume = ((savedSettings['audioSfxVolume'] as num?) ?? 1.0)
          .toDouble()
          .clamp(0, 1);
      _audioSystemVolume = ((savedSettings['audioSystemVolume'] as num?) ?? 1.0)
          .toDouble()
          .clamp(0, 1);
      shouldResetLegacyAudioSettings =
          savedSettings['audioMasterVolume'] != null ||
          savedSettings['bgmVolume'] != null;
      if (savedAudioVersion < _audioSettingsVersion &&
          savedSettings['audioSystemVolume'] == null) {
        _audioSystemVolume = 1.0;
      }
    }
    if (shouldResetLegacyAudioSettings) {
      _audioMusicVolume = 0.8;
      _audioSfxVolume = 1.0;
      _audioSystemVolume = 1.0;
      await _saveSettings();
    }
    unawaited(_syncAudioSettings());
    unawaited(_syncBgmFromStateAndVolume());

    _seed = _useFixedSeed ? _fixedSeedValue : Random().nextInt(1 << 31);
    final mode = ClassicMode(
      config: const ClassicConfig(width: 360, height: 640),
    );
    final engine = GameEngine(
      clock: _clock,
      rng: SeededRng(_seed),
      storage: storage,
      eventBus: _eventBus,
      world: EcsWorld(),
      mode: mode,
    );

    _subscriptions.addAll(<SubscriptionToken>[
      _eventBus.subscribe(RenderFrameReady, (event) {
        if (!mounted) {
          return;
        }
        setState(() => _frame = (event as RenderFrameReady).frame);
      }),
      _eventBus.subscribe(GameStateChanged, (event) {
        if (!mounted) {
          return;
        }
        final changed = event as GameStateChanged;
        final state = changed.current;
        setState(() {
          _state = state;
          _isPausedUi = state == GameLifecycleState.paused;
        });
        unawaited(_syncBgmFromStateAndVolume());
      }),
      _eventBus.subscribe(HitMissed, (event) {
        if (!mounted) {
          return;
        }
        _spawnMissFeedback(event as HitMissed);
        if (!_disableGameplaySfxOnWeb) {
          unawaited(_audio.playSfx(SfxId.miss));
        }
      }),
      _eventBus.subscribe(AsteroidDestroyed, (event) {
        if (!_disableGameplaySfxOnWeb) {
          final destroyed = event as AsteroidDestroyed;
          unawaited(_audio.playSfx(_sfxForAsteroidKind(destroyed.kind)));
        }
      }),
      _eventBus.subscribe(ParticlesRequested, (event) {
        if (!mounted) {
          return;
        }
        final fx = event as ParticlesRequested;
        _spawnHitParticles(fx);
      }),
      _eventBus.subscribe(StatsUpdated, (event) {
        if (!mounted) {
          return;
        }
        setState(() => _stats = (event as StatsUpdated).stats);
      }),
    ]);

    _publishSettings();
    _loopTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => engine.tick(),
    );

    await mode.loadLastResultTask;
    if (!mounted) {
      _loopTimer?.cancel();
      engine.dispose();
      return;
    }

    setState(() {
      _classicMode = mode;
      _engine = engine;
      _lastResult = mode.lastLoadedResult;
      _bestResult = mode.bestLoadedResult;
      _bestRecordedAt = mode.bestRecordedAt;
      _stars = _generateStarfield(_lastViewportSent ?? const Size(360, 640));
      _ready = true;
    });
  }

  void _publishSettings() {
    _eventBus.publish(
      GameSettingsUpdatedRequested(
        uiOpacity: _uiOpacity,
        asteroidSpeedLevel: _speedLevel,
        difficultyProgression: _difficultyProgression,
      ),
    );
  }

  Future<void> _saveSettings() async {
    Storage storage;
    try {
      final prefs = await SharedPreferences.getInstance();
      storage = _SharedPrefsStorage(prefs);
    } catch (_) {
      storage = _MemoryStorage();
    }
    await storage.write(_settingsKey, <String, Object>{
      'uiOpacity': _uiOpacity,
      'speedLevel': _speedLevel,
      'difficultyProgression': _difficultyProgression,
      'audioSettingsVersion': _audioSettingsVersion,
      'audioMusicVolume': _audioMusicVolume,
      'audioSfxVolume': _audioSfxVolume,
      'audioSystemVolume': _audioSystemVolume,
    });
  }

  Future<void> _syncAudioSettings() async {
    await _audio.setSfxVolume(_audioSfxVolume);
    await _audio.setUiVolume(_audioSystemVolume);
    await _bgmAudio.setMusicVolume(_audioMusicVolume);
  }

  bool get _shouldPlayBgm {
    if (_audioMusicVolume <= 0.0001) {
      return false;
    }
    if (_isPausedUi || _state == GameLifecycleState.paused) {
      return false;
    }
    return _state == GameLifecycleState.idle ||
        _state == GameLifecycleState.quit ||
        _state == GameLifecycleState.running;
  }

  Future<void> _syncBgmFromStateAndVolume() async {
    if (!_shouldPlayBgm) {
      await _bgmAudio.stop();
      return;
    }
    await _bgmAudio.playLoop();
  }

  void _scheduleAudioSync({bool syncBgm = false}) {
    _audioSyncDebounceTimer?.cancel();
    _audioSyncDebounceTimer = Timer(const Duration(milliseconds: 75), () {
      unawaited(_syncAudioSettings());
      if (syncBgm) {
        unawaited(_syncBgmFromStateAndVolume());
      }
    });
  }

  void _debouncedSfxPreview() {
    _sfxPreviewDebounceTimer?.cancel();
    _sfxPreviewDebounceTimer = Timer(const Duration(milliseconds: 140), () {
      unawaited(_audio.playSfx(SfxId.hit));
    });
  }

  void _playUiClick() {
    if (_audioSystemVolume <= 0.0001) {
      return;
    }
    unawaited(_audio.playSfx(SfxId.uiClickSoft));
  }

  SfxId _sfxForAsteroidKind(AsteroidKind kind) {
    return switch (kind) {
      AsteroidKind.gold => SfxId.goldDestroy,
      AsteroidKind.normal => SfxId.hit,
    };
  }

  _ParticlePreset _particlePresetForAsteroidKind(AsteroidKind kind) {
    return switch (kind) {
      AsteroidKind.gold => const _ParticlePreset(
        shape: _UiParticleShape.square,
        colorArgb: _goldParticleColorArgb,
        countMin: 16,
        countRange: 10,
        sizeMin: 0.9,
        sizeRange: 1.5,
      ),
      AsteroidKind.normal => const _ParticlePreset(
        shape: _UiParticleShape.circle,
        colorArgb: _defaultParticleColorArgb,
        countMin: 14,
        countRange: 8,
        sizeMin: 1.1,
        sizeRange: 2.2,
      ),
    };
  }

  @override
  void dispose() {
    _loopTimer?.cancel();
    _fxTimer?.cancel();
    _sfxPreviewDebounceTimer?.cancel();
    _audioSyncDebounceTimer?.cancel();
    _startCountdownTimer?.cancel();
    unawaited(_audio.dispose());
    unawaited(_bgmAudio.dispose());
    _settingsScrollController.dispose();
    if (_supportsDesktopWindowManager()) {
      windowManager.removeListener(this);
    }
    WidgetsBinding.instance.removeObserver(this);
    if (_isMobilePlatform) {
      SystemChrome.setSystemUIChangeCallback(null);
    }
    browser_fullscreen.removeBrowserFullscreenListener(
      _browserFullscreenListenerToken,
    );
    _browserFullscreenListenerToken = null;
    browser_close.removeBrowserCloseListener(_browserCloseListenerToken);
    _browserCloseListenerToken = null;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _engine?.dispose();
    super.dispose();
  }

  void _onStart() {
    if (_isStarting) {
      return;
    }
    final viewport = _lastViewportSent ?? MediaQuery.sizeOf(context);
    _audioSyncDebounceTimer?.cancel();
    _publishSettings();
    unawaited(_syncAudioSettings());
    if (!kIsWeb) {
      _playUiClick();
    }
    setState(() {
      _isStarting = true;
      _startCountdown = 3;
      _isPausedUi = false;
      _missPulses = const <_MissPulse>[];
      _hitParticles = const <_UiParticle>[];
    });
    _eventBus.publish(
      GameViewportChangedRequested(
        width: viewport.width,
        height: viewport.height,
      ),
    );
    _startCountdownTimer?.cancel();
    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        _startCountdownTimer = null;
        return;
      }
      if (_startCountdown <= 1) {
        timer.cancel();
        _startCountdownTimer = null;
        setState(() {
          _isStarting = false;
          _startCountdown = 0;
        });
        _eventBus.publish(const GameStartRequested());
        return;
      }
      setState(() => _startCountdown -= 1);
    });
  }

  void _spawnMissFeedback(HitMissed event) {
    final pulse = _MissPulse(
      x: event.x,
      y: event.y,
      totalMs: 220,
      remainingMs: 220,
    );
    setState(() {
      _missPulses = <_MissPulse>[..._missPulses, pulse];
    });
    _ensureFxLoop();
  }

  void _spawnHitParticles(ParticlesRequested event) {
    if (event.kind != 'asteroid-hit') {
      return;
    }
    final preset = _particlePresetForAsteroidKind(event.asteroidKind);
    final rng = Random(
      _seed ^ event.x.round() ^ event.y.round() ^ _clock.nowMs,
    );
    final spawned = <_UiParticle>[];
    final count = preset.countMin + rng.nextInt(preset.countRange);
    for (var i = 0; i < count; i++) {
      final angle = rng.nextDouble() * pi * 2;
      final speed = 70 + rng.nextDouble() * 180;
      final life = 240 + rng.nextInt(260);
      spawned.add(
        _UiParticle(
          x: event.x,
          y: event.y,
          vx: cos(angle) * speed,
          vy: sin(angle) * speed,
          size: preset.sizeMin + rng.nextDouble() * preset.sizeRange,
          colorArgb: preset.colorArgb,
          shape: preset.shape,
          totalMs: life,
          remainingMs: life,
        ),
      );
    }
    setState(() {
      _hitParticles = <_UiParticle>[..._hitParticles, ...spawned];
    });
    _ensureFxLoop();
  }

  void _ensureFxLoop() {
    if (_fxTimer != null) {
      return;
    }
    _lastFxTickMs = _clock.nowMs;
    _fxTimer = Timer.periodic(const Duration(milliseconds: 16), _tickFx);
  }

  void _tickFx(Timer timer) {
    if (!mounted) {
      timer.cancel();
      _fxTimer = null;
      return;
    }
    if (_hitParticles.isEmpty && _missPulses.isEmpty) {
      timer.cancel();
      _fxTimer = null;
      return;
    }
    final now = _clock.nowMs;
    final dtMs = (now - _lastFxTickMs).clamp(1, 50);
    _lastFxTickMs = now;
    final dtSec = dtMs / 1000.0;

    final nextParticles = <_UiParticle>[];
    for (final p in _hitParticles) {
      final left = p.remainingMs - dtMs;
      if (left <= 0) {
        continue;
      }
      nextParticles.add(
        _UiParticle(
          x: p.x + (p.vx * dtSec),
          y: p.y + (p.vy * dtSec),
          vx: p.vx * 0.97,
          vy: (p.vy * 0.97) + (12 * dtSec),
          size: p.size,
          colorArgb: p.colorArgb,
          shape: p.shape,
          totalMs: p.totalMs,
          remainingMs: left,
        ),
      );
    }

    final nextPulses = <_MissPulse>[];
    for (final pulse in _missPulses) {
      final left = pulse.remainingMs - dtMs;
      if (left <= 0) {
        continue;
      }
      nextPulses.add(
        _MissPulse(
          x: pulse.x,
          y: pulse.y,
          totalMs: pulse.totalMs,
          remainingMs: left,
        ),
      );
    }

    setState(() {
      _hitParticles = nextParticles;
      _missPulses = nextPulses;
    });
  }

  void _onPauseToggle() {
    _playUiClick();
    setState(() => _isPausedUi = !_isPausedUi);
    if (_isPausedUi) {
      unawaited(_bgmAudio.stop());
    } else {
      unawaited(_syncBgmFromStateAndVolume());
    }
    _eventBus.publish(const GamePauseToggleRequested());
  }

  void _onQuitRequested() {
    _playUiClick();
    setState(() {
      _showQuitConfirm = true;
    });
    if (_state == GameLifecycleState.running) {
      _eventBus.publish(const GamePauseToggleRequested());
    }
  }

  Future<void> _confirmQuit() async {
    setState(() => _showQuitConfirm = false);
    _playUiClick();
    unawaited(_audio.playSfx(SfxId.gameOver));
    final mode = _classicMode;
    final engine = _engine;
    if (engine != null) {
      _eventBus.publish(const GameQuitRequested());
      engine.dispose();
      await mode?.saveLastResultTask;
      _loopTimer?.cancel();
      _loopTimer = null;
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _subscriptions.clear();
      _engine = null;
      _classicMode = null;
      if (mounted) {
        setState(() => _ready = false);
      }
      await _initEngine();
    }
  }

  void _cancelQuit() {
    _playUiClick();
    setState(() => _showQuitConfirm = false);
    if (_state == GameLifecycleState.paused) {
      _eventBus.publish(const GamePauseToggleRequested());
    }
  }

  Future<void> _toggleFullscreen() async {
    _playUiClick();
    final next = !_isFullscreen;
    if (_supportsDesktopWindowManager()) {
      await windowManager.setFullScreen(next);
      if (mounted) {
        setState(() => _isFullscreen = next);
      }
      return;
    }

    if (kIsWeb) {
      await browser_fullscreen.setBrowserFullscreen(next);
      if (mounted) {
        setState(() => _isFullscreen = next);
      }
      return;
    }

    await _applyMobileImmersiveMode();
  }

  Future<void> _applyMobileImmersiveMode() async {
    if (!_isMobilePlatform) {
      return;
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (mounted && !_isFullscreen) {
      setState(() => _isFullscreen = true);
    }
  }

  Future<void> _applySettings() async {
    _audioSyncDebounceTimer?.cancel();
    _publishSettings();
    await _syncAudioSettings();
    await _syncBgmFromStateAndVolume();
    _playUiClick();
    await _saveSettings();
    setState(() => _showCustomize = false);
  }

  void _publishPointer(TapDownDetails details) {
    if (_state != GameLifecycleState.running) {
      return;
    }
    _eventBus.publish(
      InputPointerDown(
        x: details.localPosition.dx,
        y: details.localPosition.dy,
        timestampMs: _clock.nowMs,
      ),
    );
  }

  void _syncViewport(Size size) {
    final viewportUnchanged =
        _lastViewportSent != null &&
        (_lastViewportSent!.width - size.width).abs() < 0.5 &&
        (_lastViewportSent!.height - size.height).abs() < 0.5;
    final starfieldOutdated =
        _starfieldSize == null ||
        (_starfieldSize!.width - size.width).abs() >= 0.5 ||
        (_starfieldSize!.height - size.height).abs() >= 0.5;
    if (viewportUnchanged && !starfieldOutdated) {
      return;
    }
    _lastViewportSent = size;

    if (starfieldOutdated) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _starfieldSize = size;
          _stars = _generateStarfield(size);
        });
      });
    }

    if (_engine == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _eventBus.publish(
        GameViewportChangedRequested(width: size.width, height: size.height),
      );
    });
  }

  List<_Star> _generateStarfield(Size size) {
    final rng = Random(_seed ^ _clock.nowMs);
    final area = size.width * size.height;
    final shortest = size.shortestSide;
    final longest = size.longestSide;
    final densityDivisor = shortest >= 900
        ? 6500.0
        : shortest >= 700
        ? 8000.0
        : 10500.0;
    final largeScreenBoost = longest >= 1400 ? 1.2 : 1.0;
    final count = ((area / densityDivisor) * largeScreenBoost)
        .clamp(80, 460)
        .toInt();
    final out = <_Star>[];
    for (var i = 0; i < count; i++) {
      out.add(
        _Star(
          x: rng.nextDouble() * size.width,
          y: rng.nextDouble() * size.height,
          radius: rng.nextDouble() < 0.82 ? 1.0 : 1.6,
          alpha: 0.35 + rng.nextDouble() * 0.55,
        ),
      );
    }
    return out;
  }

  int _accuracyPercent(RunStatsSnapshot run) {
    final clicks = run.hits + run.misses;
    return clicks == 0 ? 0 : ((run.hits / clicks) * 100).round();
  }

  void _requestAppExitConfirm() {
    if (_showExitAppConfirm || _isExitingApp) {
      return;
    }
    if (_showBestDetailsModal) {
      setState(() => _showBestDetailsModal = false);
      return;
    }
    if (_helpDialog != null) {
      _closeHelp();
      return;
    }
    if (_showQuitConfirm) {
      _cancelQuit();
      return;
    }
    if (_showCustomize) {
      setState(() => _showCustomize = false);
      return;
    }
    setState(() => _showExitAppConfirm = true);
  }

  Future<void> _confirmAppExit() async {
    if (_isExitingApp) {
      return;
    }
    _playUiClick();
    setState(() {
      _showExitAppConfirm = false;
      _isExitingApp = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 16));
    try {
      if (_supportsDesktopWindowManager()) {
        await windowManager.setPreventClose(false);
        await windowManager.close();
        return;
      }
      if (kIsWeb) {
        await browser_close.closeWebApp();
        if (mounted) {
          setState(() => _isExitingApp = false);
        }
        return;
      }
      unawaited(SystemNavigator.pop());
    } catch (_) {
      if (mounted) {
        setState(() => _isExitingApp = false);
      }
    }
  }

  void _cancelAppExit() {
    if (!_showExitAppConfirm || _isExitingApp) {
      return;
    }
    _playUiClick();
    setState(() => _showExitAppConfirm = false);
  }

  void _openCustomize() {
    if (_isStarting) {
      return;
    }
    _playUiClick();
    setState(() => _showCustomize = true);
  }

  void _closeCustomize() {
    _playUiClick();
    setState(() => _showCustomize = false);
  }

  void _openBestDetails() {
    if (_bestResult == null) {
      return;
    }
    _playUiClick();
    setState(() => _showBestDetailsModal = true);
  }

  void _closeBestDetails() {
    if (!_showBestDetailsModal) {
      return;
    }
    _playUiClick();
    setState(() => _showBestDetailsModal = false);
  }

  @override
  void onWindowClose() {
    _requestAppExitConfirm();
  }

  String _formatDateTimePtBr(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year.toString();
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m/$y $h:$min';
  }

  Widget _buildLastRunSummary(RunStatsSnapshot? run) {
    final title = const Text(
      'Última partida',
      style: TextStyle(color: _text, fontSize: 17, fontWeight: FontWeight.w700),
    );
    if (run == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          title,
          const SizedBox(height: 4),
          const Text(
            '(ainda não registrada)',
            style: TextStyle(color: _muted, fontSize: 15),
          ),
        ],
      );
    }

    final acc = _accuracyPercent(run);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        title,
        const SizedBox(height: 4),
        Text(
          'Pontuação: ${run.score}\n'
          'Destruídos: ${run.hits}\n'
          'Fugas: ${run.escaped}\n'
          'Cliques errados: ${run.misses}\n'
          'Precisão: $acc%\n'
          'Tempo: ${_formatGameClock(run.time)}',
          style: const TextStyle(color: _text, fontSize: 15, height: 1.3),
        ),
      ],
    );
  }

  Widget _buildBestRunSummary() {
    final title = Row(
      children: <Widget>[
        const Text(
          'Melhor desempenho',
          style: TextStyle(
            color: _text,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          onTap: _bestResult == null ? null : _openBestDetails,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF191B21),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _stroke),
            ),
            child: Text(
              'i',
              style: TextStyle(
                color: _bestResult == null ? const Color(0xFF5D6470) : _muted,
                fontSize: 11,
                height: 1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
    final run = _bestResult;
    if (run == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          title,
          const SizedBox(height: 4),
          const Text(
            '(ainda não registrado)',
            style: TextStyle(color: _muted, fontSize: 15),
          ),
        ],
      );
    }

    final date = _bestRecordedAt == null
        ? '-'
        : _formatDateTimePtBr(_bestRecordedAt!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        title,
        const SizedBox(height: 4),
        Text(
          'Pontuação: ${run.score}\n'
          'Tempo: ${_formatGameClock(run.time)}\n'
          'Recorde em: $date',
          style: const TextStyle(color: _text, fontSize: 15, height: 1.3),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(color: _text),
              SizedBox(height: 12),
              Text('Carregando...', style: const TextStyle(color: _muted)),
            ],
          ),
        ),
      );
    }

    final showCustomize = _showCustomize;
    final showStart =
        !showCustomize &&
        (_state == GameLifecycleState.idle ||
            _state == GameLifecycleState.quit);
    final isDesktopContext = _isDesktopContext(MediaQuery.of(context));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _requestAppExitConfirm();
        }
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: LayoutBuilder(
          builder: (context, constraints) {
            _syncViewport(Size(constraints.maxWidth, constraints.maxHeight));
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  child: MouseRegion(
                    cursor: (!showStart && !showCustomize)
                        ? SystemMouseCursors.precise
                        : SystemMouseCursors.basic,
                    child: GestureDetector(
                      onTapDown: _publishPointer,
                      child: CustomPaint(
                        painter: _FramePainter(
                          _frame,
                          _stars,
                          _hitParticles,
                          _missPulses,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                if (!showStart && !showCustomize)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Opacity(
                      opacity: _uiOpacity,
                      child: _HudBar(stats: _stats),
                    ),
                  ),
                if (!showStart && !showCustomize)
                  Positioned(
                    top: 10,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: _uiOpacity,
                        child: Center(
                          child: Container(
                            margin: EdgeInsets.symmetric(
                              horizontal: isDesktopContext ? 84 : 112,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.28),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _stroke.withValues(alpha: 0.6),
                              ),
                            ),
                            child: Text(
                              'Pontuação: ${_stats.score}',
                              style: const TextStyle(
                                color: _text,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!showStart && !showCustomize)
                  Positioned(
                    top: 16,
                    right: isDesktopContext ? 62 : 12,
                    child: Opacity(
                      opacity: _uiOpacity,
                      child: Row(
                        children: <Widget>[
                          _IconPill(
                            icon: _isPausedUi ? Icons.play_arrow : Icons.pause,
                            onTap: _onPauseToggle,
                            compact: true,
                          ),
                          const SizedBox(width: 8),
                          _IconPill(
                            icon: Icons.close,
                            onTap: _onQuitRequested,
                            compact: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (showStart) _buildStartOverlay(),
                if (showCustomize) _buildSettingsModal(),
                if (_showQuitConfirm) _buildQuitConfirmModal(),
                if (_showExitAppConfirm) _buildExitAppConfirmModal(),
                if (_isExitingApp)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Color(0x77000000),
                      child: Center(
                        child: Text(
                          'Fechando...',
                          style: TextStyle(
                            color: _text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_helpDialog != null) _buildHelpOverlay(_helpDialog!),
                if (_showBestDetailsModal) _buildBestDetailsModal(),
                if (isDesktopContext)
                  Positioned(
                    top: 16,
                    right: 12,
                    child: Opacity(
                      opacity: (showStart || showCustomize) ? 1 : _uiOpacity,
                      child: _IconPill(
                        icon: _isFullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        onTap: _toggleFullscreen,
                        compact: true,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _overlayPanel({required Widget child}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _overlayPanelMaxWidth),
      child: Container(
        margin: _overlayPanelMargin,
        height: _overlayPanelHeight,
        padding: _overlayPanelPadding,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.74),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _stroke, width: 1),
        ),
        child: child,
      ),
    );
  }

  Widget _buildStartOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.52),
        child: Align(
          alignment: Alignment.center,
          child: _overlayPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Asteroids World',
                        style: TextStyle(
                          color: _text,
                          fontSize: 40,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                    _IconPill(
                      icon: Icons.settings,
                      onTap: _openCustomize,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Destrua o asteroide antes que ele fuja da tela.',
                  style: TextStyle(color: _muted, fontSize: 20),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _panelSoft,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _stroke),
                    ),
                    child: SingleChildScrollView(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final stacked = constraints.maxWidth < 430;
                          if (stacked) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                _buildLastRunSummary(_lastResult),
                                const SizedBox(height: 12),
                                _buildBestRunSummary(),
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Expanded(
                                child: _buildLastRunSummary(_lastResult),
                              ),
                              const SizedBox(width: 16),
                              Expanded(child: _buildBestRunSummary()),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _text,
                      enableFeedback: false,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(
                        color: Color(0xFF5A6070),
                        width: 1.2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      backgroundColor: const Color(0xFF17181C),
                    ),
                    onPressed: _isStarting ? null : _onStart,
                    child: Text(
                      _isStarting
                          ? 'Iniciando em $_startCountdown...'
                          : 'Iniciar',
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (_isStarting)
                  const Text(
                    'Preparando partida e áudio...',
                    style: TextStyle(color: _muted, height: 1.35, fontSize: 14),
                  ),
                if (_isStarting) const SizedBox(height: 8),
                const Text(
                  '- 1 hit kill • 1 asteroide por vez\n- Clique para destruir',
                  style: TextStyle(color: _muted, height: 1.35, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsModal() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.52),
        child: Center(
          child: _overlayPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Personalizar',
                        style: TextStyle(
                          color: _text,
                          fontSize: 40,
                          fontWeight: FontWeight.w700,
                          height: 1,
                        ),
                      ),
                    ),
                    _IconPill(
                      icon: Icons.arrow_back,
                      onTap: _closeCustomize,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: Scrollbar(
                    controller: _settingsScrollController,
                    thumbVisibility: true,
                    thickness: 6,
                    radius: const Radius.circular(8),
                    child: SingleChildScrollView(
                      controller: _settingsScrollController,
                      padding: const EdgeInsets.only(right: 20),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final rightColWidth = _settingsRightColumnWidth(
                            constraints.maxWidth,
                          );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'Aparência',
                                style: TextStyle(
                                  color: _text,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _SliderRow(
                                label: 'Transparência da UI',
                                value: _uiOpacity * 100,
                                min: 20,
                                max: 100,
                                divisions: 4,
                                suffix: '${(_uiOpacity * 100).round()}%',
                                valueColumnWidth: rightColWidth,
                                onInfoTap: () => _showHelp(
                                  title: 'Transparência da UI',
                                  message:
                                      'Define o quanto visíveis ficam os elementos da interface durante a partida.',
                                ),
                                onChanged: (v) => setState(
                                  () => _uiOpacity = (v / 100).clamp(0.2, 1),
                                ),
                              ),
                              const SizedBox(height: 18),
                              const Text(
                                'Jogabilidade',
                                style: TextStyle(
                                  color: _text,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _SliderRow(
                                label: 'Velocidade',
                                value: _speedLevel.toDouble(),
                                min: 1,
                                max: 5,
                                divisions: 4,
                                suffix: 'Nível $_speedLevel',
                                valueColumnWidth: rightColWidth,
                                onInfoTap: () => _showHelp(
                                  title: 'Velocidade',
                                  message:
                                      'Controla a velocidade base dos asteroides. Nível maior deixa o jogo mais rápido.',
                                ),
                                onChanged: (v) => setState(
                                  () => _speedLevel = v.round().clamp(1, 5),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: _FieldLabel(
                                      label: 'Dificuldade adaptativa',
                                      onInfoTap: () => _showHelp(
                                        title: 'Dificuldade adaptativa',
                                        message:
                                            'Quando ligado, a dificuldade aumenta ao longo do tempo da partida.',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SizedBox(
                                    width: rightColWidth,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: Switch(
                                        value: _difficultyProgression,
                                        activeThumbColor: Colors.white,
                                        activeTrackColor: const Color(
                                          0xFF178BDE,
                                        ),
                                        inactiveThumbColor: Colors.white,
                                        inactiveTrackColor: const Color(
                                          0xFF2A2D34,
                                        ),
                                        onChanged: (v) => setState(
                                          () => _difficultyProgression = v,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 18),
                              const Text(
                                'Áudio',
                                style: TextStyle(
                                  color: _text,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _SliderRow(
                                label: 'Música',
                                value: _audioMusicVolume * 100,
                                min: 0,
                                max: 100,
                                divisions: 20,
                                suffix: '${(_audioMusicVolume * 100).round()}%',
                                valueColumnWidth: rightColWidth,
                                onInfoTap: () => _showHelp(
                                  title: 'Música',
                                  message:
                                      'Controla o volume da trilha ambiente do jogo.',
                                ),
                                onChanged: (v) {
                                  setState(
                                    () => _audioMusicVolume = (v / 100).clamp(
                                      0,
                                      1,
                                    ),
                                  );
                                  _scheduleAudioSync(syncBgm: true);
                                },
                              ),
                              const SizedBox(height: 12),
                              _SliderRow(
                                label: 'Sistema',
                                value: _audioSystemVolume * 100,
                                min: 0,
                                max: 100,
                                divisions: 20,
                                suffix:
                                    '${(_audioSystemVolume * 100).round()}%',
                                valueColumnWidth: rightColWidth,
                                onInfoTap: () => _showHelp(
                                  title: 'Sistema',
                                  message:
                                      'Controla o volume dos cliques dos botões da interface.',
                                ),
                                onChanged: (v) {
                                  setState(
                                    () => _audioSystemVolume = (v / 100).clamp(
                                      0,
                                      1,
                                    ),
                                  );
                                  unawaited(
                                    _audio.setUiVolume(_audioSystemVolume),
                                  );
                                  _scheduleAudioSync();
                                  _playUiClick();
                                },
                              ),
                              const SizedBox(height: 12),
                              _SliderRow(
                                label: 'Efeitos',
                                value: _audioSfxVolume * 100,
                                min: 0,
                                max: 100,
                                divisions: 20,
                                suffix: '${(_audioSfxVolume * 100).round()}%',
                                valueColumnWidth: rightColWidth,
                                onInfoTap: () => _showHelp(
                                  title: 'Efeitos',
                                  message:
                                      'Controla o volume dos efeitos sonoros de gameplay e interface.',
                                ),
                                onChanged: (v) {
                                  setState(
                                    () =>
                                        _audioSfxVolume = (v / 100).clamp(0, 1),
                                  );
                                  _scheduleAudioSync();
                                  _debouncedSfxPreview();
                                },
                              ),
                              const SizedBox(height: 4),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _text,
                      enableFeedback: false,
                      backgroundColor: const Color(0xFF17181C),
                      side: const BorderSide(color: _stroke),
                      minimumSize: const Size.fromHeight(56),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: _applySettings,
                    child: const Text(
                      'Aplicar alterações',
                      style: TextStyle(fontSize: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showHelp({required String title, required String message}) {
    _playUiClick();
    setState(() {
      _helpDialog = _HelpDialogData(title: title, message: message);
    });
  }

  void _closeHelp() {
    if (_helpDialog == null) {
      return;
    }
    _playUiClick();
    setState(() => _helpDialog = null);
  }

  Widget _buildHelpOverlay(_HelpDialogData dialog) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closeHelp,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.45),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              margin: const EdgeInsets.symmetric(horizontal: 18),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F1116),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _stroke),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    dialog.title,
                    style: const TextStyle(
                      color: _text,
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    dialog.message,
                    style: const TextStyle(color: _muted, height: 1.35),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Toque em qualquer lugar para fechar.',
                    style: TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBestDetailsModal() {
    final run = _bestResult;
    if (run == null) {
      return const SizedBox.shrink();
    }
    final acc = _accuracyPercent(run);
    final recordedAt = _bestRecordedAt == null
        ? '-'
        : _formatDateTimePtBr(_bestRecordedAt!);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closeBestDetails,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 430),
              margin: const EdgeInsets.symmetric(horizontal: 18),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F1116),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _stroke),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'Melhor desempenho',
                          style: TextStyle(
                            color: _text,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _IconPill(
                        icon: Icons.close,
                        onTap: _closeBestDetails,
                        compact: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Pontuação: ${run.score}\n'
                    'Destruídos: ${run.hits}\n'
                    'Fugas: ${run.escaped}\n'
                    'Cliques errados: ${run.misses}\n'
                    'Precisão: $acc%\n'
                    'Tempo: ${_formatGameClock(run.time)}\n'
                    'Dificuldade jogada: Nível ${run.speedLevelAtStart}\n'
                    'Dificuldade adaptativa: ${run.difficultyAdaptiveAtStart ? "Ligada" : "Desligada"}\n'
                    'Recorde em: $recordedAt',
                    style: const TextStyle(color: _text, height: 1.35),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Toque fora do modal para fechar.',
                    style: TextStyle(color: _muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQuitConfirmModal() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.65),
        child: Center(
          child: Container(
            width: 340,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _stroke),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Encerrar partida?',
                        style: TextStyle(
                          color: _text,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _IconPill(
                      icon: Icons.close,
                      onTap: _cancelQuit,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Seu desempenho será salvo como "Última partida".',
                  style: TextStyle(color: _muted),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _text,
                          enableFeedback: false,
                          side: const BorderSide(color: _stroke),
                        ),
                        onPressed: _cancelQuit,
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _text,
                          enableFeedback: false,
                          side: const BorderSide(color: _stroke),
                          backgroundColor: const Color(0xFF2A1517),
                        ),
                        onPressed: _confirmQuit,
                        child: const Text('Encerrar'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExitAppConfirmModal() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.65),
        child: Center(
          child: Container(
            width: 340,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _stroke),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Fechar jogo?',
                        style: TextStyle(
                          color: _text,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    _IconPill(
                      icon: Icons.close,
                      onTap: _cancelAppExit,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tem certeza que deseja sair do Asteroids World?',
                  style: TextStyle(color: _muted),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _text,
                          enableFeedback: false,
                          side: const BorderSide(color: _stroke),
                        ),
                        onPressed: _isExitingApp ? null : _cancelAppExit,
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _text,
                          enableFeedback: false,
                          side: const BorderSide(color: _stroke),
                          backgroundColor: const Color(0xFF2A1517),
                        ),
                        onPressed: _isExitingApp ? null : _confirmAppExit,
                        child: const Text('Fechar'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HudBar extends StatelessWidget {
  const _HudBar({required this.stats});

  final RunStatsSnapshot stats;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Destruídos: ${stats.hits}\nFugas: ${stats.escaped}\nTempo: ${_formatGameClock(stats.time)}\n${stats.paused ? "PAUSADO" : "ATIVO"}',
      style: const TextStyle(color: _text, fontSize: 12, height: 1.25),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.valueColumnWidth,
    required this.onChanged,
    this.onInfoTap,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final double valueColumnWidth;
  final ValueChanged<double> onChanged;
  final VoidCallback? onInfoTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _InlineLabelWithInfo(label: label, onInfoTap: onInfoTap),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: valueColumnWidth,
              child: Text(
                suffix,
                textAlign: TextAlign.right,
                style: const TextStyle(color: _muted, fontSize: 18),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFF178BDE),
            inactiveTrackColor: const Color(0xFF2B2E36),
            thumbColor: const Color(0xFF178BDE),
            overlayColor: const Color(0x33178BDE),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _IconPill extends StatelessWidget {
  const _IconPill({
    required this.icon,
    required this.onTap,
    this.compact = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const radius = 14.0;
    return Material(
      color: const Color(0xFF121419),
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        onTap: onTap,
        enableFeedback: false,
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: compact ? 42 : 48,
          height: compact ? 42 : 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: _stroke),
          ),
          child: Icon(icon, color: _text, size: compact ? 19 : 22),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label, this.onInfoTap});

  final String label;
  final VoidCallback? onInfoTap;

  @override
  Widget build(BuildContext context) {
    return _InlineLabelWithInfo(label: label, onInfoTap: onInfoTap);
  }
}

class _InlineLabelWithInfo extends StatelessWidget {
  const _InlineLabelWithInfo({required this.label, this.onInfoTap});

  final String label;
  final VoidCallback? onInfoTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _text, fontSize: 18, height: 1.2),
          ),
        ),
        const SizedBox(width: 6),
        InkWell(
          onTap: onInfoTap,
          enableFeedback: false,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF191B21),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _stroke),
            ),
            child: const Text(
              '?',
              style: TextStyle(color: _muted, fontSize: 11, height: 1),
            ),
          ),
        ),
      ],
    );
  }
}

class _HelpDialogData {
  const _HelpDialogData({required this.title, required this.message});

  final String title;
  final String message;
}

class _StopwatchClock implements Clock {
  _StopwatchClock() : _baseMs = DateTime.now().millisecondsSinceEpoch {
    _stopwatch.start();
  }

  final int _baseMs;
  final Stopwatch _stopwatch = Stopwatch();

  @override
  int get nowMs => _baseMs + _stopwatch.elapsedMilliseconds;
}

class _SharedPrefsStorage implements Storage {
  _SharedPrefsStorage(this._prefs);

  static const String _jsonPrefix = '__json__:';
  final SharedPreferences _prefs;

  @override
  Future<void> clear() async {
    await _prefs.clear();
  }

  @override
  Future<void> delete(String key) async {
    await _prefs.remove(key);
  }

  @override
  Future<Object?> read(String key) async {
    final value = _prefs.get(key);
    if (value is String && value.startsWith(_jsonPrefix)) {
      return jsonDecode(value.substring(_jsonPrefix.length));
    }
    return value;
  }

  @override
  Future<void> write(String key, Object value) async {
    if (value is int) {
      await _prefs.setInt(key, value);
      return;
    }
    if (value is double) {
      await _prefs.setDouble(key, value);
      return;
    }
    if (value is bool) {
      await _prefs.setBool(key, value);
      return;
    }
    if (value is String) {
      await _prefs.setString(key, value);
      return;
    }
    if (value is List<String>) {
      await _prefs.setStringList(key, value);
      return;
    }
    await _prefs.setString(key, '$_jsonPrefix${jsonEncode(value)}');
  }
}

class _MemoryStorage implements Storage {
  final Map<String, Object> _data = <String, Object>{};

  @override
  Future<void> clear() async => _data.clear();

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<Object?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, Object value) async => _data[key] = value;
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.frame, this.stars, this.hitParticles, this.missPulses);

  final RenderFrame frame;
  final List<_Star> stars;
  final List<_UiParticle> hitParticles;
  final List<_MissPulse> missPulses;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = _bg;
    canvas.drawRect(Offset.zero & size, bg);

    final starPaint = Paint()..style = PaintingStyle.fill;
    for (final s in stars) {
      starPaint.color = Colors.white.withValues(alpha: s.alpha);
      canvas.drawCircle(Offset(s.x, s.y), s.radius, starPaint);
    }

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final fill = Paint()..style = PaintingStyle.fill;

    for (final shape in frame.shapes) {
      final alpha = (shape.alpha.clamp(0, 1) * 255).toInt();
      final defaultStroke = Color.fromARGB(alpha, 230, 230, 230);
      final defaultFill = Color.fromARGB(alpha, 11, 14, 19);
      final customStroke = shape.strokeColorArgb == null
          ? null
          : Color((alpha << 24) | (shape.strokeColorArgb! & 0x00FFFFFF));
      final customFill = shape.fillColorArgb == null
          ? null
          : Color((alpha << 24) | (shape.fillColorArgb! & 0x00FFFFFF));
      stroke.color = customStroke ?? defaultStroke;
      fill.color = customFill ?? defaultFill;

      switch (shape.kind) {
        case ShapeKind.circle:
          final c = Offset(shape.position.x, shape.position.y);
          canvas.drawCircle(c, shape.radius, fill);
          canvas.drawCircle(c, shape.radius, stroke);
          break;
        case ShapeKind.line:
          if (shape.points.length >= 2) {
            canvas.drawLine(
              Offset(shape.points.first.x, shape.points.first.y),
              Offset(shape.points.last.x, shape.points.last.y),
              stroke,
            );
          }
          break;
        case ShapeKind.polygon:
          if (shape.points.length >= 3) {
            final path = ui.Path()
              ..moveTo(shape.points.first.x, shape.points.first.y);
            for (final p in shape.points.skip(1)) {
              path.lineTo(p.x, p.y);
            }
            path.close();
            canvas.drawPath(path, fill);
            canvas.drawPath(path, stroke);
          }
          break;
      }
    }

    final particlePaint = Paint()..style = PaintingStyle.fill;
    for (final p in hitParticles) {
      final t = p.remainingMs / p.totalMs;
      final alpha = (t.clamp(0, 1) * 255).toInt();
      particlePaint.color = Color((alpha << 24) | (p.colorArgb & 0x00FFFFFF));
      final offset = Offset(p.x, p.y);
      if (p.shape == _UiParticleShape.square) {
        final side = p.size * 1.6;
        canvas.drawRect(
          Rect.fromCenter(center: offset, width: side, height: side),
          particlePaint,
        );
      } else {
        canvas.drawCircle(offset, p.size, particlePaint);
      }
    }

    final pulseStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7;
    for (final pulse in missPulses) {
      final progress = 1 - (pulse.remainingMs / pulse.totalMs);
      final alpha = ((1 - progress).clamp(0, 1) * 230).toInt();
      pulseStroke.color = Color.fromARGB(alpha, 230, 90, 90);
      canvas.drawCircle(
        Offset(pulse.x, pulse.y),
        7 + (progress * 18),
        pulseStroke,
      );
      canvas.drawLine(
        Offset(pulse.x - 5, pulse.y - 5),
        Offset(pulse.x + 5, pulse.y + 5),
        pulseStroke,
      );
      canvas.drawLine(
        Offset(pulse.x + 5, pulse.y - 5),
        Offset(pulse.x - 5, pulse.y + 5),
        pulseStroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FramePainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.stars != stars ||
      oldDelegate.hitParticles != hitParticles ||
      oldDelegate.missPulses != missPulses;
}

class _Star {
  const _Star({
    required this.x,
    required this.y,
    required this.radius,
    required this.alpha,
  });

  final double x;
  final double y;
  final double radius;
  final double alpha;
}

class _MissPulse {
  const _MissPulse({
    required this.x,
    required this.y,
    required this.totalMs,
    required this.remainingMs,
  });

  final double x;
  final double y;
  final int totalMs;
  final int remainingMs;
}

enum _UiParticleShape { circle, square }

class _ParticlePreset {
  const _ParticlePreset({
    required this.shape,
    required this.colorArgb,
    required this.countMin,
    required this.countRange,
    required this.sizeMin,
    required this.sizeRange,
  });

  final _UiParticleShape shape;
  final int colorArgb;
  final int countMin;
  final int countRange;
  final double sizeMin;
  final double sizeRange;
}

class _UiParticle {
  const _UiParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.colorArgb,
    required this.shape,
    required this.totalMs,
    required this.remainingMs,
  });

  final double x;
  final double y;
  final double vx;
  final double vy;
  final double size;
  final int colorArgb;
  final _UiParticleShape shape;
  final int totalMs;
  final int remainingMs;
}
