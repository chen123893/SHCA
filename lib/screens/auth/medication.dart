import 'package:shca/screens/auth/elderly_shared.dart';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shca/services/medication_email_service.dart';
import 'package:shca/services/medication_alarm_feedback.dart';
import 'package:shca/services/medication_service.dart';
import 'package:shca/services/push_notification_service.dart';
import 'package:shca/widgets/medication_visual.dart';

export 'package:shca/widgets/medication_visual.dart'
    show MedicationVisual, medicineAssetFor;

const Color _pageBackground = Color(0xFFFFF8F0);
const Color _orange = Color(0xFFFF7518);
const Color _ink = Color(0xFF2A2522);
const Color _green = Color(0xFF25A86B);
const Color _redOrange = Color(0xFFF04C23);
const Color _peach = Color(0xFFFFBC88);

class MedicationReminderScreen extends StatefulWidget {
  const MedicationReminderScreen({super.key, this.controller});

  final MedicationController? controller;

  @override
  State<MedicationReminderScreen> createState() =>
      _MedicationReminderScreenState();
}

class _MedicationReminderScreenState extends State<MedicationReminderScreen>
    with WidgetsBindingObserver {
  late final MedicationController _controller;
  late final bool _ownsController;
  ({bool notifications, bool exact, bool fullScreen, bool appearOnTop})?
  _alarmPermissions;
  bool _permissionPromptShown = false;
  bool _requestingAlarmPermissions = false;
  bool _testAlarmActive = false;
  bool _sendingLowStockEmail = false;
  StreamSubscription<String>? _recordRefreshSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _scheduleSubscription;
  String? _scheduleSignature;
  bool _scheduleReloadRunning = false;
  bool _scheduleReloadQueued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsController = widget.controller == null;
    if (_ownsController) {
      _alarmPermissions =
          PushNotificationService.instance.lastMedicationAlarmPermissions;
    }
    _controller =
        widget.controller ??
        MedicationController(
          storageScope: FirebaseAuth.instance.currentUser?.uid ?? 'guest',
        );
    _controller.addListener(_refresh);
    if (_ownsController) {
      _recordRefreshSubscription = MedicationRecordRefresh.events.listen((id) {
        if (id == FirebaseAuth.instance.currentUser?.uid) {
          unawaited(_controller.reload());
        }
      });
    }
    unawaited(_loadAndScheduleAlarms());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ownsController) {
      unawaited(_refreshAlarmStatusAndSync());
    }
  }

  Future<void> _refreshAlarmStatusAndSync() async {
    final elderlyId = FirebaseAuth.instance.currentUser?.uid;
    if (elderlyId == null || _controller.medicationSchedules.isEmpty) return;
    final service = PushNotificationService.instance;
    final status = await service.medicationAlarmPermissionStatus();
    if (!mounted) return;
    setState(() => _alarmPermissions = status);
    await service.syncMedicationReminders(
      elderlyId: elderlyId,
      schedules: _controller.medicationSchedules,
    );
  }

  Future<void> _loadAndScheduleAlarms() async {
    await _controller.load();
    if (!_ownsController) return;
    final elderlyId = FirebaseAuth.instance.currentUser?.uid;
    if (elderlyId == null) return;
    _startScheduleListener(elderlyId);
    if (_controller.medicationSchedules.isEmpty) return;
    unawaited(_sendRecentMissedEmails(elderlyId));
    final service = PushNotificationService.instance;
    final status = await service.medicationAlarmPermissionStatus();
    if (!mounted) return;
    setState(() => _alarmPermissions = status);
    await service.syncMedicationReminders(
      elderlyId: elderlyId,
      schedules: _controller.medicationSchedules,
    );
    if (!mounted) return;
    if ((!status.notifications ||
            !status.exact ||
            !status.fullScreen ||
            !status.appearOnTop) &&
        !_permissionPromptShown) {
      _permissionPromptShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showAlarmPermissionDialog());
      });
    }
  }

  void _startScheduleListener(String elderlyId) {
    if (_scheduleSubscription != null) return;
    _scheduleSignature = _signatureFor(_controller.medicationSchedules);
    _scheduleSubscription = FirebaseFirestore.instance
        .collection('medications')
        .where('elderlyId', isEqualTo: elderlyId)
        .snapshots()
        .listen(
          (snapshot) {
            final schedules = snapshot.docs
                .where(
                  (document) =>
                      document.data()['active'] != false &&
                      !isLegacyDemoMedicationData(document.data()),
                )
                .map(
                  (document) =>
                      MedicationSchedule.fromFirestore(document.data()),
                )
                .where((schedule) => schedule.id.isNotEmpty)
                .toList(growable: false);
            if (_signatureFor(schedules) == _scheduleSignature) return;
            unawaited(_reloadAfterScheduleChange(elderlyId));
          },
          onError: (Object error) =>
              debugPrint('Live medication update failed: $error'),
        );
  }

  String _signatureFor(Iterable<MedicationSchedule> schedules) {
    final values =
        schedules
            .map(
              (item) =>
                  '${item.id}:${item.name}:${item.dose}:${item.instruction}:'
                  '${item.hour}:${item.minute}:${item.dailyReminderMinutes.join(',')}:'
                  '${item.recurrence.name}:${item.startDate}:${item.endDate}:'
                  '${item.weekdays.join(',')}:${item.intervalDays}:${item.imageKey}:'
                  '${item.stockRemaining}',
            )
            .toList()
          ..sort();
    return values.join('|');
  }

  Future<void> _reloadAfterScheduleChange(String elderlyId) async {
    if (_scheduleReloadRunning) {
      _scheduleReloadQueued = true;
      return;
    }
    _scheduleReloadRunning = true;
    try {
      do {
        _scheduleReloadQueued = false;
        await _controller.reload();
        _scheduleSignature = _signatureFor(_controller.medicationSchedules);
        await PushNotificationService.instance.syncMedicationReminders(
          elderlyId: elderlyId,
          schedules: _controller.medicationSchedules,
        );
      } while (_scheduleReloadQueued && mounted);
    } catch (error) {
      debugPrint('Medication page could not apply the live update: $error');
    } finally {
      _scheduleReloadRunning = false;
    }
  }

  Future<void> _sendRecentMissedEmails(String elderlyId) async {
    final cutoff = DateTime.now().subtract(const Duration(days: 2));
    final service = const MedicationEmailService();
    for (final record in _controller.records) {
      if (record.status != MedicationStatus.missed ||
          record.scheduledAt.isBefore(cutoff)) {
        continue;
      }
      try {
        await service.sendMissedReminder(
          elderlyId: elderlyId,
          medicationId: record.medicationId,
          occurrenceDate: record.scheduledAt,
        );
      } catch (error) {
        debugPrint('Caregiver missed-dose email was not sent: $error');
      }
    }
  }

  Future<void> _showAlarmPermissionDialog() async {
    final enable = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.alarm_rounded, color: _orange, size: 38),
        title: const Text('Enable medicine alarms'),
        content: const Text(
          'SHCA needs Android alarm access to open the medicine screen at the '
          'saved time. Allow full-screen alerts and turn on “Appear on top” '
          'for SHCA in Android settings. This lets the alarm page open while '
          'you are using another app. Return to SHCA when finished.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enable Alarms'),
          ),
        ],
      ),
    );
    if (enable == true) await _enableMedicationAlarms();
  }

  Future<void> _enableMedicationAlarms() async {
    if (_requestingAlarmPermissions) return;
    final elderlyId = FirebaseAuth.instance.currentUser?.uid;
    if (elderlyId == null) return;
    setState(() => _requestingAlarmPermissions = true);
    try {
      final service = PushNotificationService.instance;
      final status = await service.requestMedicationAlarmPermissions();
      await service.syncMedicationReminders(
        elderlyId: elderlyId,
        schedules: _controller.medicationSchedules,
      );
      if (!mounted) return;
      setState(() => _alarmPermissions = status);
      final ready =
          status.notifications &&
          status.exact &&
          status.fullScreen &&
          status.appearOnTop;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: Icon(
            ready ? Icons.alarm_on_rounded : Icons.warning_amber_rounded,
            color: ready ? _green : const Color(0xFFE58C00),
            size: 38,
          ),
          title: Text(
            ready ? 'Full-screen alarms enabled' : 'More access is needed',
          ),
          content: Text(
            ready
                ? 'Everything is ready. At the saved medicine time, SHCA will '
                      'open the Medication Alert page automatically.'
                : 'Android still reports: ${_alarmPermissionSummary(status)}. '
                      'Turn on the items marked Off, then return to SHCA.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Alarm settings could not be opened: $error'),
          backgroundColor: _redOrange,
        ),
      );
    } finally {
      if (mounted) setState(() => _requestingAlarmPermissions = false);
    }
  }

  String _alarmPermissionSummary(
    ({bool notifications, bool exact, bool fullScreen, bool appearOnTop})
    status,
  ) =>
      'Notifications ${status.notifications ? 'On' : 'Off'} • '
      'Exact timing ${status.exact ? 'On' : 'Off'} • '
      'Full screen ${status.fullScreen ? 'On' : 'Off'} • '
      'Appear on top ${status.appearOnTop ? 'On' : 'Off'}';

  Future<void> _testAlarmSound() async {
    final elderlyId = FirebaseAuth.instance.currentUser?.uid;
    if (elderlyId == null || _controller.medicationSchedules.isEmpty) return;
    var status = await PushNotificationService.instance
        .medicationAlarmPermissionStatus();
    if (!status.notifications) {
      status = await PushNotificationService.instance
          .requestMedicationAlarmPermissions();
    }
    if (!status.notifications) return;
    await PushNotificationService.instance.showMedicationTestAlarm(
      elderlyId: elderlyId,
      medication: _controller.medicationSchedules.first,
    );
    if (!mounted) return;
    setState(() {
      _alarmPermissions = status;
      _testAlarmActive = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Test alarm is playing. Press Cancel sound to end it.'),
        backgroundColor: _green,
      ),
    );
  }

  Future<void> _cancelTestAlarm() async {
    final elderlyId = FirebaseAuth.instance.currentUser?.uid;
    if (elderlyId == null || _controller.medicationSchedules.isEmpty) return;
    await PushNotificationService.instance.cancelMedicationTestAlarm(
      elderlyId: elderlyId,
      medication: _controller.medicationSchedules.first,
    );
    if (mounted) setState(() => _testAlarmActive = false);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_recordRefreshSubscription?.cancel());
    unawaited(_scheduleSubscription?.cancel());
    if (_testAlarmActive &&
        _ownsController &&
        _controller.medicationSchedules.isNotEmpty) {
      final elderlyId = FirebaseAuth.instance.currentUser?.uid;
      if (elderlyId != null) {
        unawaited(
          PushNotificationService.instance.cancelMedicationTestAlarm(
            elderlyId: elderlyId,
            medication: _controller.medicationSchedules.first,
          ),
        );
      }
    }
    _controller.removeListener(_refresh);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBackground,
      body: SafeArea(
        child: Column(
          children: [
            const MedicationHeader(title: 'Medication Reminder'),
            Expanded(
              child: _controller.isLoaded
                  ? _buildContent()
                  : const Center(
                      child: CircularProgressIndicator(color: _orange),
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: MedicationBottomNavigation(
        selectedIndex: 1,
        onHome: () => _goHome(context),
      ),
    );
  }

  Widget _buildContent() {
    final now = DateTime.now();
    final todaySchedules = _controller.schedulesForDate(now);
    final asNeeded = _controller.asNeededMedications;
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month_outlined, color: _ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Today, ${formatLongDate(now)}',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_controller.medicationSchedules.any(
                (medication) => medication.hasAutomaticReminder,
              ) &&
              _ownsController) ...[
            _MedicationAlarmStatusCard(
              permissions: _alarmPermissions,
              requestingPermissions: _requestingAlarmPermissions,
              testAlarmActive: _testAlarmActive,
              onEnable: _enableMedicationAlarms,
              onTest: _testAlarmSound,
              onCancelTest: _cancelTestAlarm,
            ),
            const SizedBox(height: 18),
          ],
          const Text(
            'Medicine',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          if (todaySchedules.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFFFCBA7)),
              ),
              child: const Column(
                children: [
                  Icon(Icons.medication_outlined, color: _orange, size: 42),
                  SizedBox(height: 10),
                  Text(
                    'No medication scheduled today',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                  ),
                  SizedBox(height: 5),
                  Text(
                    'Medication added by your linked caregiver will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black54, height: 1.35),
                  ),
                ],
              ),
            ),
          for (final medication in todaySchedules) ...[
            for (final record in _controller.recordsFor(medication)) ...[
              MedicationCard(
                medication: medication,
                record: record,
                onTaken: () => _controller.markTaken(
                  medication,
                  scheduledAt: record.scheduledAt,
                ),
                onSnooze: () => _chooseSnooze(medication, record.scheduledAt),
              ),
              const SizedBox(height: 14),
            ],
          ],
          if (asNeeded.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Text(
              'As Needed',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            const Text(
              'Only take these according to the supplied instruction.',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 10),
            for (final medication in asNeeded) ...[
              _AsNeededMedicationCard(
                medication: medication,
                record: _controller.recordFor(medication),
                onTaken: () => _controller.markTaken(medication),
              ),
              const SizedBox(height: 14),
            ],
          ],
          const SizedBox(height: 4),
          const Text(
            'Medication History',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          InkWell(
            key: const Key('view-medication-history'),
            onTap: _openHistory,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFFFCBA7)),
              ),
              child: const Row(
                children: [
                  CircleAvatar(
                    radius: 25,
                    backgroundColor: Color(0xFFFFC7BD),
                    child: Icon(Icons.description_outlined, color: _ink),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'View History',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'See your past medication records',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: Colors.black54),
                ],
              ),
            ),
          ),
          if (_controller.lowStockMedications.isNotEmpty) ...[
            const SizedBox(height: 20),
            _LowStockCard(
              medication: _controller.lowStockMedications.first,
              isSending: _sendingLowStockEmail,
              onRemindCaregiver: () {
                unawaited(
                  _remindCaregiver(_controller.lowStockMedications.first),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _chooseSnooze(
    MedicationSchedule medication,
    DateTime scheduledAt,
  ) async {
    final minutes = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Snooze ${medication.name}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              const Text('Choose when you want to be reminded again.'),
              const SizedBox(height: 14),
              for (final value in const <int>[10, 30, 60])
                ListTile(
                  leading: const Icon(Icons.alarm_rounded, color: _orange),
                  title: Text(value == 60 ? '1 hour' : '$value minutes'),
                  onTap: () => Navigator.pop(sheetContext, value),
                ),
            ],
          ),
        ),
      ),
    );
    if (minutes != null) {
      await _controller.snooze(
        medication,
        Duration(minutes: minutes),
        scheduledAt: scheduledAt,
      );
      final elderlyId = FirebaseAuth.instance.currentUser?.uid;
      if (_ownsController && elderlyId != null) {
        await PushNotificationService.instance.snoozeMedicationReminder(
          elderlyId: elderlyId,
          medication: medication,
          scheduledAt: scheduledAt,
          duration: Duration(minutes: minutes),
        );
      }
    }
  }

  void _openHistory() {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MedicationHistoryScreen(controller: _controller),
      ),
    );
  }

  Future<void> _remindCaregiver(MedicationSchedule medication) async {
    if (_sendingLowStockEmail) return;
    final elderlyId = FirebaseAuth.instance.currentUser?.uid;
    if (elderlyId == null) {
      _showLowStockMessage('Please sign in again before sending the reminder.');
      return;
    }
    setState(() => _sendingLowStockEmail = true);
    try {
      final result = await const MedicationEmailService().sendLowStockReminder(
        elderlyId: elderlyId,
        medicationId: medication.id,
      );
      if (!mounted) return;
      if (result.sent > 0) {
        _showLowStockMessage(
          'Low-stock email sent to ${result.sent} linked ${result.sent == 1 ? 'caregiver' : 'caregivers'}.',
          success: true,
        );
      } else if (result.alreadySent > 0) {
        _showLowStockMessage(
          'A low-stock email for ${medication.name} was already sent today.',
          success: true,
        );
      } else if (result.linkedCaregivers == 0) {
        _showLowStockMessage(
          'No active caregiver is linked to this elderly account.',
        );
      } else if (result.missingEmail > 0) {
        _showLowStockMessage(
          'The caregiver email setup is incomplete. Ask the caregiver to open Profile, tap Edit Profile, then Save Changes once.',
        );
      } else if (result.disabled > 0) {
        _showLowStockMessage(
          'The linked caregiver has disabled medication reminder emails.',
        );
      } else {
        _showLowStockMessage(
          'No linked caregiver has medication email reminders enabled.',
        );
      }
    } catch (error) {
      if (mounted) {
        _showLowStockMessage(
          error is MedicationEmailException
              ? error.message
              : 'The caregiver email could not be sent. Check the internet connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _sendingLowStockEmail = false);
    }
  }

  void _showLowStockMessage(String message, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? _green : Colors.red.shade700,
      ),
    );
  }
}

