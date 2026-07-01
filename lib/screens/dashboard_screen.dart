// lib/screens/dashboard_screen.dart
//
// Dashboard — real-time business metrics for Able Home Accessibility.
// Reads from existing tables; no new Supabase schema required.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../integrations/quickbooks_service.dart';
import '../models/models.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';
import 'customers_screen.dart';
import 'email_review_screen.dart';
import 'operations_hub_screen.dart';

// ---------------------------------------------------------------------------
// DATA
// ---------------------------------------------------------------------------

enum _TimeWindow { thisWeek, thisMonth, ytd }

extension _TimeWindowX on _TimeWindow {
  String get label {
    switch (this) {
      case _TimeWindow.thisWeek:  return 'This Week';
      case _TimeWindow.thisMonth: return 'This Month';
      case _TimeWindow.ytd:       return 'YTD';
    }
  }

  DateTime get start {
    final now = DateTime.now();
    switch (this) {
      case _TimeWindow.thisWeek:
        return now.subtract(Duration(days: now.weekday - 1));
      case _TimeWindow.thisMonth:
        return DateTime(now.year, now.month, 1);
      case _TimeWindow.ytd:
        return DateTime(now.year, 1, 1);
    }
  }

  DateTime get end => DateTime.now();
}

class _DashboardData {
  final List<LiftRecord> lifts;
  final List<OpsJob> opsJobs;
  final List<ServiceJobRecord> serviceJobs;
  final List<RemovalJobRecord> removalJobs;
  final List<AnnualRecord> annuals;
  final List<WebLeadRecord> webLeads;
  final InventoryData inventory;
  final Set<String> reviewDismissed;
  final int emailQueueCount;
  final Map<String, CustomerRecord> customerById;
  final QbFinancials? financials;

  _DashboardData({
    required this.lifts,
    required this.opsJobs,
    required this.serviceJobs,
    required this.removalJobs,
    required this.annuals,
    required this.webLeads,
    required this.inventory,
    required this.reviewDismissed,
    required this.emailQueueCount,
    required this.customerById,
    this.financials,
  });
}

