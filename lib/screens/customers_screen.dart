// lib/screens/customers_screen.dart
//
// Customer Profiles — in-app customer records with full lift/service history,
// warranty status, and a deep-link to QuickBooks Online.
//
// Customers are stored in the `customers` Supabase table.
// Lifts are linked via customer_id on the lifts table (or by address match
// for legacy records that predate this feature).

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../integrations/quickbooks_service.dart';
import '../models/models.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';

// ---------------------------------------------------------------------------
// LIST SCREEN — live QB search
// ---------------------------------------------------------------------------

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  List<QbCustomer> _results = [];
  bool _loading = false;
  bool _qbConnected = true; // optimistic; set false on 401
  String? _error;
  final _searchCtrl = TextEditingController();
  String _lastQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q == _lastQuery) return;
    _lastQuery = q;
    if (q.isEmpty) {
      setState(() { _results = []; _error = null; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final results = await QuickBooksService.searchCustomers(q);
      if (!mounted || _lastQuery != q) return;
      setState(() { _results = results; _loading = false; });
    } on QbNotConnectedException {
      if (!mounted) return;
      setState(() { _loading = false; _qbConnected = false; });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  void _openDetail(QbCustomer qb) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CustomerDetailScreen.fromQb(qb)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Customers', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => _search(v),
              style: GoogleFonts.nunito(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search QuickBooks customers…',
                hintStyle: GoogleFonts.nunito(color: Colors.white60, fontSize: 13),
                prefixIcon: const Icon(Icons.search, color: Colors.white60),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white60, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _search('');
                        },
                      )
                    : null,
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
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_qbConnected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_off, size: 48, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                'QuickBooks not connected',
                style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Connect QuickBooks in the Account menu (top-right) to search customers.',
                style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[600]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Error: $_error', style: GoogleFonts.nunito(color: Colors.red[700])),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _search(_searchCtrl.text),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_searchCtrl.text.trim().isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 48, color: kBrandGreen.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text(
              'Search your QuickBooks customers above.',
              style: GoogleFonts.nunito(color: Colors.grey[600], fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Text('No customers found in QuickBooks.',
            style: GoogleFonts.nunito(color: Colors.grey[600])),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final qb = _results[i];
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
            onTap: () => _openDetail(qb),
            leading: CircleAvatar(
              backgroundColor: kBrandGreen.withValues(alpha: 0.12),
              child: Text(
                qb.name.isNotEmpty ? qb.name[0].toUpperCase() : '?',
                style: GoogleFonts.nunito(fontWeight: FontWeight.w700, color: kBrandGreen),
              ),
            ),
            title: Text(qb.name,
                style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 15)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (qb.phone.isNotEmpty)
                  Text(qb.phone,
                      style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600])),
                if (qb.address.isNotEmpty)
                  Text(qb.address,
                      style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[500]),
                      overflow: TextOverflow.ellipsis),
              ],
            ),
            trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// DETAIL SCREEN
// ---------------------------------------------------------------------------

class CustomerDetailScreen extends StatefulWidget {
  final CustomerRecord customer;
  const CustomerDetailScreen({super.key, required this.customer});

  /// Build from a live QB customer — no local Supabase record needed.
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _customer = widget.customer;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        sbFetchLiftsForCustomer(_customer.customerId),
        sbFetchServiceForCustomer(_customer.customerId),
      ]);
      if (!mounted) return;
      setState(() {
        _lifts = results[0] as List<LiftRecord>;
        _service = results[1] as List<LiftServiceRecord>;
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
    await launchUrl(Uri.parse('tel:${_customer.phone}'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text(_customer.name,
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Edit',
            onPressed: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                    builder: (_) => CustomerFormScreen(existing: _customer)),
              );
              if (saved == true && mounted) {
                Navigator.of(context).pop(true);
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
                _contactCard(),
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
    );
  }

  Widget _contactCard() {
    return _CardSection(
      title: 'Contact',
      child: Column(
        children: [
          if (_customer.address.isNotEmpty)
            _Row(icon: Icons.location_on_outlined, text: _customer.address),
          if (_customer.phone.isNotEmpty)
            _Row(
              icon: Icons.phone_outlined,
              text: _customer.phone,
              onTap: _callPhone,
              actionColor: kBrandGreen,
            ),
          if (_customer.email.isNotEmpty)
            _Row(icon: Icons.email_outlined, text: _customer.email),
          if (_customer.fundingSource != 'Private')
            _Row(
              icon: Icons.account_balance_outlined,
              text: _customer.fundingSource,
              actionColor: Colors.indigo[700],
            ),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.open_in_new, size: 15, color: kBrandGreen),
                    const SizedBox(width: 7),
                    Text('View in QuickBooks',
                        style: GoogleFonts.nunito(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: kBrandGreen)),
                  ],
                ),
              ),
            ),
          ],
        ],
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
                    ? l.isWarrantyActive
                        ? '  •  Warranty active'
                        : '  •  Warranty expired'
                    : '';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.stairs_rounded,
                      size: 18, color: kBrandGreen.withValues(alpha: 0.7)),
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
                leading: Icon(Icons.build_outlined,
                    size: 16, color: Colors.orange[700]),
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
      child: Text(_customer.notes,
          style: GoogleFonts.nunito(fontSize: 13, color: Colors.black87)),
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

  final _nameCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _qbCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  bool get _isEdit => widget.existing != null;

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
      );
      await sbUpsertCustomer(record);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
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
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: widget.ctrl,
                decoration: InputDecoration(
                  labelText: 'QuickBooks Customer ID',
                  hintText: linked ? null : 'Not linked',
                  border: const OutlineInputBorder(),
                  suffixIcon: linked
                      ? Icon(Icons.check_circle, color: Colors.green[600], size: 18)
                      : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.search, size: 16),
              label: Text(_expanded ? 'Close' : 'Find in QB',
                  style: GoogleFonts.nunito(fontSize: 12)),
              onPressed: () => setState(() {
                _expanded = !_expanded;
                if (!_expanded) { _results = []; _error = null; }
              }),
            ),
          ],
        ),
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
// SHARED CARD WIDGETS
// ---------------------------------------------------------------------------

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
              style: GoogleFonts.nunito(
                  fontSize: 13, fontWeight: FontWeight.w800, color: Colors.black87)),
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
        child: Row(
          children: [
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
          ],
        ),
      ),
    );
  }
}