class _MedicationAlarmStatusCard extends StatelessWidget {
  const _MedicationAlarmStatusCard({
    required this.permissions,
    required this.requestingPermissions,
    required this.testAlarmActive,
    required this.onEnable,
    required this.onTest,
    required this.onCancelTest,
  });

  final ({bool notifications, bool exact, bool fullScreen, bool appearOnTop})?
  permissions;
  final bool requestingPermissions;
  final bool testAlarmActive;
  final Future<void> Function() onEnable;
  final Future<void> Function() onTest;
  final Future<void> Function() onCancelTest;

  @override
  Widget build(BuildContext context) {
    final checking = permissions == null;
    final enabled = permissions?.notifications == true;
    final exact = permissions?.exact == true;
    final fullScreen = permissions?.fullScreen == true;
    final appearOnTop = permissions?.appearOnTop == true;
    final ready = enabled && exact && fullScreen && appearOnTop;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: checking
            ? const Color(0xFFF5F5F5)
            : ready
            ? const Color(0xFFEAF8F0)
            : const Color(0xFFFFF3DA),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: checking
              ? const Color(0xFFE0E0E0)
              : ready
              ? const Color(0xFF9BD7B7)
              : const Color(0xFFFFC568),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 23,
                backgroundColor: Colors.white,
                child: checking
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF75675F),
                        ),
                      )
                    : Icon(
                        ready
                            ? Icons.alarm_on_rounded
                            : Icons.alarm_off_rounded,
                        color: ready ? _green : const Color(0xFFE58C00),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      permissions == null
                          ? 'Checking medicine alarms'
                          : ready
                          ? 'Medicine alarms are ready'
                          : 'Medicine alarms need permission',
                      style: const TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (!ready && permissions != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        'Notifications ${enabled ? 'On' : 'Off'} • '
                        'Exact timing ${exact ? 'On' : 'Off'} • '
                        'Full screen ${fullScreen ? 'On' : 'Off'} • '
                        'Appear on top ${appearOnTop ? 'On' : 'Off'}',
                        style: const TextStyle(
                          color: Color(0xFF8A5B1C),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      checking
                          ? 'Reading your phone’s alarm access…'
                          : ready
                          ? 'The alert screen can open automatically with sound.'
                          : 'Enable all alarm access for direct full-screen alerts.',
                      style: const TextStyle(
                        color: Color(0xFF75675F),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!checking && !ready) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: requestingPermissions ? null : onEnable,
                style: FilledButton.styleFrom(backgroundColor: _orange),
                icon: requestingPermissions
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.notifications_active_rounded),
                label: Text(
                  requestingPermissions
                      ? 'Checking alarm access…'
                      : 'Enable full-screen alarms',
                ),
              ),
            ),
            const SizedBox(height: 9),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('test-medication-alarm'),
                  onPressed: onTest,
                  icon: const Icon(Icons.volume_up_rounded),
                  label: const Text('Test sound'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('cancel-medication-test-alarm'),
                  onPressed: testAlarmActive ? onCancelTest : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: BorderSide(
                      color: testAlarmActive ? Colors.red : Colors.black12,
                    ),
                  ),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Cancel sound'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class MedicationAlertScreen extends StatefulWidget {
  const MedicationAlertScreen({
    super.key,
    required this.elderlyId,
    required this.medicationId,
    this.scheduledAt,
    this.reminderAt,
    this.initialMedication,
    this.controller,
  });

  final String elderlyId;
  final String medicationId;
  final DateTime? scheduledAt;
  final DateTime? reminderAt;
  final MedicationSchedule? initialMedication;
  final MedicationController? controller;

  @override
  State<MedicationAlertScreen> createState() => _MedicationAlertScreenState();
}

