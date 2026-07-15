// lib/screens/operations_hub_screen.dart
//
// Operations Hub — unified view of all pending work for Able Home Accessibility.
// Replaces the fragmented Scheduling Queue + Annuals whiteboard.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/models.dart';
import '../qbt_api.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';
import 'customers_screen.dart';
import 'email_review_screen.dart';
import 'schedule_event_form_screen.dart';

// ---------------------------------------------------------------------------
// SCREEN
// ---------------------------------------------------------------------------

class OperationsHubScreen extends StatefulWidget {
  /// When set, opens the hub on that tab index (0=All, 1=Installs, 2=Removals,
  /// 3=Service, 4=Annuals, 5=Leads).
  final int initialTabIndex;

  const OperationsHubScreen({super.key, this.initialTabIndex = 0});

  @override
  State<OperationsHubScreen> createState() => _OperationsHubScreenState();
}

class _OperationsHubScreenState extends State<OperationsHubScreen>
    with SingleTickerProviderStateMixin {
  static const _tabs = [
    (label: 'All', type: null),
    (label: 'Installs', type: OpsJobType.stairliftInstall),
    (label: 'Removals', type: OpsJobType.stairliftRemoval),
    (label: 'Service', type: OpsJobType.stairliftService),
    (label: 'Annuals', type: OpsJobType.annualService),
    (label: 'Leads', type: OpsJobType.webLead),
  ];

  late TabController _tabController;
  List<OpsJob> _jobs = [];
  Map<String, QbtUser> _users = {};
  bool _loading = true;
  String? _error;
  bool _showCompleted = false;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, _tabs.length - 1),
    );
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      // Load jobs and users independently — TSheets failure shouldn't kill the hub
      final jobs = await sbFetchAllOpsJobs(includeCompleted: _showCompleted);
      Map<String, QbtUser> users = _users; // keep existing if refresh fails
      try {
        users = await qbtFetchUsers();
      } catch (_) {}
      if (!mounted) return;
      setState(() { _jobs = jobs; _users = users; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  List<OpsJob> _filtered({OpsJobType? type}) {
    var jobs = type == null
        ? _jobs
        : _jobs.where((j) => j.jobType == type).toList();

    // Merge ramp types into removals tab
    if (type == OpsJobType.stairliftRemoval) {
      jobs = _jobs
          .where((j) =>
              j.jobType == OpsJobType.stairliftRemoval ||
              j.jobType == OpsJobType.buyback ||
              j.jobType == OpsJobType.rampRemoval)
          .toList();
    }
    if (type == OpsJobType.stairliftInstall) {
      jobs = _jobs
          .where((j) =>
              j.jobType == OpsJobType.stairliftInstall ||
              j.jobType == OpsJobType.rampInstall)
          .toList();
    }
    if (type == OpsJobType.stairliftService) {
      jobs = _jobs
          .where((j) => j.jobType == OpsJobType.stairliftService)
          .toList();
    }

    if (_search.trim().isNotEmpty) {
      final q = _search.toLowerCase();
      jobs = jobs
          .where((j) =>
              j.customerName.toLowerCase().contains(q) ||
              j.city.toLowerCase().contains(q) ||
              j.address.toLowerCase().contains(q) ||
              j.phone.contains(q) ||
              j.liftType.toLowerCase().contains(q) ||
              j.notes.toLowerCase().contains(q))
          .toList();
    }

    // Sort: active before scheduled before completed, then by age (oldest first)
    jobs.sort((a, b) {
      final aOrd = _statusSortOrder(a.status);
      final bOrd = _statusSortOrder(b.status);
      if (aOrd != bOrd) return aOrd.compareTo(bOrd);
      final aDate = a.dateRequested ?? DateTime.now();
      final bDate = b.dateRequested ?? DateTime.now();
      return aDate.compareTo(bDate);
    });
    return jobs;
  }

  int _statusSortOrder(OpsJobStatus s) {
    switch (s) {
      case OpsJobStatus.needsInfo: return 0;
      case OpsJobStatus.waitingAgencyConfirmation: return 1;
      case OpsJobStatus.readyToSchedule: return 2;
      case OpsJobStatus.scheduled: return 3;
      case OpsJobStatus.completed: return 4;
    }
  }

  int _countActive({OpsJobType? type}) =>
      _filtered(type: type).where((j) => j.isActive).length;

  String _tabLabel(int i) {
    final tab = _tabs[i];
    final count = _countActive(type: tab.type);
    return count > 0 ? '${tab.label} ($count)' : tab.label;
  }

  Future<void> _openAddForm() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const OpsJobFormScreen()),
    );
    if (saved == true && mounted) _load();
  }

  Future<void> _openEditForm(OpsJob job) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => OpsJobFormScreen(existing: job)),
    );
    if (saved == true && mounted) _load();
  }

  Future<void> _advanceStatus(OpsJob job) async {
    final next = _nextStatus(job.status);
    if (next == null) return;

    if (next == OpsJobStatus.scheduled) {
      // Update status first, then open the schedule form pre-filled
      await sbUpdateOpsJobStatus(job.jobId, next);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ScheduleEventFormScreen(
            users: _users,
            initialDate: DateTime.now(),
            prefillTitle: '${job.jobTypeLabel} – ${job.customerName}',
            prefillLocation: job.address,
            prefillNotes: job.notes.isNotEmpty ? job.notes : null,
            prefillFundingSource: job.fundingSource,
            sourceJobId: job.sourceTable == 'ops_jobs' ? job.jobId : null,
            sourceJobTable: job.sourceTable == 'ops_jobs' ? 'ops_jobs' : null,
          ),
        ),
      );
      if (mounted) _load();
      return;
    }

    await sbAdvanceOpsJobStatus(job, next);
    _load();
  }

  Future<void> _deleteJob(OpsJob job) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete Job',
      content: 'Remove this job from the queue? This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    try {
      await sbDeleteOpsJobAny(job);
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e'),
              backgroundColor: Colors.red[700]),
        );
      }
    }
  }

  OpsJobStatus? _nextStatus(OpsJobStatus current) {
    switch (current) {
      case OpsJobStatus.needsInfo: return OpsJobStatus.waitingAgencyConfirmation;
      case OpsJobStatus.waitingAgencyConfirmation: return OpsJobStatus.readyToSchedule;
      case OpsJobStatus.readyToSchedule: return OpsJobStatus.scheduled;
      case OpsJobStatus.scheduled: return OpsJobStatus.completed;
      case OpsJobStatus.completed: return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Operations Hub',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.mark_email_unread_outlined, color: Colors.white),
            tooltip: 'Email Review Queue',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EmailReviewScreen()),
            ),
          ),
          IconButton(
            icon: Icon(
              _showCompleted ? Icons.check_circle : Icons.check_circle_outline,
              color: Colors.white,
            ),
            tooltip: _showCompleted ? 'Hide completed' : 'Show completed',
            onPressed: () {
              setState(() => _showCompleted = !_showCompleted);
              _load();
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(92),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  style: GoogleFonts.nunito(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search customer, city, lift type…',
                    hintStyle: GoogleFonts.nunito(
                        color: Colors.white60, fontSize: 13),
                    prefixIcon:
                        const Icon(Icons.search, color: Colors.white60),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.12),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
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
                unselectedLabelColor: Colors.white60,
                labelStyle: GoogleFonts.nunito(
                    fontWeight: FontWeight.w700, fontSize: 13),
                unselectedLabelStyle:
                    GoogleFonts.nunito(fontSize: 13),
                tabs: List.generate(
                    _tabs.length, (i) => Tab(text: _tabLabel(i))),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kBrandGreen,
        foregroundColor: Colors.white,
        onPressed: _openAddForm,
        icon: const Icon(Icons.add),
        label: Text('Add Job', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : TabBarView(
                  controller: _tabController,
                  children: _tabs
                      .map((tab) => _JobList(
                            jobs: _filtered(type: tab.type),
                            allActiveJobs: _jobs.where((j) => j.isActive).toList(),
                            onRefresh: _load,
                            onAdvance: _advanceStatus,
                            onEdit: _openEditForm,
                            onDelete: _deleteJob,
                          ))
                      .toList(),
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// JOB LIST
// ---------------------------------------------------------------------------

/// Navigates to the customer profile for a job's customer name.
/// If no customer record exists yet, opens the form pre-filled so one can be created.
Future<void> openCustomerFromJob(BuildContext context, OpsJob job) async {
  if (job.customerName.isEmpty) return;
  final matches = await sbFetchCustomers(search: job.customerName);
  if (!context.mounted) return;

  CustomerRecord? target;
  if (matches.isNotEmpty) {
    // Pick the closest name match (first result)
    target = matches.first;
  }

  if (target != null) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CustomerDetailScreen(customer: target!)),
    );
  } else {
    // No customer yet — open the add form pre-filled so it's easy to create one
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CustomerFormScreen(
          existing: CustomerRecord(
            customerId: '',
            name: job.customerName,
            address: job.address,
            city: job.city,
            phone: job.phone,
            email: '',
            fundingSource: job.fundingSource,
            qbCustomerId: '',
            notes: '',
          ),
        ),
      ),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer saved.')),
      );
    }
  }
}

