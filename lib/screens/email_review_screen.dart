// lib/screens/email_review_screen.dart
//
// Email Review Queue — surfaces agency emails that the scan-agency-emails Edge
// Function flagged for manual review (either unrecognised sender or no matching
// ops_job found). Colin can dismiss them (already handled externally) or
// advance the matching job manually.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/models.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';
import 'operations_hub_screen.dart';

class EmailReviewScreen extends StatefulWidget {
  const EmailReviewScreen({super.key});

  @override
  State<EmailReviewScreen> createState() => _EmailReviewScreenState();
}

class _EmailReviewScreenState extends State<EmailReviewScreen> {
  List<EmailQueueItem> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final items = await sbFetchEmailQueue();
      if (!mounted) return;
      setState(() { _items = items; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _dismiss(EmailQueueItem item) async {
    await sbDismissEmailQueueItem(item.key);
    if (mounted) _load();
  }

  Future<void> _createJob(EmailQueueItem item) async {
    // Pre-fill an ops job with info extracted from the email
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => OpsJobFormScreen(
          existing: OpsJob(
            jobId: '',
            jobType: OpsJobType.stairliftInstall,
            status: item.fundingSource != null
                ? OpsJobStatus.waitingAgencyConfirmation
                : OpsJobStatus.needsInfo,
            customerName: item.customerName ?? '',
            address: '',
            city: '',
            phone: '',
            liftType: '',
            fundingSource: item.fundingSource ?? 'Private',
            notes: 'From agency email — ${item.subject}\n${item.snippet}',
            dateRequested: item.scannedAt ?? DateTime.now(),
            sourceTable: 'ops_jobs',
            sourceId: '',
          ),
        ),
      ),
    );
    if (saved == true && mounted) {
      // Remove from queue once a job is created
      await sbDismissEmailQueueItem(item.key);
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
        title: Text('Email Review Queue',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
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
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Error: $_error',
                          style: GoogleFonts.nunito(color: Colors.red)),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : _items.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.mark_email_read_outlined,
                              size: 48, color: kBrandGreen.withValues(alpha: 0.4)),
                          const SizedBox(height: 12),
                          Text('No emails pending review.',
                              style: GoogleFonts.nunito(
                                  color: Colors.grey[600], fontSize: 15)),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
                        itemCount: _items.length,
                        itemBuilder: (_, i) =>
                            _EmailCard(item: _items[i], onDismiss: _dismiss, onCreateJob: _createJob),
                      ),
                    ),
    );
  }
}

class _EmailCard extends StatelessWidget {
  final EmailQueueItem item;
  final Future<void> Function(EmailQueueItem) onDismiss;
  final Future<void> Function(EmailQueueItem) onCreateJob;

  const _EmailCard({
    required this.item,
    required this.onDismiss,
    required this.onCreateJob,
  });

  @override
  Widget build(BuildContext context) {
    final isUnmatched = item.key.startsWith('email_unmatched_');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isUnmatched
              ? Colors.orange.withValues(alpha: 0.4)
              : Colors.grey.withValues(alpha: 0.2),
          width: isUnmatched ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (isUnmatched ? Colors.orange[700]! : Colors.blue[700]!)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isUnmatched ? 'No Job Match' : 'Needs Review',
                    style: GoogleFonts.nunito(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isUnmatched ? Colors.orange[700] : Colors.blue[700],
                    ),
                  ),
                ),
                if (item.fundingSource != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.indigo[700]!.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      item.fundingSource!,
                      style: GoogleFonts.nunito(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.indigo[700],
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                if (item.scannedAt != null)
                  Text(
                    formatDate(item.scannedAt),
                    style: GoogleFonts.nunito(fontSize: 11, color: Colors.grey[500]),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // From
            Text(
              item.from,
              style: GoogleFonts.nunito(
                  fontSize: 12, color: Colors.grey[600]),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            // Subject
            Text(
              item.subject.isNotEmpty ? item.subject : '(no subject)',
              style: GoogleFonts.nunito(
                  fontSize: 14, fontWeight: FontWeight.w700, color: Colors.black87),
            ),
            if (item.snippet.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                item.snippet,
                style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600]),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (item.customerName != null && item.customerName!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.person_outline, size: 13, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Text(item.customerName!,
                      style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[700])),
                ],
              ),
            ],
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            // Action row
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => onDismiss(item),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey[600],
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text('Dismiss',
                      style: GoogleFonts.nunito(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => onCreateJob(item),
                  style: TextButton.styleFrom(
                    foregroundColor: kBrandGreen,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Create Job',
                          style: GoogleFonts.nunito(
                              fontSize: 12, fontWeight: FontWeight.w700)),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 11),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
