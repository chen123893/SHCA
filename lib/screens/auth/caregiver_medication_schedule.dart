import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shca/screens/auth/caregiver_dashboard.dart';
import 'package:shca/screens/auth/caregiver_shared.dart';
import 'package:shca/services/care_link_service.dart';
import 'package:shca/services/medication_image_service.dart';
import 'package:shca/services/medication_service.dart';
import 'package:shca/widgets/medication_visual.dart';

class CaregiverMedicationScheduleScreen extends StatefulWidget {
  const CaregiverMedicationScheduleScreen({
    super.key,
    required this.elderly,
    this.linkedElderly,
    this.repository,
    this.careLinkRepository,
    this.caregiverId,
  });

  final LinkedElderly elderly;
  final List<LinkedElderly>? linkedElderly;
  final MedicationRepository? repository;
  final CareLinkRepository? careLinkRepository;
  final String? caregiverId;

  @override
  State<CaregiverMedicationScheduleScreen> createState() =>
      _CaregiverMedicationScheduleScreenState();
}

class _CaregiverMedicationScheduleScreenState
    extends State<CaregiverMedicationScheduleScreen> {
  static const Color _background = Color(0xFFFFF8F0);
  static const Color _orange = Color(0xFFFF7518);

  late final MedicationRepository _repository;
  late LinkedElderly _selectedElderly;
  late List<LinkedElderly> _linkedElderly;
  late Future<_CaregiverMedicationData> _medicationFuture;
  List<MedicationSchedule> _currentSchedules = const <MedicationSchedule>[];
  final TextEditingController _searchController = TextEditingController();
  MedicationStatus? _statusFilter;
  String? _categoryFilter;
  late DateTimeRange _dateRange;

  @override
  void initState() {
    super.initState();
    _repository = widget.repository ?? FirestoreMedicationRepository();
    _selectedElderly = widget.elderly;
    _linkedElderly = _withSelected(
      widget.linkedElderly ?? const <LinkedElderly>[],
      widget.elderly,
    );
    final today = MedicationController.dateOnly(DateTime.now());
    _dateRange = DateTimeRange(
      start: today.subtract(const Duration(days: 2)),
      end: today,
    );
    _medicationFuture = _loadMedicationData();
    if (widget.linkedElderly == null) _loadLinkedElderly();
  }

  List<LinkedElderly> _withSelected(
    List<LinkedElderly> people,
    LinkedElderly selected,
  ) => <LinkedElderly>[
    selected,
    ...people.where((person) => person.id != selected.id),
  ];

  Future<void> _loadLinkedElderly() async {
    try {
      final repository =
          widget.careLinkRepository ?? FirestoreCareLinkRepository();
      final caregiverId =
          widget.caregiverId ?? FirebaseAuth.instance.currentUser?.uid;
      if (caregiverId == null || caregiverId.isEmpty) return;
      final people = await repository.loadLinkedElderly(caregiverId);
      if (!mounted || people.isEmpty) return;
      final active =
          people
              .where((person) => person.id == _selectedElderly.id)
              .firstOrNull ??
          people.first;
      final accountChanged = active.id != _selectedElderly.id;
      setState(() {
        _selectedElderly = active;
        _linkedElderly = _withSelected(people, active);
        if (accountChanged) {
          _currentSchedules = const <MedicationSchedule>[];
          _statusFilter = null;
          _categoryFilter = null;
          _searchController.clear();
          _medicationFuture = _loadMedicationData();
        }
      });
    } catch (_) {
      // Keep the current account available if the link list cannot refresh.
    }
  }

  void _selectElderly(String id) {
    final selected = _linkedElderly
        .where((person) => person.id == id)
        .firstOrNull;
    if (selected == null || selected.id == _selectedElderly.id) return;
    _searchController.clear();
    setState(() {
      _selectedElderly = selected;
      _currentSchedules = const <MedicationSchedule>[];
      _statusFilter = null;
      _categoryFilter = null;
      _medicationFuture = _loadMedicationData();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<_CaregiverMedicationData> _loadMedicationData() async {
    final elderlyId = _selectedElderly.id;
    final results = await Future.wait<Object>(<Future<Object>>[
      _repository.loadSchedules(elderlyId),
      _repository.loadRecords(elderlyId),
    ]);
    final data = _CaregiverMedicationData(
      schedules: results[0] as List<MedicationSchedule>,
      records: results[1] as List<MedicationRecord>,
    );
    if (_selectedElderly.id == elderlyId) _currentSchedules = data.schedules;
    return data;
  }

  Future<void> _reload() async {
    setState(() {
      _medicationFuture = _loadMedicationData();
    });
    await _medicationFuture;
  }

  void _setQuickRange(int days) {
    final today = MedicationController.dateOnly(DateTime.now());
    setState(() {
      _dateRange = DateTimeRange(
        start: today.subtract(Duration(days: days - 1)),
        end: today,
      );
    });
  }

  Future<void> _chooseDateRange() async {
    final today = MedicationController.dateOnly(DateTime.now());
    final selected = await showDateRangePicker(
      context: context,
      initialDateRange: _dateRange,
      firstDate: DateTime(today.year - 1, today.month, today.day),
      lastDate: today,
      helpText: 'Choose medication record dates',
      saveText: 'Apply',
    );
    if (selected == null || !mounted) return;
    if (selected.duration.inDays > 30) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a range of 31 days or less.')),
      );
      return;
    }
    setState(() => _dateRange = selected);
  }

  Future<void> _openMedicationForm([MedicationSchedule? existing]) async {
    final selectedElderly = _selectedElderly;
    final schedule = await showModalBottomSheet<MedicationSchedule>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _background,
      showDragHandle: false,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.94,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _MedicationFormSheet(
        elderlyId: selectedElderly.id,
        initialSchedule: existing,
      ),
    );
    if (schedule == null) return;

    final duplicate = isDuplicateMedicationSchedule(
      schedule,
      _currentSchedules,
    );
    if (duplicate) {
      await _deleteUnusedImage(schedule.imageKey, existing?.imageKey ?? '');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This reminder already exists. Tap the existing medicine to edit it.',
          ),
        ),
      );
      return;
    }

    final caregiverId =
        widget.caregiverId ?? FirebaseAuth.instance.currentUser?.uid;
    if (caregiverId == null || caregiverId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Your session expired. Log in again to save medicine.'),
        ),
      );
      return;
    }

    try {
      await _repository.saveSchedules(
        selectedElderly.id,
        <MedicationSchedule>[schedule],
        createdByCaregiverId: caregiverId,
        schedulesAreNew: existing == null,
      );
      final previousImage = existing?.imageKey ?? '';
      if (previousImage.isNotEmpty && previousImage != schedule.imageKey) {
        try {
          await const MedicationImageStorageService().delete(
            imageKey: previousImage,
            elderlyId: selectedElderly.id,
          );
        } catch (_) {
          // The schedule is already correct; stale-image cleanup can retry later.
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${schedule.name} reminder ${existing == null ? 'added' : 'updated'} '
            'for ${selectedElderly.fullName}.',
          ),
          backgroundColor: Colors.green,
        ),
      );
      await _reload();
    } catch (error) {
      await _deleteUnusedImage(schedule.imageKey, existing?.imageKey ?? '');
      if (!mounted) return;
      final message =
          error is FirebaseException && error.code == 'permission-denied'
          ? 'Medication could not be saved because this caregiver no longer has access. Refresh the link and try again.'
          : 'Medication could not be saved. Check your connection and try again.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _deleteUnusedImage(String candidate, String retained) async {
    if (candidate.isEmpty || candidate == retained) return;
    try {
      await const MedicationImageStorageService().delete(
        imageKey: candidate,
        elderlyId: _selectedElderly.id,
      );
    } catch (_) {
      // Best-effort cleanup must not block medication editing.
    }
  }

  Future<void> _deleteMedication(MedicationSchedule schedule) async {
    final selectedElderly = _selectedElderly;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(
          Icons.delete_outline_rounded,
          color: Colors.redAccent,
          size: 38,
        ),
        title: const Text('Delete medication reminder?'),
        content: Text(
          '${schedule.name} will be removed from the active schedule. '
          'Past medication history will remain available.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const Key('confirm-delete-medication'),
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _repository.deleteSchedule(selectedElderly.id, schedule.id);
      if (schedule.imageKey.isNotEmpty) {
        try {
          await const MedicationImageStorageService().delete(
            imageKey: schedule.imageKey,
            elderlyId: selectedElderly.id,
          );
        } catch (_) {
          // The reminder is deleted; private image cleanup can retry later.
        }
      }
      if (!mounted) return;
      setState(
        () => _currentSchedules = _currentSchedules
            .where((item) => item.id != schedule.id)
            .toList(growable: false),
      );
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${schedule.name} was deleted.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final message =
          error is FirebaseException && error.code == 'permission-denied'
          ? 'This caregiver no longer has permission to delete that reminder.'
          : 'Medication could not be deleted. Check your connection and try again.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _showLowStockMedicines(
    List<MedicationSchedule> medicines,
  ) async {
    final selected = await showModalBottomSheet<MedicationSchedule>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _background,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Medicines running low',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 5),
            const Text(
              'Tap a medicine to review its stock or edit its details.',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 14),
            for (final medicine in medicines)
              Card(
                color: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Color(0xFFFFC86B)),
                ),
                child: ListTile(
                  key: Key('low-stock-${medicine.id}'),
                  onTap: () => Navigator.pop(context, medicine),
                  leading: MedicationVisual(medication: medicine, size: 48),
                  title: Text(
                    medicine.name,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${medicine.stockRemaining ?? 0} left • Alert at ${medicine.lowStockThreshold}',
                  ),
                  trailing: const Icon(
                    Icons.edit_rounded,
                    color: Color(0xFFFF7518),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) await _openMedicationForm(selected);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      appBar: CaregiverPageHeader(
        title: 'Medication Schedule',
        onProfile: () => openCaregiverProfile(context),
      ),
      bottomNavigationBar: CaregiverBottomNavigation(
        selectedIndex: 2,
        onHome: () => openCaregiverHome(context),
        onStatus: () => Navigator.pushReplacement<void, void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => CaregiverElderlyStatusScreen(
              elderly: _selectedElderly,
              linkedElderly: _linkedElderly,
            ),
          ),
        ),
        onMedicine: () {},
        onProfile: () => openCaregiverProfile(context),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: CaregiverElderlySelector(
              people: [
                for (final person in _linkedElderly)
                  (id: person.id, name: person.fullName),
              ],
              selectedId: _selectedElderly.id,
              onChanged: _selectElderly,
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              color: _orange,
              child: FutureBuilder<_CaregiverMedicationData>(
                future: _medicationFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: _orange),
                    );
                  }
                  if (snapshot.hasError) {
                    return ListView(
                      padding: const EdgeInsets.all(24),
                      children: const [
                        _ScheduleMessage(
                          icon: Icons.cloud_off_rounded,
                          title: 'Unable to load medication',
                          message: 'Pull down to try again.',
                        ),
                      ],
                    );
                  }

                  final data =
                      snapshot.data ?? const _CaregiverMedicationData();
                  final schedules = data.schedules;
                  final lowStockMedicines = schedules
                      .where((schedule) => schedule.isLowStock)
                      .toList(growable: false);
                  final filteredSchedules = _filteredSchedules(schedules);
                  final categories = _categoryOptions(schedules);
                  final groupedRecords = _groupedRecords(data);
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                    children: [
                      Text(
                        _selectedElderly.fullName,
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Only reminders copied from existing instructions should be '
                        'entered here.',
                        style: TextStyle(color: Colors.black54),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Medicine Records',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          FilledButton.icon(
                            key: const Key('add-medication'),
                            onPressed: _openMedicationForm,
                            style: FilledButton.styleFrom(
                              backgroundColor: _orange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 11,
                              ),
                            ),
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('Add Medicine'),
                          ),
                        ],
                      ),
                      if (lowStockMedicines.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _LowStockBanner(
                          medicines: lowStockMedicines,
                          onTap: () =>
                              _showLowStockMedicines(lowStockMedicines),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('caregiver-medication-search'),
                              controller: _searchController,
                              textInputAction: TextInputAction.search,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                hintText: 'Search medicine',
                                prefixIcon: const Icon(Icons.search_rounded),
                                suffixIcon: _searchController.text.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: 'Clear search',
                                        onPressed: () {
                                          _searchController.clear();
                                          setState(() {});
                                        },
                                        icon: const Icon(Icons.close_rounded),
                                      ),
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(15),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFFFD0AE),
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(15),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFFFD0AE),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _CategoryFilterButton(
                            categories: categories,
                            selected: _categoryFilter,
                            onSelected: (category) =>
                                setState(() => _categoryFilter = category),
                          ),
                        ],
                      ),
                      if (_categoryFilter != null) ...[
                        const SizedBox(height: 9),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: InputChip(
                            key: const Key('active-category-filter'),
                            avatar: const Icon(
                              Icons.category_rounded,
                              size: 17,
                            ),
                            label: Text(_categoryFilter!),
                            onDeleted: () =>
                                setState(() => _categoryFilter = null),
                            deleteIconColor: _orange,
                            backgroundColor: const Color(0xFFFFE8D5),
                            side: const BorderSide(color: Color(0xFFFFC18F)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      if (schedules.isEmpty)
                        const _ScheduleMessage(
                          icon: Icons.medication_outlined,
                          title: 'No reminders added',
                          message:
                              'Tap Add Medicine to create the first reminder.',
                        )
                      else if (filteredSchedules.isEmpty)
                        const _ScheduleMessage(
                          icon: Icons.search_off_rounded,
                          title: 'No medicines found',
                          message:
                              'Try another name or clear the category filter.',
                        )
                      else
                        for (final schedule in filteredSchedules) ...[
                          _ScheduleCard(
                            schedule: schedule,
                            onEdit: () => _openMedicationForm(schedule),
                            onDelete: () => _deleteMedication(schedule),
                          ),
                          const SizedBox(height: 11),
                        ],
                      const SizedBox(height: 14),
                      _DateFilterCard(
                        range: _dateRange,
                        onPickRange: _chooseDateRange,
                        onQuickRange: _setQuickRange,
                      ),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _StatusFilterChip(
                              label: 'All',
                              selected: _statusFilter == null,
                              color: _orange,
                              onSelected: () =>
                                  setState(() => _statusFilter = null),
                            ),
                            for (final status in const <MedicationStatus>[
                              MedicationStatus.taken,
                              MedicationStatus.pending,
                              MedicationStatus.snoozed,
                              MedicationStatus.missed,
                            ]) ...[
                              const SizedBox(width: 8),
                              _StatusFilterChip(
                                label: _statusLabel(status),
                                selected: _statusFilter == status,
                                color: _statusColor(status),
                                onSelected: () =>
                                    setState(() => _statusFilter = status),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Medication History',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Text(
                            '${_dateRange.duration.inDays + 1} days',
                            style: const TextStyle(
                              color: Colors.black54,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      for (final entry in groupedRecords.entries) ...[
                        _MedicationDaySection(
                          date: entry.key,
                          records: entry.value,
                          schedules: schedules,
                          onEdit: _openMedicationForm,
                        ),
                        const SizedBox(height: 14),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<MedicationSchedule> _filteredSchedules(
    List<MedicationSchedule> schedules,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    return schedules
        .where(
          (schedule) =>
              _matchesCategory(schedule) &&
              (query.isEmpty || _matchesSchedule(schedule, query)),
        )
        .toList();
  }

  List<String> _categoryOptions(List<MedicationSchedule> schedules) {
    final categories =
        schedules
            .map((schedule) => schedule.category.trim())
            .where((category) => category.isNotEmpty)
            .toSet()
            .toList()
          ..sort(
            (first, second) =>
                first.toLowerCase().compareTo(second.toLowerCase()),
          );
    return categories;
  }

  bool _matchesCategory(MedicationSchedule schedule) =>
      _categoryFilter == null ||
      schedule.category.trim().toLowerCase() ==
          _categoryFilter!.trim().toLowerCase();

  Map<DateTime, List<MedicationRecord>> _groupedRecords(
    _CaregiverMedicationData data,
  ) {
    final query = _searchController.text.trim().toLowerCase();
    final start = MedicationController.dateOnly(_dateRange.start);
    final end = MedicationController.dateOnly(_dateRange.end);
    final grouped = <DateTime, List<MedicationRecord>>{};
    for (
      var date = end;
      !date.isBefore(start);
      date = date.subtract(const Duration(days: 1))
    ) {
      grouped[date] = <MedicationRecord>[];
    }
    for (final record in data.records) {
      final date = MedicationController.dateOnly(record.scheduledAt);
      if (date.isBefore(start) || date.isAfter(end)) continue;
      if (_statusFilter != null && record.status != _statusFilter) continue;
      final schedule = _scheduleFor(data.schedules, record);
      if (!_matchesCategory(schedule)) continue;
      if (query.isNotEmpty && !_matchesSchedule(schedule, query)) continue;
      grouped[date]?.add(record);
    }
    for (final records in grouped.values) {
      records.sort(
        (first, second) => first.scheduledAt.compareTo(second.scheduledAt),
      );
    }
    return grouped;
  }

  bool _matchesSchedule(MedicationSchedule schedule, String query) =>
      schedule.name.toLowerCase().contains(query) ||
      schedule.category.toLowerCase().contains(query) ||
      schedule.dose.toLowerCase().contains(query) ||
      schedule.instruction.toLowerCase().contains(query);
}

bool isDuplicateMedicationSchedule(
  MedicationSchedule candidate,
  Iterable<MedicationSchedule> currentSchedules,
) => currentSchedules.any(
  (existing) =>
      existing.id != candidate.id &&
      existing.name.trim().toLowerCase() ==
          candidate.name.trim().toLowerCase() &&
      existing.dose.trim().toLowerCase() ==
          candidate.dose.trim().toLowerCase() &&
      existing.effectiveQuantity == candidate.effectiveQuantity &&
      _sameReminderTimes(existing, candidate) &&
      existing.recurrence == candidate.recurrence &&
      MedicationController.dateOnly(existing.startDate ?? DateTime(1970)) ==
          MedicationController.dateOnly(
            candidate.startDate ?? DateTime(1970),
          ) &&
      MedicationController.dateOnly(existing.endDate ?? DateTime(1970)) ==
          MedicationController.dateOnly(candidate.endDate ?? DateTime(1970)) &&
      existing.weekdays.toSet().containsAll(candidate.weekdays) &&
      candidate.weekdays.toSet().containsAll(existing.weekdays) &&
      existing.intervalDays == candidate.intervalDays,
);

bool _sameReminderTimes(MedicationSchedule first, MedicationSchedule second) {
  final firstTimes = first.dailyReminderMinutes;
  final secondTimes = second.dailyReminderMinutes;
  if (firstTimes.length != secondTimes.length) return false;
  for (var index = 0; index < firstTimes.length; index++) {
    if (firstTimes[index] != secondTimes[index]) return false;
  }
  return true;
}

class _CaregiverMedicationData {
  const _CaregiverMedicationData({
    this.schedules = const <MedicationSchedule>[],
    this.records = const <MedicationRecord>[],
  });

  final List<MedicationSchedule> schedules;
  final List<MedicationRecord> records;
}

class _DateFilterCard extends StatelessWidget {
  const _DateFilterCard({
    required this.range,
    required this.onPickRange,
    required this.onQuickRange,
  });

  final DateTimeRange range;
  final VoidCallback onPickRange;
  final ValueChanged<int> onQuickRange;

  @override
  Widget build(BuildContext context) {
    final selectedDays = range.duration.inDays + 1;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1E2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFC88F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.date_range_rounded,
                size: 19,
                color: Color(0xFFFF7518),
              ),
              SizedBox(width: 7),
              Text(
                'Filter by date',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 10),
          InkWell(
            key: const Key('caregiver-medication-date-range'),
            onTap: onPickRange,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFD5B5)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _shortDate(range.start),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 17,
                      color: Colors.black45,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _shortDate(range.end),
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.edit_calendar_outlined,
                    size: 19,
                    color: Color(0xFFFF7518),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final days in const <int>[3, 7, 30])
                ChoiceChip(
                  label: Text(days == 30 ? '30 days' : 'Last $days days'),
                  selected: selectedDays == days,
                  onSelected: (_) => onQuickRange(days),
                  selectedColor: const Color(0xFFFFC38F),
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFFFFD5B5)),
                  labelStyle: const TextStyle(fontWeight: FontWeight.w700),
                  showCheckmark: false,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CategoryFilterButton extends StatelessWidget {
  const _CategoryFilterButton({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  static const String _allCategories = '__all_categories__';

  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final active = selected != null;
    return PopupMenuButton<String>(
      key: const Key('caregiver-category-filter'),
      tooltip: 'Filter by category',
      initialValue: selected ?? _allCategories,
      onSelected: (value) => onSelected(value == _allCategories ? null : value),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: _allCategories,
          checked: selected == null,
          child: const Text('All categories'),
        ),
        for (final category in categories)
          CheckedPopupMenuItem<String>(
            value: category,
            checked: selected == category,
            child: Text(category),
          ),
      ],
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFF7518) : Colors.white,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: const Color(0xFFFFD0AE)),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.tune_rounded,
              color: active ? Colors.white : const Color(0xFFFF7518),
            ),
            if (active)
              const Positioned(
                right: 9,
                top: 9,
                child: CircleAvatar(radius: 4, backgroundColor: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusFilterChip extends StatelessWidget {
  const _StatusFilterChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      showCheckmark: false,
      selectedColor: color,
      backgroundColor: Colors.white,
      side: BorderSide(color: selected ? color : const Color(0xFFFFD5B5)),
      labelStyle: TextStyle(
        color: selected ? Colors.white : Colors.black87,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _MedicationDaySection extends StatelessWidget {
  const _MedicationDaySection({
    required this.date,
    required this.records,
    required this.schedules,
    required this.onEdit,
  });

  final DateTime date;
  final List<MedicationRecord> records;
  final List<MedicationSchedule> schedules;
  final ValueChanged<MedicationSchedule> onEdit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _dateHeading(date),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: const Color(0xFFFFD0AE)),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x0C000000),
                blurRadius: 10,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: records.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.event_note_rounded, color: Colors.black38),
                      SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          'No matching medication records for this day.',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    for (var index = 0; index < records.length; index++) ...[
                      _CaregiverMedicationRecordRow(
                        record: records[index],
                        schedule: _scheduleFor(schedules, records[index]),
                        canEdit: schedules.any(
                          (schedule) =>
                              schedule.id == records[index].medicationId,
                        ),
                        onEdit: onEdit,
                      ),
                      if (index < records.length - 1)
                        const Divider(height: 1, indent: 78),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _CaregiverMedicationRecordRow extends StatelessWidget {
  const _CaregiverMedicationRecordRow({
    required this.record,
    required this.schedule,
    required this.canEdit,
    required this.onEdit,
  });

  final MedicationRecord record;
  final MedicationSchedule schedule;
  final bool canEdit;
  final ValueChanged<MedicationSchedule> onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          MedicationVisual(medication: schedule, size: 54),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${schedule.name} · ${_clock(record.scheduledAt)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${schedule.doseSummary} • ${schedule.instruction}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                if (canEdit) ...[
                  const SizedBox(height: 5),
                  InkWell(
                    onTap: () => onEdit(schedule),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: Color(0xFFFF7518),
                        ),
                        SizedBox(width: 3),
                        Text(
                          'Edit schedule',
                          style: TextStyle(
                            color: Color(0xFFFF7518),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _CaregiverStatusBadge(status: record.status),
              const SizedBox(height: 7),
              Text(
                record.actionAt == null ? '—' : _clock(record.actionAt!),
                style: const TextStyle(
                  color: Colors.black54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CaregiverStatusBadge extends StatelessWidget {
  const _CaregiverStatusBadge({required this.status});

  final MedicationStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _statusLabel(status),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

MedicationSchedule _scheduleFor(
  List<MedicationSchedule> schedules,
  MedicationRecord record,
) {
  if (record.scheduleSnapshot != null) return record.scheduleSnapshot!;
  for (final schedule in schedules) {
    if (schedule.id == record.medicationId) return schedule;
  }
  return MedicationSchedule(
    id: record.medicationId,
    name: 'Archived medication',
    dose: 'Previous schedule',
    instruction: 'No longer active',
    category: 'Archived',
    hour: record.scheduledAt.hour,
    minute: record.scheduledAt.minute,
    visual: 'tablet',
  );
}

String _statusLabel(MedicationStatus status) => switch (status) {
  MedicationStatus.taken => 'Taken',
  MedicationStatus.pending => 'Pending',
  MedicationStatus.snoozed => 'Snoozed',
  MedicationStatus.missed => 'Missed',
};

Color _statusColor(MedicationStatus status) => switch (status) {
  MedicationStatus.taken => const Color(0xFF15945B),
  MedicationStatus.pending => const Color(0xFFFF8B00),
  MedicationStatus.snoozed => const Color(0xFF9A6B12),
  MedicationStatus.missed => const Color(0xFFE53935),
};

String _shortDate(DateTime date) =>
    '${date.day} ${_monthName(date.month)} ${date.year}';

String _formatFormDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/'
    '${date.month.toString().padLeft(2, '0')}/${date.year}';

String _dateHeading(DateTime date) {
  final today = MedicationController.dateOnly(DateTime.now());
  final target = MedicationController.dateOnly(date);
  final prefix = target == today
      ? 'Today'
      : target == today.subtract(const Duration(days: 1))
      ? 'Yesterday'
      : _weekdayName(target.weekday);
  return '$prefix · ${target.day} ${_monthName(target.month)}';
}

String _clock(DateTime value) {
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${value.hour < 12 ? 'AM' : 'PM'}';
}

String _monthName(int month) => const <String>[
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

String _weekdayName(int weekday) => const <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][weekday - 1];

enum _TreatmentDuration {
  ongoing,
  threeDays,
  fiveDays,
  sevenDays,
  fourteenDays,
  thirtyDays,
  custom,
}

int? _treatmentDurationDays(_TreatmentDuration value) => switch (value) {
  _TreatmentDuration.ongoing || _TreatmentDuration.custom => null,
  _TreatmentDuration.threeDays => 3,
  _TreatmentDuration.fiveDays => 5,
  _TreatmentDuration.sevenDays => 7,
  _TreatmentDuration.fourteenDays => 14,
  _TreatmentDuration.thirtyDays => 30,
};

String _treatmentDurationLabel(_TreatmentDuration value) => switch (value) {
  _TreatmentDuration.ongoing => 'Ongoing / until stopped',
  _TreatmentDuration.threeDays => '3 days',
  _TreatmentDuration.fiveDays => '5 days',
  _TreatmentDuration.sevenDays => '7 days',
  _TreatmentDuration.fourteenDays => '14 days',
  _TreatmentDuration.thirtyDays => '30 days',
  _TreatmentDuration.custom => 'Custom end date',
};

_TreatmentDuration _durationOptionFor(DateTime start, DateTime? end) {
  if (end == null) return _TreatmentDuration.ongoing;
  final days =
      MedicationController.dateOnly(
        end,
      ).difference(MedicationController.dateOnly(start)).inDays +
      1;
  return switch (days) {
    3 => _TreatmentDuration.threeDays,
    5 => _TreatmentDuration.fiveDays,
    7 => _TreatmentDuration.sevenDays,
    14 => _TreatmentDuration.fourteenDays,
    30 => _TreatmentDuration.thirtyDays,
    _ => _TreatmentDuration.custom,
  };
}

class _MedicationFormSheet extends StatefulWidget {
  const _MedicationFormSheet({required this.elderlyId, this.initialSchedule});

  final String elderlyId;
  final MedicationSchedule? initialSchedule;

  @override
  State<_MedicationFormSheet> createState() => _MedicationFormSheetState();
}

class _MedicationFormSheetState extends State<_MedicationFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _doseController = TextEditingController();
  final _instructionController = TextEditingController();
  final _categoryController = TextEditingController();
  final _stockController = TextEditingController();
  final _lowStockController = TextEditingController(text: '3');
  final _imagePicker = ImagePicker();
  final _textRecognitionService = const MedicationTextRecognitionService();
  final _imageStorageService = const MedicationImageStorageService();
  List<TimeOfDay> _times = <TimeOfDay>[const TimeOfDay(hour: 8, minute: 0)];
  late DateTime _startDate;
  DateTime? _endDate;
  _TreatmentDuration _durationOption = _TreatmentDuration.ongoing;
  MedicationRecurrence _recurrence = MedicationRecurrence.daily;
  Set<int> _selectedWeekdays = <int>{};
  int _intervalDays = 2;
  int _quantityPerDose = 1;
  String _strengthUnit = 'mg';
  String _visual = 'tablet';
  String? _instructionSource;
  bool _sourceConfirmed = false;
  bool _photoPrivacyConfirmed = false;
  bool _isScanning = false;
  bool _isSaving = false;
  XFile? _selectedImage;
  String _recognisedText = '';
  bool _removeExistingImage = false;
  String? _formMessage;
  bool _formMessageIsError = false;

  bool get _isEditing => widget.initialSchedule != null;

  bool get _hasExistingImage =>
      !_removeExistingImage &&
      (widget.initialSchedule?.imageKey.trim().isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    _startDate = MedicationController.dateOnly(DateTime.now());
    final schedule = widget.initialSchedule;
    if (schedule == null) return;
    _nameController.text = schedule.name;
    _setStrengthFromText(medicationStrengthFromText(schedule.dose));
    _quantityPerDose = schedule.effectiveQuantity;
    _instructionController.text = schedule.instruction;
    _categoryController.text = schedule.category;
    _stockController.text = schedule.stockRemaining?.toString() ?? '';
    _lowStockController.text = schedule.lowStockThreshold.toString();
    _times = schedule.dailyReminderMinutes
        .map((minutes) => TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60))
        .toList(growable: true);
    _visual =
        const <String>{
          'tablet',
          'capsule',
          'liquid',
          'vitamin',
        }.contains(schedule.visual)
        ? schedule.visual
        : 'tablet';
    _instructionSource =
        const <String>{
          'Doctor prescription',
          'Pharmacist instruction',
          'Medicine label',
          'Supplement label',
        }.contains(schedule.instructionSource)
        ? schedule.instructionSource
        : null;
    _sourceConfirmed = schedule.sourceConfirmed;
    _startDate = MedicationController.dateOnly(
      schedule.startDate ?? DateTime.now(),
    );
    _endDate = schedule.endDate == null
        ? null
        : MedicationController.dateOnly(schedule.endDate!);
    _durationOption = _durationOptionFor(_startDate, _endDate);
    _recurrence = schedule.recurrence;
    _selectedWeekdays = schedule.weekdays.toSet();
    _intervalDays = schedule.intervalDays.clamp(2, 365);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _doseController.dispose();
    _instructionController.dispose();
    _categoryController.dispose();
    _stockController.dispose();
    _lowStockController.dispose();
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'This field is required.' : null;

  void _setStrengthFromText(String? value, {bool onlyIfEmpty = false}) {
    if (onlyIfEmpty && _doseController.text.trim().isNotEmpty) return;
    final text = (value ?? '').trim();
    if (text.isEmpty) return;
    final match = RegExp(
      r'^(\d+(?:\.\d+)?)\s*(mg|mcg|µg|g|ml|iu)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return;
    _doseController.text = match.group(1)!;
    _strengthUnit = switch (match.group(2)!.toLowerCase()) {
      'mcg' || 'µg' => 'mcg',
      'ml' => 'mL',
      'iu' => 'IU',
      final unit => unit,
    };
  }

  Future<void> _chooseTime(int index) async {
    final selected = await showTimePicker(
      context: context,
      initialTime: _times[index],
    );
    if (selected != null) setState(() => _times[index] = selected);
  }

  void _setTimesPerDay(int count) {
    const defaults = <TimeOfDay>[
      TimeOfDay(hour: 8, minute: 0),
      TimeOfDay(hour: 13, minute: 0),
      TimeOfDay(hour: 18, minute: 0),
      TimeOfDay(hour: 22, minute: 0),
      TimeOfDay(hour: 10, minute: 0),
      TimeOfDay(hour: 16, minute: 0),
    ];
    setState(() {
      if (count < _times.length) {
        _times = _times.take(count).toList(growable: true);
        return;
      }
      final used = _times.map((time) => time.hour * 60 + time.minute).toSet();
      for (final value in defaults) {
        if (_times.length >= count) break;
        if (used.add(value.hour * 60 + value.minute)) _times.add(value);
      }
      while (_times.length < count) {
        final previous = _times.last;
        final minutes = (previous.hour * 60 + previous.minute + 240) % 1440;
        final value = TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60);
        if (used.add(minutes)) _times.add(value);
      }
    });
  }

  Future<void> _pickMedicinePhoto(ImageSource source) async {
    final image = await _imagePicker.pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 82,
    );
    if (image == null || !mounted) return;
    setState(() {
      _selectedImage = image;
      _removeExistingImage = false;
      _photoPrivacyConfirmed = false;
    });
  }

  Future<void> _choosePackageScanSource() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Scan medicine packaging',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 5),
              const Text(
                'SHCA reads English and Malay text on this device and suggests editable details. The scan is not saved as the medicine photo.',
                style: TextStyle(color: Colors.black54, height: 1.35),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, ImageSource.camera),
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('Scan with Camera'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Choose Package Image'),
              ),
            ],
          ),
        ),
      ),
    );
    if (source != null && mounted) await _scanPackage(source);
  }

  Future<void> _scanPackage(ImageSource source) async {
    final image = await _imagePicker.pickImage(
      source: source,
      maxWidth: 2000,
      maxHeight: 2000,
      imageQuality: 90,
    );
    if (image == null || !mounted) return;
    setState(() {
      _recognisedText = '';
      _isScanning = true;
    });
    try {
      final text = await _textRecognitionService.recognise(image);
      if (!mounted) return;
      final suggestions = medicationSuggestionsFromText(text);
      setState(() {
        _recognisedText = text;
        _applySuggestionIfEmpty(_nameController, suggestions.name);
        final suggestedDose = suggestions.dose;
        final suggestedQuantity = suggestions.quantity;
        if (suggestedQuantity != null) {
          _quantityPerDose = suggestedQuantity.clamp(1, 99);
        }
        _setStrengthFromText(suggestedDose, onlyIfEmpty: true);
        _applySuggestionIfEmpty(
          _instructionController,
          suggestions.instruction,
        );
        _applySuggestionIfEmpty(_categoryController, suggestions.category);
        _visual = suggestions.visual;
        _instructionSource ??= 'Medicine label';
      });
      final message = text.isEmpty
          ? 'No clear text was found. You can still enter the details manually.'
          : suggestions.name == null
          ? 'Text was found, but the medicine name was not clear. Enter the name from the label manually.'
          : 'Medicine label detected. Check every field before saving.';
      _showMessage([message, ...suggestions.reviewNotes].join('\n'));
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Text could not be recognised. Retake a clear photo or enter it manually.',
        );
      }
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _chooseStartDate() async {
    final selected = await _chooseDate(
      initialDate: _startDate,
      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _startDate = selected;
      final presetDays = _treatmentDurationDays(_durationOption);
      if (presetDays != null) {
        _endDate = selected.add(Duration(days: presetDays - 1));
      } else if (_endDate != null && _endDate!.isBefore(selected)) {
        _endDate = null;
        _durationOption = _TreatmentDuration.ongoing;
      }
    });
  }

  Future<void> _chooseEndDate() async {
    final selected = await _chooseDate(
      initialDate: _endDate ?? _startDate.add(const Duration(days: 7)),
      firstDate: _startDate,
    );
    if (selected != null && mounted) {
      setState(() {
        _endDate = selected;
        _durationOption = _TreatmentDuration.custom;
      });
    }
  }

  Future<void> _changeTreatmentDuration(_TreatmentDuration value) async {
    if (value == _TreatmentDuration.custom) {
      setState(() => _durationOption = value);
      await _chooseEndDate();
      return;
    }
    final days = _treatmentDurationDays(value);
    setState(() {
      _durationOption = value;
      _endDate = days == null ? null : _startDate.add(Duration(days: days - 1));
    });
  }

  Future<DateTime?> _chooseDate({
    required DateTime initialDate,
    required DateTime firstDate,
  }) async {
    final lastDate = DateTime.now().add(const Duration(days: 3650));
    final safeInitial = initialDate.isBefore(firstDate)
        ? firstDate
        : initialDate;
    final selected = await showDatePicker(
      context: context,
      initialDate: safeInitial.isAfter(lastDate) ? lastDate : safeInitial,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    return selected == null ? null : MedicationController.dateOnly(selected);
  }

  String get _scheduleSectionSubtitle => switch (_recurrence) {
    MedicationRecurrence.daily => 'Reminder repeats every day.',
    MedicationRecurrence.selectedDays => 'Reminder runs only on selected days.',
    MedicationRecurrence.intervalDays =>
      'Reminder repeats every $_intervalDays days.',
    MedicationRecurrence.oneTime => 'A single reminder on the selected date.',
    MedicationRecurrence.asNeeded =>
      'No automatic alarm and never marked as missed.',
  };

  void _applySuggestionIfEmpty(
    TextEditingController controller,
    String? suggestion,
  ) {
    if (controller.text.trim().isEmpty &&
        suggestion?.trim().isNotEmpty == true) {
      controller.text = suggestion!.trim();
    }
  }

  void _removePhoto() {
    setState(() {
      _selectedImage = null;
      _removeExistingImage = true;
      _recognisedText = '';
      _photoPrivacyConfirmed = false;
    });
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _formMessage = message;
      _formMessageIsError = isError;
    });
  }

  Future<bool> _confirmCategoryFallback() async {
    if (_imageStorageService.isConfigured) return false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.cloud_off_outlined),
            title: const Text('Private upload is not configured'),
            content: const Text(
              'Save this reminder without the photo? SHCA will use the selected medicine type image instead.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Use category image'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _save() async {
    final formIsValid = _formKey.currentState!.validate();
    final selectedTimes =
        (_recurrence == MedicationRecurrence.oneTime ||
                    _recurrence == MedicationRecurrence.asNeeded
                ? _times.take(1)
                : _times)
            .map((time) => time.hour * 60 + time.minute)
            .toList()
          ..sort();
    final issues = <String>[
      if (_nameController.text.trim().isEmpty) 'medicine name',
      if (_instructionSource == null) 'instruction source',
      if (_instructionController.text.trim().isEmpty) 'instruction',
      if (_recurrence == MedicationRecurrence.selectedDays &&
          _selectedWeekdays.isEmpty)
        'at least one repeat day',
      if (_recurrence != MedicationRecurrence.oneTime &&
          _durationOption == _TreatmentDuration.custom &&
          _endDate == null)
        'a treatment end date',
      if (!_sourceConfirmed) 'the safety confirmation',
      if (_selectedImage != null && !_photoPrivacyConfirmed)
        'the photo privacy confirmation',
      if (selectedTimes.toSet().length != selectedTimes.length)
        'a different time for every daily dose',
    ];
    final stockText = _stockController.text.trim();
    final stock = stockText.isEmpty ? null : int.tryParse(stockText);
    if (stockText.isNotEmpty && (stock == null || stock < 0)) {
      issues.add('a whole number of 0 or more for stock');
    }
    final lowStockText = _lowStockController.text.trim();
    final lowStockThreshold = int.tryParse(lowStockText);
    if (lowStockThreshold == null || lowStockThreshold < 0) {
      issues.add('a refill alert level of 0 or more');
    }
    final strengthText = _doseController.text.trim();
    final strength = strengthText.isEmpty
        ? null
        : double.tryParse(strengthText);
    if (strengthText.isNotEmpty && (strength == null || strength <= 0)) {
      issues.add('a positive number for strength');
    }
    if (!formIsValid || issues.isNotEmpty) {
      _showMessage(
        issues.isEmpty
            ? 'Check the highlighted fields before saving.'
            : 'Before saving, complete: ${issues.join(', ')}.',
        isError: true,
      );
      return;
    }
    final medicationId =
        widget.initialSchedule?.id ??
        DateTime.now().microsecondsSinceEpoch.toString();
    var imageKey = _hasExistingImage ? widget.initialSchedule!.imageKey : '';
    final selectedImage = _selectedImage;
    if (selectedImage != null && !_imageStorageService.isConfigured) {
      if (!await _confirmCategoryFallback()) return;
    } else if (selectedImage != null) {
      setState(() => _isSaving = true);
      try {
        imageKey = await _imageStorageService.upload(
          image: selectedImage,
          elderlyId: widget.elderlyId,
          medicationId: medicationId,
        );
      } catch (error) {
        if (!mounted) return;
        _showMessage(
          'Medicine photo could not be uploaded: $error',
          isError: true,
        );
        setState(() => _isSaving = false);
        return;
      }
    }
    if (!mounted) return;
    final firstReminder = selectedTimes.first;
    Navigator.pop(
      context,
      MedicationSchedule(
        id: medicationId,
        name: _nameController.text.trim(),
        dose: strengthText.isEmpty ? '' : '$strengthText $_strengthUnit',
        instruction: _instructionController.text.trim(),
        category: _categoryController.text.trim(),
        hour: firstReminder ~/ 60,
        minute: firstReminder % 60,
        visual: _visual,
        elderlyId: widget.elderlyId,
        imageKey: imageKey,
        instructionSource: _instructionSource!,
        sourceConfirmed: true,
        quantity: _quantityPerDose,
        stockRemaining: stock,
        lowStockThreshold: lowStockThreshold ?? 3,
        recurrence: _recurrence,
        startDate: _startDate,
        endDate: _recurrence == MedicationRecurrence.oneTime ? null : _endDate,
        weekdays: _selectedWeekdays.toList()..sort(),
        intervalDays: _intervalDays,
        reminderMinutes: selectedTimes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themed = Theme.of(context).copyWith(
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFFFFCF8),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 15,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFFFD4B5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFFF7518), width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.redAccent),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.redAccent, width: 2),
        ),
      ),
    );
    return Theme(
      data: themed,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.94,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
              decoration: const BoxDecoration(
                color: Color(0xFFFFB87D),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.82),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Icon(
                      Icons.medication_liquid_rounded,
                      color: Color(0xFFFF7518),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isEditing ? 'Edit Medication' : 'Add Medication',
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          _isEditing
                              ? 'Update the reminder details below.'
                              : 'Create a reminder from existing instructions.',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    key: const Key('scan-medication-package'),
                    tooltip: 'Scan medicine packaging',
                    onPressed: _isSaving || _isScanning
                        ? null
                        : _choosePackageScanSource,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.82),
                      foregroundColor: const Color(0xFFFF7518),
                    ),
                    icon: _isScanning
                        ? const SizedBox(
                            width: 19,
                            height: 19,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.document_scanner_outlined),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (_formMessage != null)
              Semantics(
                liveRegion: true,
                child: Container(
                  key: const Key('medication-form-message'),
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(18, 11, 10, 11),
                  color: _formMessageIsError
                      ? const Color(0xFFFFE8E8)
                      : const Color(0xFFFFF3D6),
                  child: Row(
                    children: [
                      Icon(
                        _formMessageIsError
                            ? Icons.error_outline_rounded
                            : Icons.info_outline_rounded,
                        color: _formMessageIsError
                            ? const Color(0xFFB42318)
                            : const Color(0xFF8A5A00),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _formMessage!,
                          style: TextStyle(
                            color: _formMessageIsError
                                ? const Color(0xFF8F1D18)
                                : const Color(0xFF684500),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('dismiss-medication-form-message'),
                        tooltip: 'Dismiss message',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _formMessage = null),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  18,
                  18,
                  18,
                  MediaQuery.viewInsetsOf(context).bottom + 24,
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FormSection(
                        icon: Icons.add_a_photo_outlined,
                        title: 'Medicine image',
                        subtitle:
                            'Add a clear photo so the elderly can identify it.',
                        child: Column(
                          children: [
                            _MedicinePhotoPicker(
                              image: _selectedImage,
                              existingMedication: widget.initialSchedule,
                              hasExistingImage: _hasExistingImage,
                              onCamera: _isSaving
                                  ? null
                                  : () =>
                                        _pickMedicinePhoto(ImageSource.camera),
                              onGallery: _isSaving
                                  ? null
                                  : () =>
                                        _pickMedicinePhoto(ImageSource.gallery),
                              onRemove:
                                  _isSaving ||
                                      (_selectedImage == null &&
                                          !_hasExistingImage)
                                  ? null
                                  : _removePhoto,
                            ),
                            if (_selectedImage != null) ...[
                              const SizedBox(height: 8),
                              Material(
                                color: Colors.transparent,
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  value: _photoPrivacyConfirmed,
                                  onChanged: _isSaving
                                      ? null
                                      : (value) => setState(
                                          () => _photoPrivacyConfirmed =
                                              value ?? false,
                                        ),
                                  title: const Text(
                                    'No patient name, IC number, address or phone number is visible.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (_recognisedText.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Material(
                                color: const Color(0xFFFFF3E7),
                                borderRadius: BorderRadius.circular(12),
                                child: ExpansionTile(
                                  dense: true,
                                  leading: const Icon(
                                    Icons.document_scanner_outlined,
                                    color: Color(0xFFFF7518),
                                  ),
                                  title: const Text(
                                    'Recognised package text',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  subtitle: const Text(
                                    'From the separate package scan — check every field',
                                  ),
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        0,
                                        16,
                                        14,
                                      ),
                                      child: SelectableText(
                                        _recognisedText,
                                        style: const TextStyle(
                                          color: Colors.black54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _FormSection(
                        icon: Icons.medication_outlined,
                        title: 'Medicine details',
                        subtitle: 'Copy the information exactly as written.',
                        child: Column(
                          children: [
                            TextFormField(
                              key: const Key('medication-name'),
                              controller: _nameController,
                              validator: _required,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Medicine name',
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    key: const Key('medication-dose'),
                                    controller: _doseController,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: 'Strength (optional)',
                                      hintText: 'e.g. 500',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  width: 112,
                                  child: DropdownButtonFormField<String>(
                                    key: const Key('medication-strength-unit'),
                                    initialValue: _strengthUnit,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                      labelText: 'Unit',
                                    ),
                                    items: const <DropdownMenuItem<String>>[
                                      DropdownMenuItem(
                                        value: 'mg',
                                        child: Text('mg'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'mcg',
                                        child: Text('mcg'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'g',
                                        child: Text('g'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'mL',
                                        child: Text('mL'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'IU',
                                        child: Text('IU'),
                                      ),
                                    ],
                                    onChanged: _isSaving
                                        ? null
                                        : (value) => setState(
                                            () => _strengthUnit = value!,
                                          ),
                                  ),
                                ),
                              ],
                            ),
                            const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Copy both the number and unit from the package or prescription.',
                                  style: TextStyle(
                                    color: Colors.black54,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _QuantityStepper(
                              quantity: _quantityPerDose,
                              unit: switch (_visual) {
                                'capsule' => 'capsule',
                                'liquid' => 'dose',
                                _ => 'tablet',
                              },
                              enabled: !_isSaving,
                              onDecrease: _quantityPerDose <= 1
                                  ? null
                                  : () => setState(() => _quantityPerDose--),
                              onIncrease: _quantityPerDose >= 99
                                  ? null
                                  : () => setState(() => _quantityPerDose++),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              key: ValueKey(
                                'instruction-source-${_instructionSource ?? 'none'}',
                              ),
                              isExpanded: true,
                              initialValue: _instructionSource,
                              validator: (value) => value == null
                                  ? 'Select where the instruction came from.'
                                  : null,
                              decoration: const InputDecoration(
                                labelText: 'Instruction source',
                              ),
                              items: const <DropdownMenuItem<String>>[
                                DropdownMenuItem(
                                  value: 'Doctor prescription',
                                  child: Text('Doctor prescription'),
                                ),
                                DropdownMenuItem(
                                  value: 'Pharmacist instruction',
                                  child: Text('Pharmacist instruction'),
                                ),
                                DropdownMenuItem(
                                  value: 'Medicine label',
                                  child: Text('Medicine label'),
                                ),
                                DropdownMenuItem(
                                  value: 'Supplement label',
                                  child: Text('Supplement label'),
                                ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _instructionSource = value),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              key: const Key('medication-instruction'),
                              controller: _instructionController,
                              validator: _required,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Instructions (English or Malay)',
                                helperText: 'e.g. Selepas makan / After meal',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _categoryController,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: 'Purpose or category (optional)',
                                hintText: 'e.g. Diabetes, Vitamin',
                              ),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              key: ValueKey('medicine-type-$_visual'),
                              isExpanded: true,
                              initialValue: _visual,
                              decoration: const InputDecoration(
                                labelText: 'Medicine type / fallback image',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'tablet',
                                  child: Text('Tablet'),
                                ),
                                DropdownMenuItem(
                                  value: 'capsule',
                                  child: Text('Capsule'),
                                ),
                                DropdownMenuItem(
                                  value: 'liquid',
                                  child: Text('Liquid'),
                                ),
                                DropdownMenuItem(
                                  value: 'vitamin',
                                  child: Text('Vitamin'),
                                ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _visual = value!),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _FormSection(
                        icon: Icons.alarm_rounded,
                        title: 'Reminder schedule',
                        subtitle: _scheduleSectionSubtitle,
                        child: Column(
                          children: [
                            DropdownButtonFormField<MedicationRecurrence>(
                              key: const Key('medication-repeat-type'),
                              initialValue: _recurrence,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Repeat',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: MedicationRecurrence.daily,
                                  child: Text('Every day'),
                                ),
                                DropdownMenuItem(
                                  value: MedicationRecurrence.selectedDays,
                                  child: Text('Selected days'),
                                ),
                                DropdownMenuItem(
                                  value: MedicationRecurrence.intervalDays,
                                  child: Text('Every few days'),
                                ),
                                DropdownMenuItem(
                                  value: MedicationRecurrence.oneTime,
                                  child: Text('One time only'),
                                ),
                                DropdownMenuItem(
                                  value: MedicationRecurrence.asNeeded,
                                  child: Text('As needed (no alarm)'),
                                ),
                              ],
                              onChanged: _isSaving
                                  ? null
                                  : (value) =>
                                        setState(() => _recurrence = value!),
                            ),
                            const SizedBox(height: 12),
                            _DateSelectionTile(
                              key: const Key('medication-start-date'),
                              label: _recurrence == MedicationRecurrence.oneTime
                                  ? 'Reminder date'
                                  : 'Treatment start date',
                              value: _formatFormDate(_startDate),
                              onTap: _isSaving ? null : _chooseStartDate,
                            ),
                            if (_recurrence !=
                                MedicationRecurrence.oneTime) ...[
                              const SizedBox(height: 12),
                              DropdownButtonFormField<_TreatmentDuration>(
                                key: const Key('medication-duration'),
                                initialValue: _durationOption,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Treatment duration',
                                  helperText:
                                      'Copy the duration from the prescription or medicine label.',
                                ),
                                items: _TreatmentDuration.values
                                    .map(
                                      (value) => DropdownMenuItem(
                                        value: value,
                                        child: Text(
                                          _treatmentDurationLabel(value),
                                        ),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: _isSaving
                                    ? null
                                    : (value) {
                                        if (value != null) {
                                          _changeTreatmentDuration(value);
                                        }
                                      },
                              ),
                              if (_durationOption ==
                                  _TreatmentDuration.custom) ...[
                                const SizedBox(height: 12),
                                _DateSelectionTile(
                                  key: const Key('medication-end-date'),
                                  label: 'Treatment end date',
                                  value: _endDate == null
                                      ? 'Choose date'
                                      : _formatFormDate(_endDate!),
                                  onTap: _isSaving ? null : _chooseEndDate,
                                ),
                              ] else if (_endDate != null) ...[
                                const SizedBox(height: 7),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Ends ${_formatFormDate(_endDate!)} (${_treatmentDurationLabel(_durationOption)})',
                                    style: const TextStyle(
                                      color: Color(0xFF6F625A),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                            if (_recurrence ==
                                MedicationRecurrence.selectedDays) ...[
                              const SizedBox(height: 12),
                              _WeekdaySelector(
                                selected: _selectedWeekdays,
                                enabled: !_isSaving,
                                onChanged: (weekday, selected) => setState(() {
                                  if (selected) {
                                    _selectedWeekdays.add(weekday);
                                  } else {
                                    _selectedWeekdays.remove(weekday);
                                  }
                                }),
                              ),
                            ],
                            if (_recurrence ==
                                MedicationRecurrence.intervalDays) ...[
                              const SizedBox(height: 12),
                              _IntervalDayStepper(
                                days: _intervalDays,
                                enabled: !_isSaving,
                                onDecrease: _intervalDays <= 2
                                    ? null
                                    : () => setState(() => _intervalDays--),
                                onIncrease: _intervalDays >= 365
                                    ? null
                                    : () => setState(() => _intervalDays++),
                              ),
                            ],
                            if (_recurrence !=
                                MedicationRecurrence.asNeeded) ...[
                              const SizedBox(height: 12),
                              if (_recurrence !=
                                  MedicationRecurrence.oneTime) ...[
                                DropdownButtonFormField<int>(
                                  key: const Key('medication-times-per-day'),
                                  initialValue: _times.length,
                                  decoration: const InputDecoration(
                                    labelText: 'How many times per day?',
                                    prefixIcon: Icon(Icons.repeat_rounded),
                                  ),
                                  items: <int>[1, 2, 3, 4, 5, 6]
                                      .map(
                                        (count) => DropdownMenuItem<int>(
                                          value: count,
                                          child: Text(
                                            count == 1
                                                ? 'Once per day'
                                                : '$count times per day',
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: _isSaving
                                      ? null
                                      : (count) {
                                          if (count != null) {
                                            _setTimesPerDay(count);
                                          }
                                        },
                                ),
                                const SizedBox(height: 7),
                                const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Set a separate reminder for each dose.',
                                    style: TextStyle(
                                      color: Color(0xFF75675F),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                              for (
                                var index = 0;
                                index <
                                    (_recurrence == MedicationRecurrence.oneTime
                                        ? 1
                                        : _times.length);
                                index++
                              ) ...[
                                const SizedBox(height: 10),
                                InkWell(
                                  key: index == 0
                                      ? const Key('change-medication-time')
                                      : Key('change-medication-time-$index'),
                                  onTap: _isSaving
                                      ? null
                                      : () => _chooseTime(index),
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFFCF8),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: const Color(0xFFFFD4B5),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.schedule_rounded,
                                          color: Color(0xFFFF7518),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            _recurrence ==
                                                    MedicationRecurrence.oneTime
                                                ? 'Reminder time'
                                                : 'Dose ${index + 1} time',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          _times[index].format(context),
                                          style: const TextStyle(
                                            color: Color(0xFFFF7518),
                                            fontSize: 17,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Icon(Icons.chevron_right_rounded),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ] else ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF5D9),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: const Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.info_outline_rounded,
                                      color: Color(0xFF9A6B12),
                                    ),
                                    SizedBox(width: 9),
                                    Expanded(
                                      child: Text(
                                        'Use this only when the label or healthcare professional says “as needed”. It will not create alarms or missed-dose records.',
                                        style: TextStyle(
                                          color: Color(0xFF6E5015),
                                          fontSize: 12,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    key: const Key('medication-stock'),
                                    controller: _stockController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Doses remaining',
                                      hintText: 'Optional',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: TextFormField(
                                    key: const Key(
                                      'medication-low-stock-threshold',
                                    ),
                                    controller: _lowStockController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Refill alert at',
                                      helperText: 'Number of doses left',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _FormSection(
                        icon: Icons.verified_user_outlined,
                        title: 'Safety check',
                        subtitle:
                            'SHCA creates reminders and does not prescribe.',
                        child: Material(
                          color: Colors.transparent,
                          child: CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _sourceConfirmed,
                            onChanged: _isSaving
                                ? null
                                : (value) => setState(
                                    () => _sourceConfirmed = value ?? false,
                                  ),
                            title: const Text(
                              'I copied an existing instruction and did not independently change the dosage.',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: FilledButton.icon(
                          key: const Key('save-medication'),
                          onPressed: _isSaving || _isScanning ? null : _save,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFFF7518),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                          icon: _isSaving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(
                                  _isEditing
                                      ? Icons.save_outlined
                                      : Icons.add_task_rounded,
                                ),
                          label: Text(
                            _isSaving
                                ? 'Uploading securely...'
                                : _isEditing
                                ? 'Save Changes'
                                : 'Save Medication',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.schedule,
    required this.onEdit,
    required this.onDelete,
  });

  final MedicationSchedule schedule;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final reminderTimes = schedule.dailyReminderMinutes
        .map(
          (minutes) => TimeOfDay(
            hour: minutes ~/ 60,
            minute: minutes % 60,
          ).format(context),
        )
        .join(', ');
    return Material(
      color: Colors.white,
      elevation: 1,
      shadowColor: Colors.black12,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        key: Key('edit-medication-${schedule.id}'),
        onTap: onEdit,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFFFCBA7)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MedicationVisual(medication: schedule, size: 60),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      schedule.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${schedule.doseSummary} • ${schedule.instruction}',
                      style: const TextStyle(color: Colors.black54),
                    ),
                    if (schedule.category.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        schedule.category,
                        style: const TextStyle(
                          color: Color(0xFFFF7518),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      schedule.scheduleSummary,
                      style: const TextStyle(
                        color: Color(0xFF6F625A),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (schedule.hasAutomaticReminder) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${schedule.timesPerDay == 1 ? 'Once' : '${schedule.timesPerDay} times'} per day • $reminderTimes',
                        style: const TextStyle(
                          color: Color(0xFFFF7518),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      schedule.treatmentDurationSummary,
                      style: const TextStyle(
                        color: Color(0xFF8A776B),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Row(
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 15,
                          color: Colors.black45,
                        ),
                        SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Tap to edit details',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.black45,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (schedule.stockRemaining != null) ...[
                      const SizedBox(height: 5),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (schedule.isLowStock) ...[
                            const Icon(
                              Icons.warning_amber_rounded,
                              size: 16,
                              color: Color(0xFFFF9800),
                            ),
                            const SizedBox(width: 3),
                          ],
                          Text(
                            '${schedule.stockRemaining} left',
                            style: TextStyle(
                              color: schedule.isLowStock
                                  ? const Color(0xFFE87800)
                                  : Colors.black54,
                              fontSize: schedule.isLowStock ? 12 : 11,
                              fontWeight: schedule.isLowStock
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF1E5),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      schedule.hasAutomaticReminder
                          ? schedule.timesPerDay == 1
                                ? reminderTimes
                                : '${schedule.timesPerDay}× daily'
                          : 'No alarm',
                      style: const TextStyle(
                        color: Color(0xFFFF7518),
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  IconButton(
                    tooltip: 'Edit ${schedule.name}',
                    visualDensity: VisualDensity.compact,
                    onPressed: onEdit,
                    icon: const Icon(
                      Icons.edit_rounded,
                      color: Color(0xFFFF7518),
                    ),
                  ),
                  IconButton(
                    key: Key('delete-medication-${schedule.id}'),
                    tooltip: 'Delete ${schedule.name}',
                    visualDensity: VisualDensity.compact,
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MedicinePhotoPicker extends StatelessWidget {
  const _MedicinePhotoPicker({
    required this.image,
    required this.existingMedication,
    required this.hasExistingImage,
    required this.onCamera,
    required this.onGallery,
    required this.onRemove,
  });

  final XFile? image;
  final MedicationSchedule? existingMedication;
  final bool hasExistingImage;
  final VoidCallback? onCamera;
  final VoidCallback? onGallery;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final selected = image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFAF5),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: const Color(0xFFFFCBA7),
              style: BorderStyle.solid,
            ),
          ),
          child: selected != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(selected.path),
                    width: double.infinity,
                    height: 178,
                    fit: BoxFit.cover,
                  ),
                )
              : hasExistingImage && existingMedication != null
              ? Column(
                  children: [
                    MedicationVisual(
                      medication: existingMedication!,
                      size: 112,
                    ),
                    const SizedBox(height: 8),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 15,
                          color: Colors.green,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Private medicine photo',
                          style: TextStyle(
                            color: Colors.green,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                )
              : const SizedBox(
                  height: 104,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 38,
                          color: Color(0xFFFF9B55),
                        ),
                        SizedBox(height: 7),
                        Text(
                          'No medicine photo added',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          'A medicine-type image will be used.',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('take-medication-photo'),
                onPressed: onCamera,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Take Photo'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('choose-medication-photo'),
                onPressed: onGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Gallery'),
              ),
            ),
          ],
        ),
        if (onRemove != null) ...[
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Use category image instead'),
            ),
          ),
        ],
      ],
    );
  }
}

class _DateSelectionTile extends StatelessWidget {
  const _DateSelectionTile({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 66),
        padding: const EdgeInsets.fromLTRB(12, 9, 7, 9),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFCF8),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFFFD4B5)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.calendar_month_outlined,
              color: Color(0xFFFF7518),
              size: 21,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: const TextStyle(color: Colors.black54, fontSize: 11),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeekdaySelector extends StatelessWidget {
  const _WeekdaySelector({
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final Set<int> selected;
  final bool enabled;
  final void Function(int weekday, bool selected) onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Choose days',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 7),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var index = 0; index < labels.length; index++)
              FilterChip(
                key: Key('medication-weekday-${index + 1}'),
                label: Text(labels[index]),
                selected: selected.contains(index + 1),
                onSelected: enabled
                    ? (value) => onChanged(index + 1, value)
                    : null,
                selectedColor: const Color(0xFFFFD3B2),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
          ],
        ),
      ],
    );
  }
}

class _IntervalDayStepper extends StatelessWidget {
  const _IntervalDayStepper({
    required this.days,
    required this.enabled,
    required this.onDecrease,
    required this.onIncrease,
  });

  final int days;
  final bool enabled;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFCF8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD4B5)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Repeat interval',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton.filledTonal(
            onPressed: enabled ? onDecrease : null,
            icon: const Icon(Icons.remove_rounded),
          ),
          SizedBox(
            width: 74,
            child: Text(
              '$days days',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFF7518),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          IconButton.filled(
            onPressed: enabled ? onIncrease : null,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFFF7518),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({
    required this.quantity,
    required this.unit,
    required this.enabled,
    required this.onDecrease,
    required this.onIncrease,
  });

  final int quantity;
  final String unit;
  final bool enabled;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    final label = '$quantity $unit${quantity == 1 ? '' : 's'}';
    return Container(
      key: const Key('medication-quantity-stepper'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFCF8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD4B5)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Quantity per reminder',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                SizedBox(height: 2),
                Text(
                  'Use the supplied instruction',
                  style: TextStyle(fontSize: 11, color: Colors.black45),
                ),
              ],
            ),
          ),
          IconButton.filledTonal(
            key: const Key('decrease-medication-quantity'),
            tooltip: 'Decrease quantity',
            onPressed: enabled ? onDecrease : null,
            icon: const Icon(Icons.remove_rounded),
          ),
          SizedBox(
            width: 82,
            child: Text(
              label,
              key: const Key('medication-quantity-label'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFFF7518),
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          IconButton.filled(
            key: const Key('increase-medication-quantity'),
            tooltip: 'Increase quantity',
            onPressed: enabled ? onIncrease : null,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFFF7518),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

class _FormSection extends StatelessWidget {
  const _FormSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFD9BE)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF0E4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFFFF7518), size: 21),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _LowStockBanner extends StatelessWidget {
  const _LowStockBanner({required this.medicines, required this.onTap});

  final List<MedicationSchedule> medicines;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final count = medicines.length;
    final names = medicines.map((medicine) => medicine.name).join(', ');
    return Material(
      color: const Color(0xFFFFF3D6),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const Key('caregiver-low-stock-banner'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFFC86B)),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF9800)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$count ${count == 1 ? 'medicine is' : 'medicines are'} running low',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$names • Tap to view',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFFFF7518)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScheduleMessage extends StatelessWidget {
  const _ScheduleMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8DED6)),
      ),
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFFFF7518), size: 44),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
