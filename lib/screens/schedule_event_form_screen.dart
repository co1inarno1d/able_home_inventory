// lib/screens/schedule_event_form_screen.dart
//
// Schedule event create/edit form. Extracted from main.dart so other screens
// (e.g. OperationsHubScreen) can navigate to it directly.

import 'package:flutter/material.dart';

import '../qbt_api.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';

class ScheduleEventFormScreen extends StatefulWidget {
  final Map<String, QbtUser> users;
  final QbtScheduleEvent? existingEvent;
  final DateTime initialDate;

  // Pre-fill values when creating from a queue job
  final String? prefillTitle;
  final String? prefillLocation;
  final String? prefillNotes;
  final String? prefillJobType;
  final List<String>? prefillLiftIds;
  final String? sourceJobId;
  final String? sourceJobTable; // 'service_jobs' or 'removal_jobs' or 'ops_jobs'
  final String? prefillFundingSource;

  const ScheduleEventFormScreen({
    super.key,
    required this.users,
    this.existingEvent,
    required this.initialDate,
    this.prefillTitle,
    this.prefillLocation,
    this.prefillNotes,
    this.prefillJobType,
    this.prefillLiftIds,
    this.sourceJobId,
    this.sourceJobTable,
    this.prefillFundingSource,
  });

  @override
  State<ScheduleEventFormScreen> createState() => _ScheduleEventFormScreenState();
}

