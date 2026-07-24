// lib/screens/customers_screen.dart
//
// Customer Lifecycle CRM — the canonical local `customers` table is the source
// of truth. QuickBooks is used only to import/link and to deep-link out.
//
// Three views (toggled in the app bar):
//   • List       — searchable local customers, filterable by lifecycle status
//   • Board       — kanban by lifecycle status, tap-to-advance the funnel
//   • Follow-ups  — everything due across customers (reviews, annuals, service)
//
// The detail screen ties the three pipelines together: a customer's lifecycle
// status, their reminders (customer_activities), their Ops Hub jobs, plus the
// equipment + service history that finally populates now that we always carry a
// real customer_id (the old QB-search flow built records with customer_id: '').

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../integrations/quickbooks_service.dart';
import '../models/models.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';

// ---------------------------------------------------------------------------
// LIFECYCLE STATUS PRESENTATION
// ---------------------------------------------------------------------------

Color customerLifecycleColor(CustomerLifecycleStatus s) {
  switch (s) {
    case CustomerLifecycleStatus.newLead: return Colors.blueGrey;
    case CustomerLifecycleStatus.contacted: return Colors.indigo;
    case CustomerLifecycleStatus.evalScheduled: return Colors.deepPurple;
    case CustomerLifecycleStatus.quoted: return Colors.orange.shade800;
    case CustomerLifecycleStatus.won: return Colors.teal;
    case CustomerLifecycleStatus.active: return kBrandGreen;
    case CustomerLifecycleStatus.past: return Colors.grey;
    case CustomerLifecycleStatus.dormant: return Colors.brown;
    case CustomerLifecycleStatus.lost: return Colors.red.shade400;
  }
}

/// The order statuses appear in as board columns / filter tabs.
const List<CustomerLifecycleStatus> kLifecycleOrder = [
  CustomerLifecycleStatus.newLead,
  CustomerLifecycleStatus.contacted,
  CustomerLifecycleStatus.evalScheduled,
  CustomerLifecycleStatus.quoted,
  CustomerLifecycleStatus.won,
  CustomerLifecycleStatus.active,
  CustomerLifecycleStatus.past,
  CustomerLifecycleStatus.dormant,
  CustomerLifecycleStatus.lost,
];

// ---------------------------------------------------------------------------
// LIST / BOARD / FOLLOW-UPS SCREEN
// ---------------------------------------------------------------------------