class _MedicationAlertScreenState extends State<MedicationAlertScreen> {
  late final MedicationController _controller;
  late final bool _ownsController;
  bool _busy = false;
  late final String _alarmKey =
      '${widget.elderlyId}:${widget.medicationId}:${identityHashCode(this)}';

  DateTime _occurrenceFor(MedicationSchedule medication) =>
      widget.scheduledAt ??
      MedicationController.scheduledDateTime(medication, DateTime.now());

  DateTime _displayTimeFor(MedicationSchedule medication) =>
      widget.reminderAt ?? _occurrenceFor(medication);

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        MedicationController(storageScope: widget.elderlyId);
    _controller.addListener(_refresh);
    unawaited(_controller.load());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (!_controller.isLoaded || _medication != null)) {
        unawaited(MedicationAlarmFeedback.start(_alarmKey));
      }
    });
  }

  void _refresh() {
    if (!mounted) return;
    if (_controller.isLoaded && _medication == null) {
      unawaited(MedicationAlarmFeedback.stop(_alarmKey));
    }
    setState(() {});
  }

  Future<void> _markMissed(MedicationSchedule medication) async {
    await _controller.markMissed(
      medication,
      scheduledAt: _occurrenceFor(medication),
    );
    if (!_ownsController) return;
    try {
      await const MedicationEmailService().sendMissedReminder(
        elderlyId: widget.elderlyId,
        medicationId: widget.medicationId,
      );
    } catch (error) {
      // The local alarm must remain usable when the phone is offline or the
      // optional email provider is unavailable.
      debugPrint('Caregiver missed-dose email was not sent: $error');
    }
  }

  MedicationSchedule? get _medication {
    for (final medication in _controller.medicationSchedules) {
      if (medication.id == widget.medicationId) return medication;
    }
    if (!_controller.isLoaded &&
        widget.initialMedication?.id == widget.medicationId) {
      return widget.initialMedication;
    }
    return null;
  }

  Future<void> _complete(
    MedicationSchedule medication,
    Future<void> Function() action,
    String message,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    await MedicationAlarmFeedback.stop(_alarmKey);
    try {
      await action();
      MedicationRecordRefresh.notify(widget.elderlyId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message), backgroundColor: _green));
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      } else {
        Navigator.pushReplacementNamed(context, '/home');
      }
    } catch (_) {
      if (mounted) unawaited(MedicationAlarmFeedback.start(_alarmKey));
      rethrow;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _snooze(MedicationSchedule medication) async {
    await _complete(medication, () async {
      const duration = Duration(minutes: 10);
      final occurrence = _occurrenceFor(medication);
      await _controller.snooze(medication, duration, scheduledAt: occurrence);
      if (_ownsController) {
        await PushNotificationService.instance.snoozeMedicationReminder(
          elderlyId: widget.elderlyId,
          medication: medication,
          scheduledAt: occurrence,
          duration: duration,
        );
      }
    }, 'Reminder snoozed for 10 minutes.');
  }

  @override
  void dispose() {
    unawaited(MedicationAlarmFeedback.stop(_alarmKey));
    _controller.removeListener(_refresh);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final medication = _medication;
    return Scaffold(
      backgroundColor: _pageBackground,
      body: SafeArea(
        child: Column(
          children: [
            const MedicationHeader(title: 'Medication Alert'),
            Expanded(
              child: !_controller.isLoaded && medication == null
                  ? const Center(
                      child: CircularProgressIndicator(color: _orange),
                    )
                  : medication == null
                  ? _MissingMedicationAlert(onBack: () => _goHome(context))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(22, 28, 22, 32),
                      child: Column(
                        children: [
                          const Text(
                            'Time to Take Medicine',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _ink,
                              fontSize: 25,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 28),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(26),
                              border: Border.all(
                                color: const Color(0xFFFFCBA7),
                              ),
                              boxShadow: const <BoxShadow>[
                                BoxShadow(
                                  color: Color(0x12000000),
                                  blurRadius: 18,
                                  offset: Offset(0, 7),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF4DE),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xFFFFBE61),
                                    ),
                                  ),
                                  child: MedicationVisual(
                                    medication: medication,
                                    size: 92,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  medication.name,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _ink,
                                    fontSize: 27,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  '${medication.doseSummary} • ${medication.instruction}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Color(0xFF88766B),
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Reminder time: ${formatClock(_displayTimeFor(medication))}',
                                  style: const TextStyle(
                                    color: _redOrange,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _ReminderFrequencyBadge(
                                  label: medication.scheduleSummary,
                                ),
                              ],
                            ),
                          ),
                          if (!_controller.isLoaded) ...[
                            const SizedBox(height: 12),
                            const Text(
                              'Checking your latest medication details…',
                              style: TextStyle(
                                color: Color(0xFF88766B),
                                fontSize: 13,
                              ),
                            ),
                          ],
                          const SizedBox(height: 30),
                          _AlertActionButton(
                            key: const Key('alert-taken'),
                            label: 'Taken',
                            icon: Icons.check_circle_rounded,
                            color: _green,
                            enabled: !_busy && _controller.isLoaded,
                            onPressed: () => _complete(
                              medication,
                              () => _controller.markTaken(
                                medication,
                                scheduledAt: _occurrenceFor(medication),
                              ),
                              'Medication marked as taken.',
                            ),
                          ),
                          const SizedBox(height: 13),
                          _AlertActionButton(
                            key: const Key('alert-snooze'),
                            label: 'Snooze 10 min',
                            icon: Icons.alarm_rounded,
                            color: const Color(0xFFFFA000),
                            enabled: !_busy && _controller.isLoaded,
                            onPressed: () => _snooze(medication),
                          ),
                          const SizedBox(height: 13),
                          _AlertActionButton(
                            key: const Key('alert-skip'),
                            label: 'Skip',
                            icon: Icons.close_rounded,
                            color: Colors.white,
                            foreground: Colors.red,
                            borderColor: Colors.red,
                            enabled: !_busy && _controller.isLoaded,
                            onPressed: () => _complete(
                              medication,
                              () => _markMissed(medication),
                              'Medication marked as skipped.',
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReminderFrequencyBadge extends StatelessWidget {
  const _ReminderFrequencyBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEFE6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: _redOrange,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _AlertActionButton extends StatelessWidget {
  const _AlertActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onPressed,
    this.foreground = Colors.white,
    this.borderColor,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Color foreground;
  final Color? borderColor;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: foreground,
          side: borderColor == null ? null : BorderSide(color: borderColor!),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        icon: Icon(icon),
        label: Text(label, style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}

class _MissingMedicationAlert extends StatelessWidget {
  const _MissingMedicationAlert({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.medication_outlined, color: _orange, size: 58),
            const SizedBox(height: 12),
            const Text(
              'This medication is no longer available.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: onBack, child: const Text('Back to Home')),
          ],
        ),
      ),
    );
  }
}

class MedicationHistoryScreen extends StatefulWidget {
  const MedicationHistoryScreen({super.key, required this.controller});

  final MedicationController controller;

  @override
  State<MedicationHistoryScreen> createState() =>
      _MedicationHistoryScreenState();
}

class _MedicationHistoryScreenState extends State<MedicationHistoryScreen> {
  int _selectedRange = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupedRecords();
    return Scaffold(
      backgroundColor: _pageBackground,
      body: SafeArea(
        child: Column(
          children: [
            const MedicationHeader(title: 'Medication History'),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Medication Records',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Text(
                      'View taken, missed, and snoozed medicine history.',
                      style: TextStyle(color: Color(0xFF85756B)),
                    ),
                    const SizedBox(height: 18),
                    SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<int>>[
                        ButtonSegment(value: 0, label: Text('Today')),
                        ButtonSegment(value: 1, label: Text('Week')),
                        ButtonSegment(value: 2, label: Text('Month')),
                      ],
                      selected: <int>{_selectedRange},
                      onSelectionChanged: (selection) =>
                          setState(() => _selectedRange = selection.first),
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? _orange
                              : Colors.white,
                        ),
                        foregroundColor: WidgetStateProperty.resolveWith(
                          (states) => states.contains(WidgetState.selected)
                              ? Colors.white
                              : const Color(0xFF806F65),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (grouped.isEmpty)
                      const _EmptyHistory()
                    else
                      for (final entry in grouped.entries) ...[
                        Text(
                          historyDateHeading(entry.key),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFFFFCBA7)),
                          ),
                          child: Column(
                            children: [
                              for (
                                var index = 0;
                                index < entry.value.length;
                                index++
                              ) ...[
                                MedicationHistoryRow(
                                  record: entry.value[index],
                                  medication: widget.controller.scheduleFor(
                                    entry.value[index].medicationId,
                                    scheduledAt: entry.value[index].scheduledAt,
                                  ),
                                ),
                                if (index < entry.value.length - 1)
                                  const Divider(height: 1),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: MedicationBottomNavigation(
        selectedIndex: 1,
        onHome: () => _goHome(context),
      ),
    );
  }

  Map<DateTime, List<MedicationRecord>> _groupedRecords() {
    final today = MedicationController.dateOnly(DateTime.now());
    final start = switch (_selectedRange) {
      0 => today,
      1 => today.subtract(const Duration(days: 6)),
      _ => DateTime(today.year, today.month, 1),
    };
    final records = widget.controller.recordsBetween(
      start,
      today.add(const Duration(days: 1)),
    );
    final grouped = <DateTime, List<MedicationRecord>>{};
    for (final record in records) {
      final date = MedicationController.dateOnly(record.scheduledAt);
      grouped.putIfAbsent(date, () => <MedicationRecord>[]).add(record);
    }
    return grouped;
  }
}

class MedicationCard extends StatelessWidget {
  const MedicationCard({
    super.key,
    required this.medication,
    required this.record,
    required this.onTaken,
    required this.onSnooze,
  });

  final MedicationSchedule medication;
  final MedicationRecord record;
  final VoidCallback onTaken;
  final VoidCallback onSnooze;

  @override
  Widget build(BuildContext context) {
    final isTaken = record.status == MedicationStatus.taken;
    final displayedReminderTime =
        record.status == MedicationStatus.snoozed && record.snoozedUntil != null
        ? record.snoozedUntil!
        : record.scheduledAt;
    final actionKey = medication.timesPerDay == 1
        ? medication.id
        : '${medication.id}-${record.scheduledAt.hour.toString().padLeft(2, '0')}${record.scheduledAt.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFCBA7)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MedicationVisual(medication: medication, size: 66),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      medication.name,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${medication.doseSummary} • ${medication.instruction}',
                      style: const TextStyle(color: Color(0xFF8B7C72)),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      medication.category,
                      style: const TextStyle(
                        color: _redOrange,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _TimeBadge(time: formatClock(displayedReminderTime)),
                  const SizedBox(height: 12),
                  StatusBadge(status: record.status),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.event_repeat_rounded, size: 20),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  medication.scheduleSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!isTaken) ...[
                FilledButton.icon(
                  key: Key('take-$actionKey'),
                  onPressed: onTaken,
                  style: FilledButton.styleFrom(
                    backgroundColor: _green,
                    minimumSize: const Size(88, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.check_circle, size: 19),
                  label: const Text('Taken'),
                ),
                const SizedBox(width: 7),
                OutlinedButton.icon(
                  key: Key('snooze-$actionKey'),
                  onPressed: onSnooze,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(88, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  icon: const Icon(Icons.alarm_rounded, size: 18),
                  label: const Text('Snooze'),
                ),
              ] else
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE7F7ED),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle, color: _green, size: 18),
                      SizedBox(width: 5),
                      Text(
                        'Completed',
                        style: TextStyle(
                          color: _green,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (record.status == MedicationStatus.snoozed &&
              record.snoozedUntil != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                'Reminder moved to ${formatClock(record.snoozedUntil!)}',
                style: const TextStyle(
                  color: _orange,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AsNeededMedicationCard extends StatelessWidget {
  const _AsNeededMedicationCard({
    required this.medication,
    required this.record,
    required this.onTaken,
  });

  final MedicationSchedule medication;
  final MedicationRecord record;
  final VoidCallback onTaken;

  @override
  Widget build(BuildContext context) {
    final takenToday = record.status == MedicationStatus.taken;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFCBA7)),
      ),
      child: Row(
        children: [
          MedicationVisual(medication: medication, size: 58),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  medication.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${medication.doseSummary} • ${medication.instruction}',
                  style: const TextStyle(color: Color(0xFF8B7C72)),
                ),
                const SizedBox(height: 5),
                const Text(
                  'No automatic alarm',
                  style: TextStyle(
                    color: Color(0xFF9A6B12),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (takenToday)
            const StatusBadge(status: MedicationStatus.taken)
          else
            FilledButton(
              onPressed: onTaken,
              style: FilledButton.styleFrom(
                backgroundColor: _green,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Taken now'),
            ),
        ],
      ),
    );
  }
}

class MedicationHistoryRow extends StatelessWidget {
  const MedicationHistoryRow({
    super.key,
    required this.record,
    required this.medication,
  });

  final MedicationRecord record;
  final MedicationSchedule medication;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          MedicationVisual(medication: medication, size: 64),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${medication.name} - ${formatClock(record.scheduledAt)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '${medication.doseSummary} • ${medication.instruction}',
                  style: const TextStyle(color: Color(0xFF8B7C72)),
                ),
                const SizedBox(height: 2),
                Text(
                  medication.category,
                  style: const TextStyle(
                    color: _redOrange,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              StatusBadge(status: record.status),
              const SizedBox(height: 10),
              Text(
                record.actionAt == null ? '-' : formatClock(record.actionAt!),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final MedicationStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, foreground, background) = switch (status) {
      MedicationStatus.taken => ('Taken', _green, const Color(0xFFE7F7ED)),
      MedicationStatus.snoozed => (
        'Snoozed',
        const Color(0xFF8D6415),
        const Color(0xFFFFF0C9),
      ),
      MedicationStatus.missed => (
        'Missed',
        Colors.red,
        const Color(0xFFFFE5E2),
      ),
      MedicationStatus.pending => ('Pending', _orange, const Color(0xFFFFF1E5)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _TimeBadge extends StatelessWidget {
  const _TimeBadge({required this.time});

  final String time;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5EB),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.schedule_rounded, color: _orange, size: 17),
          const SizedBox(width: 4),
          Text(
            time,
            style: const TextStyle(
              color: _orange,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _LowStockCard extends StatelessWidget {
  const _LowStockCard({
    required this.medication,
    required this.onRemindCaregiver,
    required this.isSending,
  });

  final MedicationSchedule medication;
  final VoidCallback onRemindCaregiver;
  final bool isSending;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3DA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFB53F)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange,
            size: 42,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Medicine Running Low',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                Text(
                  '${medication.name} only has ${medication.stockRemaining} tablets left',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: isSending ? null : onRemindCaregiver,
            style: FilledButton.styleFrom(
              backgroundColor: _orange,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: isSending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Remind Caregiver'),
          ),
        ],
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Column(
        children: [
          Icon(Icons.history_rounded, color: _orange, size: 44),
          SizedBox(height: 10),
          Text(
            'No medication records in this period.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class MedicationHeader extends StatelessWidget {
  const MedicationHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(color: _peach),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 45,
                height: 45,
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Image.asset('assets/images/logo.png'),
              ),
              const CircleAvatar(
                radius: 24,
                backgroundColor: Color(0xFFFFF3E3),
                child: Icon(Icons.elderly_rounded, color: _orange, size: 31),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 58),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 21,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MedicationBottomNavigation extends StatelessWidget {
  const MedicationBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onHome,
  });

  final int selectedIndex;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) => ElderlyBottomNavigation(
    selectedIndex: selectedIndex,
    onHome: onHome,
    onMedicine: () {},
    onMonitor: () => Navigator.pushReplacementNamed(context, '/monitoring'),
    onProfile: () =>
        Navigator.pushReplacementNamed(context, '/elderly-profile'),
  );
}

void _goHome(BuildContext context) {
  if (Navigator.canPop(context)) {
    Navigator.popUntil(context, (route) => route.isFirst);
  } else {
    Navigator.pushReplacementNamed(context, '/home');
  }
}

String formatMedicationTime(MedicationSchedule medication) {
  final hour = medication.hour % 12 == 0 ? 12 : medication.hour % 12;
  final suffix = medication.hour < 12 ? 'AM' : 'PM';
  return '$hour:${medication.minute.toString().padLeft(2, '0')} $suffix';
}

String formatClock(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final suffix = value.hour < 12 ? 'AM' : 'PM';
  return '$hour:${value.minute.toString().padLeft(2, '0')} $suffix';
}

String formatLongDate(DateTime value) {
  const months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${value.day} ${months[value.month - 1]} ${value.year}';
}

String historyDateHeading(DateTime value) {
  final today = MedicationController.dateOnly(DateTime.now());
  final date = MedicationController.dateOnly(value);
  final prefix = date == today
      ? 'Today'
      : date == today.subtract(const Duration(days: 1))
      ? 'Yesterday'
      : weekdayName(date.weekday);
  return '$prefix - ${date.day} ${shortMonthName(date.month)}';
}

String weekdayName(int weekday) => const <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][weekday - 1];

String shortMonthName(int month) => const <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month - 1];