// ---------------------------------------------------------------------------
// SCREEN
// ---------------------------------------------------------------------------

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  _DashboardData? _data;
  bool _loading = true;
  String? _error;
  _TimeWindow _window = _TimeWindow.thisMonth;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        sbFetchLifts(),
        sbFetchAllOpsJobs(includeCompleted: false),
        sbFetchServiceJobs(),
        sbFetchRemovalJobs(),
        sbFetchAnnuals(),
        sbFetchWebLeads(),
        sbFetchInventory(),
        sbFetchReviewDismissed(),
        sbFetchEmailQueue(),
        sbFetchCustomers(),
        QuickBooksService.fetchFinancials(
          start: _window.start,
          end: _window.end,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        final customers = results[9] as List<CustomerRecord>;
        _data = _DashboardData(
          lifts: results[0] as List<LiftRecord>,
          opsJobs: results[1] as List<OpsJob>,
          serviceJobs: results[2] as List<ServiceJobRecord>,
          removalJobs: results[3] as List<RemovalJobRecord>,
          annuals: results[4] as List<AnnualRecord>,
          webLeads: results[5] as List<WebLeadRecord>,
          inventory: results[6] as InventoryData,
          reviewDismissed: results[7] as Set<String>,
          emailQueueCount: (results[8] as List<EmailQueueItem>).length,
          customerById: {for (final c in customers) c.customerId: c},
          financials: results[10] as QbFinancials?,
        );
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Dashboard', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
          // Time window toggle
          PopupMenuButton<_TimeWindow>(
            initialValue: _window,
            onSelected: (w) {
              setState(() => _window = w);
              _load();
            },
            itemBuilder: (_) => _TimeWindow.values
                .map((w) => PopupMenuItem(
                      value: w,
                      child: Text(w.label, style: GoogleFonts.nunito()),
                    ))
                .toList(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_window.label,
                      style: GoogleFonts.nunito(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                  const SizedBox(width: 4),
                  const Icon(Icons.arrow_drop_down, color: Colors.white, size: 18),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorBody(error: _error!, onRetry: _load)
              : _Body(data: _data!, onRefresh: _load, window: _window),
    );
  }
}

// ---------------------------------------------------------------------------
// BODY
// ---------------------------------------------------------------------------

class _Body extends StatelessWidget {
  final _DashboardData d;
  final Future<void> Function() onRefresh;
  final _TimeWindow window;
  const _Body({required _DashboardData data, required this.onRefresh, required this.window}) : d = data;

  void _goHub(BuildContext context, {int tab = 0}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => OperationsHubScreen(initialTabIndex: tab),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 40),
        children: [
          _financialSection(),
          const SizedBox(height: 18),
          _pipelineSection(context),
          const SizedBox(height: 18),
          _inventorySection(),
          const SizedBox(height: 18),
          _liftsSection(context),
          const SizedBox(height: 18),
          _annualsSection(context),
          const SizedBox(height: 18),
          _leadsSection(context),
          const SizedBox(height: 18),
          _reviewSection(context),
        ],
      ),
    );
  }

  // ── Financial ─────────────────────────────────────────────────────────────

  Widget _financialSection() {
    final f = d.financials;
    String fmt(double? v) => v == null ? '--' : '\$${v.toStringAsFixed(0).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',')}';

    return _Section(
      title: 'Financials  ·  ${window.label}',
      icon: Icons.attach_money_rounded,
      children: [
        _StatRow(children: [
          _Stat(
            label: 'Billed',
            value: fmt(f?.billed),
            color: kBrandGreen,
          ),
          _Stat(
            label: 'Collected',
            value: fmt(f?.collected),
            color: Colors.teal[700]!,
          ),
          _Stat(
            label: 'Outstanding',
            value: fmt(f?.totalOwed),
            color: f != null && f.totalOwed > 0 ? Colors.orange[800]! : Colors.grey[600]!,
          ),
        ]),
        if (f != null && f.overdueCount > 0) ...[
          const SizedBox(height: 10),
          _AlertChip(
            label: '${f.overdueCount} overdue invoice${f.overdueCount == 1 ? '' : 's'} — check QuickBooks',
            color: Colors.red[700]!,
          ),
        ],
        if (f == null) ...[
          const SizedBox(height: 8),
          Text(
            'Connect QuickBooks in Account settings to see financial data.',
            style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[500]),
          ),
        ],
      ],
    );
  }

  // ── Pipeline ──────────────────────────────────────────────────────────────

  Widget _pipelineSection(BuildContext context) {
    final ops = d.opsJobs;

    // Count by type among active ops jobs
    int pending(OpsJobType t) => ops.where((j) => j.jobType == t && j.isActive).length;

    final installs = ops.where((j) =>
        (j.jobType == OpsJobType.stairliftInstall || j.jobType == OpsJobType.rampInstall) &&
        j.isActive).length;
    final removals = ops.where((j) =>
        (j.jobType == OpsJobType.stairliftRemoval || j.jobType == OpsJobType.rampRemoval ||
         j.jobType == OpsJobType.buyback) &&
        j.isActive).length;
    final service = pending(OpsJobType.stairliftService);
    final annuals = pending(OpsJobType.annualService);
    final leads = pending(OpsJobType.webLead);

    // Waiting agency confirmation
    final waitingConfirm = ops.where((j) =>
        j.status == OpsJobStatus.waitingAgencyConfirmation).length;

    // Aging — jobs waiting > 7 days
    final aging = ops.where((j) => j.isActive && j.daysWaiting >= 7).length;

    return _Section(
      title: 'Pipeline',
      icon: Icons.pending_actions_rounded,
      children: [
        _StatRow(children: [
          _Stat(label: 'Installs', value: '$installs', color: kBrandGreen,
              onTap: () => _goHub(context, tab: 1)),
          _Stat(label: 'Removals', value: '$removals', color: Colors.blueGrey[700]!,
              onTap: () => _goHub(context, tab: 2)),
          _Stat(label: 'Service', value: '$service', color: Colors.orange[800]!,
              onTap: () => _goHub(context, tab: 3)),
        ]),
        const SizedBox(height: 10),
        _StatRow(children: [
          _Stat(label: 'Annuals', value: '$annuals', color: Colors.blue[700]!,
              onTap: () => _goHub(context, tab: 4)),
          _Stat(label: 'Web Leads', value: '$leads', color: Colors.purple[700]!,
              onTap: () => _goHub(context, tab: 5)),
          _Stat(label: 'Waiting Confirm', value: '$waitingConfirm', color: Colors.orange[700]!,
              onTap: () => _goHub(context, tab: 0)),
        ]),
        if (aging > 0) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _goHub(context, tab: 0),
            child: _AlertChip(
              label: '$aging job${aging == 1 ? '' : 's'} waiting 7+ days',
              color: Colors.red[700]!,
            ),
          ),
        ],
        if (d.emailQueueCount > 0) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EmailReviewScreen()),
            ),
            child: _AlertChip(
              label: '${d.emailQueueCount} agency email${d.emailQueueCount == 1 ? '' : 's'} need review',
              color: Colors.indigo[700]!,
            ),
          ),
        ],
      ],
    );
  }

  // ── Inventory ─────────────────────────────────────────────────────────────

  Widget _inventorySection() {
    final lifts = d.lifts;

    final totalLifts = lifts.length;
    final installed = lifts.where((l) => l.status == 'Installed').length;
    final inStock = lifts.where((l) =>
        l.status == 'New' || l.status == 'Removed').length;
    final prepped = lifts.where((l) => l.preppedStatus == 'Prepped').length;
    final needsPrep = lifts.where((l) => l.preppedStatus == 'Needs prepping').length;
    final needsRepair = lifts.where((l) => l.preppedStatus == 'Needs repair').length;

    // Ramps below minimum
    final rampsLow = d.inventory.ramps.where((r) =>
        r.active && r.minQty > 0 && r.currentQty < r.minQty).length;
    // Stairlift items below minimum
    final stairliftsLow = d.inventory.stairlifts.where((s) =>
        s.active && s.minQty > 0 && s.currentQty < s.minQty).length;

    return _Section(
      title: 'Inventory',
      icon: Icons.inventory_2_outlined,
      children: [
        _StatRow(children: [
          _Stat(label: 'Lifts Total', value: '$totalLifts', color: Colors.grey[700]!),
          _Stat(label: 'Installed', value: '$installed', color: kBrandGreen),
          _Stat(label: 'In Stock', value: '$inStock', color: Colors.blueGrey[600]!),
        ]),
        const SizedBox(height: 10),
        _StatRow(children: [
          _Stat(label: 'Prepped', value: '$prepped', color: kBrandGreen),
          _Stat(label: 'Needs Prep', value: '$needsPrep',
              color: needsPrep > 0 ? Colors.orange[800]! : Colors.grey[600]!),
          _Stat(label: 'Needs Repair', value: '$needsRepair',
              color: needsRepair > 0 ? Colors.red[700]! : Colors.grey[600]!),
        ]),
        if (rampsLow > 0 || stairliftsLow > 0) ...[
          const SizedBox(height: 10),
          if (stairliftsLow > 0)
            _AlertChip(
              label: '$stairliftsLow stairlift item${stairliftsLow == 1 ? '' : 's'} below minimum',
              color: Colors.red[700]!,
            ),
          if (rampsLow > 0) ...[
            const SizedBox(height: 6),
            _AlertChip(
              label: '$rampsLow ramp item${rampsLow == 1 ? '' : 's'} below minimum',
              color: Colors.red[700]!,
            ),
          ],
        ],
      ],
    );
  }

  // ── Lifts Lifecycle ───────────────────────────────────────────────────────

  Widget _liftsSection(BuildContext context) {
    final lifts = d.lifts;
    final now = DateTime.now();

    // Warranty: installs with a valid install_date
    // Default warranty = 2 years from install date
    final withInstallDate = lifts.where((l) {
      if (l.installDate.isEmpty || l.status != 'Installed') return false;
      final parsed = _parseDate(l.installDate);
      return parsed != null;
    }).toList();

    final expiringSoon = withInstallDate.where((l) {
      final install = _parseDate(l.installDate)!;
      final expiry = DateTime(install.year + 2, install.month, install.day);
      final daysLeft = expiry.difference(now).inDays;
      return daysLeft >= 0 && daysLeft <= 60;
    }).length;

    final expired = withInstallDate.where((l) {
      final install = _parseDate(l.installDate)!;
      final expiry = DateTime(install.year + 2, install.month, install.day);
      return expiry.isBefore(now);
    }).length;

    // Acquisition source breakdown
    final bySource = <String, int>{};
    for (final l in lifts) {
      final src = l.acquisitionSource.isEmpty ? 'Unknown' : l.acquisitionSource;
      bySource[src] = (bySource[src] ?? 0) + 1;
    }
    // Top 3 sources
    final topSources = (bySource.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)))
        .take(3)
        .toList();

    return _Section(
      title: 'Lifts Lifecycle',
      icon: Icons.stairs_rounded,
      children: [
        _StatRow(children: [
          _Stat(
            label: 'Warranty Expiring\n(60 days)',
            value: '$expiringSoon',
            color: expiringSoon > 0 ? Colors.orange[800]! : Colors.grey[600]!,
          ),
          _Stat(
            label: 'Warranty\nExpired',
            value: '$expired',
            color: expired > 0 ? Colors.red[700]! : Colors.grey[600]!,
          ),
          _Stat(
            label: 'Installs\nTracked',
            value: '${withInstallDate.length}',
            color: Colors.grey[600]!,
          ),
        ]),
        if (topSources.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Acquisition Sources',
              style: GoogleFonts.nunito(
                  fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey[600])),
          const SizedBox(height: 6),
          ...topSources.map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(e.key,
                      style: GoogleFonts.nunito(fontSize: 13, color: Colors.black87)),
                ),
                Text('${e.value}',
                    style: GoogleFonts.nunito(
                        fontSize: 13, fontWeight: FontWeight.w700, color: kBrandGreen)),
              ],
            ),
          )),
        ],
        _buybackBlock(lifts),
      ],
    );
  }

  Widget _buybackBlock(List<LiftRecord> lifts) {
    final buybacks = lifts.where((l) =>
        l.acquisitionSource.toLowerCase() == 'buyback' && l.buybackPrice != null).toList();
    if (buybacks.isEmpty) return const SizedBox.shrink();

    final inInventory = buybacks.where((l) => l.status != 'Installed').toList();
    final installed = buybacks.where((l) => l.status == 'Installed').toList();
    final totalInvested = inInventory.fold<double>(0, (sum, l) => sum + (l.buybackPrice ?? 0));
    final totalRecouped = installed.fold<double>(0, (sum, l) => sum + (l.buybackPrice ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 12),
        Text('Buyback Inventory',
            style: GoogleFonts.nunito(
                fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey[600])),
        const SizedBox(height: 6),
        _StatRow(children: [
          _Stat(
            label: 'In Inventory',
            value: '${inInventory.length}',
            color: inInventory.isNotEmpty ? Colors.indigo[700]! : Colors.grey[600]!,
          ),
          _Stat(
            label: 'Capital\nInvested',
            value: '\$${totalInvested.toStringAsFixed(0)}',
            color: totalInvested > 0 ? Colors.orange[800]! : Colors.grey[600]!,
          ),
          _Stat(
            label: 'Installed\n(Resold)',
            value: '${installed.length}',
            color: installed.isNotEmpty ? kBrandGreen : Colors.grey[600]!,
          ),
        ]),
        if (totalRecouped > 0) ...[
          const SizedBox(height: 6),
          Text(
            'Acquisition cost on resold units: \$${totalRecouped.toStringAsFixed(0)}  •  See QB for sale prices',
            style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[500]),
          ),
        ],
      ],
    );
  }

  // ── Annuals ───────────────────────────────────────────────────────────────

  Widget _annualsSection(BuildContext context) {
    final annuals = d.annuals;
    final unscheduled = annuals.where((a) => !a.scheduled).length;
    final scheduled = annuals.where((a) => a.scheduled).length;

    return _Section(
      title: 'Annual Service',
      icon: Icons.event_repeat_outlined,
      children: [
        _StatRow(children: [
          _Stat(label: 'Pending', value: '$unscheduled',
              color: unscheduled > 0 ? Colors.orange[800]! : Colors.grey[600]!,
              onTap: () => _goHub(context, tab: 4)),
          _Stat(label: 'Scheduled', value: '$scheduled', color: kBrandGreen,
              onTap: () => _goHub(context, tab: 4)),
          _Stat(label: 'Total', value: '${annuals.length}', color: Colors.grey[600]!,
              onTap: () => _goHub(context, tab: 4)),
        ]),
      ],
    );
  }

  // ── Web Leads ─────────────────────────────────────────────────────────────

  Widget _leadsSection(BuildContext context) {
    final leads = d.webLeads;
    final newLeads = leads.where((l) => l.status.toLowerCase() == 'new').length;
    final contacted = leads.where((l) => l.status.toLowerCase() == 'contacted').length;
    final won = leads.where((l) => l.status.toLowerCase() == 'won').length;

    return _Section(
      title: 'Web Leads',
      icon: Icons.language_outlined,
      children: [
        _StatRow(children: [
          _Stat(label: 'New', value: '$newLeads',
              color: newLeads > 0 ? Colors.purple[700]! : Colors.grey[600]!,
              onTap: () => _goHub(context, tab: 5)),
          _Stat(label: 'Contacted', value: '$contacted', color: Colors.blueGrey[600]!,
              onTap: () => _goHub(context, tab: 5)),
          _Stat(label: 'Won', value: '$won', color: kBrandGreen,
              onTap: () => _goHub(context, tab: 5)),
        ]),
      ],
    );
  }

  // ── Review Requests ───────────────────────────────────────────────────────

  Widget _reviewSection(BuildContext context) {
    final now = DateTime.now();
    const reviewDays = 7;

    // Lifts installed 7-90 days ago whose review hasn't been dismissed
    final pending = d.lifts.where((l) {
      if (l.status != 'Installed' || l.installDate.isEmpty) return false;
      final install = _parseDate(l.installDate);
      if (install == null) return false;
      final days = now.difference(install).inDays;
      if (days < reviewDays || days > 90) return false;
      return !d.reviewDismissed.contains(l.liftId);
    }).toList();

    if (pending.isEmpty) return const SizedBox.shrink();

    return _Section(
      title: 'Review Requests (${pending.length})',
      icon: Icons.star_outline_rounded,
      children: [
        Text(
          'These installs are ${reviewDays}+ days old — consider reaching out for a review.',
          style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600]),
        ),
        const SizedBox(height: 10),
        ...pending.take(5).map((l) {
          final customer = l.customerId.isNotEmpty ? d.customerById[l.customerId] : null;
          final label = [l.brand, l.series].where((s) => s.isNotEmpty).join(' ');
          final displayName = customer?.name.isNotEmpty == true
              ? customer!.name
              : (l.currentLocation.isNotEmpty ? l.currentLocation : label);
          final phone = customer?.phone ?? '';
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            elevation: 0,
            color: Colors.amber.withValues(alpha: 0.05),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Colors.amber.withValues(alpha: 0.25)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: customer != null
                          ? () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => CustomerDetailScreen(customer: customer),
                              ))
                          : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(displayName,
                                  style: GoogleFonts.nunito(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: customer != null ? kBrandGreen : Colors.black87,
                                      decoration: customer != null
                                          ? TextDecoration.underline
                                          : null,
                                      decorationColor: kBrandGreen)),
                              if (customer != null)
                                const Icon(Icons.chevron_right, size: 14, color: kBrandGreen),
                            ],
                          ),
                          Text('Installed ${l.installDate}  •  $label',
                              style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[600])),
                          if (phone.isNotEmpty)
                            Text(phone,
                                style: GoogleFonts.nunito(
                                    fontSize: 11, color: Colors.grey[600])),
                        ],
                      ),
                    ),
                  ),
                  if (phone.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.phone_outlined, size: 18),
                      color: kBrandGreen,
                      tooltip: 'Call $phone',
                      onPressed: () => launchUrl(Uri.parse('tel:$phone')),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      constraints: const BoxConstraints(),
                    ),
                  TextButton(
                    onPressed: () async {
                      await sbDismissReview(l.liftId);
                      onRefresh();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.grey[600],
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text('Dismiss', style: GoogleFonts.nunito(fontSize: 12)),
                  ),
                ],
              ),
            ),
          );
        }),
        if (pending.length > 5)
          Text('+${pending.length - 5} more',
              style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600])),
      ],
    );
  }

  DateTime? _parseDate(String s) {
    if (s.isEmpty) return null;
    // Supports MM/DD/YYYY and YYYY-MM-DD
    try {
      final parts = s.contains('/') ? s.split('/') : s.split('-');
      if (s.contains('/') && parts.length == 3) {
        return DateTime(int.parse(parts[2]), int.parse(parts[0]), int.parse(parts[1]));
      } else if (parts.length == 3) {
        return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      }
    } catch (_) {}
    return null;
  }
}

