import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TobaccoControlApp());
}

const int defaultDailyLimit = 7;
const int defaultMinIntervalMinutes = 90;
const int morningLimit = 1;
const int afternoonLimit = 3;
const int eveningLimit = 3;
const int cigaretteUnitPriceCents = 150;
const int dayStartHour = 11;
const int dayEndHour = 23;

class TobaccoControlApp extends StatelessWidget {
  const TobaccoControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff2e7d64),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: '控烟计划',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfff6f8f5),
        cardTheme: CardTheme(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xffdfe7df)),
          ),
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: false,
          backgroundColor: Color(0xfff6f8f5),
          surfaceTintColor: Colors.transparent,
        ),
      ),
      home: const SmokeHomePage(),
    );
  }
}

enum SmokePeriod {
  morning('上午', TimeOfDay(hour: 11, minute: 0), TimeOfDay(hour: 12, minute: 0),
      morningLimit),
  afternoon('下午', TimeOfDay(hour: 12, minute: 0),
      TimeOfDay(hour: 18, minute: 0), afternoonLimit),
  evening('晚上', TimeOfDay(hour: 18, minute: 0), TimeOfDay(hour: 23, minute: 0),
      eveningLimit),
  closed('禁烟时段', TimeOfDay(hour: 23, minute: 0), TimeOfDay(hour: 11, minute: 0),
      0);

  const SmokePeriod(this.label, this.start, this.end, this.limit);

  final String label;
  final TimeOfDay start;
  final TimeOfDay end;
  final int limit;
}

class SmokeSlot {
  const SmokeSlot({
    required this.period,
    required this.label,
    required this.time,
  });

  final SmokePeriod period;
  final String label;
  final DateTime time;
}

class SmokeEvent {
  const SmokeEvent({
    required this.id,
    required this.createdAt,
    required this.kind,
    required this.period,
    required this.note,
  });

  final int id;
  final DateTime createdAt;
  final String kind;
  final String period;
  final String note;

  bool get isSmoke => kind == 'smoke' || kind == 'makeup';
  bool get isControl => kind == 'control';
  bool get isDelay => kind == 'delay';
  bool get isMakeup => kind == 'makeup';
}

class AppSettings {
  const AppSettings({
    required this.dailyLimit,
    required this.minIntervalMinutes,
    this.pendingDelayStartedAt,
    this.pendingDelayAllowedAt,
  });

  final int dailyLimit;
  final int minIntervalMinutes;
  final DateTime? pendingDelayStartedAt;
  final DateTime? pendingDelayAllowedAt;

  Duration get minInterval => Duration(minutes: minIntervalMinutes);

  AppSettings copyWith({
    int? dailyLimit,
    int? minIntervalMinutes,
    DateTime? pendingDelayStartedAt,
    DateTime? pendingDelayAllowedAt,
    bool clearPendingDelay = false,
  }) {
    return AppSettings(
      dailyLimit: dailyLimit ?? this.dailyLimit,
      minIntervalMinutes: minIntervalMinutes ?? this.minIntervalMinutes,
      pendingDelayStartedAt: clearPendingDelay
          ? null
          : pendingDelayStartedAt ?? this.pendingDelayStartedAt,
      pendingDelayAllowedAt: clearPendingDelay
          ? null
          : pendingDelayAllowedAt ?? this.pendingDelayAllowedAt,
    );
  }
}

class DailySmokeCount {
  const DailySmokeCount(this.day, this.count);

  final DateTime day;
  final int count;
}

class TodayState {
  const TodayState({
    required this.now,
    required this.settings,
    required this.todayEvents,
    required this.last14Days,
    required this.totalSmokes,
    required this.totalControls,
    required this.controlStreak,
  });

  final DateTime now;
  final AppSettings settings;
  final List<SmokeEvent> todayEvents;
  final List<DailySmokeCount> last14Days;
  final int totalSmokes;
  final int totalControls;
  final int controlStreak;

  int get todaySmokes => todayEvents.where((event) => event.isSmoke).length;
  int get todayControls => todayEvents.where((event) => event.isControl).length;
  int get todayDelays => todayEvents.where((event) => event.isDelay).length;
  int get remainingToday => math.max(0, settings.dailyLimit - todaySmokes);
  SmokeEvent? get lastSmokeEvent {
    for (final event in todayEvents) {
      if (event.isSmoke) {
        return event;
      }
    }
    return null;
  }

  int countForPeriod(SmokePeriod period) {
    return todayEvents
        .where((event) => event.isSmoke && event.period == period.name)
        .length;
  }

  int get avoidedToday => math.max(0, settings.dailyLimit - todaySmokes);
  double get savedYuanToday => avoidedToday * cigaretteUnitPriceCents / 100;
}

class SmokeDatabase {
  SmokeDatabase._(this._db);

  final sqlite.Database _db;