class _ScheduleEventFormScreenState extends State<ScheduleEventFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _locationCtrl;

  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  bool _allDay = false;
  List<String> _selectedUserIds = [];
  late String _selectedColor;
  String? _jobType;
  String _fundingSource = 'Private';
  bool _saving = false;
  bool _deleting = false;

  static const _fundingSourceOptions = [
    'Private', 'VA', 'CCALS', 'NaviCare', 'Summit', 'Fallon', 'Mass Health', 'Other',
  ];

  static const _jobTypeOptions = [
    'Stairlift Install',
    'Stairlift Removal',
    'Stairlift Service',
    'Stairlift Annual Service',
    'Ramp Install',
    'Ramp Removal',
    'Reminder',
    'Other',
  ];

  static const _colorOptions = [
    '#2196F3', // blue
    '#EF6C00', // orange
    '#43A047', // green
    '#888888', // grey
    '#F44336', // red (Steve)
    '#8A2731', // dark red
    '#9C27B0', // purple
    '#827717', // olive/dark yellow
    '#F8C499', // peach
    '#010101', // black
  ];

  bool get _isEditing => widget.existingEvent != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existingEvent;
    _titleCtrl = TextEditingController(text: e?.title ?? widget.prefillTitle ?? '');
    _notesCtrl = TextEditingController(text: e?.notes ?? widget.prefillNotes ?? '');
    _locationCtrl = TextEditingController(text: e?.location ?? widget.prefillLocation ?? '');
    _allDay = e?.allDay ?? false;
    _selectedColor = e?.color ?? '#2196F3';
    _selectedUserIds = List.from(e?.assignedUserIds ?? []);

    if (e != null) {
      final startLocal = e.start.toLocal();
      final endLocal = e.end.toLocal();
      _date = DateTime(startLocal.year, startLocal.month, startLocal.day);
      _startTime = TimeOfDay.fromDateTime(startLocal);
      _endTime = TimeOfDay.fromDateTime(endLocal);
      // Load existing job type + funding source from Supabase metadata
      sbGetEventMeta(e.id).then((meta) {
        if (mounted) setState(() {
          _jobType = meta['job_type'] as String?;
          final fs = meta['funding_source'] as String?;
          if (fs != null && fs.isNotEmpty) _fundingSource = fs;
        });
      });
    } else {
      _date = widget.initialDate;
      _startTime = const TimeOfDay(hour: 8, minute: 0);
      _endTime = const TimeOfDay(hour: 10, minute: 0);
      if (widget.prefillJobType != null) { _jobType = widget.prefillJobType; }
      if (widget.prefillFundingSource != null && widget.prefillFundingSource!.isNotEmpty) {
        _fundingSource = widget.prefillFundingSource!;
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  DateTime _toDateTime(DateTime date, TimeOfDay time) =>
      DateTime(date.year, date.month, date.day, time.hour, time.minute);

  String _formatTimeOfDay(TimeOfDay t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    final ampm = t.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime({required bool isStart}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _startTime : _endTime,
      initialEntryMode: TimePickerEntryMode.input,
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
          // Auto-advance end time if it's now before start
          final startMin = picked.hour * 60 + picked.minute;
          final endMin = _endTime.hour * 60 + _endTime.minute;
          if (endMin <= startMin) {
            final newEnd = startMin + 60;
            _endTime = TimeOfDay(hour: newEnd ~/ 60 % 24, minute: newEnd % 60);
          }
        } else {
          _endTime = picked;
        }
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final start = _allDay
        ? DateTime(_date.year, _date.month, _date.day, 0, 0)
        : _toDateTime(_date, _startTime);
    final end = _allDay
        ? DateTime(_date.year, _date.month, _date.day, 23, 59)
        : _toDateTime(_date, _endTime);

    final event = QbtScheduleEvent(
      id: widget.existingEvent?.id ?? '',
      title: _titleCtrl.text.trim(),
      notes: _notesCtrl.text.trim(),
      start: start,
      end: end,
      allDay: _allDay,
      location: _locationCtrl.text.trim(),
      color: _selectedColor,
      assignedUserIds: _selectedUserIds,
      active: true,
    );

    try {
      QbtScheduleEvent saved;
      if (_isEditing) {
        saved = await qbtUpdateScheduleEvent(event);
      } else {
        saved = await qbtCreateScheduleEvent(event);
      }
      // Persist job type + funding source metadata (independent of QBT)
      await sbSetEventJobType(saved.id, _jobType);
      await sbSetEventFundingSource(saved.id, _fundingSource == 'Private' ? null : _fundingSource);

      // Link lift IDs and source job when scheduling from the queue
      final prefillLiftIds = widget.prefillLiftIds ?? [];
      if (prefillLiftIds.isNotEmpty) {
        await sbSetEventLiftIds(saved.id, prefillLiftIds);
      }
      final srcId = widget.sourceJobId;
      final srcTable = widget.sourceJobTable;
      if (srcId != null && srcId.isNotEmpty && srcTable != null) {
        await sbSetEventSource(saved.id, '$srcTable:$srcId');
        final scheduledDateStr =
            '${_date.month.toString().padLeft(2, '0')}/${_date.day.toString().padLeft(2, '0')}/${_date.year}';
        if (srcTable == 'service_jobs') {
          await sbUpdateServiceJobStatus(jobId: srcId, status: 'Scheduled', scheduledDate: scheduledDateStr);
        } else if (srcTable == 'removal_jobs') {
          await sbUpdateRemovalJobStatus(jobId: srcId, status: 'Scheduled', scheduledDate: scheduledDateStr);
        }
        // ops_jobs: status was already updated to 'scheduled' before opening this form
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Event'),
        content: const Text('Are you sure you want to delete this event?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    try {
      await qbtDeleteScheduleEvent(widget.existingEvent!.id);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sortedUsers = widget.users.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text(_isEditing ? 'Edit Event' : 'New Event'),
        actions: [
          if (_isEditing)
            IconButton(
              icon: _deleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _deleting ? null : _delete,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Title
            TextFormField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Title *',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Title is required' : null,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),

            // Job type
            DropdownButtonFormField<String>(
              initialValue: _jobType,
              decoration: const InputDecoration(
                labelText: 'Job Type',
                border: OutlineInputBorder(),
              ),
              hint: const Text('Select job type (optional)'),
              items: [
                const DropdownMenuItem<String>(value: null, child: Text('— None —')),
                ..._jobTypeOptions.map((t) => DropdownMenuItem(value: t, child: Text(t))),
              ],
              onChanged: (v) => setState(() => _jobType = v),
            ),
            const SizedBox(height: 16),

            // Funding source
            DropdownButtonFormField<String>(
              value: _fundingSource,
              decoration: const InputDecoration(
                labelText: 'Funding Source',
                border: OutlineInputBorder(),
              ),
              items: _fundingSourceOptions
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _fundingSource = v ?? 'Private'),
            ),
            const SizedBox(height: 16),

            // Date
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today, color: kBrandGreen),
              title: const Text('Date'),
              subtitle: Text('${_date.month}/${_date.day}/${_date.year}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickDate,
            ),
            const Divider(height: 1),

            // All day toggle
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('All Day'),
              value: _allDay,
              activeThumbColor: kBrandGreen,
              onChanged: (v) => setState(() => _allDay = v),
            ),
            const Divider(height: 1),

            // Start / end time (hidden when all day)
            if (!_allDay) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.access_time, color: kBrandGreen),
                title: const Text('Start time'),
                subtitle: Text(_formatTimeOfDay(_startTime)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickTime(isStart: true),
              ),
              const Divider(height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.access_time_filled, color: kBrandGreen),
                title: const Text('End time'),
                subtitle: Text(_formatTimeOfDay(_endTime)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _pickTime(isStart: false),
              ),
              const Divider(height: 1),
            ],

            const SizedBox(height: 16),

            // Location
            TextFormField(
              controller: _locationCtrl,
              decoration: const InputDecoration(
                labelText: 'Location / Address',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.location_on_outlined),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),

            // Notes
            TextFormField(
              controller: _notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),

            // Assign to
            const Text('Assign to',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: sortedUsers.map((user) {
                final selected = _selectedUserIds.contains(user.id);
                return FilterChip(
                  label: Text(user.displayName),
                  selected: selected,
                  selectedColor: kBrandGreen.withAlpha(40),
                  checkmarkColor: kBrandGreen,
                  onSelected: (v) {
                    setState(() {
                      if (v) {
                        _selectedUserIds.add(user.id);
                      } else {
                        _selectedUserIds.remove(user.id);
                      }
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // Color
            const Text('Color',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              children: _colorOptions.map((hex) {
                final c = Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
                final selected = _selectedColor == hex;
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = hex),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: selected
                          ? Border.all(color: Colors.black, width: 2.5)
                          : null,
                    ),
                    child: selected
                        ? Icon(
                            Icons.check,
                            color: c.computeLuminance() > 0.35
                                ? Colors.black87
                                : Colors.white,
                            size: 18,
                          )
                        : null,
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 24),

            // Save button
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving...' : 'Save Event'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: kBrandGreen,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