class _JobList extends StatelessWidget {
  final List<OpsJob> jobs;
  /// All active jobs across ALL tabs — used to compute city proximity hints.
  final List<OpsJob> allActiveJobs;
  final Future<void> Function() onRefresh;
  final Future<void> Function(OpsJob) onAdvance;
  final Future<void> Function(OpsJob) onEdit;
  final Future<void> Function(OpsJob) onDelete;

  const _JobList({
    required this.jobs,
    required this.allActiveJobs,
    required this.onRefresh,
    required this.onAdvance,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // Build city → count of OTHER active jobs map once for the whole list
    final cityCount = <String, int>{};
    for (final j in allActiveJobs) {
      final c = j.city.trim().toLowerCase();
      if (c.isNotEmpty) cityCount[c] = (cityCount[c] ?? 0) + 1;
    }

    if (jobs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 48, color: kBrandGreen.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text('All clear — nothing pending here.',
                style: GoogleFonts.nunito(
                    color: Colors.grey[600], fontSize: 15)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
        itemCount: jobs.length,
        itemBuilder: (ctx, i) {
          final job = jobs[i];
          final cityKey = job.city.trim().toLowerCase();
          // Subtract 1 for this job itself
          final otherJobsInCity = cityKey.isNotEmpty
              ? (cityCount[cityKey] ?? 1) - 1
              : 0;
          return _OpsJobCard(
            job: job,
            otherJobsInCity: otherJobsInCity,
            onAdvance: () => onAdvance(job),
            onEdit: () => onEdit(job),
            onDelete: () => onDelete(job),
            onOpenCustomer: (ctx2, j) => openCustomerFromJob(ctx2, j),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// JOB CARD
// ---------------------------------------------------------------------------

class _OpsJobCard extends StatelessWidget {
  final OpsJob job;
  final int otherJobsInCity;
  final VoidCallback onAdvance;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Future<void> Function(BuildContext, OpsJob) onOpenCustomer;

  const _OpsJobCard({
    required this.job,
    required this.otherJobsInCity,
    required this.onAdvance,
    required this.onEdit,
    required this.onDelete,
    required this.onOpenCustomer,
  });

  @override
  Widget build(BuildContext context) {
    final agingColor = _agingColor(job.daysWaiting, job.status);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: agingColor != null
              ? agingColor.withValues(alpha: 0.4)
              : Colors.grey.withValues(alpha: 0.15),
          width: agingColor != null ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Row 1: job type chip + status chip + aging badge + date requested
              Row(
                children: [
                  _JobTypeChip(job: job),
                  const SizedBox(width: 6),
                  _StatusChip(status: job.status),
                  if (agingColor != null) ...[
                    const SizedBox(width: 6),
                    _AgingBadge(days: job.daysWaiting, color: agingColor),
                  ],
                  const Spacer(),
                  if (job.dateRequested != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
                      ),
                      child: Text(
                        formatDate(job.dateRequested),
                        style: GoogleFonts.nunito(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[700],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (job.isAgencyFunded)
                    _FundingBadge(source: job.fundingSource),
                ],
              ),
              const SizedBox(height: 10),
              // ── Row 2: customer name + city
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: job.customerName.isNotEmpty
                              ? () => onOpenCustomer(context, job)
                              : null,
                          child: Text(
                            job.customerName.isNotEmpty
                                ? job.customerName
                                : 'Unknown Customer',
                            style: GoogleFonts.nunito(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: job.customerName.isNotEmpty
                                  ? kBrandGreen
                                  : Colors.black54,
                              decoration: job.customerName.isNotEmpty
                                  ? TextDecoration.underline
                                  : null,
                              decorationColor: kBrandGreen,
                            ),
                          ),
                        ),
                        if (job.city.isNotEmpty || job.address.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // City chip — bold and prominent for scheduling
                                if (job.city.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
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
                                        Text(
                                          job.city,
                                          style: GoogleFonts.nunito(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.blue[800],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                // Full address underneath when available
                                if (job.address.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Text(
                                      job.address,
                                      style: GoogleFonts.nunito(
                                          fontSize: 11, color: Colors.grey[600]),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (job.liftType.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              job.liftType,
                              style: GoogleFonts.nunito(
                                  fontSize: 13, color: Colors.grey[700]),
                            ),
                          ),
                        if (otherJobsInCity > 0 && job.city.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
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
                                    '$otherJobsInCity other job${otherJobsInCity == 1 ? '' : 's'} in ${job.city}',
                                    style: GoogleFonts.nunito(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.teal[800],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Phone quick-dial
                  if (job.phone.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.phone_outlined,
                          size: 20, color: kBrandGreen),
                      onPressed: () => launchUrl(
                          Uri.parse('tel:${job.phone}'),
                          mode: LaunchMode.externalApplication),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: job.phone,
                    ),
                ],
              ),
              // ── Notes preview
              if (job.notes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  job.notes,
                  style: GoogleFonts.nunito(
                      fontSize: 12, color: Colors.grey[600]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              // ── Buyback price
              if (job.jobType == OpsJobType.buyback &&
                  job.buybackOfferPrice != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Offer: \$${job.buybackOfferPrice!.toStringAsFixed(0)}',
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: kBrandGreen,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),
              // ── Action row
              Row(
                children: [
                  const Spacer(),
                  // Delete
                  IconButton(
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: Colors.red),
                    onPressed: onDelete,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Delete',
                  ),
                  const SizedBox(width: 12),
                  // Advance status button
                  if (job.status != OpsJobStatus.completed)
                    _AdvanceButton(status: job.status, onAdvance: onAdvance),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Returns a color when a job has been waiting too long, null otherwise.
  Color? _agingColor(int days, OpsJobStatus status) {
    if (status == OpsJobStatus.completed || status == OpsJobStatus.scheduled) {
      return null;
    }
    if (days >= 7) return Colors.red[600];
    if (days >= 3) return Colors.orange[700];
    return null;
  }
}

// ---------------------------------------------------------------------------
// SMALL WIDGETS
// ---------------------------------------------------------------------------

class _JobTypeChip extends StatelessWidget {
  final OpsJob job;
  const _JobTypeChip({required this.job});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _typeColor(job.jobType).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_typeIcon(job.jobType),
              size: 13, color: _typeColor(job.jobType)),
          const SizedBox(width: 4),
          Text(
            job.jobTypeLabel,
            style: GoogleFonts.nunito(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: _typeColor(job.jobType),
            ),
          ),
        ],
      ),
    );
  }

  Color _typeColor(OpsJobType t) {
    switch (t) {
      case OpsJobType.stairliftInstall:
      case OpsJobType.rampInstall:
        return kBrandGreen;
      case OpsJobType.stairliftRemoval:
      case OpsJobType.rampRemoval:
        return Colors.blueGrey[700]!;
      case OpsJobType.buyback:
        return Colors.teal[700]!;
      case OpsJobType.stairliftService:
        return Colors.orange[800]!;
      case OpsJobType.annualService:
        return Colors.blue[700]!;
      case OpsJobType.webLead:
        return Colors.purple[700]!;
    }
  }

  IconData _typeIcon(OpsJobType t) {
    switch (t) {
      case OpsJobType.stairliftInstall:
      case OpsJobType.rampInstall:
        return Icons.arrow_downward_rounded;
      case OpsJobType.stairliftRemoval:
      case OpsJobType.rampRemoval:
        return Icons.arrow_upward_rounded;
      case OpsJobType.buyback:
        return Icons.loop_rounded;
      case OpsJobType.stairliftService:
        return Icons.build_outlined;
      case OpsJobType.annualService:
        return Icons.event_repeat_outlined;
      case OpsJobType.webLead:
        return Icons.language_outlined;
    }
  }
}

class _StatusChip extends StatelessWidget {
  final OpsJobStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: _statusColor(status).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: _statusColor(status).withValues(alpha: 0.3), width: 1),
      ),
      child: Text(
        _label(status),
        style: GoogleFonts.nunito(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _statusColor(status),
        ),
      ),
    );
  }

  String _label(OpsJobStatus s) {
    switch (s) {
      case OpsJobStatus.needsInfo: return 'Needs Info';
      case OpsJobStatus.waitingAgencyConfirmation: return 'Waiting Confirmation';
      case OpsJobStatus.readyToSchedule: return 'Ready to Schedule';
      case OpsJobStatus.scheduled: return 'Scheduled';
      case OpsJobStatus.completed: return 'Completed';
    }
  }

  Color _statusColor(OpsJobStatus s) {
    switch (s) {
      case OpsJobStatus.needsInfo: return Colors.red[700]!;
      case OpsJobStatus.waitingAgencyConfirmation: return Colors.orange[800]!;
      case OpsJobStatus.readyToSchedule: return kBrandGreen;
      case OpsJobStatus.scheduled: return Colors.blue[700]!;
      case OpsJobStatus.completed: return Colors.grey[600]!;
    }
  }
}

class _AgingBadge extends StatelessWidget {
  final int days;
  final Color color;
  const _AgingBadge({required this.days, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${days}d',
        style: GoogleFonts.nunito(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
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
        color: Colors.indigo[700]!.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        source,
        style: GoogleFonts.nunito(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.indigo[700],
        ),
      ),
    );
  }
}

class _AdvanceButton extends StatelessWidget {
  final OpsJobStatus status;
  final VoidCallback onAdvance;
  const _AdvanceButton({required this.status, required this.onAdvance});

  String get _label {
    switch (status) {
      case OpsJobStatus.needsInfo: return 'Mark Waiting';
      case OpsJobStatus.waitingAgencyConfirmation: return 'Confirmed';
      case OpsJobStatus.readyToSchedule: return 'Mark Scheduled';
      case OpsJobStatus.scheduled: return 'Mark Complete';
      case OpsJobStatus.completed: return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onAdvance,
      style: TextButton.styleFrom(
        foregroundColor: kBrandGreen,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_label,
              style: GoogleFonts.nunito(
                  fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_forward_ios_rounded, size: 11),
        ],
      ),
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
            const Icon(Icons.error_outline, size: 40, color: Colors.red),
            const SizedBox(height: 12),
            Text('Failed to load jobs', style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(error, style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600]), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ADD / EDIT FORM
// ---------------------------------------------------------------------------

class OpsJobFormScreen extends StatefulWidget {
  final OpsJob? existing;
  const OpsJobFormScreen({super.key, this.existing});

  @override
  State<OpsJobFormScreen> createState() => _OpsJobFormScreenState();
}

class _OpsJobFormScreenState extends State<OpsJobFormScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  late OpsJobType _jobType;
  late OpsJobStatus _status;
  late String _fundingSource;
  final _customerCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _liftTypeCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _buybackCtrl = TextEditingController();
  DateTime? _dateRequested;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _jobType = e?.jobType ?? OpsJobType.stairliftService;
    _status = e?.status ?? OpsJobStatus.readyToSchedule;
    _fundingSource = e?.fundingSource ?? 'Private';
    _customerCtrl.text = e?.customerName ?? '';
    _addressCtrl.text = e?.address ?? '';
    _phoneCtrl.text = e?.phone ?? '';
    _liftTypeCtrl.text = e?.liftType ?? '';
    _notesCtrl.text = e?.notes ?? '';
    _buybackCtrl.text = e?.buybackOfferPrice?.toStringAsFixed(0) ?? '';
    _dateRequested = e?.dateRequested ?? DateTime.now();
  }

  @override
  void dispose() {
    _customerCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _liftTypeCtrl.dispose();
    _notesCtrl.dispose();
    _buybackCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final address = _addressCtrl.text.trim();
      final city = extractCity(address);
      final job = OpsJob(
        jobId: widget.existing?.jobId ?? '',
        jobType: _jobType,
        status: _status,
        customerName: _customerCtrl.text.trim(),
        address: address,
        city: city,
        phone: _phoneCtrl.text.trim(),
        liftType: _liftTypeCtrl.text.trim(),
        fundingSource: _fundingSource,
        notes: _notesCtrl.text.trim(),
        dateRequested: _dateRequested,
        buybackOfferPrice: _jobType == OpsJobType.buyback
            ? double.tryParse(_buybackCtrl.text.trim())
            : null,
        sourceTable: widget.existing?.sourceTable ?? 'ops_jobs',
        sourceId: widget.existing?.sourceId ?? '',
      );
      if (_isEdit) {
        await sbUpdateOpsJob(job);
      } else {
        // Auto-set status to waiting if agency-funded
        final effectiveJob = requiresAgencyConfirmation(_fundingSource) &&
                _status == OpsJobStatus.readyToSchedule
            ? OpsJob(
                jobId: job.jobId,
                jobType: job.jobType,
                status: OpsJobStatus.waitingAgencyConfirmation,
                customerName: job.customerName,
                address: job.address,
                city: job.city,
                phone: job.phone,
                liftType: job.liftType,
                fundingSource: job.fundingSource,
                notes: job.notes,
                dateRequested: job.dateRequested,
                buybackOfferPrice: job.buybackOfferPrice,
                sourceTable: job.sourceTable,
                sourceId: job.sourceId,
              )
            : job;
        await sbCreateOpsJob(effectiveJob);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e')),
        );
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text(_isEdit ? 'Edit Job' : 'Add Job',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Job Type
            _SectionLabel('Job Type'),
            _DropdownField<OpsJobType>(
              value: _jobType,
              items: OpsJobType.values,
              labelFor: (t) => OpsJob(
                jobId: '', jobType: t, status: OpsJobStatus.readyToSchedule,
                customerName: '', address: '', city: '', phone: '',
                liftType: '', fundingSource: 'Private', notes: '',
                sourceTable: '', sourceId: '',
              ).jobTypeLabel,
              onChanged: (v) => setState(() => _jobType = v!),
            ),
            const SizedBox(height: 12),

            // Status
            _SectionLabel('Status'),
            _DropdownField<OpsJobStatus>(
              value: _status,
              items: OpsJobStatus.values,
              labelFor: (s) => OpsJob(
                jobId: '', jobType: OpsJobType.stairliftService, status: s,
                customerName: '', address: '', city: '', phone: '',
                liftType: '', fundingSource: 'Private', notes: '',
                sourceTable: '', sourceId: '',
              ).statusLabel,
              onChanged: (v) => setState(() => _status = v!),
            ),
            const SizedBox(height: 12),

            // Funding Source
            _SectionLabel('Funding Source'),
            _DropdownField<String>(
              value: _fundingSource,
              items: kFundingSources,
              labelFor: (s) => s,
              onChanged: (v) => setState(() => _fundingSource = v!),
            ),
            const SizedBox(height: 12),

            // Customer Name
            _SectionLabel('Customer Name'),
            _Field(controller: _customerCtrl, hint: 'Jane Smith', required: true),
            const SizedBox(height: 12),

            // Address
            _SectionLabel('Address'),
            _Field(
              controller: _addressCtrl,
              hint: '123 Main St, Needham, MA 02492',
              helperText: 'Include city for location-based scheduling hints',
            ),
            const SizedBox(height: 12),

            // Phone
            _SectionLabel('Phone'),
            _Field(controller: _phoneCtrl, hint: '(508) 555-1234', keyboardType: TextInputType.phone),
            const SizedBox(height: 12),

            // Lift / Equipment Type
            _SectionLabel('Equipment Type'),
            _Field(controller: _liftTypeCtrl, hint: 'Bruno Elan, EZ Access 3G, etc.'),
            const SizedBox(height: 12),

            // Buyback price (only for buybacks)
            if (_jobType == OpsJobType.buyback) ...[
              _SectionLabel('Buyback Offer Price'),
              _Field(
                controller: _buybackCtrl,
                hint: '250',
                prefixText: '\$',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
            ],

            // Date Requested
            _SectionLabel('Date Requested'),
            _DatePickerField(
              value: _dateRequested,
              onChanged: (d) => setState(() => _dateRequested = d),
            ),
            const SizedBox(height: 12),

            // Notes
            _SectionLabel('Notes'),
            _Field(
              controller: _notesCtrl,
              hint: 'Any relevant details…',
              maxLines: 3,
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kBrandGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(_isEdit ? 'Save Changes' : 'Add to Hub',
                        style: GoogleFonts.nunito(
                            fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FORM HELPERS
// ---------------------------------------------------------------------------

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.grey[700],
              letterSpacing: 0.3)),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool required;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? helperText;
  final String? prefixText;

  const _Field({
    required this.controller,
    required this.hint,
    this.required = false,
    this.maxLines = 1,
    this.keyboardType,
    this.helperText,
    this.prefixText,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: GoogleFonts.nunito(fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.nunito(color: Colors.grey[400], fontSize: 14),
        helperText: helperText,
        helperStyle: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[500]),
        prefixText: prefixText,
        filled: true,
        fillColor: kCardSurface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: kBrandGreen, width: 2),
        ),
      ),
      validator: required
          ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
          : null,
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  final T value;
  final List<T> items;
  final String Function(T) labelFor;
  final void Function(T?) onChanged;

  const _DropdownField({
    required this.value,
    required this.items,
    required this.labelFor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<T>(
      value: value,
      items: items
          .map((i) => DropdownMenuItem<T>(
                value: i,
                child: Text(labelFor(i),
                    style: GoogleFonts.nunito(fontSize: 14)),
              ))
          .toList(),
      onChanged: onChanged,
      decoration: InputDecoration(
        filled: true,
        fillColor: kCardSurface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: kBrandGreen, width: 2),
        ),
      ),
    );
  }
}

class _DatePickerField extends StatelessWidget {
  final DateTime? value;
  final void Function(DateTime?) onChanged;

  const _DatePickerField({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime(2030),
        );
        if (picked != null) onChanged(picked);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: kCardSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[300]!),
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today_outlined,
                size: 16, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Text(
              value != null ? formatDate(value) : 'Select date',
              style: GoogleFonts.nunito(
                fontSize: 14,
                color: value != null ? Colors.black87 : Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
