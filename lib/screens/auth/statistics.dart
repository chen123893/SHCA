import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shca/models/health_statistics.dart';
import 'package:shca/screens/auth/caregiver_dashboard.dart';
import 'package:shca/screens/auth/caregiver_medication_schedule.dart';
import 'package:shca/screens/auth/caregiver_shared.dart';
import 'package:shca/screens/auth/elderly_shared.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/gemini_statistics_service.dart';
import 'package:shca/services/health_statistics_service.dart';
import 'package:shca/services/statistics_pdf_service.dart';
import 'package:shca/widgets/statistics_charts.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key, this.repository, this.forecastService});
  final HealthStatisticsRepository? repository;
  final AiStatisticsService? forecastService;
  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> {
  late final HealthStatisticsRepository _repository;
  late final AiStatisticsService _forecastService;
  List<LinkedElderly> _people = [];
  String? _elderlyId;
  String? _accountError;
  bool _loadingAccounts = true;
  bool _exporting = false;
  int _period = 30;
  Future<StatisticsHistory>? _history;
  Future<AiStatisticsForecast>? _aiForecast;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? FirestoreHealthStatisticsRepository();
    _forecastService = widget.forecastService ?? AiStatisticsService();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    setState(() {
      _loadingAccounts = true;
      _accountError = null;
    });
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw StateError('Please sign in to see statistics.');
      final people = await FirestoreCareLinkRepository().loadLinkedElderly(
        user.uid,
      );
      if (!mounted) return;
      setState(() {
        _people = people;
        _elderlyId = people.isEmpty ? null : people.first.id;
        _loadingAccounts = false;
        _reload();
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingAccounts = false;
          _accountError =
              'Could not load your account. Check your connection and try again.';
        });
      }
    }
  }

  void _reload() {
    final id = _elderlyId;
    if (id == null) {
      _history = null;
      _aiForecast = null;
      return;
    }
    final history = _repository.load(id, _period, DateTime.now());
    _history = history;
    _aiForecast = history.then(
      (value) => _forecastService.generate(
        elderlyId: id,
        statistics: value.statistics,
      ),
    );
  }

  Future<void> _refresh() async {
    setState(_reload);
    try {
      await _history;
    } catch (_) {
      /* FutureBuilder displays the failure. */
    }
  }

  Future<void> _exportPdf(StatisticsHistory visibleHistory) async {
    final selectedPeriod = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Export statistics PDF'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Choose the period to include in the report.',
              style: TextStyle(color: statisticsMuted),
            ),
          ),
          for (final entry in statisticsExportPeriods.entries)
            SimpleDialogOption(
              key: Key('statistics-export-${entry.key}'),
              onPressed: () => Navigator.pop(context, entry.key),
              child: Row(
                children: [
                  Icon(
                    entry.key == 1
                        ? Icons.today_rounded
                        : entry.key == 7
                        ? Icons.date_range_rounded
                        : Icons.calendar_month_rounded,
                    color: statisticsOrange,
                  ),
                  const SizedBox(width: 12),
                  Text(entry.value),
                  if (entry.key == _period) ...[
                    const Spacer(),
                    const Text(
                      'Current',
                      style: TextStyle(color: statisticsMuted, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
    if (selectedPeriod == null || _exporting) return;
    final elderlyId = _elderlyId;
    final person = _people.where((item) => item.id == elderlyId).firstOrNull;
    if (elderlyId == null || person == null) return;
    setState(() => _exporting = true);
    try {
      final history = selectedPeriod == _period
          ? visibleHistory
          : await _repository.load(elderlyId, selectedPeriod, DateTime.now());
      final shared = await const StatisticsPdfService().shareReport(
        personName: person.fullName,
        statistics: history.statistics,
        fromCache: history.fromCache,
      );
      if (!mounted || !shared) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Statistics PDF is ready to save or share.'),
          backgroundColor: statisticsGreen,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The PDF could not be created. Check your connection and try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _openCaregiverPage(bool medicine) {
    final person = _people
        .where((person) => person.id == _elderlyId)
        .firstOrNull;
    if (person == null) {
      Navigator.pushNamed(context, '/link-elderly');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => medicine
            ? CaregiverMedicationScheduleScreen(
                elderly: person,
                linkedElderly: _people,
              )
            : CaregiverElderlyStatusScreen(
                elderly: person,
                linkedElderly: _people,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: elderlyPageBackground,
    appBar: AppBar(
      backgroundColor: elderlyPeach,
      title: const Text('Statistics'),
      actions: [
        IconButton(
          tooltip: 'Knowledge & prevention',
          icon: const Icon(Icons.menu_book_rounded),
          onPressed: () => Navigator.pushNamed(context, '/knowledge'),
        ),
      ],
    ),
    bottomNavigationBar: CaregiverBottomNavigation(
      selectedIndex: 4,
      onHome: () => Navigator.popUntil(context, (route) => route.isFirst),
      onStatus: () => _openCaregiverPage(false),
      onMedicine: () => _openCaregiverPage(true),
      onProfile: () => Navigator.pushNamed(context, '/caregiver-profile'),
      onStatistics: () {},
    ),
    body: _loadingAccounts
        ? const Center(child: CircularProgressIndicator())
        : _accountError != null
        ? _message(_accountError!, _loadAccounts)
        : _elderlyId == null
        ? _message(
            'Link an elderly account to see their statistics.',
            () async {
              await Navigator.pushNamed(context, '/link-elderly');
              if (mounted) await _loadAccounts();
            },
          )
        : RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(20),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const Text(
                  'Care overview',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Review recorded patterns for a linked elderly person.',
                  style: TextStyle(color: statisticsMuted),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey(_elderlyId),
                  initialValue: _elderlyId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Linked elderly person',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final person in _people)
                      DropdownMenuItem(
                        value: person.id,
                        child: Text(
                          person.fullName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) => setState(() {
                    _elderlyId = id;
                    _reload();
                  }),
                ),
                const SizedBox(height: 18),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 7, label: Text('7 days')),
                    ButtonSegment(value: 30, label: Text('30 days')),
                    ButtonSegment(value: 90, label: Text('90 days')),
                  ],
                  selected: {_period},
                  onSelectionChanged: (selection) => setState(() {
                    _period = selection.single;
                    _reload();
                  }),
                ),
                const SizedBox(height: 20),
                FutureBuilder<StatisticsHistory>(
                  future: _history,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(60),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      final error = snapshot.error;
                      final message = error is StateError
                          ? error.message
                          : error is FirebaseException &&
                                error.code == 'permission-denied'
                          ? 'You no longer have access to this history. Check your account link.'
                          : 'History could not be loaded. Check your connection and try again.';
                      return _message(message, _refresh);
                    }
                    final history = snapshot.data;
                    if (history == null) return const SizedBox.shrink();
                    return Column(
                      children: [
                        if (history.fromCache)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text(
                              'Offline copy: these records may be incomplete. Refresh when connected.',
                            ),
                          ),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            key: const Key('export-statistics-pdf'),
                            onPressed: _exporting
                                ? null
                                : () => _exportPdf(history),
                            icon: _exporting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.picture_as_pdf_rounded),
                            label: Text(
                              _exporting
                                  ? 'Creating PDF…'
                                  : 'Export statistics PDF',
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: statisticsOrange,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        StatisticsDashboard(statistics: history.statistics),
                        const SizedBox(height: 16),
                        SmartInsightsPanel(statistics: history.statistics),
                        const SizedBox(height: 16),
                        GeminiForecastPanel(
                          forecast: _aiForecast,
                          onRetry: () => setState(() {
                            _aiForecast = _forecastService.generate(
                              elderlyId: _elderlyId!,
                              statistics: history.statistics,
                            );
                          }),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
  );

  Widget _message(String message, VoidCallback retry) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: retry, child: const Text('Try again')),
      ],
    ),
  );
}

class StatisticsDashboard extends StatelessWidget {
  const StatisticsDashboard({super.key, required this.statistics});
  final HealthStatistics statistics;

  @override
  Widget build(BuildContext context) {
    final data = statistics;
    final dates = [
      for (final day in data.days) '${day.date.day}/${day.date.month}',
    ];
    final outlook = data.outlook;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _metric(
              'Recorded completion',
              data.completion == null
                  ? '—'
                  : '${data.completion!.toStringAsFixed(0)}%',
            ),
            _metric('Possible-fall alerts', '${data.alerts}'),
            _metric(
              'Days with dose records',
              '${data.recordDays} / ${data.days.length}',
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          'Charts show saved records only. No record does not mean no fall or no medication was due. Dates use this device’s local time.',
          style: TextStyle(fontSize: 12, color: statisticsMuted, height: 1.5),
        ),
        if (data.invalidRecords > 0)
          Text('${data.invalidRecords} incomplete records were excluded.'),
        if (data.doses == 0 && data.alerts == 0)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: _card(
              'Your history starts here',
              const Text(
                'No records in this period. Saved medication actions and possible-fall alerts will appear here.',
              ),
            ),
          ),
        const SizedBox(height: 16),
        _card(
          'Medication completion',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Taken ÷ all saved doses due by now. Gaps mean no dose records.',
                style: TextStyle(color: statisticsMuted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              StatisticsSeriesChart(
                values: [for (final day in data.days) day.completion],
                labels: dates,
                unit: '%',
                percent: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          'Medication outcomes',
          Column(
            children: [
              StatisticsBreakdown(
                values: {
                  'Taken': data.taken,
                  'Marked missed': data.missed,
                  'Pending / snoozed / unknown': data.unresolved,
                },
                colors: const [statisticsGreen, statisticsRed, statisticsMuted],
              ),
              const SizedBox(height: 10),
              const Text(
                'Unresolved records are not assumed to be missed doses.',
                style: TextStyle(fontSize: 12, color: statisticsMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          'Possible-fall alerts over time',
          Column(
            children: [
              StatisticsSeriesChart(
                values: [for (final day in data.days) day.alerts.toDouble()],
                labels: dates,
                unit: 'alerts',
                bars: true,
              ),
              const Text(
                'Sensor alerts are not confirmed falls. Cancelled alerts are included.',
                style: TextStyle(fontSize: 12, color: statisticsMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          'Alert outcomes',
          StatisticsBreakdown(
            values: data.fallStatuses,
            colors: const [statisticsRed, statisticsGreen, statisticsMuted],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          'When alerts were recorded',
          Column(
            children: [
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              const [
                                '00:00–05:59',
                                '06:00–11:59',
                                '12:00–17:59',
                                '18:00–23:59',
                              ][i],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${data.alertHours[i]} alerts'),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: data.alerts == 0
                            ? 0
                            : data.alertHours[i] / data.alerts,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(5),
                        color: statisticsOrange,
                        backgroundColor: const Color(0xFFF4E9DF),
                      ),
                    ],
                  ),
                ),
              const Text(
                'Counts are not adjusted for monitoring time and do not measure risk by hour.',
                style: TextStyle(fontSize: 12, color: statisticsMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          'Next 7 days · completion outlook',
          outlook == null
              ? const Text(
                  'More history is needed: at least 7 completed days with dose records and 14 recorded doses. Try a longer date range.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Around ${outlook.percent.toStringAsFixed(0)}%',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: statisticsGreen,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'If recording habits and schedules stay similar, recorded completion may remain near this historical rate. Based on ${outlook.recordDays} completed days.',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Historical uncertainty: ${outlook.lower.toStringAsFixed(0)}–${outlook.upper.toStringAsFixed(0)}% (95% Wilson interval). This is not a guaranteed future range. Missing records and changes in routine can change the outcome.',
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: statisticsMuted,
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => Navigator.pushNamed(context, '/knowledge'),
          icon: const Icon(Icons.menu_book_rounded),
          label: const Text('Explore knowledge & prevention'),
        ),
      ],
    );
  }

  Widget _metric(String label, String value) => Container(
    width: 148,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFFF0D7C4)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: statisticsMuted),
        ),
      ],
    ),
  );
}

Widget _card(String title, Widget content) => elderlySectionCard(
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 14),
      Material(type: MaterialType.transparency, child: content),
    ],
  ),
);

class SmartInsightsPanel extends StatelessWidget {
  const SmartInsightsPanel({super.key, required this.statistics});

  final HealthStatistics statistics;

  @override
  Widget build(BuildContext context) {
    final insights = statistics.smartInsights;
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFF4E8), Colors.white],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFFFC99E)),
        boxShadow: [
          BoxShadow(
            color: statisticsOrange.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: statisticsOrange,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.auto_graph_rounded,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Smart Insights',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'On-device rules · automatic',
                      style: TextStyle(color: statisticsMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.lock_rounded, color: statisticsGreen, size: 20),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            insights.headline,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(insights.summary, style: const TextStyle(height: 1.45)),
          const SizedBox(height: 16),
          for (var index = 0; index < insights.items.length; index++) ...[
            _SmartInsightRow(insight: insights.items[index]),
            if (index != insights.items.length - 1) const Divider(height: 24),
          ],
          const Divider(height: 28),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Insight confidence',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5ED),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  insights.confidenceLabel,
                  style: const TextStyle(
                    color: statisticsGreen,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: insights.confidenceValue,
            minHeight: 7,
            borderRadius: BorderRadius.circular(8),
            color: statisticsGreen,
            backgroundColor: const Color(0xFFE9E2DC),
          ),
          const SizedBox(height: 8),
          Text(
            insights.confidenceDetail,
            style: const TextStyle(
              color: statisticsMuted,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.phone_android_rounded,
                size: 16,
                color: statisticsMuted,
              ),
              SizedBox(width: 7),
              Expanded(
                child: Text(
                  'Calculated on this device from saved records. These observations remain available if the AI forecast is offline.',
                  style: TextStyle(
                    color: statisticsMuted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class GeminiForecastPanel extends StatelessWidget {
  const GeminiForecastPanel({
    super.key,
    required this.forecast,
    required this.onRetry,
  });

  final Future<AiStatisticsForecast>? forecast;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('gemini-forecast-panel'),
    decoration: BoxDecoration(
      color: const Color(0xFFF5F1FF),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFD9CCFF)),
    ),
    padding: const EdgeInsets.all(18),
    child: FutureBuilder<AiStatisticsForecast>(
      future: forecast,
      builder: (context, snapshot) {
        final value = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: const Color(0xFF7357C8),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI Forecast',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Next 7 days · anonymous aggregates only',
                        style: TextStyle(color: statisticsMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.shield_outlined,
                  color: Color(0xFF7357C8),
                  size: 21,
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (snapshot.connectionState != ConnectionState.done)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 22),
                child: Column(
                  children: [
                    CircularProgressIndicator(color: Color(0xFF7357C8)),
                    SizedBox(height: 12),
                    Text('Analysing recorded patterns…'),
                  ],
                ),
              )
            else if (snapshot.hasError)
              _GeminiUnavailable(error: snapshot.error, onRetry: onRetry)
            else if (value != null)
              _GeminiForecastBody(forecast: value),
          ],
        );
      },
    ),
  );
}

class _GeminiUnavailable extends StatelessWidget {
  const _GeminiUnavailable({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is StatisticsForecastException
        ? (error! as StatisticsForecastException).message
        : 'The AI service could not create a forecast right now. The rule-based outlook is still available.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message, style: const TextStyle(height: 1.45)),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('retry-gemini-forecast'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try AI Forecast again'),
        ),
      ],
    );
  }
}

