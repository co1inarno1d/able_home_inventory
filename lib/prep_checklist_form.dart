import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';
import 'supabase_api.dart';

/// =======================
/// PREP CHECKLIST FORM SCREEN
/// =======================

class PrepChecklistFormScreen extends StatefulWidget {
  final LiftRecord lift;
  final PrepChecklist? existingChecklist;

  const PrepChecklistFormScreen({
    super.key,
    required this.lift,
    this.existingChecklist,
  });

  @override
  State<PrepChecklistFormScreen> createState() =>
      _PrepChecklistFormScreenState();
}

class _PrepChecklistFormScreenState extends State<PrepChecklistFormScreen> {
  late Future<Map<String, dynamic>> _templateFuture;
  final Map<String, bool> _checklistItems = {};
  final TextEditingController _notesController = TextEditingController();
  bool _saving = false;
  String? _savedChecklistId;

  @override
  void initState() {
    super.initState();
    _templateFuture = _loadTemplate();

    // If resuming an existing checklist, populate the values
    if (widget.existingChecklist != null) {
      _checklistItems.addAll(widget.existingChecklist!.checklistItems);
      _notesController.text = widget.existingChecklist!.notes;
      _savedChecklistId = widget.existingChecklist!.checklistId;
    }
  }

  Future<Map<String, dynamic>> _loadTemplate() async {
    return sbGetPrepChecklistTemplate(
      brand: widget.lift.brand,
      series: widget.lift.series,
    );
  }

  String _formatFieldName(String fieldName) {
    // Convert snake_case to readable text
    return fieldName
        .split('_')
        .map((word) => word[0].toUpperCase() + word.substring(1))
        .join(' ');
  }

  Future<bool> _saveChecklist({bool andClose = false}) async {
    setState(() => _saving = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final userName = prefs.getString('user_name') ?? '';
      final userEmail = prefs.getString('user_email') ?? '';

      final checklistData = {
        if (_savedChecklistId != null)
          'checklist_id': _savedChecklistId,
        'lift_id': widget.lift.liftId,
        'serial_number': widget.lift.serialNumber,
        'brand': widget.lift.brand,
        'series': widget.lift.series,
        'prep_date': '${DateTime.now().month.toString().padLeft(2, '0')}/${DateTime.now().day.toString().padLeft(2, '0')}/${DateTime.now().year}',
        'prepped_by_name': userName,
        'prepped_by_email': userEmail,
        'notes': _notesController.text.trim(),
        ..._checklistItems,
      };

      final savedId = await sbSavePrepChecklist(checklistData: checklistData);
      if (mounted) setState(() => _savedChecklistId = savedId);

      if (!mounted) return false;

      if (andClose) {
        Navigator.of(context).pop(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Progress saved')),
        );
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving checklist: $e')),
      );
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _checkAll(List<String> fields, bool value) {
    setState(() {
      for (final field in fields) {
        _checklistItems[field] = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Prep Checklist - ${widget.lift.serialNumber}'),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _templateFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error loading checklist: ${snapshot.error}'),
            );
          }

          final template = snapshot.data!;
          final fields = List<String>.from(template['fields'] ?? []);
          final checklistType = template['checklist_type'] ?? '';

          // Initialize all fields to false if not already set
          for (final field in fields) {
            _checklistItems.putIfAbsent(field, () => false);
          }

          return Column(
            children: [
              // Header info
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16.0),
                color: kBrandGreen.withAlpha(25),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${widget.lift.brand} ${widget.lift.series}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('Serial: ${widget.lift.serialNumber}'),
                    Text('Type: ${_formatFieldName(checklistType)}'),
                  ],
                ),
              ),

              // Checklist items
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16.0),
                  children: [
                    // Check All / Uncheck All
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Row(
                        children: [
                          ElevatedButton(
                            onPressed: () => _checkAll(fields, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kBrandGreen,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            ),
                            child: const Text('Check All'),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton(
                            onPressed: () => _checkAll(fields, false),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            ),
                            child: const Text('Uncheck All'),
                          ),
                        ],
                      ),
                    ),
                    ...fields.map((field) {
                      return CheckboxListTile(
                        title: Text(_formatFieldName(field)),
                        value: _checklistItems[field] ?? false,
                        onChanged: (value) {
                          setState(() {
                            _checklistItems[field] = value ?? false;
                          });
                        },
                        activeColor: kBrandGreen,
                      );
                    }),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _notesController,
                      decoration: const InputDecoration(
                        labelText: 'Notes',
                        border: OutlineInputBorder(),
                        hintText: 'Add any additional notes here...',
                      ),
                      maxLines: 3,
                    ),
                  ],
                ),
              ),

              // Save buttons
              Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving ? null : () => _saveChecklist(andClose: false),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                        ),
                        child: _saving
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Save Progress'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saving ? null : () => _saveChecklist(andClose: true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kBrandGreen,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 48),
                        ),
                        child: const Text('Save & Close'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