enum _CustomersView { list, board, followUps }

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  _CustomersView _view = _CustomersView.list;

  List<CustomerRecord> _customers = [];
  List<CustomerActivity> _dueActivities = [];
  bool _loading = true;
  String? _error;

  // List view state
  final _searchCtrl = TextEditingController();
  String _query = '';
  CustomerLifecycleStatus? _statusFilter; // null = all

  // QB import state
  List<QbCustomer> _qbResults = [];
  bool _qbSearching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        sbFetchCustomers(),
        sbFetchDueActivities(),
      ]);
      if (!mounted) return;
      setState(() {
        _customers = results[0] as List<CustomerRecord>;
        _dueActivities = results[1] as List<CustomerActivity>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  List<CustomerRecord> get _filtered {
    var list = _customers;
    if (_statusFilter != null) {
      list = list.where((c) => c.lifecycleStatus == _statusFilter).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((c) =>
          c.name.toLowerCase().contains(q) ||
          c.address.toLowerCase().contains(q) ||
          c.city.toLowerCase().contains(q) ||
          c.phone.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  Future<void> _openCustomer(CustomerRecord c) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CustomerDetailScreen(customer: c)),
    );
    if (changed == true && mounted) _load();
  }

  Future<void> _addCustomer() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CustomerFormScreen()),
    );
    if (saved == true && mounted) _load();
  }

  // --- QB import (fall-through when a local search finds nothing) ------------

  Future<void> _qbImportSearch() async {
    final q = _query.trim();
    if (q.length < 2) return;
    setState(() { _qbSearching = true; _qbResults = []; });
    try {
      final results = await QuickBooksService.searchCustomers(q);
      if (mounted) setState(() { _qbResults = results; _qbSearching = false; });
    } on QbNotConnectedException {
      if (mounted) {
        setState(() => _qbSearching = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('QuickBooks not connected — connect it in the Account menu.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _qbSearching = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('QB error: $e')));
      }
    }
  }

  Future<void> _importQbCustomer(QbCustomer qb) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CustomerFormScreen(
          existing: CustomerRecord(
            customerId: '',
            name: qb.name,
            address: qb.address,
            city: extractCity(qb.address),
            phone: qb.phone,
            email: qb.email,
            fundingSource: 'Private',
            qbCustomerId: qb.id,
            notes: '',
            lifecycleStatus: CustomerLifecycleStatus.active,
          ),
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() { _qbResults = []; });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Customers', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _viewToggle(),
          ),
        ),
      ),
      floatingActionButton: _view == _CustomersView.followUps
          ? null
          : FloatingActionButton.extended(
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
              onPressed: _addCustomer,
              icon: const Icon(Icons.person_add_alt_1),
              label: Text('Add', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
            ),
      body: _buildBody(),
    );
  }

  Widget _viewToggle() {
    Widget seg(_CustomersView v, IconData icon, String label) {
      final selected = _view == v;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _view = v),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: selected ? kBrandGreenDark : Colors.white70),
                const SizedBox(width: 5),
                Text(label,
                    style: GoogleFonts.nunito(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: selected ? kBrandGreenDark : Colors.white70)),
                if (v == _CustomersView.followUps && _dueActivities.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: selected ? kBrandGreen : Colors.orange,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('${_dueActivities.length}',
                        style: GoogleFonts.nunito(
                            fontSize: 10, fontWeight: FontWeight.w800, color: Colors.white)),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Row(children: [
      seg(_CustomersView.list, Icons.view_list_rounded, 'List'),
      const SizedBox(width: 6),
      seg(_CustomersView.board, Icons.view_column_rounded, 'Board'),
      const SizedBox(width: 6),
      seg(_CustomersView.followUps, Icons.notifications_active_rounded, 'Due'),
    ]);
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Error: $_error', style: GoogleFonts.nunito(color: Colors.red[700])),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _load, child: const Text('Retry')),
        ]),
      );
    }
    switch (_view) {
      case _CustomersView.list: return _listView();
      case _CustomersView.board: return _boardView();
      case _CustomersView.followUps: return _followUpsView();
    }
  }

  // --- LIST VIEW -------------------------------------------------------------

  Widget _listView() {
    final filtered = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() { _query = v; _qbResults = []; }),
            decoration: InputDecoration(
              hintText: 'Search customers…',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() {
                        _searchCtrl.clear();
                        _query = '';
                        _qbResults = [];
                      }),
                    )
                  : null,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
              ),
            ),
          ),
        ),
        _statusFilterBar(),
        Expanded(
          child: filtered.isEmpty
              ? _emptyListState()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 90),
                  itemCount: filtered.length,
                  itemBuilder: (_, i) => _customerListTile(filtered[i]),
                ),
        ),
      ],
    );
  }

  Widget _statusFilterBar() {
    // Only show statuses that actually have customers, plus "All".
    final counts = <CustomerLifecycleStatus, int>{};
    for (final c in _customers) {
      counts[c.lifecycleStatus] = (counts[c.lifecycleStatus] ?? 0) + 1;
    }
    final present = kLifecycleOrder.where((s) => (counts[s] ?? 0) > 0).toList();
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _filterChip('All (${_customers.length})', _statusFilter == null,
              () => setState(() => _statusFilter = null), kBrandGreen),
          for (final s in present)
            _filterChip('${customerLifecycleLabel(s)} (${counts[s]})',
                _statusFilter == s,
                () => setState(() => _statusFilter = s),
                customerLifecycleColor(s)),
        ],
      ),
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? color : color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: selected ? 1 : 0.3)),
          ),
          child: Text(label,
              style: GoogleFonts.nunito(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : color)),
        ),
      ),
    );
  }

  Widget _emptyListState() {
    // If a search yielded no local matches, offer QB import.
    if (_query.trim().length >= 2) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Icon(Icons.person_search, size: 44, color: kBrandGreen.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text('No local customer matches "$_query".',
              style: GoogleFonts.nunito(color: Colors.grey[700]), textAlign: TextAlign.center),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            icon: _qbSearching
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_download_outlined, size: 18),
            label: const Text('Search QuickBooks to import'),
            onPressed: _qbSearching ? null : _qbImportSearch,
          ),
          const SizedBox(height: 8),
          ..._qbResults.map((qb) => Card(
                margin: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.cloud_outlined, color: kBrandGreen),
                  title: Text(qb.name, style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
                  subtitle: Text([qb.phone, qb.address].where((s) => s.isNotEmpty).join(' · '),
                      style: GoogleFonts.nunito(fontSize: 11)),
                  trailing: const Icon(Icons.add_circle_outline, color: kBrandGreen),
                  onTap: () => _importQbCustomer(qb),
                ),
              )),
        ]),
      );
    }
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.people_outline, size: 48, color: kBrandGreen.withValues(alpha: 0.3)),
        const SizedBox(height: 12),
        Text(_statusFilter == null
            ? 'No customers yet. Tap Add to create one.'
            : 'No ${customerLifecycleLabel(_statusFilter!)} customers.',
            style: GoogleFonts.nunito(color: Colors.grey[600])),
      ]),
    );
  }

  Widget _customerListTile(CustomerRecord c) {
    final color = customerLifecycleColor(c.lifecycleStatus);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        onTap: () => _openCustomer(c),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Text(c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
              style: GoogleFonts.nunito(fontWeight: FontWeight.w700, color: color)),
        ),
        title: Text(c.name, style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 15)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (c.city.isNotEmpty)
              Text(c.city, style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 4),
            _LifecycleChip(status: c.lifecycleStatus),
          ],
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
      ),
    );
  }

  // --- BOARD VIEW ------------------------------------------------------------

  Widget _boardView() {
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
      children: [
        for (final status in kLifecycleOrder)
          _boardColumn(status,
              _customers.where((c) => c.lifecycleStatus == status).toList()),
      ],
    );
  }

  Widget _boardColumn(CustomerLifecycleStatus status, List<CustomerRecord> customers) {
    final color = customerLifecycleColor(status);
    return Container(
      width: 240,
      margin: const EdgeInsets.only(right: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(customerLifecycleLabel(status),
                    style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 13)),
              ),
              Text('${customers.length}',
                  style: GoogleFonts.nunito(fontWeight: FontWeight.w800, color: color)),
            ]),
          ),
          Expanded(
            child: customers.isEmpty
                ? Center(
                    child: Text('—', style: GoogleFonts.nunito(color: Colors.grey[400])))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: customers.length,
                    itemBuilder: (_, i) => _boardCard(customers[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _boardCard(CustomerRecord c) {
    final next = customerLifecycleNext(c.lifecycleStatus);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _openCustomer(c),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.name,
                  style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              if (c.city.isNotEmpty)
                Text(c.city, style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[600])),
              if (c.fundingSource != 'Private' && c.fundingSource.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(c.fundingSource,
                    style: GoogleFonts.nunito(
                        fontSize: 10, fontWeight: FontWeight.w700, color: Colors.indigo[700])),
              ],
              if (next != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.arrow_forward, size: 14),
                    label: Text('→ ${customerLifecycleLabel(next)}',
                        style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w700)),
                    onPressed: () => _advanceCustomer(c, next),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _advanceCustomer(CustomerRecord c, CustomerLifecycleStatus to) async {
    await sbUpdateCustomerLifecycle(c.customerId, to);
    if (mounted) _load();
  }

  // --- FOLLOW-UPS VIEW -------------------------------------------------------

  Widget _followUpsView() {
    if (_dueActivities.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_outline, size: 48, color: kBrandGreen.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text('All caught up — nothing due.',
              style: GoogleFonts.nunito(color: Colors.grey[700], fontSize: 15)),
        ]),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
      itemCount: _dueActivities.length,
      itemBuilder: (_, i) => _followUpTile(_dueActivities[i]),
    );
  }

  Widget _followUpTile(CustomerActivity a) {
    final (icon, color) = _activityVisual(a.type);
    final due = a.dueDate != null ? 'Due ${formatDate(a.dueDate)}' : 'Ready to send';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(children: [
          CircleAvatar(backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color, size: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.customerName.isEmpty ? 'Customer' : a.customerName,
                  style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 14)),
              Text('${a.typeLabel} · $due',
                  style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600])),
            ]),
          ),
          if (a.type == CustomerActivityType.annual ||
              a.type == CustomerActivityType.buybackCandidate)
            TextButton(
              onPressed: () => _actOnActivity(a),
              child: Text(a.type == CustomerActivityType.annual ? 'Schedule' : 'Buyback',
                  style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
            ),
          IconButton(
            icon: Icon(Icons.check_circle_outline, color: kBrandGreen),
            tooltip: 'Mark done',
            onPressed: () => _completeActivity(a),
          ),
        ]),
      ),
    );
  }

  (IconData, Color) _activityVisual(CustomerActivityType t) {
    switch (t) {
      case CustomerActivityType.review: return (Icons.star_outline, Colors.amber.shade800);
      case CustomerActivityType.annual: return (Icons.event_repeat, Colors.blue.shade700);
      case CustomerActivityType.buybackCandidate: return (Icons.sync_alt, Colors.deepOrange);
    }
  }

  Future<void> _completeActivity(CustomerActivity a) async {
    await sbUpdateActivityStatus(a.activityId, CustomerActivityStatus.done);
    if (mounted) _load();
  }

  /// Acting on an annual/buyback reminder spawns a real ops_job (the reminder
  /// layer feeding the jobs pipeline), then marks the reminder done.
  Future<void> _actOnActivity(CustomerActivity a) async {
    final customer = _customers.cast<CustomerRecord?>().firstWhere(
        (c) => c?.customerId == a.customerId, orElse: () => null);
    final jobType = a.type == CustomerActivityType.annual
        ? OpsJobType.annualService
        : OpsJobType.buyback;
    try {
      final job = await sbCreateOpsJob(OpsJob(
        jobId: '',
        jobType: jobType,
        status: OpsJobStatus.readyToSchedule,
        customerName: customer?.name ?? a.customerName,
        customerId: a.customerId,
        address: customer?.address ?? '',
        city: customer?.city ?? '',
        phone: customer?.phone ?? '',
        liftType: '',
        fundingSource: customer?.fundingSource ?? 'Private',
        notes: a.type == CustomerActivityType.annual
            ? 'Auto-created from annual reminder'
            : 'Auto-created from buyback candidate',
        dateRequested: DateTime.now(),
        sourceTable: 'ops_jobs',
        sourceId: '',
      ));
      await sbUpdateActivityStatus(a.activityId, CustomerActivityStatus.done,
          spawnedJobId: job.jobId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${customerActivityTypeLabel(a.type)} → job added to the Operations Hub.'),
        ));
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

// ---------------------------------------------------------------------------
// DETAIL SCREEN
// ---------------------------------------------------------------------------

class CustomerDetailScreen extends StatefulWidget {
  final CustomerRecord customer;
  const CustomerDetailScreen({super.key, required this.customer});

  /// Build from a live QB customer. NOTE: the local customer_id is resolved (or
  /// created) on load, so equipment/service history populate correctly — the
  /// old flow left customer_id empty and those queries always returned nothing.
  factory CustomerDetailScreen.fromQb(QbCustomer qb) {
    return CustomerDetailScreen(
      customer: CustomerRecord(
        customerId: '',
        name: qb.name,
        address: qb.address,
        city: extractCity(qb.address),
        phone: qb.phone,
        email: qb.email,
        fundingSource: 'Private',
        qbCustomerId: qb.id,
        notes: '',
        lifecycleStatus: CustomerLifecycleStatus.active,
      ),
    );
  }

  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  late CustomerRecord _customer;
  List<LiftRecord> _lifts = [];
  List<LiftServiceRecord> _service = [];
  List<OpsJob> _jobs = [];
  List<CustomerActivity> _activities = [];
  bool _loading = true;
  bool _changed = false; // whether to signal the list to refresh

  @override
  void initState() {
    super.initState();
    _customer = widget.customer;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Guarantee a canonical local row (fixes the empty-customer_id bug for
      // records reached via QuickBooks search).
      if (_customer.customerId.isEmpty) {
        final resolved = await sbResolveOrCreateCustomerByQb(
          name: _customer.name,
          qbId: _customer.qbCustomerId,
          address: _customer.address,
          phone: _customer.phone,
          email: _customer.email,
        );
        _customer = resolved;
        _changed = true;
      }
      final results = await Future.wait([
        sbFetchLiftsForCustomer(_customer.customerId),
        sbFetchServiceForCustomer(_customer.customerId),
        sbFetchJobsForCustomer(_customer.customerId),
        sbFetchActivitiesForCustomer(_customer.customerId),
      ]);
      if (!mounted) return;
      setState(() {
        _lifts = results[0] as List<LiftRecord>;
        _service = results[1] as List<LiftServiceRecord>;
        _jobs = results[2] as List<OpsJob>;
        _activities = results[3] as List<CustomerActivity>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openQb() async {
    final uri = Uri.parse(_customer.qbUrl);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open QuickBooks')),
      );
    }
  }

  Future<void> _callPhone() async {
    if (_customer.phone.isEmpty) return;
    await launchUrl(Uri.parse('tel:${_customer.phone}'), mode: LaunchMode.externalApplication);
  }

  Future<void> _setStatus(CustomerLifecycleStatus status) async {
    await sbUpdateCustomerLifecycle(_customer.customerId, status);
    if (!mounted) return;
    setState(() {
      _customer = _customer.copyWith(lifecycleStatus: status);
      _changed = true;
    });
  }

  Future<void> _pickStatus() async {
    final chosen = await showModalBottomSheet<CustomerLifecycleStatus>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text('Set lifecycle status',
                  style: GoogleFonts.nunito(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            for (final s in kLifecycleOrder)
              ListTile(
                leading: Container(width: 12, height: 12,
                    decoration: BoxDecoration(color: customerLifecycleColor(s), shape: BoxShape.circle)),
                title: Text(customerLifecycleLabel(s), style: GoogleFonts.nunito()),
                trailing: s == _customer.lifecycleStatus
                    ? const Icon(Icons.check, color: kBrandGreen)
                    : null,
                onTap: () => Navigator.pop(context, s),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != _customer.lifecycleStatus) {
      await _setStatus(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        backgroundColor: kSurface,
        appBar: AppBar(
          backgroundColor: kBrandGreenDark,
          foregroundColor: Colors.white,
          title: Text(_customer.name, style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_changed),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () async {
                final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => CustomerFormScreen(existing: _customer)),
                );
                if (saved == true && mounted) {
                  _changed = true;
                  _load();
                }
              },
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _statusCard(),
                  const SizedBox(height: 14),
                  _contactCard(),
                  if (_activities.any((a) => a.status == CustomerActivityStatus.pending)) ...[
                    const SizedBox(height: 14),
                    _remindersCard(),
                  ],
                  const SizedBox(height: 14),
                  _jobsCard(),
                  const SizedBox(height: 14),
                  _liftsCard(),
                  const SizedBox(height: 14),
                  _serviceCard(),
                  if (_customer.notes.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _notesCard(),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
      ),
    );
  }

  Widget _statusCard() {
    return _CardSection(
      title: 'Lifecycle',
      child: Row(
        children: [
          _LifecycleChip(status: _customer.lifecycleStatus),
          const Spacer(),
          if (customerLifecycleNext(_customer.lifecycleStatus) != null)
            OutlinedButton.icon(
              icon: const Icon(Icons.arrow_forward, size: 15),
              label: Text(customerLifecycleLabel(customerLifecycleNext(_customer.lifecycleStatus)!),
                  style: GoogleFonts.nunito(fontSize: 12, fontWeight: FontWeight.w700)),
              onPressed: () => _setStatus(customerLifecycleNext(_customer.lifecycleStatus)!),
            ),
          const SizedBox(width: 8),
          TextButton(onPressed: _pickStatus, child: const Text('Change')),
        ],
      ),
    );
  }

  Widget _contactCard() {
    return _CardSection(
      title: 'Contact',
      child: Column(children: [
        if (_customer.address.isNotEmpty)
          _Row(icon: Icons.location_on_outlined, text: _customer.address),
        if (_customer.phone.isNotEmpty)
          _Row(icon: Icons.phone_outlined, text: _customer.phone, onTap: _callPhone, actionColor: kBrandGreen),
        if (_customer.email.isNotEmpty)
          _Row(icon: Icons.email_outlined, text: _customer.email),
        if (_customer.fundingSource != 'Private')
          _Row(icon: Icons.account_balance_outlined, text: _customer.fundingSource, actionColor: Colors.indigo[700]),
        if (_customer.qbCustomerId.isNotEmpty) ...[
          const SizedBox(height: 8),
          InkWell(
            onTap: _openQb,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: kBrandGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kBrandGreen.withValues(alpha: 0.25)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.open_in_new, size: 15, color: kBrandGreen),
                const SizedBox(width: 7),
                Text('View in QuickBooks',
                    style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600, color: kBrandGreen)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _remindersCard() {
    final pending = _activities.where((a) => a.status == CustomerActivityStatus.pending).toList();
    return _CardSection(
      title: 'Follow-ups (${pending.length})',
      child: Column(
        children: pending.map((a) {
          final due = a.dueDate != null ? 'Due ${formatDate(a.dueDate)}' : 'Ready';
          return ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(_reminderIcon(a.type), size: 18, color: kBrandGreen.withValues(alpha: 0.8)),
            title: Text(a.typeLabel, style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600)),
            subtitle: Text(due, style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[600])),
            trailing: TextButton(
              onPressed: () async {
                await sbUpdateActivityStatus(a.activityId, CustomerActivityStatus.done);
                _changed = true;
                _load();
              },
              child: const Text('Done'),
            ),
          );
        }).toList(),
      ),
    );
  }

  IconData _reminderIcon(CustomerActivityType t) {
    switch (t) {
      case CustomerActivityType.review: return Icons.star_outline;
      case CustomerActivityType.annual: return Icons.event_repeat;
      case CustomerActivityType.buybackCandidate: return Icons.sync_alt;
    }
  }

  Widget _jobsCard() {
    return _CardSection(
      title: 'Jobs (${_jobs.length})',
      child: _jobs.isEmpty
          ? Text('No jobs linked to this customer yet.',
              style: GoogleFonts.nunito(color: Colors.grey[600], fontSize: 13))
          : Column(
              children: _jobs.map((j) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(Icons.work_outline, size: 18, color: kBrandGreen.withValues(alpha: 0.7)),
                    title: Text(j.jobTypeLabel,
                        style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text(j.statusLabel,
                        style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[600])),
                    trailing: Text(j.dateRequested != null ? formatDate(j.dateRequested) : '',
                        style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[500])),
                  )).toList(),
            ),
    );
  }

  Widget _liftsCard() {
    return _CardSection(
      title: 'Equipment (${_lifts.length})',
      child: _lifts.isEmpty
          ? Text('No lifts linked to this customer yet.',
              style: GoogleFonts.nunito(color: Colors.grey[600], fontSize: 13))
          : Column(
              children: _lifts.map((l) {
                final label = [l.brand, l.series, l.orientation]
                    .where((s) => s.isNotEmpty && s != 'N/A')
                    .join(' ');
                final warrantySuffix = l.warrantyExpiry.isNotEmpty
                    ? l.isWarrantyActive ? '  •  Warranty active' : '  •  Warranty expired'
                    : '';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.stairs_rounded, size: 18, color: kBrandGreen.withValues(alpha: 0.7)),
                  title: Text(label.isEmpty ? 'Unknown lift' : label,
                      style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${l.status}${l.installDate.isNotEmpty ? '  •  Installed ${l.installDate}' : ''}$warrantySuffix',
                    style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[600]),
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _serviceCard() {
    return _CardSection(
      title: 'Service History (${_service.length})',
      child: _service.isEmpty
          ? Text('No service records.',
              style: GoogleFonts.nunito(color: Colors.grey[600], fontSize: 13))
          : Column(
              children: _service.take(8).map((s) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(Icons.build_outlined, size: 16, color: Colors.orange[700]),
                    title: Text(s.serviceType,
                        style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      '${s.serviceDate != null ? formatDate(s.serviceDate) : ''}${s.technicianName.isNotEmpty ? '  •  ${s.technicianName}' : ''}',
                      style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[600]),
                    ),
                  )).toList(),
            ),
    );
  }

  Widget _notesCard() {
    return _CardSection(
      title: 'Notes',
      child: Text(_customer.notes, style: GoogleFonts.nunito(fontSize: 13, color: Colors.black87)),
    );
  }
}

// ---------------------------------------------------------------------------
// FORM SCREEN
// ---------------------------------------------------------------------------

class CustomerFormScreen extends StatefulWidget {
  final CustomerRecord? existing;
  const CustomerFormScreen({super.key, this.existing});

  @override
  State<CustomerFormScreen> createState() => _CustomerFormScreenState();
}

class _CustomerFormScreenState extends State<CustomerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  String _fundingSource = 'Private';
  CustomerLifecycleStatus _lifecycleStatus = CustomerLifecycleStatus.newLead;

  final _nameCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _qbCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  bool get _isEdit => widget.existing != null && widget.existing!.customerId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _nameCtrl.text = e.name;
      _addressCtrl.text = e.address;
      _phoneCtrl.text = e.phone;
      _emailCtrl.text = e.email;
      _qbCtrl.text = e.qbCustomerId;
      _notesCtrl.text = e.notes;
      _fundingSource = e.fundingSource;
      _lifecycleStatus = e.lifecycleStatus;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _qbCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final address = _addressCtrl.text.trim();
      final record = CustomerRecord(
        customerId: widget.existing?.customerId ?? '',
        name: _nameCtrl.text.trim(),
        address: address,
        city: extractCity(address),
        phone: _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        fundingSource: _fundingSource,
        qbCustomerId: _qbCtrl.text.trim(),
        notes: _notesCtrl.text.trim(),
        lifecycleStatus: _lifecycleStatus,
        annualDueDate: widget.existing?.annualDueDate,
        lastContactAt: widget.existing?.lastContactAt,
      );
      await sbUpsertCustomer(record);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
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
        title: Text(_isEdit ? 'Edit Customer' : 'Add Customer',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field(_nameCtrl, 'Name *', required: true),
            const SizedBox(height: 12),
            _field(_addressCtrl, 'Address', hint: '123 Main St, Needham, MA 02492'),
            const SizedBox(height: 12),
            _field(_phoneCtrl, 'Phone', keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            _field(_emailCtrl, 'Email', keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 12),
            DropdownButtonFormField<CustomerLifecycleStatus>(
              value: _lifecycleStatus,
              decoration: const InputDecoration(labelText: 'Lifecycle Status', border: OutlineInputBorder()),
              items: kLifecycleOrder
                  .map((s) => DropdownMenuItem(value: s, child: Text(customerLifecycleLabel(s))))
                  .toList(),
              onChanged: (v) => setState(() => _lifecycleStatus = v ?? CustomerLifecycleStatus.newLead),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _fundingSource,
              decoration: const InputDecoration(labelText: 'Funding Source', border: OutlineInputBorder()),
              items: kFundingSources.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
              onChanged: (v) => setState(() => _fundingSource = v ?? 'Private'),
            ),
            const SizedBox(height: 12),
            _QbLinkField(ctrl: _qbCtrl, onFill: (qb) {
              _nameCtrl.text = _nameCtrl.text.isEmpty ? qb.name : _nameCtrl.text;
              _phoneCtrl.text = _phoneCtrl.text.isEmpty ? qb.phone : _phoneCtrl.text;
              _emailCtrl.text = _emailCtrl.text.isEmpty ? qb.email : _emailCtrl.text;
              _addressCtrl.text = _addressCtrl.text.isEmpty ? qb.address : _addressCtrl.text;
            }),
            const SizedBox(height: 12),
            _field(_notesCtrl, 'Notes', maxLines: 3),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kBrandGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _saving
                    ? const SizedBox(height: 18, width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(_isEdit ? 'Save Changes' : 'Add Customer',
                        style: GoogleFonts.nunito(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label,
      {bool required = false, int maxLines = 1, TextInputType? keyboardType, String? hint}) {
    return TextFormField(
      controller: ctrl,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
      validator: required ? (v) => v == null || v.trim().isEmpty ? 'Required' : null : null,
    );
  }
}

// ---------------------------------------------------------------------------
// QB LINK FIELD — search QB for a customer and fill in the ID
// ---------------------------------------------------------------------------

class _QbLinkField extends StatefulWidget {
  final TextEditingController ctrl;
  final void Function(QbCustomer) onFill;
  const _QbLinkField({required this.ctrl, required this.onFill});

  @override
  State<_QbLinkField> createState() => _QbLinkFieldState();
}

class _QbLinkFieldState extends State<_QbLinkField> {
  final _searchCtrl = TextEditingController();
  List<QbCustomer> _results = [];
  bool _searching = false;
  bool _expanded = false;
  String? _error;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.length < 2) return;
    setState(() { _searching = true; _error = null; _results = []; });
    try {
      final results = await QuickBooksService.searchCustomers(q);
      if (mounted) setState(() { _results = results; _searching = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _searching = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final linked = widget.ctrl.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: TextFormField(
              controller: widget.ctrl,
              decoration: InputDecoration(
                labelText: 'QuickBooks Customer ID',
                hintText: linked ? null : 'Not linked',
                border: const OutlineInputBorder(),
                suffixIcon: linked ? Icon(Icons.check_circle, color: Colors.green[600], size: 18) : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.search, size: 16),
            label: Text(_expanded ? 'Close' : 'Find in QB', style: GoogleFonts.nunito(fontSize: 12)),
            onPressed: () => setState(() {
              _expanded = !_expanded;
              if (!_expanded) { _results = []; _error = null; }
            }),
          ),
        ]),
        if (_expanded) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Search QB by name…',
                  hintStyle: GoogleFonts.nunito(fontSize: 13),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                style: GoogleFonts.nunito(fontSize: 13),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: kBrandGreen, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
              onPressed: _searching ? null : _search,
              child: _searching
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.search, size: 18),
            ),
          ]),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: GoogleFonts.nunito(color: Colors.red[700], fontSize: 12)),
            ),
          if (_results.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
                color: Colors.white,
              ),
              child: Column(
                children: _results.map((qb) => ListTile(
                      dense: true,
                      title: Text(qb.name, style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 13)),
                      subtitle: qb.phone.isNotEmpty || qb.address.isNotEmpty
                          ? Text([qb.phone, qb.address].where((s) => s.isNotEmpty).join(' · '),
                              style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[600]))
                          : null,
                      trailing: const Icon(Icons.link, size: 16),
                      onTap: () {
                        widget.ctrl.text = qb.id;
                        widget.onFill(qb);
                        setState(() { _expanded = false; _results = []; _searchCtrl.clear(); });
                      },
                    )).toList(),
              ),
            ),
          if (_results.isEmpty && !_searching && _searchCtrl.text.isNotEmpty && _error == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('No QB customers found.', style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600])),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// SHARED WIDGETS
// ---------------------------------------------------------------------------

class _LifecycleChip extends StatelessWidget {
  final CustomerLifecycleStatus status;
  const _LifecycleChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = customerLifecycleColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(customerLifecycleLabel(status),
          style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w800, color: color)),
    );
  }
}

class _CardSection extends StatelessWidget {
  final String title;
  final Widget child;
  const _CardSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kCardSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w800, color: Colors.black87)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onTap;
  final Color? actionColor;
  const _Row({required this.icon, required this.text, this.onTap, this.actionColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Row(children: [
          Icon(icon, size: 16, color: actionColor ?? Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: GoogleFonts.nunito(
                  fontSize: 13,
                  color: actionColor ?? Colors.black87,
                  decoration: onTap != null ? TextDecoration.underline : null,
                )),
          ),
        ]),
      ),
    );
  }
}
