// lib/screens/documents_screen.dart
//
// Shared document repository — admin-managed, visible to all roles.
// Admins can upload PDFs/images; everyone can view and print.
// Files are stored in the Supabase 'documents' storage bucket.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../supabase_api.dart';
import '../auth/auth.dart';
import '../utils/utils.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  List<DocRecord> _docs = [];
  List<DocRecord> _filtered = [];
  bool _loading = true;
  bool _uploading = false;
  String? _error;
  final _searchCtrl = TextEditingController();

  bool get _isAdmin =>
      AuthService.instance.profile?.canSeeSettings == true;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(() => _applyFilter());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final docs = await sbFetchDocs();
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _applyFilter();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  void _applyFilter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _docs
          : _docs.where((d) => d.name.toLowerCase().contains(q)).toList();
    });
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx', 'xls', 'xlsx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() => _uploading = true);
    int uploaded = 0;
    try {
      for (final file in result.files) {
        if (file.bytes == null) continue;
        final mime = _mimeFor(file.extension ?? '');
        await sbUploadDoc(
          fileName: file.name,
          bytes: file.bytes!,
          contentType: mime,
        );
        uploaded++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(uploaded == 1
              ? '1 document uploaded.'
              : '$uploaded documents uploaded.'),
        ));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _delete(DocRecord doc) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${doc.name}"?',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        content: Text('This cannot be undone.', style: GoogleFonts.nunito()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await sbDeleteDoc(doc.path);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  String _mimeFor(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf': return 'application/pdf';
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'png': return 'image/png';
      case 'doc': return 'application/msword';
      case 'docx': return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls': return 'application/vnd.ms-excel';
      case 'xlsx': return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      default: return 'application/octet-stream';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Documents', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
          if (_uploading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(child: SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))),
            )
          else if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: _upload,
              tooltip: 'Upload document',
            ),
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
                hintText: 'Search documents…',
                hintStyle: GoogleFonts.nunito(fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchCtrl.text.isNotEmpty
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
          Expanded(
            child: _loading
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
                    : _filtered.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.folder_open_outlined,
                                    size: 48,
                                    color: kBrandGreen.withValues(alpha: 0.35)),
                                const SizedBox(height: 12),
                                Text(
                                  _docs.isEmpty
                                      ? 'No documents yet.'
                                      : 'No documents match your search.',
                                  style: GoogleFonts.nunito(
                                      color: Colors.grey[600], fontSize: 14),
                                ),
                                if (_docs.isEmpty && _isAdmin) ...[
                                  const SizedBox(height: 16),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                        backgroundColor: kBrandGreen,
                                        foregroundColor: Colors.white),
                                    icon: const Icon(Icons.upload_file_outlined),
                                    label: Text('Upload first document',
                                        style: GoogleFonts.nunito()),
                                    onPressed: _upload,
                                  ),
                                ],
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 40),
                            itemCount: _filtered.length,
                            itemBuilder: (_, i) => _DocTile(
                              doc: _filtered[i],
                              isAdmin: _isAdmin,
                              onDelete: () => _delete(_filtered[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Doc tile
// ---------------------------------------------------------------------------

class _DocTile extends StatelessWidget {
  final DocRecord doc;
  final bool isAdmin;
  final VoidCallback onDelete;

  const _DocTile({
    required this.doc,
    required this.isAdmin,
    required this.onDelete,
  });

  IconData _iconFor(String ext) {
    switch (ext) {
      case 'pdf': return Icons.picture_as_pdf_outlined;
      case 'jpg':
      case 'jpeg':
      case 'png': return Icons.image_outlined;
      case 'doc':
      case 'docx': return Icons.description_outlined;
      case 'xls':
      case 'xlsx': return Icons.table_chart_outlined;
      default: return Icons.insert_drive_file_outlined;
    }
  }

  Color _colorFor(String ext) {
    switch (ext) {
      case 'pdf': return Colors.red[700]!;
      case 'jpg':
      case 'jpeg':
      case 'png': return Colors.teal[700]!;
      case 'doc':
      case 'docx': return Colors.blue[700]!;
      case 'xls':
      case 'xlsx': return Colors.green[700]!;
      default: return Colors.grey[600]!;
    }
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    final ext = doc.extension;
    final color = _colorFor(ext);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => launchUrl(Uri.parse(doc.url),
            mode: LaunchMode.externalApplication),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(_iconFor(ext), size: 22, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doc.fileName,
                      style: GoogleFonts.nunito(
                          fontSize: 14, fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (doc.folderName != null)
                          Text('${doc.folderName}  ·  ',
                              style: GoogleFonts.nunito(
                                  fontSize: 11,
                                  color: kBrandGreen.withValues(alpha: 0.7),
                                  fontWeight: FontWeight.w600)),
                        if (doc.sizeBytes > 0)
                          Text(_sizeLabel(doc.sizeBytes),
                              style: GoogleFonts.nunito(
                                  fontSize: 11, color: Colors.grey[500])),
                        if (doc.sizeBytes > 0 && doc.updatedAt != null)
                          Text('  ·  ',
                              style: GoogleFonts.nunito(
                                  fontSize: 11, color: Colors.grey[400])),
                        if (doc.updatedAt != null)
                          Text(
                            _formatDate(doc.updatedAt!),
                            style: GoogleFonts.nunito(
                                fontSize: 11, color: Colors.grey[500]),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              // Open externally
              IconButton(
                icon: const Icon(Icons.open_in_new, size: 18),
                color: kBrandGreen,
                tooltip: 'Open',
                onPressed: () => launchUrl(Uri.parse(doc.url),
                    mode: LaunchMode.externalApplication),
              ),
              if (isAdmin)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  color: Colors.red[400],
                  tooltip: 'Delete',
                  onPressed: onDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.month}/${local.day}/${local.year}';
  }
}
