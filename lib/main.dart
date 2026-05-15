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

const int dailyLimit = 7;
const int morningLimit = 1;
const int afternoonLimit = 3;
const int eveningLimit = 3;
const int cigaretteUnitPriceCents = 150;

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

  bool get isSmoke => kind == 'smoke';
  bool get isControl => kind == 'control';
}

class DailySmokeCount {
  const DailySmokeCount(this.day, this.count);

  final DateTime day;
  final int count;
}

class TodayState {
  const TodayState({
    required this.now,
    required this.todayEvents,
    required this.last14Days,
    required this.totalSmokes,
    required this.totalControls,
    required this.controlStreak,
  });

  final DateTime now;
  final List<SmokeEvent> todayEvents;
  final List<DailySmokeCount> last14Days;
  final int totalSmokes;
  final int totalControls;
  final int controlStreak;

  int get todaySmokes => todayEvents.where((event) => event.isSmoke).length;
  int get todayControls => todayEvents.where((event) => event.isControl).length;
  int get remainingToday => math.max(0, dailyLimit - todaySmokes);

  int countForPeriod(SmokePeriod period) {
    return todayEvents
        .where((event) => event.isSmoke && event.period == period.name)
        .length;
  }

  int get avoidedToday => math.max(0, dailyLimit - todaySmokes);
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
        kind TEXT NOT NULL CHECK(kind IN ('smoke', 'control')),
        period TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT ''
      );
    ''');
    _db.execute(
        'CREATE INDEX IF NOT EXISTS idx_smoke_events_day ON smoke_events(day_key, created_at);');
  }

  Future<void> addSmoke({
    required DateTime at,
    required SmokePeriod period,
    String note = '',
  }) async {
    _insert(at: at, kind: 'smoke', period: period, note: note);
  }

  Future<void> addControl({
    required DateTime at,
    required SmokePeriod period,
    String note = '',
  }) async {
    _insert(at: at, kind: 'control', period: period, note: note);
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
    final todayEvents = await eventsForDay(now);
    return TodayState(
      now: now,
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
      note: row['note'] as String,
    );
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
    await db.addSmoke(at: DateTime.now(), period: period, note: '提醒后选择抽一支');
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
                    ),
    );
  }
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    required this.state,
    required this.onSmoke,
    required this.onControl,
  });

  final TodayState state;
  final Future<void> Function(SmokePeriod period) onSmoke;
  final Future<void> Function(SmokePeriod period) onControl;

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
            '今天已抽 ${state.todaySmokes} / $dailyLimit 根',
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
  });

  final TodayState state;
  final SmokeDecision decision;
  final Future<void> Function(SmokePeriod period) onSmoke;
  final Future<void> Function(SmokePeriod period) onControl;

  @override
  Widget build(BuildContext context) {
    final period = currentPeriod(state.now);

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
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: decision.canSmoke ? () => onSmoke(period) : null,
                  icon: const Icon(Icons.smoking_rooms_outlined),
                  label: const Text('抽一支并打卡'),
                ),
                OutlinedButton.icon(
                  onPressed: () => onControl(period == SmokePeriod.closed
                      ? SmokePeriod.morning
                      : period),
                  icon: const Icon(Icons.favorite_outline),
                  label: const Text('继续控制'),
                ),
              ],
            ),
          ],
        ),
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
              '推荐节奏：11:00 后 1 根；12:00-18:00 最多 3 根；18:00-23:00 最多 3 根。每一段都按均匀间隔安排，能忍住就跳过这一根。',
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
                painter: SmokeBarChartPainter(state.last14Days),
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
                  leading: Icon(
                    event.isSmoke
                        ? Icons.smoking_rooms_outlined
                        : Icons.favorite_outline,
                    color: event.isSmoke
                        ? Colors.orange.shade800
                        : const Color(0xff2e7d64),
                  ),
                  title: Text(event.isSmoke ? '抽了一支' : '继续控制'),
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

class SmokeBarChartPainter extends CustomPainter {
  SmokeBarChartPainter(this.values);

  final List<DailySmokeCount> values;

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
    final maxValue = math.max(
        dailyLimit, values.map((value) => value.count).fold(0, math.max));
    final slotWidth = size.width / values.length;

    canvas.drawLine(
        Offset(0, chartBottom), Offset(size.width, chartBottom), axisPaint);
    final limitY = chartBottom - chartHeight * (dailyLimit / maxValue);
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

    textPainter.text = const TextSpan(
      text: '7 根上限',
      style: TextStyle(fontSize: 11, color: Color(0xff9b6508)),
    );
    textPainter.layout();
    textPainter.paint(canvas,
        Offset(size.width - textPainter.width, math.max(0, limitY - 18)));
  }

  @override
  bool shouldRepaint(covariant SmokeBarChartPainter oldDelegate) {
    return oldDelegate.values != values;
  }
}

class SmokeDecision {
  const SmokeDecision({
    required this.canSmoke,
    required this.period,
    required this.title,
    required this.summary,
    this.blockReason,
  });

  final bool canSmoke;
  final SmokePeriod period;
  final String title;
  final String summary;
  final String? blockReason;

  static SmokeDecision fromState(TodayState state) {
    final now = state.now;
    final period = currentPeriod(now);
    final nextSlot = nextAllowedSlot(now, state);

    if (state.todaySmokes >= dailyLimit) {
      return const SmokeDecision(
        canSmoke: false,
        period: SmokePeriod.closed,
        title: '今日额度已用完',
        summary: '今天已经达到 7 根上限，后面不要再抽。',
        blockReason: '今天已经达到 7 根上限。为了达成控烟目标，后面不要再抽。',
      );
    }
    if (period == SmokePeriod.closed) {
      final next = nextSlot == null
          ? '明天 11:00'
          : intl.DateFormat('HH:mm').format(nextSlot.time);
      return SmokeDecision(
        canSmoke: false,
        period: period,
        title: '现在是禁烟时段',
        summary: '下一次规则允许时间：$next。',
        blockReason: '现在还不能抽。上午 11 点后才进入第一支可选时间。',
      );
    }
    if (state.countForPeriod(period) >= period.limit) {
      final next = nextSlot == null
          ? '明天 11:00'
          : intl.DateFormat('HH:mm').format(nextSlot.time);
      return SmokeDecision(
        canSmoke: false,
        period: period,
        title: '${period.label}额度已满',
        summary: '下一次规则允许时间：$next。',
        blockReason: '${period.label}已经达到 ${period.limit} 根上限，下一次可选时间是 $next。',
      );
    }

    final availableSlot = currentAvailableSlot(now, state);
    if (availableSlot == null) {
      final next = nextSlot == null
          ? '明天 11:00'
          : intl.DateFormat('HH:mm').format(nextSlot.time);
      return SmokeDecision(
        canSmoke: false,
        period: period,
        title: '还没到均匀间隔',
        summary: '下一次可选时间：$next。',
        blockReason: '为了把时间分散开，现在先不抽。下一次可选时间是 $next。',
      );
    }

    return SmokeDecision(
      canSmoke: true,
      period: period,
      title: '到达可选吸烟时间',
      summary: '你可以选择抽一支，也可以继续控制。建议继续控制。',
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
