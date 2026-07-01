// lib/screens/bin_whiteboard_screen.dart
//
// Digital Bin Whiteboard — replaces the physical whiteboard in the shop
// showing which lift is in which bin. Read from lifts table filtered to
// lifts that have a bin number set.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/models.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';

class BinWhiteboardScreen extends StatefulWidget {
  const BinWhiteboardScreen({super.key});

  @override
  State<BinWhiteboardScreen> createState() => _BinWhiteboardScreenState();
}

class _BinWhiteboardScreenState extends State<BinWhiteboardScreen> {
  List<LiftRecord> _lifts = [];
  bool _loading = true;
  String? _error;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final all = await sbFetchLifts();
      if (!mounted) return;
      setState(() {
        // Only show lifts that have a bin number assigned
        _lifts = all.where((l) => l.binNumber.isNotEmpty).toList()
          ..sort((a, b) => _binSort(a.binNumber, b.binNumber));
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  int _binSort(String a, String b) {
    // Extract numeric part for natural sort: "Bin 3" < "Bin 12"
    final aNum = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 9999;
    final bNum = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 9999;
    if (aNum != bNum) return aNum.compareTo(bNum);
    return a.compareTo(b);
  }

  List<LiftRecord> get _filtered {
    if (_search.trim().isEmpty) return _lifts;
    final q = _search.toLowerCase();
    return _lifts.where((l) =>
        l.binNumber.toLowerCase().contains(q) ||
        l.brand.toLowerCase().contains(q) ||
        l.series.toLowerCase().contains(q) ||
        l.serialNumber.toLowerCase().contains(q) ||
        l.condition.toLowerCase().contains(q)).toList();
  }

  /// Group lifts by normalized bin number.
  Map<String, List<LiftRecord>> get _byBin {
    final map = <String, List<LiftRecord>>{};
    for (final l in _filtered) {
      final key = normalizeBinDisplay(l.binNumber);
      map.putIfAbsent(key, () => []).add(l);
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Bin Whiteboard',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              onChanged: (v) => setState(() => _search = v),
              style: GoogleFonts.nunito(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search bin, brand, serial…',
                hintStyle: GoogleFonts.nunito(color: Colors.white60, fontSize: 13),
                prefixIcon: const Icon(Icons.search, color: Colors.white60),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Error: $_error'),
                    const SizedBox(height: 12),
                    ElevatedButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ))
              : _filtered.isEmpty
                  ? Center(
                      child: Text(
                        _lifts.isEmpty
                            ? 'No lifts with bin numbers assigned.'
                            : 'No results.',
                        style: GoogleFonts.nunito(color: Colors.grey[600]),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _buildList(),
                    ),
    );
  }

  Widget _buildList() {
    final bins = _byBin;
    // Sort bin keys numerically
    final sortedKeys = bins.keys.toList()
      ..sort((a, b) => _binSort(a, b));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
      itemCount: sortedKeys.length,
      itemBuilder: (ctx, i) {
        final binLabel = sortedKeys[i];
        final lifts = bins[binLabel]!;
        return _BinCard(binLabel: binLabel, lifts: lifts);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// BIN CARD
// ---------------------------------------------------------------------------

class _BinCard extends StatelessWidget {
  final String binLabel;
  final List<LiftRecord> lifts;
  const _BinCard({required this.binLabel, required this.lifts});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Bin header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: kBrandGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.inbox_outlined, size: 14, color: kBrandGreen),
                      const SizedBox(width: 5),
                      Text(binLabel,
                          style: GoogleFonts.nunito(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: kBrandGreen,
                          )),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text('${lifts.length} lift${lifts.length == 1 ? '' : 's'}',
                    style: GoogleFonts.nunito(
                        fontSize: 12, color: Colors.grey[600])),
              ],
            ),
            const SizedBox(height: 10),
            // Lifts in this bin
            ...lifts.map((l) => _LiftRow(lift: l)),
          ],
        ),
      ),
    );
  }
}

class _LiftRow extends StatelessWidget {
  final LiftRecord lift;
  const _LiftRow({required this.lift});

  @override
  Widget build(BuildContext context) {
    final label = [lift.brand, lift.series]
        .where((s) => s.isNotEmpty)
        .join(' ');
    final orientation = lift.orientation.isNotEmpty && lift.orientation != 'N/A'
        ? lift.orientation
        : '';
    final conditionColor = lift.condition.toLowerCase().contains('new')
        ? Colors.green[700]!
        : Colors.blueGrey[600]!;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [label, if (orientation.isNotEmpty) orientation].join(' '),
                  style: GoogleFonts.nunito(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
                if (lift.serialNumber.isNotEmpty)
                  Text('SN: ${lift.serialNumber}',
                      style: GoogleFonts.nunito(
                          fontSize: 12, color: Colors.grey[600])),
              ],
            ),
          ),
          // Condition pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: conditionColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(lift.condition,
                style: GoogleFonts.nunito(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: conditionColor,
                )),
          ),
          const SizedBox(width: 6),
          // Prep status pill
          if (lift.preppedStatus.isNotEmpty &&
              lift.preppedStatus != 'Not applicable')
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _prepColor(lift.preppedStatus).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_prepLabel(lift.preppedStatus),
                  style: GoogleFonts.nunito(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _prepColor(lift.preppedStatus),
                  )),
            ),
        ],
      ),
    );
  }

  Color _prepColor(String s) {
    if (s == 'Prepped') return Colors.green[700]!;
    if (s == 'Needs repair') return Colors.red[700]!;
    return Colors.orange[700]!;
  }

  String _prepLabel(String s) {
    if (s == 'Needs prepping') return 'Needs Prep';
    if (s == 'Needs repair') return 'Needs Repair';
    return s;
  }
}