class _GeminiForecastBody extends StatelessWidget {
  const _GeminiForecastBody({required this.forecast});

  final AiStatisticsForecast forecast;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _forecastMetric(
            'Predicted completion',
            '${forecast.predictedCompletion}%',
          ),
          _forecastMetric('Trend', _friendly(forecast.trend)),
          _forecastMetric(
            'Possible-alert level',
            _friendly(forecast.possibleFallAlertLevel),
          ),
        ],
      ),
      const SizedBox(height: 14),
      Text(forecast.summary, style: const TextStyle(height: 1.5)),
      const SizedBox(height: 10),
      Text(
        'Estimated completion range: ${forecast.completionLower}–${forecast.completionUpper}%',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      if (forecast.actions.isNotEmpty) ...[
        const SizedBox(height: 16),
        const Text(
          'Suggested caregiver actions',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 7),
        for (final action in forecast.actions)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.check_circle_outline_rounded,
                    size: 17,
                    color: Color(0xFF7357C8),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(action)),
              ],
            ),
          ),
      ],
      const Divider(height: 26),
      Text(
        forecast.limitations,
        style: const TextStyle(
          color: statisticsMuted,
          fontSize: 12,
          height: 1.45,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Generated by ${forecast.model}${forecast.cached ? ' · saved result' : ''}. This is a pattern estimate, not medical advice or a guaranteed outcome.',
        style: const TextStyle(
          color: statisticsMuted,
          fontSize: 11,
          height: 1.4,
        ),
      ),
    ],
  );

  static Widget _forecastMetric(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(13),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFF5E43B1),
            fontSize: 17,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: statisticsMuted, fontSize: 11),
        ),
      ],
    ),
  );

  static String _friendly(String value) => value
      .split('_')
      .map(
        (part) => part.isEmpty
            ? part
            : '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}

class _SmartInsightRow extends StatelessWidget {
  const _SmartInsightRow({required this.insight});

  final SmartInsight insight;

  @override
  Widget build(BuildContext context) {
    final (color, background, icon) = switch (insight.tone) {
      SmartInsightTone.positive => (
        statisticsGreen,
        const Color(0xFFE8F5ED),
        Icons.check_circle_outline_rounded,
      ),
      SmartInsightTone.attention => (
        statisticsRed,
        const Color(0xFFFFECE9),
        Icons.priority_high_rounded,
      ),
      SmartInsightTone.neutral => (
        statisticsOrange,
        const Color(0xFFFFEEDC),
        Icons.insights_rounded,
      ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: background, shape: BoxShape.circle),
          child: Icon(icon, size: 19, color: color),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                insight.title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                insight.body,
                style: const TextStyle(color: statisticsMuted, height: 1.45),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
