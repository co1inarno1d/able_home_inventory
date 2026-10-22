// lib/screens/operations_hub_screen.dart
//
// Operations Hub — a tabular view of the SCHEDULE.
//
// This is the key property: the hub and the schedule are the same system with
// two presentations. Every event on the schedule appears in exactly one hub
// bucket, and every hub row is a schedule event. Nothing exists in one and not
// the other, and tapping a row opens the same detail screen the schedule does,
// so there is no second place where a job's state can be edited.
//
// It previously read four legacy job tables (ops_jobs, service_jobs,
// removal_jobs, annuals) and never looked at the schedule at all, which made
// it a parallel system that drifted. Those tables are now empty and no longer
// read from here.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../hub_jobs.dart';
import '../models/models.dart';
import '../qbt_api.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';
import 'email_review_screen.dart';

// ---------------------------------------------------------------------------
// TABS
// ---------------------------------------------------------------------------

/// A hub tab: a label plus the buckets it shows.
typedef _HubTab = ({String label, List<HubBucket> buckets});

const List<_HubTab> _kHubTabs = [
  (label: 'Installs', buckets: [
    HubBucket.straightInstall,
    HubBucket.curveInstall,
    HubBucket.rampInstall,
  ]),
  (label: 'Removals', buckets: [
    HubBucket.straightRemoval,
    HubBucket.curveRemoval,
    HubBucket.rampRemoval,
  ]),
  (label: 'Service', buckets: [
    HubBucket.service,
    HubBucket.annualService,
  ]),
  (label: 'Leads', buckets: [HubBucket.lead]),
  (label: 'To Schedule', buckets: [HubBucket.needsScheduling]),
  (label: 'Reminders', buckets: [HubBucket.reminder, HubBucket.other]),
];

/// Named tab indices, so callers navigating to a specific tab don't hardcode
/// numbers that silently point somewhere else when the tabs change.
class HubTabs {
  const HubTabs._();
  static const int installs = 0;
  static const int removals = 1;
  static const int service = 2;
  static const int leads = 3;
  static const int toSchedule = 4;
  static const int reminders = 5;
}

// ---------------------------------------------------------------------------
// SCREEN
// ---------------------------------------------------------------------------

class OperationsHubScreen extends StatefulWidget {
  /// Opens the hub on this tab index.
  final int initialTabIndex;

  /// The schedule's already-loaded events. The hub is a view of the same data,
  /// so it does not fetch TSheets again when the schedule has already done so.
  final List<QbtScheduleEvent>? events;
  final Map<String, QbtUser>? users;

  /// Opens an event's detail screen — supplied by the schedule so both views
  /// route to the same place. Returns true when something changed.
  final Future<bool?> Function(QbtScheduleEvent)? onOpenEvent;

  const OperationsHubScreen({
    super.key,
    this.initialTabIndex = 0,
    this.events,
    this.users,
    this.onOpenEvent,
  });

  @override
  State<OperationsHubScreen> createState() => _OperationsHubScreenState();
}

