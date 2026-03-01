library;

import 'dart:async';
import 'dart:math' as math;

import 'contracts.dart';
import 'ecs.dart';
import 'game_events.dart';

class ClassicConfig {
  const ClassicConfig({
    required this.width,
    required this.height,
    this.spawnCooldown,
    this.spawnCooldownMin = const Duration(milliseconds: 200),
    this.spawnCooldownMax = const Duration(milliseconds: 500),
    this.baseAsteroidSpeed = 72,
    this.asteroidRadius = 18,
    this.asteroidRadiusMin = 14,
    this.asteroidRadiusMax = 34,
    this.asteroidSpeedJitter = 0.18,
    this.escapePadding = 120,
    this.scorePerHit = 10,
    this.defaultSpeedLevel = 3,
    this.defaultDifficultyProgression = true,
    this.defaultUiOpacity = 1,
    this.trajectoryDistortion = 0.5,
    this.centerTargetZone = 0.4,
    this.spawnEdgeOffset = 80,
    this.goldSpawnChance = 0.05,
    this.goldScorePerHit = 1000,
    this.goldBorderColorArgb = 0xFFFFD700,
    this.goldSpeedMultiplier = 1.20,
  });

  final double width;
  final double height;
  final Duration? spawnCooldown;
  final Duration spawnCooldownMin;
  final Duration spawnCooldownMax;
  final double baseAsteroidSpeed;
  final double asteroidRadius;
  final double asteroidRadiusMin;
  final double asteroidRadiusMax;
  final double asteroidSpeedJitter;
  final double escapePadding;
  final int scorePerHit;
  final int defaultSpeedLevel;
  final bool defaultDifficultyProgression;
  final double defaultUiOpacity;
  final double trajectoryDistortion;
  final double centerTargetZone;
  final double spawnEdgeOffset;
  final double goldSpawnChance;
  final int goldScorePerHit;
  final int goldBorderColorArgb;
  final double goldSpeedMultiplier;
}

class _AsteroidTypeProfile {
  const _AsteroidTypeProfile({
    required this.kind,
    required this.scorePerHit,
    required this.forceMinRadius,
    required this.forceMaxSpeed,
    this.speedMultiplier = 1.0,
    this.strokeColorArgb,
  });

  final AsteroidKind kind;
  final int scorePerHit;
  final bool forceMinRadius;
  final bool forceMaxSpeed;
  final double speedMultiplier;
  final int? strokeColorArgb;
}

class ClassicMode implements GameMode {
  ClassicMode({required this.config});

  @override
  String get id => 'classic';

  final ClassicConfig config;
  final List<InputPointerDown> _pendingPointerDown = <InputPointerDown>[];

  static const String lastResultStorageKey = 'classic.lastResult';
  static const String bestRecordStorageKey = 'classic.bestRecord';
  static const int _scorePerHit = 100;
  static const int _scorePenaltyEscape = 70;
  static const int _scorePenaltyMiss = 25;
  static const int _scoreTimeBonusPer10s = 20;
  SubscriptionToken? _inputSub;
  SubscriptionToken? _stateSub;
  SubscriptionToken? _settingsSub;
  SubscriptionToken? _viewportSub;
  EntityId? _runEntity;
  int _spawnSideCursor = 0;
  GameLifecycleState _currentState = GameLifecycleState.idle;
  double _viewportWidth = 0;
  double _viewportHeight = 0;
  int _speedLevel = 3;
  bool _difficultyProgression = true;
  int _runStartSpeedLevel = 3;
  bool _runStartDifficultyAdaptive = true;
  bool _runStartCaptured = false;
  double _uiOpacity = 1;
  Future<void> _loadLastResultTask = Future<void>.value();
  Future<void>? _saveLastResultTask;
  RunStatsSnapshot? _lastLoadedResult;
  RunStatsSnapshot? _bestLoadedResult;
  int? _bestRecordedAtMs;
  int _lastDifficultyWindow = -1;
  RenderFrame _lastFrame = RenderFrame(
    timestampMs: 0,
    shapes: const <ShapeModel>[],
    hud: const HudModel(
      destroyed: 0,
      misses: 0,
      time: Duration.zero,
      paused: false,
    ),
    uiState: const UiState(
      showStartScreen: true,
      showPauseModal: false,
      showQuitModal: false,
    ),
  );

