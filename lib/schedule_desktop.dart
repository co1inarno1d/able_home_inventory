import 'dart:async';

import 'package:flutter/material.dart';

import 'initials_avatar.dart';
import 'qbt_api.dart';
import 'supabase_api.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Public constants (shared with main.dart via import)
// ─────────────────────────────────────────────────────────────────────────────

const Color kDesktopBrandGreen     = Color(0xFF2F7D46);
const Color kDesktopBrandGreenDark = Color(0xFF1A4728);

// ─────────────────────────────────────────────────────────────────────────────
// ScheduleDesktopView
// ─────────────────────────────────────────────────────────────────────────────

class ScheduleDesktopView extends StatefulWidget {
  final List<QbtScheduleEvent> events;
  final Map<String, QbtUser> users;
  final Set<String> completedIds;
  final bool isLoading;
  final String? error;
  final Future<void> Function(QbtScheduleEvent) onToggleComplete;
  final Future<void> Function() onRefresh;
  /// Called when the user taps an event chip/card. The parent handles routing.
  final Future<bool?> Function(QbtScheduleEvent) onTapEvent;
  final VoidCallback onAddEvent;
  /// Earliest date currently loaded in [events].
  final DateTime activeStart;
  /// Latest date currently loaded in [events].
  final DateTime activeEnd;

  const ScheduleDesktopView({
    super.key,
    required this.events,
    required this.users,
    required this.completedIds,
    required this.isLoading,
    required this.error,
    required this.onToggleComplete,
    required this.onRefresh,
    required this.onTapEvent,
    required this.onAddEvent,
    required this.activeStart,
    required this.activeEnd,
  });

  @override
  State<ScheduleDesktopView> createState() => _ScheduleDesktopViewState();
}

class _ScheduleDesktopViewState extends State<ScheduleDesktopView> {
  /// Always a Monday.
  late DateTime _weekStart;

  // Search
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  bool _isSearchMode = false;
  bool _isSearchLoading = false;
  List<QbtScheduleEvent> _searchResults = [];
  String _sortBy = 'oldest';
  Timer? _searchDebounce;
  static const _kDebounce = Duration(milliseconds: 400);

  static const double _kLeftColW  = 170.0;
  static const double _kRowMinH   = 72.0;

  static const Map<String, int> _monthMap = {
    'jan': 1, 'january': 1,   'feb': 2, 'february': 2,
    'mar': 3, 'march': 3,     'apr': 4, 'april': 4,
    'may': 5,                 'jun': 6, 'june': 6,
    'jul': 7, 'july': 7,      'aug': 8, 'august': 8,
    'sep': 9, 'sept': 9, 'september': 9,
    'oct': 10, 'october': 10, 'nov': 11, 'november': 11,
    'dec': 12, 'december': 12,
  };

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _weekStart = _mondayOf(DateTime.now());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  // ── Date helpers ──────────────────────────────────────────────────────────

  DateTime _mondayOf(DateTime d) =>
      DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

  List<DateTime> get _weekDays =>
      List.generate(7, (i) => _weekStart.add(Duration(days: i)));

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isToday(DateTime d) => _isSameDay(d, DateTime.now());

  String _formatWeekLabel() {
    final end = _weekStart.add(const Duration(days: 6));
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    if (_weekStart.month == end.month && _weekStart.year == end.year) {
      return '${months[_weekStart.month - 1]} ${_weekStart.day} – ${end.day}, ${end.year}';
    }
    if (_weekStart.year == end.year) {
      return '${months[_weekStart.month - 1]} ${_weekStart.day} – '
             '${months[end.month - 1]} ${end.day}, ${end.year}';
    }
    return '${months[_weekStart.month - 1]} ${_weekStart.day}, ${_weekStart.year} – '
           '${months[end.month - 1]} ${end.day}, ${end.year}';
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final m = local.minute;
    final ampm = local.hour < 12 ? 'a' : 'p';
    return m == 0 ? '$h$ampm' : '${h}:${m.toString().padLeft(2, '0')}$ampm';
  }

