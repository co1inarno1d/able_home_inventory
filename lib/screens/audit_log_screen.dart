// lib/screens/audit_log_screen.dart
//
// Admin-only global audit feed — every lift_history event across the app,
// most recent first. Shows who did what and when.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/models.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';

class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  List<LiftHistoryEvent> _events = [];
  List<LiftHistoryEvent> _filtered = [];
  bool _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() {
      setState(() {
        _search = _searchCtrl.text.trim().toLowerCase();
        _applyFilter();
      });
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final events = await sbFetchAuditLog(limit: 500);
      if (!mounted) return;
      setState(() {
        _events = events;
        _applyFilter();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  void _applyFilter() {
    if (_search.isEmpty) {
      _filtered = _events;
      return;
    }
    _filtered = _events.where((e) =>
      e.userName.toLowerCase().contains(_search) ||
      e.userEmail.toLowerCase().contains(_search) ||
      e.serialNumber.toLowerCase().contains(_search) ||
      e.eventType.toLowerCase().contains(_search) ||
      e.status.toLowerCase().contains(_search) ||
      e.note.toLowerCase().contains(_search) ||
      e.location.toLowerCase().contains(_search),
    ).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Audit Log', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by person, serial number, action…',
                hintStyle: GoogleFonts.nunito(fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _search.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () => _searchCtrl.clear(),
                      )
                    : null,
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              style: GoogleFonts.nunito(fontSize: 13),
            ),
          ),
          if (!_loading && !_filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 14, bottom: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_filtered.length} event${_filtered.length == 1 ? '' : 's'}',
                  style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[500]),
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Error: $_error', style: GoogleFonts.nunito(color: Colors.red)),
                            const SizedBox(height: 12),
                            ElevatedButton(onPressed: _load, child: const Text('Retry')),
                          ],
                        ),
                      )
                    : _filtered.isEmpty
                        ? Center(
                            child: Text('No events found.',
                                style: GoogleFonts.nunito(color: Colors.grey[600], fontSize: 14)),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 40),
                            itemCount: _filtered.length,
                            itemBuilder: (_, i) => _AuditEventTile(event: _filtered[i]),
                          ),
          ),
        ],
      ),
    );
  }
}

class _AuditEventTile extends StatelessWidget {
  final LiftHistoryEvent event;
  const _AuditEventTile({required this.event});

  Color _typeColor(String type) {
    switch (type.toLowerCase()) {
      case 'created': return Colors.green[700]!;
      case 'deleted': return Colors.red[700]!;
      case 'status change': return Colors.indigo[700]!;
      default: return Colors.grey[600]!;
    }
  }

  IconData _typeIcon(String type) {
    switch (type.toLowerCase()) {
      case 'created': return Icons.add_circle_outline;
      case 'deleted': return Icons.delete_outline;
      case 'status change': return Icons.swap_horiz_rounded;
      default: return Icons.edit_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final who = event.userName.isNotEmpty ? event.userName : event.userEmail;
    final type = event.eventType.isNotEmpty ? event.eventType : 'Updated';
    final color = _typeColor(type);

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.13)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Type icon
            Container(
              margin: const EdgeInsets.only(top: 1, right: 10),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_typeIcon(type), size: 16, color: color),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Event type + serial
                  Row(
                    children: [
                      Text(type,
                          style: GoogleFonts.nunito(
                              fontSize: 12, fontWeight: FontWeight.w700, color: color)),
                      if (event.serialNumber.isNotEmpty) ...[
                        Text('  ·  ', style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[400])),
                        Text('SN ${event.serialNumber}',
                            style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[700])),
                      ],
                      const Spacer(),
                      if (event.timestamp != null)
                        Text(
                          _formatTs(event.timestamp!),
                          style: GoogleFonts.nunito(fontSize: 10, color: Colors.grey[500]),
                        ),
                    ],
                  ),
                  if (event.status.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      event.status,
                      style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ],
                  if (event.note.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      event.note,
                      style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (who.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.person_outline, size: 12, color: Colors.grey[500]),
                        const SizedBox(width: 3),
                        Text(who,
                            style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[500])),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTs(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${local.month}/${local.day}/${local.year}';
  }
}