// ---------------------------------------------------------------------------
// REUSABLE WIDGETS
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _Section({
    required this.title,
    required this.icon,
    required this.children,
  });

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
          Row(
            children: [
              Icon(icon, size: 17, color: kBrandGreen),
              const SizedBox(width: 7),
              Text(title,
                  style: GoogleFonts.nunito(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                    letterSpacing: 0.2,
                  )),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final List<Widget> children;
  const _StatRow({required this.children});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: children
          .expand((w) => [Expanded(child: w), const SizedBox(width: 8)])
          .take(children.length * 2 - 1)
          .toList(),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onTap;

  const _Stat({
    required this.label,
    required this.value,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(value,
              style: GoogleFonts.nunito(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: color,
                height: 1,
              )),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(label,
                    style: GoogleFonts.nunito(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                Icon(Icons.arrow_forward_ios_rounded,
                    size: 8, color: Colors.grey[400]),
              ],
            ],
          ),
        ],
      ),
    );

    if (onTap == null) return box;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: box,
    );
  }
}

class _AlertChip extends StatelessWidget {
  final String label;
  final Color color;
  const _AlertChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: GoogleFonts.nunito(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              )),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorBody({required this.error, required this.onRetry});

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
            Text('Failed to load dashboard',
                style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(error,
                style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600]),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