class _OperationsHubScreenState extends State<OperationsHubScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<HubJob> _jobs = [];
  List<WebLeadRecord> _leads = [];
  bool _loading = true;
  String? _error;
  bool _showCompleted = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _kHubTabs.length,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, _kHubTabs.length - 1),
    );
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Reuse the schedule's events when it handed them over; otherwise load
      // the same window the schedule uses so both views agree.
      var events = widget.events;
      var users = widget.users;
      if (events == null || users == null) {
        final now = DateTime.now();
        final results = await Future.wait([
          qbtFetchScheduleEvents(
            start: now.subtract(const Duration(days: 30)),
            end: now.add(const Duration(days: 60)),
          ),
          qbtFetchUsers(),
        ]);
        events = results[0] as List<QbtScheduleEvent>;
        users = results[1] as Map<String, QbtUser>;
      }

      final jobs = await buildHubJobs(
        events: events,
        users: users,
        includeCompleted: _showCompleted,
      );

      // Web leads have no schedule event yet — they arrive from the website
      // and are the one thing that legitimately precedes a calendar entry.
      // They were previously never shown anywhere: the Leads tab filtered an
      // ops_jobs type that nothing ever created.
      List<WebLeadRecord> leads = [];
      try {
        leads = await sbFetchWebLeads();
      } catch (_) {
        // A lead-fetch failure must not take down the whole hub.
      }

      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _leads = leads;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  List<HubJob> _jobsFor(List<HubBucket> buckets) {
    var list = _jobs.where((j) => buckets.contains(j.bucket)).toList();
    final q = _search.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((j) {
        return j.displayName.toLowerCase().contains(q) ||
            j.location.toLowerCase().contains(q) ||
            j.notes.toLowerCase().contains(q) ||
            j.assignedNames.toLowerCase().contains(q) ||
            j.fundingSource.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  List<WebLeadRecord> get _filteredLeads {
    final q = _search.trim().toLowerCase();
    var list = _showCompleted
        ? _leads
        : _leads.where((l) => l.status.toLowerCase() != 'closed').toList();
    if (q.isNotEmpty) {
      list = list.where((l) {
        return l.name.toLowerCase().contains(q) ||
            l.email.toLowerCase().contains(q) ||
            l.phone.toLowerCase().contains(q) ||
            l.message.toLowerCase().contains(q);
      }).toList();
    }
    return list;
  }

  /// Count shown on a tab label — open work only, so the number means
  /// "things needing attention" rather than "rows".
  int _countFor(_HubTab tab) {
    if (tab.buckets.contains(HubBucket.lead)) return _filteredLeads.length;
    return _jobsFor(tab.buckets).where((j) => !j.completed).length;
  }

  Future<void> _openEvent(HubJob job) async {
    final handler = widget.onOpenEvent;
    if (handler == null) return;
    final changed = await handler(job.event);
    if (changed == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Operations Hub',
            style: GoogleFonts.nunito(
                fontSize: 20, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.mark_email_unread_outlined),
            tooltip: 'Email review queue',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EmailReviewScreen()),
            ),
          ),
          IconButton(
            icon: Icon(_showCompleted
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined),
            tooltip: _showCompleted
                ? 'Hide completed'
                : 'Show completed (last 7 days)',
            onPressed: () {
              setState(() => _showCompleted = !_showCompleted);
              _load();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(92),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  cursorColor: Colors.white,
                  decoration: InputDecoration(
                    // filled:false matters — the global inputDecorationTheme
                    // fills white, which on this dark bar would hide the text.
                    filled: false,
                    isDense: true,
                    hintText: 'Search name, address, notes, tech...',
                    hintStyle:
                        TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                    prefixIcon: const Icon(Icons.search,
                        color: Colors.white70, size: 20),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.35)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.35)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: Colors.white),
                    ),
                  ),
                ),
              ),
              TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: Colors.white,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                labelStyle: GoogleFonts.nunito(
                    fontSize: 13, fontWeight: FontWeight.w700),
                tabs: _kHubTabs.map((t) {
                  final n = _loading ? null : _countFor(t);
                  return Tab(text: n == null || n == 0
                      ? t.label
                      : '${t.label} ($n)');
                }).toList(),
              ),
            ],
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : TabBarView(
                  controller: _tabController,
                  children: _kHubTabs.map((tab) {
                    if (tab.buckets.contains(HubBucket.lead)) {
                      return _LeadList(
                        leads: _filteredLeads,
                        onRefresh: _load,
                      );
                    }
                    return _HubJobList(
                      jobs: _jobsFor(tab.buckets),
                      allJobs: _jobs,
                      showBucketLabel: tab.buckets.length > 1,
                      onRefresh: _load,
                      onOpen: _openEvent,
                    );
                  }).toList(),
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// JOB LIST
// ---------------------------------------------------------------------------

class _HubJobList extends StatelessWidget {
  final List<HubJob> jobs;
  final List<HubJob> allJobs;
  final bool showBucketLabel;
  final Future<void> Function() onRefresh;
  final Future<void> Function(HubJob) onOpen;

  const _HubJobList({
    required this.jobs,
    required this.allJobs,
    required this.showBucketLabel,
    required this.onRefresh,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    // Proximity hint: how much other open work sits in the same town, so jobs
    // can be grouped into one trip.
    final cityCounts = <String, int>{};
    for (final j in allJobs) {
      if (j.completed) continue;
      final city = extractCity(j.location);
      if (city.isEmpty) continue;
      cityCounts[city] = (cityCounts[city] ?? 0) + 1;
    }

    if (jobs.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            Icon(Icons.check_circle_outline,
                size: 46, color: Colors.green[300]),
            const SizedBox(height: 12),
            Center(
              child: Text('All clear — nothing pending here.',
                  style: GoogleFonts.nunito(
                      fontSize: 14, color: Colors.grey[600])),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
        itemCount: jobs.length,
        itemBuilder: (context, i) {
          final job = jobs[i];
          final city = extractCity(job.location);
          final others = (cityCounts[city] ?? 0) - (job.completed ? 0 : 1);
          return _HubJobCard(
            job: job,
            otherJobsInCity: others > 0 ? others : 0,
            showBucketLabel: showBucketLabel,
            onTap: () => onOpen(job),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// JOB CARD
// ---------------------------------------------------------------------------

class _HubJobCard extends StatelessWidget {
  final HubJob job;
  final int otherJobsInCity;
  final bool showBucketLabel;
  final VoidCallback onTap;

  const _HubJobCard({
    required this.job,
    required this.otherJobsInCity,
    required this.showBucketLabel,
    required this.onTap,
  });

  /// Days until (negative) or since (positive) the job's date.
  int get _daysOverdue => DateTime.now().difference(job.date).inDays;

  /// Border tint. Only open work ages: a completed job is not a problem, and a
  /// future job is not late yet.
  Color? get _agingColor {
    if (job.completed) return null;
    if (_daysOverdue >= 7) return Colors.red[600];
    if (_daysOverdue >= 1) return Colors.orange[700];
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final aging = _agingColor;
    final city = extractCity(job.location);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: aging != null
              ? aging.withValues(alpha: 0.4)
              : Colors.grey.withValues(alpha: 0.15),
          width: aging != null ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Opacity(
          opacity: job.completed ? 0.55 : 1,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Row 1 — what kind of job, its state, and when
                Row(
                  children: [
                    if (showBucketLabel) ...[
                      _BucketChip(bucket: job.bucket),
                      const SizedBox(width: 6),
                    ],
                    if (job.completed)
                      const _MiniChip(
                          label: 'Done',
                          color: Colors.green,
                          icon: Icons.check_rounded)
                    else if (aging != null)
                      _MiniChip(
                        label: _daysOverdue >= 7
                            ? '${_daysOverdue}d overdue'
                            : 'overdue',
                        color: aging,
                        icon: Icons.schedule_rounded,
                      ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        formatDate(job.date),
                        style: GoogleFonts.nunito(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey[700]),
                      ),
                    ),
                    if (job.isAgencyFunded) ...[
                      const SizedBox(width: 6),
                      _FundingBadge(source: job.fundingSource),
                    ],
                  ],
                ),
                const SizedBox(height: 10),

                // Row 2 — who and where
                Text(
                  job.displayName.isNotEmpty
                      ? job.displayName
                      : 'Untitled job',
                  style: GoogleFonts.nunito(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.black87,
                  ),
                ),
                if (city.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Colors.blue.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_on_rounded,
                            size: 13, color: Colors.blue[700]),
                        const SizedBox(width: 4),
                        Text(city,
                            style: GoogleFonts.nunito(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.blue[800])),
                      ],
                    ),
                  ),
                ],
                if (job.location.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      job.location,
                      style: GoogleFonts.nunito(
                          fontSize: 11, color: Colors.grey[600]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (job.assignedNames.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(Icons.person_outline,
                            size: 13, color: Colors.grey[500]),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(job.assignedNames,
                              style: GoogleFonts.nunito(
                                  fontSize: 12, color: Colors.grey[700]),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                if (otherJobsInCity > 0 && city.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.teal.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: Colors.teal.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.location_city_outlined,
                              size: 12, color: Colors.teal[700]),
                          const SizedBox(width: 4),
                          Text(
                            '$otherJobsInCity other job'
                            '${otherJobsInCity == 1 ? '' : 's'} in $city',
                            style: GoogleFonts.nunito(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.teal[800]),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (job.notes.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      job.notes.trim(),
                      style: GoogleFonts.nunito(
                          fontSize: 12, color: Colors.grey[700]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LEADS
// ---------------------------------------------------------------------------

class _LeadList extends StatelessWidget {
  final List<WebLeadRecord> leads;
  final Future<void> Function() onRefresh;

  const _LeadList({required this.leads, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (leads.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            Icon(Icons.check_circle_outline,
                size: 46, color: Colors.green[300]),
            const SizedBox(height: 12),
            Center(
              child: Text('No open leads.',
                  style: GoogleFonts.nunito(
                      fontSize: 14, color: Colors.grey[600])),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
        itemCount: leads.length,
        itemBuilder: (context, i) =>
            _LeadCard(lead: leads[i], onChanged: onRefresh),
      ),
    );
  }
}

class _LeadCard extends StatelessWidget {
  final WebLeadRecord lead;
  final Future<void> Function() onChanged;

  const _LeadCard({required this.lead, required this.onChanged});

  Future<void> _setStatus(BuildContext context, String status) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await sbUpdateWebLeadStatus(id: lead.id, status: status);
      await onChanged();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not update lead: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = lead.status.toLowerCase() == 'new';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isNew
              ? Colors.purple.withValues(alpha: 0.35)
              : Colors.grey.withValues(alpha: 0.15),
          width: isNew ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _MiniChip(
                  label: lead.status,
                  color: isNew ? Colors.purple : Colors.grey,
                  icon: Icons.language,
                ),
                const Spacer(),
                Text(formatDate(lead.createdAt),
                    style: GoogleFonts.nunito(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey[700])),
              ],
            ),
            const SizedBox(height: 8),
            Text(lead.name.isNotEmpty ? lead.name : 'Unnamed lead',
                style: GoogleFonts.nunito(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            if (lead.source.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('via ${lead.source}',
                    style: GoogleFonts.nunito(
                        fontSize: 11, color: Colors.grey[600])),
              ),
            if (lead.message.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(lead.message.trim(),
                    style: GoogleFonts.nunito(
                        fontSize: 12, color: Colors.grey[800])),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (lead.phone.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.phone, size: 18),
                    color: kBrandGreen,
                    tooltip: lead.phone,
                    onPressed: () =>
                        launchUrl(Uri.parse('tel:${lead.phone}')),
                  ),
                if (lead.email.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.email_outlined, size: 18),
                    color: kBrandGreen,
                    tooltip: lead.email,
                    onPressed: () =>
                        launchUrl(Uri.parse('mailto:${lead.email}')),
                  ),
                const Spacer(),
                if (isNew)
                  TextButton(
                    onPressed: () => _setStatus(context, 'Contacted'),
                    child: const Text('Mark Contacted'),
                  ),
                if (lead.status.toLowerCase() != 'closed')
                  TextButton(
                    onPressed: () => _setStatus(context, 'Closed'),
                    child: const Text('Close'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SMALL WIDGETS
// ---------------------------------------------------------------------------

class _BucketChip extends StatelessWidget {
  final HubBucket bucket;
  const _BucketChip({required this.bucket});

  (Color, IconData) get _style {
    switch (bucket) {
      case HubBucket.straightInstall:
        return (Colors.green.shade700, Icons.arrow_downward_rounded);
      case HubBucket.curveInstall:
        return (Colors.teal.shade700, Icons.turn_right_rounded);
      case HubBucket.rampInstall:
        return (Colors.lightGreen.shade800, Icons.accessible_forward);
      case HubBucket.straightRemoval:
        return (Colors.orange.shade800, Icons.arrow_upward_rounded);
      case HubBucket.curveRemoval:
        return (Colors.deepOrange.shade700, Icons.turn_left_rounded);
      case HubBucket.rampRemoval:
        return (Colors.brown.shade600, Icons.accessible_forward);
      case HubBucket.service:
        return (Colors.blue.shade700, Icons.build_outlined);
      case HubBucket.annualService:
        return (Colors.indigo.shade600, Icons.event_repeat);
      case HubBucket.needsScheduling:
        return (Colors.red.shade700, Icons.pending_actions);
      case HubBucket.reminder:
        return (Colors.blueGrey.shade600, Icons.sticky_note_2_outlined);
      case HubBucket.lead:
        return (Colors.purple.shade600, Icons.language);
      case HubBucket.other:
        return (Colors.grey.shade600, Icons.more_horiz);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (color, icon) = _style;
    return _MiniChip(
        label: hubBucketLabel(bucket), color: color, icon: icon);
  }
}

class _MiniChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  const _MiniChip(
      {required this.label, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: GoogleFonts.nunito(
                  fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

class _FundingBadge extends StatelessWidget {
  final String source;
  const _FundingBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.purple.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.purple.withValues(alpha: 0.35)),
      ),
      child: Text(source,
          style: GoogleFonts.nunito(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Colors.purple[700])),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(error,
                textAlign: TextAlign.center,
                style: GoogleFonts.nunito(fontSize: 13)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