  RenderFrame get lastFrame => _lastFrame;
  Future<void> get loadLastResultTask => _loadLastResultTask;
  Future<void>? get saveLastResultTask => _saveLastResultTask;
  RunStatsSnapshot? get lastLoadedResult => _lastLoadedResult;
  RunStatsSnapshot? get bestLoadedResult => _bestLoadedResult;
  DateTime? get bestRecordedAt => _bestRecordedAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_bestRecordedAtMs!);

  @override
  void onEnter(GameContext context) {
    _speedLevel = config.defaultSpeedLevel;
    _difficultyProgression = config.defaultDifficultyProgression;
    _runStartSpeedLevel = _speedLevel;
    _runStartDifficultyAdaptive = _difficultyProgression;
    _runStartCaptured = false;
    _uiOpacity = config.defaultUiOpacity;
    _lastDifficultyWindow = -1;
    _runEntity = context.world.createEntity();
    _spawnSideCursor = context.rng.nextInt(4);
    _viewportWidth = config.width;
    _viewportHeight = config.height;
    context.world.attachComponent(_runEntity!, RunStats());
    _inputSub = context.eventBus.subscribe(InputPointerDown, (event) {
      if (_currentState != GameLifecycleState.running) {
        return;
      }
      _pendingPointerDown.add(event as InputPointerDown);
    });
    _stateSub = context.eventBus.subscribe(GameStateChanged, (event) {
      final changed = event as GameStateChanged;
      _currentState = changed.current;
      if (_currentState != GameLifecycleState.running &&
          _pendingPointerDown.isNotEmpty) {
        _pendingPointerDown.clear();
      }
      final stats = _safeStats(context);
      if (stats != null) {
        _publishRenderSnapshot(context, stats);
      }
    });
    _settingsSub = context.eventBus.subscribe(GameSettingsUpdatedRequested, (
      event,
    ) {
      final settings = event as GameSettingsUpdatedRequested;
      _speedLevel = settings.asteroidSpeedLevel.clamp(1, 5).toInt();
      _difficultyProgression = settings.difficultyProgression;
      _uiOpacity = settings.uiOpacity.clamp(0.2, 1).toDouble();
    });
    _viewportSub = context.eventBus.subscribe(GameViewportChangedRequested, (
      event,
    ) {
      final viewport = event as GameViewportChangedRequested;
      _viewportWidth = viewport.width > 1 ? viewport.width : config.width;
      _viewportHeight = viewport.height > 1 ? viewport.height : config.height;
    });
    _loadLastResultTask = _loadPersistedResults(context);
    _publishRenderSnapshot(context, _stats(context));
  }

  @override
  void onUpdate(GameContext context, Duration dt) {
    final stats = _stats(context);
    if (!_runStartCaptured && _currentState == GameLifecycleState.running) {
      _runStartSpeedLevel = _speedLevel;
      _runStartDifficultyAdaptive = _difficultyProgression;
      _runStartCaptured = true;
    }
    stats.elapsed += dt;

    _difficultySystem(stats);
    _spawnSystem(context, stats, dt);
    _movementSystem(context, dt);
    _escapeSystem(context);
    _hitSystem(context);
    _statsSystem(context, stats);
    _publishRenderSnapshot(context, stats);
  }

  @override
  void onExit(GameContext context) {
    _saveLastResultTask = _saveLastResult(context);
    unawaited(_saveLastResultTask);
    _inputSub?.cancel();
    _inputSub = null;
    _stateSub?.cancel();
    _stateSub = null;
    _settingsSub?.cancel();
    _settingsSub = null;
    _viewportSub?.cancel();
    _viewportSub = null;
  }

  double get _w => _viewportWidth > 1 ? _viewportWidth : config.width;
  double get _h => _viewportHeight > 1 ? _viewportHeight : config.height;

  Future<void> _loadPersistedResults(GameContext context) async {
    final rawLast = await context.storage.read(lastResultStorageKey);
    if (rawLast is Map) {
      _lastLoadedResult = _snapshotFromMap(rawLast);
    }

    final rawBest = await context.storage.read(bestRecordStorageKey);
    if (rawBest is Map) {
      _bestLoadedResult = _snapshotFromMap(rawBest);
      _bestRecordedAtMs = (rawBest['recordedAtMs'] as num?)?.toInt();
    }

    // Bootstrap: se já existe última partida e não há recorde ainda.
    if (_bestLoadedResult == null && _lastLoadedResult != null) {
      _bestLoadedResult = _lastLoadedResult;
      _bestRecordedAtMs = DateTime.now().millisecondsSinceEpoch;
      await context.storage.write(
        bestRecordStorageKey,
        _bestRecordMap(_bestLoadedResult!, _bestRecordedAtMs!),
      );
    }
  }

  Future<void> _saveLastResult(GameContext context) async {
    final stats = _safeStats(context);
    if (stats == null) {
      return;
    }
    final candidate = _snapshotFromStats(stats);
    await context.storage.write(lastResultStorageKey, _snapshotMap(candidate));
    _lastLoadedResult = candidate;

    final shouldPromote = _shouldPromoteBest(candidate, _bestLoadedResult);
    if (shouldPromote) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      _bestLoadedResult = candidate;
      _bestRecordedAtMs = nowMs;
      await context.storage.write(
        bestRecordStorageKey,
        _bestRecordMap(candidate, nowMs),
      );
    }
  }

  RunStatsSnapshot _snapshotFromStats(RunStats stats) => RunStatsSnapshot(
    spawned: stats.spawned,
    escaped: stats.escaped,
    hits: stats.hits,
    misses: stats.misses,
    score: stats.score,
    difficultyMultiplier: stats.difficultyMultiplier,
    speedLevelAtStart: _runStartSpeedLevel,
    difficultyAdaptiveAtStart: _runStartDifficultyAdaptive,
    time: stats.elapsed,
    paused: false,
  );

  RunStatsSnapshot _snapshotFromMap(Map raw) {
    int readInt(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return RunStatsSnapshot(
      spawned: readInt('spawned'),
      escaped: readInt('escaped'),
      hits: readInt('hits'),
      misses: readInt('misses'),
      score: readInt('score'),
      difficultyMultiplier:
          (raw['difficultyMultiplier'] as num?)?.toDouble() ?? 1,
      speedLevelAtStart: (raw['speedLevelAtStart'] as num?)?.toInt() ?? 3,
      difficultyAdaptiveAtStart:
          (raw['difficultyAdaptiveAtStart'] as bool?) ?? true,
      time: Duration(milliseconds: readInt('timeMs')),
      paused: false,
    );
  }

  Map<String, Object> _snapshotMap(RunStatsSnapshot snapshot) =>
      <String, Object>{
        'spawned': snapshot.spawned,
        'escaped': snapshot.escaped,
        'hits': snapshot.hits,
        'misses': snapshot.misses,
        'score': snapshot.score,
        'difficultyMultiplier': snapshot.difficultyMultiplier,
        'speedLevelAtStart': snapshot.speedLevelAtStart,
        'difficultyAdaptiveAtStart': snapshot.difficultyAdaptiveAtStart,
        'timeMs': snapshot.time.inMilliseconds,
      };

  Map<String, Object> _bestRecordMap(
    RunStatsSnapshot snapshot,
    int recordedAtMs,
  ) => <String, Object>{
    ..._snapshotMap(snapshot),
    'recordedAtMs': recordedAtMs,
  };

  bool _shouldPromoteBest(RunStatsSnapshot candidate, RunStatsSnapshot? best) {
    if (best == null) {
      return true;
    }
    if (candidate.score > best.score) {
      return true;
    }
    if (candidate.score < best.score) {
      return false;
    }
    final candidateAccuracy = _accuracy(candidate.hits, candidate.misses);
    final bestAccuracy = _accuracy(best.hits, best.misses);
    return candidateAccuracy > bestAccuracy;
  }

  double _accuracy(int hits, int misses) {
    final total = hits + misses;
    if (total <= 0) {
      return 0;
    }
    return hits / total;
  }

  int _computeScore(RunStats stats) {
    final timeBonusBlocks = stats.elapsed.inSeconds ~/ 10;
    final raw =
        stats.hitScore -
        (stats.escaped * _scorePenaltyEscape) -
        (stats.misses * _scorePenaltyMiss) +
        (timeBonusBlocks * _scoreTimeBonusPer10s);
    return math.max(0, raw);
  }

  RunStats? _safeStats(GameContext context) {
    final run = _runEntity;
    if (run == null) {
      return null;
    }
    return context.world.getComponent<RunStats>(run);
  }

  RunStats _stats(GameContext context) {
    final stats = _safeStats(context);
    if (stats == null) {
      throw StateError('RunStats missing on run entity.');
    }
    return stats;
  }

  void _difficultySystem(RunStats stats) {
    const speedMap = <double>[1, 1.5, 2, 3, 4];
    final base = speedMap[_speedLevel.clamp(1, 5).toInt() - 1];
    if (!_difficultyProgression) {
      stats.difficultyMultiplier = base;
      _lastDifficultyWindow = -1;
      return;
    }

    final bounds = _difficultyBounds(base);
    if (_lastDifficultyWindow == -1) {
      stats.difficultyMultiplier = base;
      _lastDifficultyWindow = 0;
    }
    stats.difficultyMultiplier = stats.difficultyMultiplier.clamp(
      bounds.floor,
      bounds.ceiling,
    );

    final window = stats.elapsed.inSeconds ~/ 10;
    if (window == 0 || window == _lastDifficultyWindow) {
      return;
    }
    _lastDifficultyWindow = window;

    final clicks = stats.hits + stats.misses;
    if (clicks <= 0) {
      return;
    }

    final accuracy = stats.hits / clicks;
    if (accuracy < 0.50) {
      stats.difficultyMultiplier = (stats.difficultyMultiplier - 0.2).clamp(
        bounds.floor,
        bounds.ceiling,
      );
      return;
    }
    if (accuracy > 0.80) {
      stats.difficultyMultiplier = (stats.difficultyMultiplier + 0.2).clamp(
        bounds.floor,
        bounds.ceiling,
      );
    }
  }

  ({double floor, double ceiling}) _difficultyBounds(double base) {
    final floor = base * 0.8;
    final ceiling = math.max(base * 1.6, floor + 0.2);
    return (floor: floor, ceiling: ceiling);
  }

  Duration _randomSpawnCooldown(GameContext context) {
    if (config.spawnCooldown != null) {
      return config.spawnCooldown!;
    }
    final minMs = config.spawnCooldownMin.inMilliseconds;
    final maxMs = config.spawnCooldownMax.inMilliseconds;
    if (maxMs <= minMs) {
      return Duration(milliseconds: minMs);
    }
    final delta = maxMs - minMs;
    return Duration(milliseconds: minMs + context.rng.nextInt(delta + 1));
  }

  _AsteroidTypeProfile get _normalAsteroidProfile => const _AsteroidTypeProfile(
    kind: AsteroidKind.normal,
    scorePerHit: _scorePerHit,
    forceMinRadius: false,
    forceMaxSpeed: false,
  );

  _AsteroidTypeProfile get _goldAsteroidProfile => _AsteroidTypeProfile(
    kind: AsteroidKind.gold,
    scorePerHit: config.goldScorePerHit,
    forceMinRadius: true,
    forceMaxSpeed: true,
    speedMultiplier: config.goldSpeedMultiplier,
    strokeColorArgb: config.goldBorderColorArgb,
  );

  _AsteroidTypeProfile _profileForKind(AsteroidKind kind) {
    return switch (kind) {
      AsteroidKind.gold => _goldAsteroidProfile,
      AsteroidKind.normal => _normalAsteroidProfile,
    };
  }

  AsteroidKind _pickAsteroidKind(GameContext context) {
    final chance = config.goldSpawnChance.clamp(0.0, 1.0).toDouble();
    if (context.rng.nextDouble() < chance) {
      return AsteroidKind.gold;
    }
    return AsteroidKind.normal;
  }

  double _resolveRadiusForKind(
    GameContext context,
    _AsteroidTypeProfile profile,
  ) {
    if (profile.forceMinRadius) {
      final minR = math.min(config.asteroidRadiusMin, config.asteroidRadiusMax);
      return minR;
    }
    return _randomRadius(context);
  }

  double _resolveSpeedForKind(
    GameContext context,
    double difficultyMultiplier,
    _AsteroidTypeProfile profile,
  ) {
    final multiplier = profile.speedMultiplier.clamp(0.1, 5.0).toDouble();
    if (profile.forceMaxSpeed) {
      final base = config.baseAsteroidSpeed * difficultyMultiplier;
      final jitter = config.asteroidSpeedJitter.clamp(0, 0.8).toDouble();
      return (base * (1 + jitter)) * multiplier;
    }
    return _randomSpeed(context, difficultyMultiplier) * multiplier;
  }

  int _scoreForKind(_AsteroidTypeProfile profile) => profile.scorePerHit;

  void _spawnSystem(GameContext context, RunStats stats, Duration dt) {
    if (stats.spawnCooldown > Duration.zero) {
      final next = stats.spawnCooldown - dt;
      stats.spawnCooldown = next.isNegative ? Duration.zero : next;
    }

    final asteroidExists = context.world.query(<Type>[AsteroidTag]).isNotEmpty;
    if (asteroidExists || stats.spawnCooldown > Duration.zero) {
      return;
    }

    final entity = context.world.createEntity();
    final side = _spawnSideCursor;
    _spawnSideCursor = (_spawnSideCursor + 1) % 4;
    final edge = math.max(config.spawnEdgeOffset, config.asteroidRadiusMax + 2);
    late final double x;
    late final double y;
    switch (side) {
      case 0:
        x = (context.rng.nextDouble() * (_w + edge * 2)) - edge;
        y = -edge;
        break;
      case 1:
        x = _w + edge;
        y = (context.rng.nextDouble() * (_h + edge * 2)) - edge;
        break;
      case 2:
        x = (context.rng.nextDouble() * (_w + edge * 2)) - edge;
        y = _h + edge;
        break;
      default:
        x = -edge;
        y = (context.rng.nextDouble() * (_h + edge * 2)) - edge;
        break;
    }

    final centerX = _w / 2;
    final centerY = _h / 2;
    final zoneFactor = config.centerTargetZone.clamp(0.1, 1).toDouble();
    final zoneHalfW = (_w * zoneFactor) / 2;
    final zoneHalfH = (_h * zoneFactor) / 2;
    final targetX = centerX + ((context.rng.nextDouble() * 2 - 1) * zoneHalfW);
    final targetY = centerY + ((context.rng.nextDouble() * 2 - 1) * zoneHalfH);
    final baseAngle = math.atan2(targetY - y, targetX - x);
    final maxOffsetByConfig =
        (math.pi / 12) * config.trajectoryDistortion.clamp(0, 1).toDouble();
    final angleOffset =
        ((context.rng.nextDouble() * 2) - 1) * maxOffsetByConfig;
    final finalAngle = baseAngle + angleOffset;
    final kind = _pickAsteroidKind(context);
    final profile = _profileForKind(kind);
    final radius = _resolveRadiusForKind(context, profile);
    final speed = _resolveSpeedForKind(
      context,
      stats.difficultyMultiplier,
      profile,
    );
    final vx = math.cos(finalAngle) * speed;
    final vy = math.sin(finalAngle) * speed;
    final polygon = _randomAsteroidPolygon(context, radius);
    context.world.attachComponent(entity, AsteroidTag());
    context.world.attachComponent(entity, AsteroidKindComponent(kind: kind));
    context.world.attachComponent(entity, Transform(x: x, y: y));
    context.world.attachComponent(
      entity,
      Velocity(vx: vx, vy: vy, angVel: 0.4),
    );
    context.world.attachComponent(entity, ColliderCircle(r: radius));
    context.world.attachComponent(
      entity,
      AsteroidVisual(localPolygon: polygon),
    );
    context.world.attachComponent(
      entity,
      EscapeBounds(padding: config.escapePadding),
    );
    stats.spawned++;
    stats.spawnCooldown = _randomSpawnCooldown(context);
    context.eventBus.publish(AsteroidSpawned(entity: entity));
  }

  double _randomRadius(GameContext context) {
    final minR = math.min(config.asteroidRadiusMin, config.asteroidRadiusMax);
    final maxR = math.max(config.asteroidRadiusMin, config.asteroidRadiusMax);
    if ((maxR - minR).abs() < 0.001) {
      return minR;
    }
    return minR + (context.rng.nextDouble() * (maxR - minR));
  }

  double _randomSpeed(GameContext context, double difficultyMultiplier) {
    final base = config.baseAsteroidSpeed * difficultyMultiplier;
    final jitter = config.asteroidSpeedJitter.clamp(0, 0.8).toDouble();
    final factor = 1 + ((context.rng.nextDouble() * 2 - 1) * jitter);
    return base * factor;
  }

  List<Vec2> _randomAsteroidPolygon(GameContext context, double radius) {
    final vertices = 8 + context.rng.nextInt(4); // 8..11
    final out = <Vec2>[];
    for (var i = 0; i < vertices; i++) {
      final angle = (i / vertices) * math.pi * 2;
      final rr = radius * (0.72 + context.rng.nextDouble() * 0.46); // 72%..118%
      out.add(Vec2(math.cos(angle) * rr, math.sin(angle) * rr));
    }
    return out;
  }

  void _movementSystem(GameContext context, Duration dt) {
    final seconds = dt.inMicroseconds / Duration.microsecondsPerSecond;
    for (final entity in context.world.query(<Type>[Transform, Velocity])) {
      final t = context.world.getComponent<Transform>(entity);
      final v = context.world.getComponent<Velocity>(entity);
      if (t == null || v == null) {
        continue;
      }
      t.x += v.vx * seconds;
      t.y += v.vy * seconds;
      t.rot += v.angVel * seconds;
    }
  }

  void _escapeSystem(GameContext context) {
    final toRemove = <EntityId>[];
    for (final entity in context.world.query(<Type>[
      AsteroidTag,
      Transform,
      EscapeBounds,
    ])) {
      final t = context.world.getComponent<Transform>(entity);
      final b = context.world.getComponent<EscapeBounds>(entity);
      if (t == null || b == null) {
        continue;
      }
      final escaped =
          t.x < -b.padding ||
          t.x > _w + b.padding ||
          t.y < -b.padding ||
          t.y > _h + b.padding;
      if (escaped) {
        toRemove.add(entity);
      }
    }

    final stats = _stats(context);
    for (final entity in toRemove) {
      if (context.world.removeEntity(entity)) {
        stats.escaped++;
        context.eventBus.publish(AsteroidEscaped(entity: entity));
      }
    }
  }

  void _hitSystem(GameContext context) {
    if (_pendingPointerDown.isEmpty) {
      return;
    }

    final stats = _stats(context);
    final inputs = List<InputPointerDown>.from(_pendingPointerDown);
    _pendingPointerDown.clear();

    for (final pointer in inputs) {
      var hit = false;
      for (final entity in context.world.query(<Type>[
        AsteroidTag,
        Transform,
        ColliderCircle,
      ])) {
        final t = context.world.getComponent<Transform>(entity);
        final c = context.world.getComponent<ColliderCircle>(entity);
        if (t == null || c == null) {
          continue;
        }
        final dx = pointer.x - t.x;
        final dy = pointer.y - t.y;
        if ((dx * dx) + (dy * dy) <= c.r * c.r) {
          final kind = context.world.getComponent<AsteroidKindComponent>(
            entity,
          );
          final profile = _profileForKind(kind?.kind ?? AsteroidKind.normal);
          if (context.world.removeEntity(entity)) {
            stats.hits++;
            stats.hitScore += _scoreForKind(profile);
            stats.spawnCooldown = _randomSpawnCooldown(context);
            context.eventBus.publish(
              AsteroidDestroyed(
                entity: entity,
                x: pointer.x,
                y: pointer.y,
                kind: profile.kind,
              ),
            );
            context.eventBus.publish(
              ParticlesRequested(
                x: pointer.x,
                y: pointer.y,
                kind: 'asteroid-hit',
                asteroidKind: profile.kind,
              ),
            );
            hit = true;
          }
          break;
        }
      }
      if (!hit) {
        stats.misses++;
        context.eventBus.publish(
          HitMissed(
            x: pointer.x,
            y: pointer.y,
            timestampMs: pointer.timestampMs,
          ),
        );
      }
    }
  }

  void _statsSystem(GameContext context, RunStats stats) {
    stats.score = _computeScore(stats);
    context.eventBus.publish(
      StatsUpdated(
        RunStatsSnapshot(
          spawned: stats.spawned,
          escaped: stats.escaped,
          hits: stats.hits,
          misses: stats.misses,
          score: stats.score,
          difficultyMultiplier: stats.difficultyMultiplier,
          speedLevelAtStart: _runStartSpeedLevel,
          difficultyAdaptiveAtStart: _runStartDifficultyAdaptive,
          time: stats.elapsed,
          paused: _currentState == GameLifecycleState.paused,
        ),
      ),
    );
  }

  void _publishRenderSnapshot(GameContext context, RunStats stats) {
    final shapes = <ShapeModel>[];
    for (final entity in context.world.query(<Type>[
      AsteroidTag,
      Transform,
      ColliderCircle,
    ])) {
      final t = context.world.getComponent<Transform>(entity);
      final c = context.world.getComponent<ColliderCircle>(entity);
      final v = context.world.getComponent<AsteroidVisual>(entity);
      final kind = context.world.getComponent<AsteroidKindComponent>(entity);
      final profile = _profileForKind(kind?.kind ?? AsteroidKind.normal);
      if (t == null || c == null) {
        continue;
      }
      if (v == null || v.localPolygon.length < 3) {
        shapes.add(
          ShapeModel.circle(
            position: Vec2(t.x, t.y),
            radius: c.r,
            alpha: _uiOpacity,
            strokeColorArgb: profile.strokeColorArgb,
          ),
        );
      } else {
        final points = v.localPolygon
            .map((p) => Vec2(t.x + p.x, t.y + p.y))
            .toList(growable: false);
        shapes.add(
          ShapeModel.polygon(
            points: points,
            alpha: _uiOpacity,
            strokeColorArgb: profile.strokeColorArgb,
          ),
        );
      }
    }

    _lastFrame = RenderFrame(
      timestampMs: context.clock.nowMs,
      shapes: shapes,
      hud: HudModel(
        destroyed: stats.hits,
        misses: stats.misses,
        time: stats.elapsed,
        paused: _currentState == GameLifecycleState.paused,
      ),
      uiState: UiState(
        showStartScreen: _currentState == GameLifecycleState.idle,
        showPauseModal: _currentState == GameLifecycleState.paused,
        showQuitModal: _currentState == GameLifecycleState.quit,
      ),
    );
    context.eventBus.publish(RenderFrameReady(_lastFrame));
  }
}