  static Future<SmokeDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'tobacco_control.sqlite');
    final db = sqlite.sqlite3.open(dbPath);
    final store = SmokeDatabase._(db);
    store._migrate();
    return store;
  }

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS smoke_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at TEXT NOT NULL,
        day_key TEXT NOT NULL,
        kind TEXT NOT NULL,
        period TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT ''
      );
    ''');
    _relaxEventKindConstraintIfNeeded();
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_smoke_events_day ON smoke_events(day_key, created_at);');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    _insertDefaultSetting('daily_limit', '$defaultDailyLimit');
    _insertDefaultSetting('min_interval_minutes', '$defaultMinIntervalMinutes');
  }

  void _relaxEventKindConstraintIfNeeded() {
    final result = _db.select(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'smoke_events'",
    );
    if (result.isEmpty) {
      return;
    }
    final sql = result.first['sql'] as String;
    if (!sql.contains('CHECK(kind IN')) {
      return;
    }
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute('''
        CREATE TABLE smoke_events_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at TEXT NOT NULL,
          day_key TEXT NOT NULL,
          kind TEXT NOT NULL,
          period TEXT NOT NULL,
          note TEXT NOT NULL DEFAULT ''
        );
      ''');
      _db.execute('''
        INSERT INTO smoke_events_new(id, created_at, day_key, kind, period, note)
        SELECT id, created_at, day_key, kind, period, note FROM smoke_events;
      ''');
      _db.execute('DROP TABLE smoke_events');
      _db.execute('ALTER TABLE smoke_events_new RENAME TO smoke_events');
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _insertDefaultSetting(String key, String value) {
    final statement = _db.prepare(
      'INSERT OR IGNORE INTO app_settings(key, value) VALUES (?, ?)',
    );
    try {
      statement.execute([key, value]);
    } finally {
      statement.dispose();
    }
  }

  Future<void> addSmoke({
    required DateTime at,
    required SmokePeriod period,
    String note = '',
  }) async {
    _insert(at: at, kind: 'smoke', period: period, note: note);
  }

  Future<void> addMakeupSmoke({
    required DateTime at,
    required SmokePeriod period,
    String note = '',
  }) async {
    _insert(at: at, kind: 'makeup', period: period, note: note);
  }

  Future<void> addControl({
    required DateTime at,
    required SmokePeriod period,
    String note = '',
  }) async {
    _insert(at: at, kind: 'control', period: period, note: note);
  }

  Future<void> addDelay({
    required DateTime at,
    required SmokePeriod period,
    String note = '',
  }) async {
    _insert(at: at, kind: 'delay', period: period, note: note);
  }

  void _insert({
    required DateTime at,
    required String kind,
    required SmokePeriod period,
    required String note,
  }) {
    final statement = _db.prepare(
      'INSERT INTO smoke_events(created_at, day_key, kind, period, note) VALUES (?, ?, ?, ?, ?)',
    );
    try {
      statement
          .execute([at.toIso8601String(), dayKey(at), kind, period.name, note]);
    } finally {
      statement.dispose();
    }
  }

  Future<List<SmokeEvent>> eventsForDay(DateTime day) async {
    final result = _db.select(
      'SELECT * FROM smoke_events WHERE day_key = ? ORDER BY created_at DESC',
      [dayKey(day)],
    );
    return result.map(_eventFromRow).toList();
  }

  Future<List<DailySmokeCount>> lastDays(
      {required int days, required DateTime now}) async {
    final start = DateUtils.dateOnly(now).subtract(Duration(days: days - 1));
    final result = _db.select(
      '''
      SELECT day_key, COUNT(*) AS total
      FROM smoke_events
      WHERE kind = 'smoke' AND day_key >= ?
      GROUP BY day_key
      ORDER BY day_key ASC
      ''',
      [dayKey(start)],
    );
    final counts = <String, int>{};
    for (final row in result) {
      counts[row['day_key'] as String] = row['total'] as int;
    }
    return List.generate(days, (index) {
      final day = start.add(Duration(days: index));
      return DailySmokeCount(day, counts[dayKey(day)] ?? 0);
    });
  }

  Future<int> countByKind(String kind) async {
    final result = _db.select(
        'SELECT COUNT(*) AS total FROM smoke_events WHERE kind = ?', [kind]);
    return result.first['total'] as int;
  }

  Future<AppSettings> loadSettings() async {
    final result = _db.select('SELECT key, value FROM app_settings');
    final values = {
      for (final row in result) row['key'] as String: row['value'] as String,
    };
    return AppSettings(
      dailyLimit:
          int.tryParse(values['daily_limit'] ?? '') ?? defaultDailyLimit,
      minIntervalMinutes: int.tryParse(values['min_interval_minutes'] ?? '') ??
          defaultMinIntervalMinutes,
      pendingDelayStartedAt: _parseNullableDate(
        values['pending_delay_started_at'],
      ),
      pendingDelayAllowedAt: _parseNullableDate(
        values['pending_delay_allowed_at'],
      ),
    );
  }

  Future<void> saveSettings({
    required int dailyLimit,
    required int minIntervalMinutes,
  }) async {
    _upsertSetting('daily_limit', '$dailyLimit');
    _upsertSetting('min_interval_minutes', '$minIntervalMinutes');
  }

  Future<void> setPendingDelay({
    required DateTime startedAt,
    required DateTime allowedAt,
  }) async {
    _upsertSetting('pending_delay_started_at', startedAt.toIso8601String());
    _upsertSetting('pending_delay_allowed_at', allowedAt.toIso8601String());
  }

  Future<void> clearPendingDelay() async {
    _db.execute(
      "DELETE FROM app_settings WHERE key IN ('pending_delay_started_at', 'pending_delay_allowed_at')",
    );
  }

  void _upsertSetting(String key, String value) {
    final statement = _db.prepare('''
      INSERT INTO app_settings(key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
    ''');
    try {
      statement.execute([key, value]);
    } finally {
      statement.dispose();
    }
  }

  Future<int> controlStreak(DateTime now) async {
    var streak = 0;
    for (var offset = 0; offset < 365; offset++) {
      final day = DateUtils.dateOnly(now).subtract(Duration(days: offset));
      final result = _db.select(
        'SELECT COUNT(*) AS total FROM smoke_events WHERE kind = ? AND day_key = ?',
        ['control', dayKey(day)],
      );
      final total = result.first['total'] as int;
      if (total == 0) {
        break;
      }
      streak++;
    }
    return streak;
  }

  Future<TodayState> loadState() async {
    final now = DateTime.now();
    final settings = await loadSettings();
    final todayEvents = await eventsForDay(now);
    return TodayState(
      now: now,
      settings: settings,
      todayEvents: todayEvents,
      last14Days: await lastDays(days: 14, now: now),
      totalSmokes: await countByKind('smoke'),
      totalControls: await countByKind('control'),
      controlStreak: await controlStreak(now),
    );
  }

  SmokeEvent _eventFromRow(sqlite.Row row) {
    return SmokeEvent(
      id: row['id'] as int,
      createdAt: DateTime.parse(row['created_at'] as String),
      kind: row['kind'] as String,
      period: row['period'] as String,
      note: row['note'] as String? ?? '',
    );
  }

  DateTime? _parseNullableDate(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  void close() => _db.dispose();
}

class SmokeHomePage extends StatefulWidget {
  const SmokeHomePage({super.key});

  @override
  State<SmokeHomePage> createState() => _SmokeHomePageState();
}

class _SmokeHomePageState extends State<SmokeHomePage> {
  SmokeDatabase? _db;
  TodayState? _state;
  Timer? _timer;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _reload());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _db?.close();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final db = await SmokeDatabase.open();
      _db = db;
      await _reload();
    } catch (error) {
      setState(() {
        _error = '数据库初始化失败：$error';
        _isLoading = false;
      });
    }
  }

  Future<void> _reload() async {
    final db = _db;
    if (db == null) {
      return;
    }
    final state = await db.loadState();
    if (!mounted) {
      return;
    }
    setState(() {
      _state = state;
      _isLoading = false;
    });
  }

  Future<void> _recordSmoke(SmokePeriod period) async {
    final state = _state;
    final db = _db;
    if (state == null || db == null) {
      return;
    }
    final decision = SmokeDecision.fromState(state);
    if (!decision.canSmoke) {
      _showMessage(decision.blockReason ?? '现在不建议抽烟，再忍一下。');
      return;
    }
    final now = DateTime.now();
    final delayMinutes = _delayMinutes(state, now);
    await db.addSmoke(
      at: now,
      period: period,
      note: delayMinutes > 0 ? '延后 $delayMinutes 分钟后，先打卡再吸烟' : '到点后先打卡再吸烟',
    );
    await db.clearPendingDelay();
    await _reload();
    _showMessage('已打卡。抽完这一支就回到控制节奏，下一支尽量再晚一点。');
  }

  Future<void> _recordControl(SmokePeriod period) async {
    final db = _db;
    if (db == null) {
      return;
    }
    await db.addControl(at: DateTime.now(), period: period, note: '提醒后选择继续控制');
    await _reload();
    _showMessage('做得很好，你又把冲动压下去了一次。多忍一会就是进步。');
  }

  Future<void> _recordDelay() async {
    final state = _state;
    final db = _db;
    if (state == null || db == null) {
      return;
    }
    final decision = SmokeDecision.fromState(state);
    if (!decision.canSmoke || decision.allowedAt == null) {
      _showMessage(decision.blockReason ?? '还没到可吸烟时间，先继续控制。');
      return;
    }
    final now = DateTime.now();
    await db.addDelay(
      at: now,
      period: decision.period,
      note: '到点后选择延后吸烟',
    );
    await db.setPendingDelay(startedAt: now, allowedAt: decision.allowedAt!);
    await _reload();
    _showMessage('已记录延后。现在不抽，就是一次实实在在的控制。');
  }

  Future<void> _recordMakeupSmoke() async {
    final state = _state;
    final db = _db;
    if (state == null || db == null) {
      return;
    }
    final now = DateTime.now();
    final period = currentPeriod(now) == SmokePeriod.closed
        ? SmokePeriod.morning
        : currentPeriod(now);
    await db.addMakeupSmoke(
      at: now,
      period: period,
      note: '未到可吸烟时间，憋不住后补录打卡',
    );
    await db.clearPendingDelay();
    await _reload();
    _showMessage('已补录。这次先记下来，下一次尽量按间隔来。');
  }

  Future<void> _openSettings() async {
    final state = _state;
    final db = _db;
    if (state == null || db == null) {
      return;
    }
    final updated = await Navigator.of(context).push<AppSettings>(
      MaterialPageRoute(
        builder: (_) => SettingsPage(settings: state.settings),
      ),
    );
    if (updated == null) {
      return;
    }
    await db.saveSettings(
      dailyLimit: updated.dailyLimit,
      minIntervalMinutes: updated.minIntervalMinutes,
    );
    await _reload();
    _showMessage('设置已保存。新的控烟规则从现在开始生效。');
  }

  int _delayMinutes(TodayState state, DateTime now) {
    final allowedAt = state.settings.pendingDelayAllowedAt;
    if (allowedAt == null || now.isBefore(allowedAt)) {
      return 0;
    }
    return now.difference(allowedAt).inMinutes;
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('控烟计划'),
        actions: [
          IconButton(
            tooltip: '规则',
            onPressed: () => showRulesSheet(context),
            icon: const Icon(Icons.rule_outlined),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : state == null
                  ? const Center(child: Text('暂无数据'))
                  : _Dashboard(
                      state: state,
                      onSmoke: _recordSmoke,
                      onControl: _recordControl,
                      onDelay: _recordDelay,
                      onMakeupSmoke: _recordMakeupSmoke,
                    ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    required this.state,
    required this.onSmoke,
    required this.onControl,
    required this.onDelay,
    required this.onMakeupSmoke,
  });

  final TodayState state;
  final Future<void> Function(SmokePeriod period) onSmoke;
  final Future<void> Function(SmokePeriod period) onControl;
  final Future<void> Function() onDelay;
  final Future<void> Function() onMakeupSmoke;

  @override
  Widget build(BuildContext context) {
    final decision = SmokeDecision.fromState(state);

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async {},
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            _HeroSummary(state: state, decision: decision),
            const SizedBox(height: 14),
            _ReminderCard(
              state: state,
              decision: decision,
              onSmoke: onSmoke,
              onControl: onControl,
              onDelay: onDelay,
              onMakeupSmoke: onMakeupSmoke,
            ),
            const SizedBox(height: 14),
            _PeriodQuotaCard(state: state),
            const SizedBox(height: 14),
            _DelayControlCard(
              decision: decision,
              onControl: onControl,
            ),
            const SizedBox(height: 14),
            _ChartCard(state: state),
            const SizedBox(height: 14),
            _AchievementCard(state: state),
            const SizedBox(height: 14),
            _HistoryCard(events: state.todayEvents),
          ],
        ),
      ),
    );
  }
}

class _HeroSummary extends StatelessWidget {
  const _HeroSummary({required this.state, required this.decision});

  final TodayState state;
  final SmokeDecision decision;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          colors: [Color(0xff173f34), Color(0xff275e4f)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatChineseDate(state.now),
            style: theme.textTheme.labelLarge?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Text(
            '今天已抽 ${state.todaySmokes} / ${state.settings.dailyLimit} 根',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            decision.summary,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: Colors.white.withValues(alpha: 0.84)),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 620;
              final cards = [
                _MiniMetric(label: '剩余额度', value: '${state.remainingToday} 根'),
                _MiniMetric(
                    label: '最低间隔',
                    value: '${state.settings.minIntervalMinutes} 分钟'),
                _MiniMetric(label: '今日忍住', value: '${state.todayControls} 次'),
                _MiniMetric(
                    label: '节省估算',
                    value: '${state.savedYuanToday.toStringAsFixed(1)} 元'),
              ];
              return wide
                  ? Row(
                      children:
                          cards.map((card) => Expanded(child: card)).toList())
                  : Column(children: cards);
            },
          ),
        ],
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(right: 8, bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({
    required this.state,
    required this.decision,
    required this.onSmoke,
    required this.onControl,
    required this.onDelay,
    required this.onMakeupSmoke,
  });

  final TodayState state;
  final SmokeDecision decision;
  final Future<void> Function(SmokePeriod period) onSmoke;
  final Future<void> Function(SmokePeriod period) onControl;
  final Future<void> Function() onDelay;
  final Future<void> Function() onMakeupSmoke;

  @override
  Widget build(BuildContext context) {
    final period = currentPeriod(state.now);
    final lastSmoke = state.lastSmokeEvent;
    final nextText = decision.allowedAt == null
        ? '暂无'
        : intl.DateFormat('HH:mm').format(decision.allowedAt!);
    final remainingText = decision.canSmoke
        ? '现在可以'
        : decision.remaining == null
            ? '明天再看'
            : formatDurationZh(decision.remaining!);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  decision.canSmoke
                      ? Icons.notifications_active_outlined
                      : Icons.hourglass_bottom_outlined,
                  color: decision.canSmoke
                      ? const Color(0xffd17b00)
                      : const Color(0xff2e7d64),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    decision.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              decision.canSmoke
                  ? '你现在可以抽烟了，你可以选择[抽一支]，也可以选择[继续控制]，建议继续控制，尽量多忍一会是一会。'
                  : decision.blockReason ?? '还没到下一次可吸烟时间，建议继续控制。',
              style:
                  Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.55),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _InfoChip(
                  icon: Icons.history_outlined,
                  label: '上次吸烟',
                  value: lastSmoke == null
                      ? '今天还没有'
                      : intl.DateFormat('HH:mm').format(lastSmoke.createdAt),
                ),
                _InfoChip(
                  icon: Icons.event_available_outlined,
                  label: '下次可吸',
                  value: nextText,
                ),
                _InfoChip(
                  icon: Icons.timer_outlined,
                  label: '还需等待',
                  value: remainingText,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: decision.canSmoke ? () => onSmoke(period) : null,
                  icon: const Icon(Icons.smoking_rooms_outlined),
                  label: const Text('先打卡，再吸烟'),
                ),
                FilledButton.tonalIcon(
                  onPressed: decision.canSmoke ? onDelay : null,
                  icon: const Icon(Icons.snooze_outlined),
                  label: const Text('延后吸烟'),
                ),
                OutlinedButton.icon(
                  onPressed: () => onControl(period == SmokePeriod.closed
                      ? SmokePeriod.morning
                      : period),
                  icon: const Icon(Icons.favorite_outline),
                  label: const Text('继续控制'),
                ),
                OutlinedButton.icon(
                  onPressed: onMakeupSmoke,
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('补录打卡'),
                ),
              ],
            ),
            if (state.settings.pendingDelayStartedAt != null) ...[
              const SizedBox(height: 12),
              Text(
                '已延后 ${formatDurationZh(state.now.difference(state.settings.pendingDelayStartedAt!))}。想抽时先点“先打卡，再吸烟”，系统会记录延后时长。',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: const Color(0xff2e7d64), height: 1.45),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xfff1f6f2),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xffdfe9e2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: const Color(0xff2e7d64)),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Colors.black54)),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
            ],
          ),
        ],
      ),
    );
  }
}

class _PeriodQuotaCard extends StatelessWidget {
  const _PeriodQuotaCard({required this.state});

  final TodayState state;

  @override
  Widget build(BuildContext context) {
    final periods = [
      SmokePeriod.morning,
      SmokePeriod.afternoon,
      SmokePeriod.evening
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '今日分时段控制',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            for (final period in periods)
              _PeriodRow(period: period, used: state.countForPeriod(period)),
            const Divider(height: 28),
            Text(
              '基础节奏：11:00 后再开始，23:00 后不再抽；两次吸烟至少间隔 ${state.settings.minIntervalMinutes} 分钟。能忍住就延后或跳过这一根。',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.black54, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodRow extends StatelessWidget {
  const _PeriodRow({required this.period, required this.used});

  final SmokePeriod period;
  final int used;

  @override
  Widget build(BuildContext context) {
    final progress =
        period.limit == 0 ? 0.0 : (used / period.limit).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${period.label} ${formatTime(period.start)}-${formatTime(period.end)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text('$used / ${period.limit} 根'),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: progress,
            minHeight: 10,
            borderRadius: BorderRadius.circular(99),
            backgroundColor: const Color(0xffe4ece6),
          ),
        ],
      ),
    );
  }
}

class _DelayControlCard extends StatelessWidget {
  const _DelayControlCard({
    required this.decision,
    required this.onControl,
  });

  final SmokeDecision decision;
  final Future<void> Function(SmokePeriod period) onControl;

  @override
  Widget build(BuildContext context) {
    final ideas = [
      '喝一杯水，慢慢喝完再决定。',
      '做 10 次深呼吸，把想抽的冲动拖过去。',
      '出门走 3 分钟，离开触发场景。',
      '把烟放远一点，不随手拿得到。',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '有效控烟动作',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            for (final idea in ideas)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_outline,
                        size: 20, color: Color(0xff2e7d64)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(idea)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => onControl(decision.period == SmokePeriod.closed
                  ? SmokePeriod.morning
                  : decision.period),
              icon: const Icon(Icons.timer_outlined),
              label: const Text('我先忍 5 分钟，并记录一次控制成功'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.state});

  final TodayState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '最近 14 天吸烟趋势',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 190,
              child: CustomPaint(
                painter: SmokeBarChartPainter(
                    state.last14Days, state.settings.dailyLimit),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AchievementCard extends StatelessWidget {
  const _AchievementCard({required this.state});

  final TodayState state;

  @override
  Widget build(BuildContext context) {
    final avoidedTotal = math.max(0, state.totalControls);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '控烟成果',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _PillMetric(
                    icon: Icons.shield_outlined,
                    label: '总计忍住',
                    value: '$avoidedTotal 次'),
                _PillMetric(
                    icon: Icons.local_fire_department_outlined,
                    label: '连续控制',
                    value: '${state.controlStreak} 天'),
                _PillMetric(
                    icon: Icons.savings_outlined,
                    label: '累计少花',
                    value:
                        '${(state.totalControls * cigaretteUnitPriceCents / 100).toStringAsFixed(1)} 元'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PillMetric extends StatelessWidget {
  const _PillMetric(
      {required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xffeef6f1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xff2e7d64)),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.black54)),
              Text(value,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 18)),
            ],
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.events});

  final List<SmokeEvent> events;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '今日记录',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            if (events.isEmpty)
              const Text('还没有记录。今天的目标是：能不抽就不抽，必须抽也要打卡。')
            else
              for (final event in events)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(eventIcon(event),
                      color: event.isSmoke
                          ? Colors.orange.shade800
                          : const Color(0xff2e7d64)),
                  title: Text(eventTitle(event)),
                  subtitle:
                      Text('${periodLabel(event.period)} · ${event.note}'),
                  trailing:
                      Text(intl.DateFormat('HH:mm').format(event.createdAt)),
                ),
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late double _dailyLimit;
  late double _minIntervalMinutes;

  @override
  void initState() {
    super.initState();
    _dailyLimit = widget.settings.dailyLimit.toDouble();
    _minIntervalMinutes = widget.settings.minIntervalMinutes.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('控烟设置'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
          children: [
            _SettingSliderCard(
              title: '每天吸烟上限',
              subtitle: '超过这个数量后，首页会提示今天额度已用完。',
              valueText: '${_dailyLimit.round()} 根',
              value: _dailyLimit,
              min: 1,
              max: 20,
              divisions: 19,
              onChanged: (value) => setState(() => _dailyLimit = value),
            ),
            const SizedBox(height: 14),
            _SettingSliderCard(
              title: '每次最低间隔',
              subtitle: '两次吸烟至少隔这么久。间隔越长，越容易减少总量。',
              valueText: '${_minIntervalMinutes.round()} 分钟',
              value: _minIntervalMinutes,
              min: 15,
              max: 240,
              divisions: 15,
              onChanged: (value) => setState(() => _minIntervalMinutes = value),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop(
                  widget.settings.copyWith(
                    dailyLimit: _dailyLimit.round(),
                    minIntervalMinutes: _minIntervalMinutes.round(),
                  ),
                );
              },
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存设置'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingSliderCard extends StatelessWidget {
  const _SettingSliderCard({
    required this.title,
    required this.subtitle,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  valueText,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xff2e7d64),
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.black54, height: 1.45),
            ),
            Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: valueText,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class SmokeBarChartPainter extends CustomPainter {
  SmokeBarChartPainter(this.values, this.limit);

  final List<DailySmokeCount> values;
  final int limit;

  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = const Color(0xffdce6de)
      ..strokeWidth = 1;
    final limitPaint = Paint()
      ..color = const Color(0xffefb45b)
      ..strokeWidth = 1.2;
    final barPaint = Paint()
      ..color = const Color(0xff2e7d64)
      ..style = PaintingStyle.fill;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final chartTop = 8.0;
    final chartBottom = size.height - 28;
    final chartHeight = chartBottom - chartTop;
    final maxValue =
        math.max(limit, values.map((value) => value.count).fold(0, math.max));
    final slotWidth = size.width / values.length;

    canvas.drawLine(
        Offset(0, chartBottom), Offset(size.width, chartBottom), axisPaint);
    final limitY = chartBottom - chartHeight * (limit / maxValue);
    canvas.drawLine(Offset(0, limitY), Offset(size.width, limitY), limitPaint);

    for (var i = 0; i < values.length; i++) {
      final item = values[i];
      final barWidth = math.max(8.0, slotWidth * 0.46);
      final barHeight = chartHeight * (item.count / maxValue);
      final left = i * slotWidth + (slotWidth - barWidth) / 2;
      final top = chartBottom - barHeight;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, top, barWidth, barHeight),
        const Radius.circular(8),
      );
      canvas.drawRRect(rect, barPaint);

      if (i == values.length - 1 || item.day.day == 1 || i % 4 == 0) {
        textPainter.text = TextSpan(
          text: intl.DateFormat('M/d').format(item.day),
          style: const TextStyle(fontSize: 10, color: Color(0xff66756f)),
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(i * slotWidth + 2, chartBottom + 8));
      }
    }

    textPainter.text = TextSpan(
      text: '$limit 根上限',
      style: const TextStyle(fontSize: 11, color: Color(0xff9b6508)),
    );
    textPainter.layout();
    textPainter.paint(canvas,
        Offset(size.width - textPainter.width, math.max(0, limitY - 18)));
  }

  @override
  bool shouldRepaint(covariant SmokeBarChartPainter oldDelegate) {
    return oldDelegate.values != values || oldDelegate.limit != limit;
  }
}

class SmokeDecision {
  const SmokeDecision({
    required this.canSmoke,
    required this.period,
    required this.title,
    required this.summary,
    this.allowedAt,
    this.remaining,
    this.blockReason,
  });

  final bool canSmoke;
  final SmokePeriod period;
  final String title;
  final String summary;
  final DateTime? allowedAt;
  final Duration? remaining;
  final String? blockReason;

  static SmokeDecision fromState(TodayState state) {
    final now = state.now;
    final period = currentPeriod(now);
    final nextTime = nextAllowedTime(now, state);
    final remaining = nextTime == null || !nextTime.isAfter(now)
        ? Duration.zero
        : nextTime.difference(now);

    if (state.todaySmokes >= state.settings.dailyLimit) {
      return SmokeDecision(
        canSmoke: false,
        period: SmokePeriod.closed,
        title: '今日额度已用完',
        summary: '今天已经达到 ${state.settings.dailyLimit} 根上限，后面不要再抽。',
        allowedAt: nextTime,
        remaining: remaining,
        blockReason: '今天已经达到 ${state.settings.dailyLimit} 根上限。为了达成控烟目标，后面不要再抽。',
      );
    }
    if (period == SmokePeriod.closed) {
      final next = nextTime == null
          ? '明天 11:00'
          : formatDateTimeForDecision(nextTime, now);
      return SmokeDecision(
        canSmoke: false,
        period: period,
        title: '现在是禁烟时段',
        summary: '下一次规则允许时间：$next。',
        allowedAt: nextTime,
        remaining: remaining,
        blockReason: '现在还不能抽。每天 11:00 后才进入可吸烟窗口，23:00 后不要再抽。',
      );
    }

    if (nextTime != null && nextTime.isAfter(now)) {
      final next = formatDateTimeForDecision(nextTime, now);
      return SmokeDecision(
        canSmoke: false,
        period: period,
        title: '还没到最低间隔',
        summary: '下一次规则允许时间：$next。',
        allowedAt: nextTime,
        remaining: remaining,
        blockReason:
            '为了把吸烟时间拉开，两次至少间隔 ${state.settings.minIntervalMinutes} 分钟。下一次可选时间是 $next。',
      );
    }

    return SmokeDecision(
      canSmoke: true,
      period: period,
      title: '到达可选吸烟时间',
      summary: '你可以选择抽一支，也可以继续控制。建议继续控制。',
      allowedAt: nextTime ?? now,
      remaining: Duration.zero,
    );
  }
}

SmokePeriod currentPeriod(DateTime now) {
  final minutes = now.hour * 60 + now.minute;
  if (minutes >= 11 * 60 && minutes < 12 * 60) {
    return SmokePeriod.morning;
  }
  if (minutes >= 12 * 60 && minutes < 18 * 60) {
    return SmokePeriod.afternoon;
  }
  if (minutes >= 18 * 60 && minutes < 23 * 60) {
    return SmokePeriod.evening;
  }
  return SmokePeriod.closed;
}

DateTime? nextAllowedTime(DateTime now, TodayState state) {
  final today = DateUtils.dateOnly(now);
  final dayStart = today.add(const Duration(hours: dayStartHour));
  final dayEnd = today.add(const Duration(hours: dayEndHour));
  final tomorrowStart = dayStart.add(const Duration(days: 1));

  if (!now.isBefore(dayEnd) || state.todaySmokes >= state.settings.dailyLimit) {
    return tomorrowStart;
  }

  var allowedAt = dayStart;
  final lastSmoke = state.lastSmokeEvent;
  if (lastSmoke != null) {
    final intervalReady = lastSmoke.createdAt.add(state.settings.minInterval);
    if (intervalReady.isAfter(allowedAt)) {
      allowedAt = intervalReady;
    }
  }

  if (!allowedAt.isBefore(dayEnd)) {
    return tomorrowStart;
  }
  return allowedAt.isAfter(now) ? allowedAt : now;
}

List<SmokeSlot> slotsForDay(DateTime day) {
  final date = DateUtils.dateOnly(day);
  return [
    SmokeSlot(
        period: SmokePeriod.morning,
        label: '上午第 1 根',
        time: date.add(const Duration(hours: 11))),
    SmokeSlot(
        period: SmokePeriod.afternoon,
        label: '下午第 1 根',
        time: date.add(const Duration(hours: 12))),
    SmokeSlot(
        period: SmokePeriod.afternoon,
        label: '下午第 2 根',
        time: date.add(const Duration(hours: 15))),
    SmokeSlot(
        period: SmokePeriod.afternoon,
        label: '下午第 3 根',
        time: date.add(const Duration(hours: 17, minutes: 30))),
    SmokeSlot(
        period: SmokePeriod.evening,
        label: '晚上第 1 根',
        time: date.add(const Duration(hours: 18))),
    SmokeSlot(
        period: SmokePeriod.evening,
        label: '晚上第 2 根',
        time: date.add(const Duration(hours: 20, minutes: 30))),
    SmokeSlot(
        period: SmokePeriod.evening,
        label: '晚上第 3 根',
        time: date.add(const Duration(hours: 22, minutes: 30))),
  ];
}

SmokeSlot? currentAvailableSlot(DateTime now, TodayState state) {
  final period = currentPeriod(now);
  if (period == SmokePeriod.closed) {
    return null;
  }
  final used = state.countForPeriod(period);
  final periodSlots =
      slotsForDay(now).where((slot) => slot.period == period).toList();
  if (used >= periodSlots.length) {
    return null;
  }
  final slot = periodSlots[used];
  return now.isBefore(slot.time) ? null : slot;
}

SmokeSlot? nextAllowedSlot(DateTime now, TodayState state) {
  final slots = [
    ...slotsForDay(now),
    ...slotsForDay(now.add(const Duration(days: 1)))
  ];
  for (final slot in slots) {
    if (slot.time.isBefore(now)) {
      continue;
    }
    if (slot.time.day == now.day &&
        state.countForPeriod(slot.period) >= slot.period.limit) {
      continue;
    }
    return slot;
  }
  return null;
}

String dayKey(DateTime date) {
  return intl.DateFormat('yyyy-MM-dd').format(date);
}

String formatChineseDate(DateTime date) {
  const weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  return '${date.month}月${date.day}日 ${weekdays[date.weekday - 1]}';
}

String formatTime(TimeOfDay time) {
  return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

String periodLabel(String name) {
  for (final period in SmokePeriod.values) {
    if (period.name == name) {
      return period.label;
    }
  }
  return name;
}

String formatDurationZh(Duration duration) {
  final minutes = math.max(0, duration.inMinutes);
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) {
    return '$rest 分钟';
  }
  if (rest == 0) {
    return '$hours 小时';
  }
  return '$hours 小时 $rest 分钟';
}

String formatDateTimeForDecision(DateTime target, DateTime now) {
  final today = DateUtils.dateOnly(now);
  if (DateUtils.isSameDay(target, today)) {
    return intl.DateFormat('HH:mm').format(target);
  }
  return '明天 ${intl.DateFormat('HH:mm').format(target)}';
}

IconData eventIcon(SmokeEvent event) {
  if (event.isMakeup) {
    return Icons.edit_calendar_outlined;
  }
  if (event.isDelay) {
    return Icons.snooze_outlined;
  }
  if (event.isSmoke) {
    return Icons.smoking_rooms_outlined;
  }
  return Icons.favorite_outline;
}

String eventTitle(SmokeEvent event) {
  if (event.isMakeup) {
    return '补录吸烟';
  }
  if (event.isDelay) {
    return '延后吸烟';
  }
  if (event.isSmoke) {
    return '打卡吸烟';
  }
  return '继续控制';
}

void showRulesSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '使用规则',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 12),
              const _RuleLine(
                icon: Icons.lock_clock_outlined,
                text: '每天 11:00 后才开始，23:00 后就不要再抽。',
              ),
              const _RuleLine(
                icon: Icons.speed_outlined,
                text: '每天最多抽几根、两次至少隔多久，都可以在设置里改。',
              ),
              const _RuleLine(
                icon: Icons.touch_app_outlined,
                text: '想抽烟时先打开 App，看上次时间和还要等多久。',
              ),
              const _RuleLine(
                icon: Icons.check_circle_outline,
                text: '到了可吸烟时间，如果真的要抽，先点打卡，再吸烟。',
              ),
              const _RuleLine(
                icon: Icons.snooze_outlined,
                text: '如果能忍住，就点延后或继续控制，系统会记录你延后了多久。',
              ),
              const _RuleLine(
                icon: Icons.edit_calendar_outlined,
                text: '如果没到时间就憋不住抽了，也要补录打卡，先把真实情况记下来。',
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _RuleLine extends StatelessWidget {
  const _RuleLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xff2e7d64)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style:
                  Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