  Color _parseColor(String hex) {
    try {
      return Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
    } catch (_) {
      return kDesktopBrandGreen;
    }
  }

  // ── Week navigation ───────────────────────────────────────────────────────

  void _prevWeek() =>
      setState(() => _weekStart = _weekStart.subtract(const Duration(days: 7)));

  void _nextWeek() =>
      setState(() => _weekStart = _weekStart.add(const Duration(days: 7)));

  void _goToToday() =>
      setState(() => _weekStart = _mondayOf(DateTime.now()));

  // ── Search ────────────────────────────────────────────────────────────────

  void _onSearchChanged(String v) {
    setState(() => _searchQuery = v);
    _searchDebounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _isSearchMode = false;
        _isSearchLoading = false;
        _searchResults = [];
      });
      return;
    }
    setState(() => _isSearchLoading = true);
    _searchDebounce = Timer(_kDebounce, _performSearch);
  }

  Future<void> _performSearch() async {
    final query = _searchQuery.trim();
    if (query.isEmpty) return;

    final parsed = _parseDateRange(query);
    final dateRange = parsed.$1;
    final textQuery = parsed.$2;

    try {
      final historyResults = await sbSearchScheduleHistory(
        query: textQuery,
        startDate: dateRange?.$1,
        endDate: dateRange?.$2,
        newestFirst: _sortBy == 'newest',
      );
      final liveFiltered = _filterLiveForSearch(textQuery, dateRange);

      final seen = <String>{};
      final merged = <QbtScheduleEvent>[];
      for (final e in [...liveFiltered, ...historyResults]) {
        if (seen.add(e.id)) merged.add(e);
      }
      merged.sort((a, b) => _sortBy == 'newest'
          ? b.start.compareTo(a.start)
          : a.start.compareTo(b.start));

      if (!mounted) return;
      setState(() {
        _searchResults = merged;
        _isSearchMode = true;
        _isSearchLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSearchLoading = false);
    }
  }

  List<QbtScheduleEvent> _filterLiveForSearch(
      String textQuery, (DateTime, DateTime)? dateRange) {
    return widget.events.where((e) {
      if (dateRange != null) {
        final local = e.start.toLocal();
        if (local.isBefore(dateRange.$1) || local.isAfter(dateRange.$2)) return false;
      }
      if (textQuery.isEmpty) return true;
      final terms = textQuery
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((t) => t.length >= 2);
      for (final term in terms) {
        final inTitle    = e.title.toLowerCase().contains(term);
        final inNotes    = e.notes.toLowerCase().contains(term);
        final inLocation = e.location.toLowerCase().contains(term);
        final inNames    = e.assignedUserIds.any(
            (id) => (widget.users[id]?.displayName ?? '').toLowerCase().contains(term));
        if (!inTitle && !inNotes && !inLocation && !inNames) return false;
      }
      return true;
    }).toList();
  }

  ((DateTime, DateTime)?, String) _parseDateRange(String query) {
    var q = query.toLowerCase().trim();

    String strip(String src, Pattern pat) =>
        src.replaceAll(pat, ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    (DateTime, DateTime) dayRange(int y, int mo, int d) =>
        (DateTime(y, mo, d), DateTime(y, mo, d, 23, 59, 59));

    final slash = RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b');
    var m = slash.firstMatch(q);
    if (m != null) {
      var y = int.parse(m.group(3)!);
      if (y < 100) y += 2000;
      return (dayRange(y, int.parse(m.group(1)!), int.parse(m.group(2)!)), strip(q, slash));
    }

    for (final entry in _monthMap.entries) {
      final mn = entry.key;
      final mo = entry.value;

      final pat1 = RegExp(r'\b' + mn + r'\s+(\d{1,2})\s+(20\d{2})\b');
      m = pat1.firstMatch(q);
      if (m != null) {
        return (dayRange(int.parse(m.group(2)!), mo, int.parse(m.group(1)!)), strip(q, pat1));
      }

      final pat2 = RegExp(r'\b(\d{1,2})\s+' + mn + r'\s+(20\d{2})\b');
      m = pat2.firstMatch(q);
      if (m != null) {
        return (dayRange(int.parse(m.group(2)!), mo, int.parse(m.group(1)!)), strip(q, pat2));
      }

      final pat3 = RegExp(r'\b' + mn + r'\s+(20\d{2})\b');
      m = pat3.firstMatch(q);
      if (m != null) {
        final y = int.parse(m.group(1)!);
        final lastDay = DateTime(y, mo + 1, 0).day;
        return (
          (DateTime(y, mo, 1), DateTime(y, mo, lastDay, 23, 59, 59)),
          strip(q, pat3),
        );
      }
    }

    final yearPat = RegExp(r'\b(20\d{2})\b');
    m = yearPat.firstMatch(q);
    if (m != null) {
      final y = int.parse(m.group(1)!);
      return ((DateTime(y, 1, 1), DateTime(y, 12, 31, 23, 59, 59)), strip(q, yearPat));
    }

    return (null, q);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(widget.error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: widget.onRefresh, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildNavBar(),
        if (_isSearchLoading)
          const LinearProgressIndicator(color: kDesktopBrandGreen),
        if (!_isSearchMode) _buildDayHeaders(),
        Expanded(
          child: _isSearchMode ? _buildSearchResults() : _buildGrid(),
        ),
      ],
    );
  }

  // ── Nav bar ───────────────────────────────────────────────────────────────

  Widget _buildNavBar() {
    return Container(
      color: kDesktopBrandGreenDark,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          // Today button
          OutlinedButton(
            onPressed: _isSearchMode ? null : _goToToday,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white38,
              side: BorderSide(
                  color: _isSearchMode ? Colors.white24 : Colors.white54),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Today', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 4),
          // Prev / next
          _navArrow(Icons.chevron_left, _isSearchMode ? null : _prevWeek, 'Previous week'),
          _navArrow(Icons.chevron_right, _isSearchMode ? null : _nextWeek, 'Next week'),
          const SizedBox(width: 6),
          // Week label
          AnimatedOpacity(
            opacity: _isSearchMode ? 0.35 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: Text(
              _formatWeekLabel(),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const Spacer(),
          // Search field
          SizedBox(width: 320, child: _buildSearchField()),
          const SizedBox(width: 8),
          // Refresh
          _iconBtn(Icons.refresh, widget.onRefresh, 'Refresh'),
          // Add event
          _iconBtn(Icons.add_circle_outline, widget.onAddEvent, 'Add event'),
        ],
      ),
    );
  }

  Widget _navArrow(IconData icon, VoidCallback? onTap, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon,
              color: onTap != null ? Colors.white : Colors.white30, size: 22),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback? onTap, String tooltip) {
    return IconButton(
      icon: Icon(icon, color: Colors.white, size: 22),
      onPressed: onTap,
      tooltip: tooltip,
      splashRadius: 18,
    );
  }

  Widget _buildSearchField() {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(35),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: _isSearchMode ? Colors.white54 : Colors.transparent,
          width: 1,
        ),
      ),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        cursorColor: Colors.white,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, color: Colors.white60, size: 17),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, color: Colors.white60, size: 15),
                  onPressed: () {
                    _searchCtrl.clear();
                    _onSearchChanged('');
                  },
                  splashRadius: 14,
                )
              : null,
          hintText: 'Search all schedule history...',
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 9),
        ),
        onChanged: _onSearchChanged,
      ),
    );
  }

  // ── Day header row ────────────────────────────────────────────────────────

  Widget _buildDayHeaders() {
    const dayAbbr = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    final days = _weekDays;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(12),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Left column header
          Container(
            width: _kLeftColW,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: Colors.grey.shade300)),
            ),
            child: Text(
              'TEAM MEMBER',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade500,
                letterSpacing: 0.6,
              ),
            ),
          ),
          // Day columns
          for (int i = 0; i < 7; i++)
            Expanded(child: _buildDayHeaderCell(days[i], dayAbbr[i])),
        ],
      ),
    );
  }

  Widget _buildDayHeaderCell(DateTime day, String abbr) {
    final today = _isToday(day);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: today ? const Color(0xFFFFF8E1) : null,
        border: Border(left: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            abbr,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: today ? kDesktopBrandGreen : Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            day.day.toString(),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: today ? kDesktopBrandGreen : Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  // ── Grid ──────────────────────────────────────────────────────────────────

  Widget _buildGrid() {
    // Collect all user IDs that appear in any loaded event
    final activeIds = <String>{};
    for (final e in widget.events) {
      activeIds.addAll(e.assignedUserIds);
    }

    // Show all known users alphabetically, filtering to those with data
    final members = widget.users.values
        .where((u) => activeIds.contains(u.id))
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    if (members.isEmpty) {
      return const Center(
          child: Text('No events scheduled', style: TextStyle(color: Colors.grey)));
    }

    // Is the current week outside the loaded active range?
    final weekEnd = _weekStart.add(const Duration(days: 6, hours: 23, minutes: 59));
    final outOfRange = weekEnd.isBefore(widget.activeStart) ||
        _weekStart.isAfter(widget.activeEnd);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (outOfRange) _buildOutOfRangeBanner(),
          ...members.map((m) => _buildMemberRow(m, outOfRange)),
        ],
      ),
    );
  }

  Widget _buildOutOfRangeBanner() {
    return Container(
      color: const Color(0xFFFFF8E1),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        children: [
          Icon(Icons.history, size: 15, color: Colors.amber.shade700),
          const SizedBox(width: 8),
          Text(
            'This week is outside your 90-day active window — use search to find events.',
            style: TextStyle(fontSize: 12, color: Colors.amber.shade800),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberRow(QbtUser member, bool outOfRange) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left: member info
          Container(
            width: _kLeftColW,
            constraints: const BoxConstraints(minHeight: _kRowMinH),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F6F6),
              border: Border(
                right: BorderSide(color: Colors.grey.shade300),
                bottom: BorderSide(color: Colors.grey.shade200),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                InitialsAvatar(name: member.displayName, size: 34),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    member.displayName,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          // Day cells (Mon – Sun)
          ...(_weekDays.map(
            (day) => Expanded(
              child: _buildDayCell(day, member, outOfRange),
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildDayCell(DateTime day, QbtUser member, bool outOfRange) {
    final today = _isToday(day);

    final cellEvents = outOfRange
        ? <QbtScheduleEvent>[]
        : widget.events.where((e) {
            if (!e.assignedUserIds.contains(member.id)) return false;
            return _isSameDay(e.start.toLocal(), day);
          }).toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    return Container(
      constraints: const BoxConstraints(minHeight: _kRowMinH),
      decoration: BoxDecoration(
        color: today ? const Color(0xFFFFFDF0) : Colors.white,
        border: Border(
          left: BorderSide(color: Colors.grey.shade200),
          bottom: BorderSide(color: Colors.grey.shade200),
        ),
      ),
      child: cellEvents.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.all(3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: cellEvents.map(_buildEventChip).toList(),
              ),
            ),
    );
  }

  Widget _buildEventChip(QbtScheduleEvent event) {
    final color = _parseColor(event.color);
    final completed = widget.completedIds.contains(event.id);
    final chipColor = completed ? Color.lerp(color, Colors.white, 0.45)! : color;

    final sl = event.start.toLocal();
    final el = event.end.toLocal();
    final timeLabel = event.allDay
        ? 'All day'
        : sl == el
            ? _formatTime(sl)
            : '${_formatTime(sl)}–${_formatTime(el)}';

    return _DesktopEventChip(
      event: event,
      chipColor: chipColor,
      timeLabel: timeLabel,
      completed: completed,
      onTap: () => widget.onTapEvent(event),
      onToggleComplete: () => widget.onToggleComplete(event),
    );
  }

  // ── Search results ────────────────────────────────────────────────────────

  Widget _buildSearchResults() {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const dayNames = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

    return Column(
      children: [
        // Results toolbar
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Text(
                '${_searchResults.length} result${_searchResults.length == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const Spacer(),
              DropdownButton<String>(
                value: _sortBy,
                underline: const SizedBox(),
                style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
                items: const [
                  DropdownMenuItem(value: 'newest', child: Text('Newest first')),
                  DropdownMenuItem(value: 'oldest', child: Text('Oldest first')),
                ],
                onChanged: (v) {
                  if (v != null && v != _sortBy) {
                    setState(() => _sortBy = v);
                    _performSearch();
                  }
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: _searchResults.isEmpty
              ? Center(
                  child: Text(
                    _isSearchLoading ? 'Searching...' : 'No results found',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                  itemCount: _searchResults.length,
                  itemBuilder: (context, i) {
                    final event = _searchResults[i];
                    final local = event.start.toLocal();
                    final dateLabel =
                        '${dayNames[local.weekday - 1]}, '
                        '${months[local.month - 1]} ${local.day}, ${local.year}';
                    final names = event.assignedUserIds
                        .map((id) => widget.users[id]?.displayName ?? '')
                        .where((n) => n.isNotEmpty)
                        .join(', ');
                    return _buildSearchCard(event, dateLabel, names);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSearchCard(
      QbtScheduleEvent event, String dateLabel, String names) {
    final color = _parseColor(event.color);
    final completed = widget.completedIds.contains(event.id);
    final cardColor = completed ? Color.lerp(color, Colors.white, 0.45)! : color;

    final sl = event.start.toLocal();
    final el = event.end.toLocal();
    final timeLabel = event.allDay
        ? 'All day'
        : sl == el
            ? _formatTimeExpanded(sl)
            : '${_formatTimeExpanded(sl)} – ${_formatTimeExpanded(el)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: InkWell(
        onTap: () => widget.onTapEvent(event),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title.isNotEmpty ? event.title : '(No title)',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        decoration: completed ? TextDecoration.lineThrough : null,
                        decorationColor: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$dateLabel  ·  $timeLabel',
                      style: TextStyle(
                          color: Colors.white.withAlpha(210), fontSize: 12),
                    ),
                    if (names.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        names,
                        style: TextStyle(
                            color: Colors.white.withAlpha(175), fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
              // Complete toggle (always visible on search cards)
              Tooltip(
                message: completed ? 'Mark incomplete' : 'Mark complete',
                child: InkWell(
                  onTap: () => widget.onToggleComplete(event),
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      completed ? Icons.check_circle : Icons.check_circle_outline,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Expanded time format: "8:00 AM" (for search result cards).
  String _formatTimeExpanded(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final m = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DesktopEventChip — compact coloured chip with hover-reveal complete button
// ─────────────────────────────────────────────────────────────────────────────

class _DesktopEventChip extends StatefulWidget {
  final QbtScheduleEvent event;
  final Color chipColor;
  final String timeLabel;
  final bool completed;
  final VoidCallback onTap;
  final VoidCallback onToggleComplete;

  const _DesktopEventChip({
    required this.event,
    required this.chipColor,
    required this.timeLabel,
    required this.completed,
    required this.onTap,
    required this.onToggleComplete,
  });

  @override
  State<_DesktopEventChip> createState() => _DesktopEventChipState();
}

class _DesktopEventChipState extends State<_DesktopEventChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(6, 3, 3, 3),
          decoration: BoxDecoration(
            color: widget.chipColor,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.timeLabel,
                      style: TextStyle(
                        color: Colors.white.withAlpha(210),
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      widget.event.title.isNotEmpty
                          ? widget.event.title
                          : '(No title)',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                        decoration: widget.completed
                            ? TextDecoration.lineThrough
                            : null,
                        decorationColor: Colors.white70,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Hover-reveal complete button
              AnimatedOpacity(
                opacity: _hovered ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: GestureDetector(
                  onTap: widget.onToggleComplete,
                  behavior: HitTestBehavior.opaque,
                  child: Tooltip(
                    message: widget.completed ? 'Mark incomplete' : 'Mark complete',
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(2, 1, 0, 0),
                      child: Icon(
                        widget.completed
                            ? Icons.check_circle
                            : Icons.check_circle_outline,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
