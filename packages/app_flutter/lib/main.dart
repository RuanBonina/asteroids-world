import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:asteroids_core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Color _bg = Color(0xFF000000);
const Color _panel = Color(0xFF0D0E11);
const Color _panelSoft = Color(0xFF121317);
const Color _stroke = Color(0xFF2B2E36);
const Color _text = Color(0xFFE5E7EB);
const Color _muted = Color(0xFFB7BDC8);
const double _settingsLabelWidth = 170;
const double _overlayPanelMaxWidth = 560;
const double _overlayPanelHeight = 430;
const EdgeInsets _overlayPanelMargin = EdgeInsets.symmetric(horizontal: 18);
const EdgeInsets _overlayPanelPadding = EdgeInsets.all(18);

void main() {
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

class _ShellScreenState extends State<ShellScreen> {
  static const bool _useFixedSeed = bool.fromEnvironment('FIXED_SEED', defaultValue: false);
  static const int _fixedSeedValue = int.fromEnvironment('FIXED_SEED_VALUE', defaultValue: 42);

  static const String _settingsKey = 'classic.settings';

  late final Clock _clock;
  late final LocalEventBus _eventBus;
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
    uiState: UiState(showStartScreen: true, showPauseModal: false, showQuitModal: false),
  );
  RunStatsSnapshot _stats = const RunStatsSnapshot(
    spawned: 0,
    escaped: 0,
    hits: 0,
    misses: 0,
    score: 0,
    difficultyMultiplier: 1,
    time: Duration.zero,
    paused: false,
  );
  RunStatsSnapshot? _lastResult;

  double _uiOpacity = 1;
  int _speedLevel = 3;
  bool _difficultyProgression = true;
  bool _showCustomize = false;
  bool _showQuitConfirm = false;
  Size? _lastViewportSent;
  List<_Star> _stars = const <_Star>[];
  List<_MissPulse> _missPulses = const <_MissPulse>[];
  List<_UiParticle> _hitParticles = const <_UiParticle>[];
  Timer? _fxTimer;
  int _lastFxTickMs = 0;
  bool _isPausedUi = false;
  bool _isFullscreen = false;
  _HelpDialogData? _helpDialog;

  @override
  void initState() {
    super.initState();
    _clock = _StopwatchClock();
    _eventBus = LocalEventBus();
    unawaited(_initEngine());
  }

  Future<void> _initEngine() async {
    Storage storage;
    try {
      final prefs = await SharedPreferences.getInstance();
      storage = _SharedPrefsStorage(prefs);
    } catch (_) {
      storage = _MemoryStorage();
    }
    final savedSettings = await storage.read(_settingsKey);
    if (savedSettings is Map) {
      _uiOpacity = ((savedSettings['uiOpacity'] as num?) ?? 1).toDouble().clamp(0.2, 1);
      _speedLevel = ((savedSettings['speedLevel'] as num?) ?? 3).toInt().clamp(1, 5);
      _difficultyProgression = (savedSettings['difficultyProgression'] as bool?) ?? true;
    }

    _seed = _useFixedSeed ? _fixedSeedValue : Random().nextInt(1 << 31);
    final mode = ClassicMode(config: const ClassicConfig(width: 360, height: 640));
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
      }),
      _eventBus.subscribe(HitMissed, (event) {
        if (!mounted) {
          return;
        }
        _spawnMissFeedback(event as HitMissed);
      }),
      _eventBus.subscribe(ParticlesRequested, (event) {
        if (!mounted) {
          return;
        }
        _spawnHitParticles(event as ParticlesRequested);
      }),
      _eventBus.subscribe(StatsUpdated, (event) {
        if (!mounted) {
          return;
        }
        setState(() => _stats = (event as StatsUpdated).stats);
      }),
    ]);

    _publishSettings();
    _loopTimer = Timer.periodic(const Duration(milliseconds: 16), (_) => engine.tick());

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
    await storage.write(
      _settingsKey,
      <String, Object>{
        'uiOpacity': _uiOpacity,
        'speedLevel': _speedLevel,
        'difficultyProgression': _difficultyProgression,
      },
    );
  }

  @override
  void dispose() {
    _loopTimer?.cancel();
    _fxTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _engine?.dispose();
    super.dispose();
  }

  void _onStart() {
    final viewport = _lastViewportSent ?? MediaQuery.sizeOf(context);
    setState(() {
      _isPausedUi = false;
      _stars = _generateStarfield(viewport);
      _missPulses = const <_MissPulse>[];
      _hitParticles = const <_UiParticle>[];
    });
    _eventBus.publish(
      GameViewportChangedRequested(
        width: viewport.width,
        height: viewport.height,
      ),
    );
    _eventBus.publish(const GameStartRequested());
  }

  void _spawnMissFeedback(HitMissed event) {
    final pulse = _MissPulse(x: event.x, y: event.y, totalMs: 220, remainingMs: 220);
    setState(() {
      _missPulses = <_MissPulse>[..._missPulses, pulse];
    });
    _ensureFxLoop();
  }

  void _spawnHitParticles(ParticlesRequested event) {
    if (event.kind != 'asteroid-hit') {
      return;
    }
    final rng = Random(_seed ^ event.x.round() ^ event.y.round() ^ _clock.nowMs);
    final spawned = <_UiParticle>[];
    final count = 14 + rng.nextInt(8);
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
          size: 1.1 + rng.nextDouble() * 2.2,
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
    setState(() => _isPausedUi = !_isPausedUi);
    _eventBus.publish(const GamePauseToggleRequested());
  }

  void _onQuitRequested() {
    setState(() {
      _showQuitConfirm = true;
    });
    if (_state == GameLifecycleState.running) {
      _eventBus.publish(const GamePauseToggleRequested());
    }
  }

  Future<void> _confirmQuit() async {
    setState(() => _showQuitConfirm = false);
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
    setState(() => _showQuitConfirm = false);
    if (_state == GameLifecycleState.paused) {
      _eventBus.publish(const GamePauseToggleRequested());
    }
  }

  Future<void> _toggleFullscreen() async {
    final next = !_isFullscreen;
    if (next) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (mounted) {
      setState(() => _isFullscreen = next);
    }
  }

  Future<void> _applySettings() async {
    _publishSettings();
    await _saveSettings();
    setState(() => _showCustomize = false);
  }

  void _publishPointer(TapDownDetails details) {
    _eventBus.publish(
      InputPointerDown(
        x: details.localPosition.dx,
        y: details.localPosition.dy,
        timestampMs: _clock.nowMs,
      ),
    );
  }

  void _syncViewport(Size size) {
    if (_engine == null) {
      return;
    }
    if (_lastViewportSent != null &&
        (_lastViewportSent!.width - size.width).abs() < 0.5 &&
        (_lastViewportSent!.height - size.height).abs() < 0.5) {
      return;
    }
    _lastViewportSent = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _eventBus.publish(
        GameViewportChangedRequested(
          width: size.width,
          height: size.height,
        ),
      );
    });
  }

  List<_Star> _generateStarfield(Size size) {
    final rng = Random(_seed ^ _clock.nowMs);
    final count = (size.width * size.height / 12000).clamp(80, 180).toInt();
    final out = <_Star>[];
    for (var i = 0; i < count; i++) {
      out.add(
        _Star(
          x: rng.nextDouble() * size.width,
          y: rng.nextDouble() * size.height,
          radius: rng.nextDouble() < 0.82 ? 0.9 : 1.4,
          alpha: 0.25 + rng.nextDouble() * 0.55,
        ),
      );
    }
    return out;
  }

  String _lastResultText() {
    final r = _lastResult;
    if (r == null) {
      return 'Ultima partida: (ainda nao jogada)';
    }
    final clicks = r.hits + r.misses;
    final acc = clicks == 0 ? 0 : ((r.hits / clicks) * 100).round();
    return 'Ultima partida\n'
        'Destruidos: ${r.hits}\n'
        'Fugas: ${r.escaped}\n'
        'Cliques: $clicks\n'
        'Precisao: $acc%\n'
        'Tempo: ${r.time.inSeconds}s';
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
    final showStart = !showCustomize &&
        (_state == GameLifecycleState.idle || _state == GameLifecycleState.quit);
    return Scaffold(
      backgroundColor: _bg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          _syncViewport(Size(constraints.maxWidth, constraints.maxHeight));
          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: GestureDetector(
                  onTapDown: _publishPointer,
                  child: CustomPaint(
                    painter: _FramePainter(_frame, _stars, _hitParticles, _missPulses),
                    child: const SizedBox.expand(),
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
                  top: 16,
                  right: 12,
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
                        _IconPill(icon: Icons.close, onTap: _onQuitRequested, compact: true),
                        const SizedBox(width: 8),
                        _IconPill(
                          icon: _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                          onTap: _toggleFullscreen,
                          compact: true,
                        ),
                      ],
                    ),
                  ),
                ),
              if (showStart) _buildStartOverlay(),
              if (showCustomize) _buildSettingsModal(),
              if (_showQuitConfirm) _buildQuitConfirmModal(),
              if (_helpDialog != null) _buildHelpOverlay(_helpDialog!),
            ],
          );
        },
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
          color: Colors.black.withValues(alpha: 0.82),
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
        color: Colors.black.withValues(alpha: 0.75),
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
                        style: TextStyle(color: _text, fontSize: 40, fontWeight: FontWeight.w700, height: 1),
                      ),
                    ),
                    _IconPill(
                      icon: Icons.settings,
                      onTap: () => setState(() => _showCustomize = true),
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Destrua o asteroide antes que ele fuja da tela.',
                  style: TextStyle(color: _muted, fontSize: 24),
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
                      child: Text(
                        _lastResultText(),
                        style: const TextStyle(color: _text, fontSize: 20, height: 1.35),
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
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: _stroke),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      backgroundColor: const Color(0xFF17181C),
                    ),
                    onPressed: _onStart,
                    child: const Text('Iniciar', style: TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '- 1 hit kill • 1 asteroide por vez\n- Clique para destruir\n- Esc pausa/retoma • X encerra',
                  style: TextStyle(color: _muted, height: 1.35, fontSize: 20),
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
        color: _bg,
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
                        style: TextStyle(color: _text, fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                    ),
                    _IconPill(
                      icon: Icons.arrow_back,
                      onTap: () => setState(() => _showCustomize = false),
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _SliderRow(
                  label: 'Transparencia UI',
                  value: _uiOpacity * 100,
                  min: 20,
                  max: 100,
                  divisions: 4,
                  suffix: '${(_uiOpacity * 100).round()}%',
                  onInfoTap: () => _showHelp(
                    title: 'Transparencia UI',
                    message:
                        'Define o quao visiveis ficam os elementos da interface durante a partida.',
                  ),
                  onChanged: (v) => setState(() => _uiOpacity = (v / 100).clamp(0.2, 1)),
                ),
                const SizedBox(height: 12),
                _SliderRow(
                  label: 'Velocidade',
                  value: _speedLevel.toDouble(),
                  min: 1,
                  max: 5,
                  divisions: 4,
                  suffix: 'Nivel $_speedLevel',
                  onInfoTap: () => _showHelp(
                    title: 'Velocidade',
                    message:
                        'Controla a velocidade base dos asteroides. Nivel maior deixa o jogo mais rapido.',
                  ),
                  onChanged: (v) => setState(() => _speedLevel = v.round().clamp(1, 5)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    _FieldLabel(
                      label: 'Escalar dificuldade',
                      onInfoTap: () => _showHelp(
                        title: 'Escalar dificuldade',
                        message:
                            'Quando ligado, a dificuldade aumenta ao longo do tempo da partida.',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Align(
                        alignment: Alignment.center,
                        child: Switch(
                          value: _difficultyProgression,
                          activeThumbColor: Colors.white,
                          activeTrackColor: const Color(0xFF178BDE),
                          inactiveThumbColor: Colors.white,
                          inactiveTrackColor: const Color(0xFF2A2D34),
                          onChanged: (v) => setState(() => _difficultyProgression = v),
                        ),
                      ),
                    ),
                    const SizedBox(width: 72),
                  ],
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _text,
                      backgroundColor: const Color(0xFF17181C),
                      side: const BorderSide(color: _stroke),
                      minimumSize: const Size.fromHeight(56),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: _applySettings,
                    child: const Text('Aplicar alteracoes', style: TextStyle(fontSize: 24)),
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
    setState(() {
      _helpDialog = _HelpDialogData(title: title, message: message);
    });
  }

  void _closeHelp() {
    if (_helpDialog == null) {
      return;
    }
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
                    style: const TextStyle(color: _text, fontWeight: FontWeight.w700, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Text(dialog.message, style: const TextStyle(color: _muted, height: 1.35)),
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
                        style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ),
                    _IconPill(icon: Icons.close, onTap: _cancelQuit, compact: true),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Seu desempenho sera salvo como "Ultima partida".',
                  style: TextStyle(color: _muted),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _text,
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
}

class _HudBar extends StatelessWidget {
  const _HudBar({required this.stats});

  final RunStatsSnapshot stats;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Destruidos: ${stats.hits}\nFugas: ${stats.escaped}\nTempo: 00:${stats.time.inSeconds.toString().padLeft(2, '0')}\n${stats.paused ? "PAUSADO" : "ATIVO"}',
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
    required this.onChanged,
    this.onInfoTap,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final ValueChanged<double> onChanged;
  final VoidCallback? onInfoTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const SizedBox(width: 0),
        _FieldLabel(label: label, onInfoTap: onInfoTap),
        const SizedBox(width: 12),
        Expanded(
          child: SliderTheme(
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
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 72,
          child: Text(suffix, textAlign: TextAlign.right, style: const TextStyle(color: _muted)),
        ),
      ],
    );
  }
}

class _IconPill extends StatelessWidget {
  const _IconPill({required this.icon, required this.onTap, this.compact = false});

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
    return SizedBox(
      width: _settingsLabelWidth,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _text),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: onInfoTap,
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
              child: const Text('?', style: TextStyle(color: _muted, fontSize: 11, height: 1)),
            ),
          ),
        ],
      ),
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
      stroke.color = Color.fromARGB(alpha, 230, 230, 230);
      fill.color = Color.fromARGB((alpha * 0.15).toInt(), 230, 230, 230);

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
            final path = ui.Path()..moveTo(shape.points.first.x, shape.points.first.y);
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
      particlePaint.color = Color.fromARGB(alpha, 240, 240, 240);
      canvas.drawCircle(Offset(p.x, p.y), p.size, particlePaint);
    }

    final pulseStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7;
    for (final pulse in missPulses) {
      final progress = 1 - (pulse.remainingMs / pulse.totalMs);
      final alpha = ((1 - progress).clamp(0, 1) * 230).toInt();
      pulseStroke.color = Color.fromARGB(alpha, 230, 90, 90);
      canvas.drawCircle(Offset(pulse.x, pulse.y), 7 + (progress * 18), pulseStroke);
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

class _UiParticle {
  const _UiParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.size,
    required this.totalMs,
    required this.remainingMs,
  });

  final double x;
  final double y;
  final double vx;
  final double vy;
  final double size;
  final int totalMs;
  final int remainingMs;
}
