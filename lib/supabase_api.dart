// lib/supabase_api.dart
//
// Supabase backend implementation — drop-in replacement for the
// Apps Script API functions in main.dart.
//
// USAGE: This file is imported by main.dart on the supabase-migration branch.
// The main branch still uses Apps Script and is unaffected.
//
// Supabase project: https://kaujczbhtajqfrjgbxft.supabase.co

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'qbt_api.dart' show QbtScheduleEvent;

import 'auth/auth.dart' show UserProfile, UserRole;
import 'models/models.dart';
import 'utils/utils.dart' show normalizeDrivePhotoUrl, extractCity;


// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------

const String _supabaseUrl = 'https://kaujczbhtajqfrjgbxft.supabase.co';
const String _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImthdWpjemJodGFqcWZyamdieGZ0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0NDI3NjYsImV4cCI6MjA4NzAxODc2Nn0.WbxeNDGKlOVEy7_2F_VBoa0oRv0JHqK1NdpP1G6LDbk';

const String _photosBucket = 'lift-photos';
const String _docsBucket = 'documents';

SupabaseClient get _sb => Supabase.instance.client;

/// Call once from main() before runApp()
Future<void> initSupabase() async {
  await Supabase.initialize(url: _supabaseUrl, anonKey: _supabaseAnonKey);
}

// ---------------------------------------------------------------------------
// INVENTORY
// ---------------------------------------------------------------------------

Future<InventoryData> sbFetchInventory() async {
  final stairliftsRaw =
      await _sb.from('inventory_stairlifts').select().order('item_id');
  final rampsRaw =
      await _sb.from('inventory_ramps').select().order('item_id');

  return InventoryData(
    stairlifts: (stairliftsRaw as List)
        .map((r) => StairliftItem.fromJson(r as Map<String, dynamic>))
        .where((s) => s.itemId.isNotEmpty)
        .toList(),
    ramps: (rampsRaw as List)
        .map((r) => RampItem.fromJson(r as Map<String, dynamic>))
        .where((r) => r.itemId.isNotEmpty)
        .toList(),
  );
}

Future<List<InventoryChange>> sbFetchChanges({int limit = 200}) async {
  final raw = await _sb
      .from('inventory_changes')
      .select()
      .order('timestamp', ascending: false)
      .limit(limit);

  return (raw as List)
      .map((r) => InventoryChange.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<void> sbSubmitFullCheck({
  required String userEmail,
  required String userName,
  required List<Map<String, dynamic>> items,
}) async {
  for (final item in items) {
    final category = item['category'] as String;
    final itemId = item['item_id'] as String;
    final newQty = item['new_qty'] as int;
    final condition = item['condition'] as String;
    final table =
        category == 'ramp' ? 'inventory_ramps' : 'inventory_stairlifts';

    // Get current qty
    final existing =
        await _sb.from(table).select('current_qty').eq('item_id', itemId).maybeSingle();
    final oldQty =
        (existing?['current_qty'] as int?) ?? 0;
    final delta = newQty - oldQty;

    // Update quantity
    await _sb
        .from(table)
        .update({'current_qty': newQty}).eq('item_id', itemId);

    // Log change
    await _sb.from('inventory_changes').insert({
      'timestamp': DateTime.now().toIso8601String(),
      'user_email': userEmail,
      'user_name': userName,
      'change_type': 'Full Check',
      'item_id': itemId,
      'brand': item['brand'] ?? '',
      'series_or_size': item['series'] ?? item['size'] ?? '',
      'orientation': item['orientation'] ?? '',
      'condition': condition,
      'old_qty': oldQty,
      'new_qty': newQty,
      'delta': delta,
      'job_ref': '',
    });
  }
}

Future<void> sbSubmitJobAdjustment({
  required String userEmail,
  required String userName,
  required String jobRef,
  required List<Map<String, dynamic>> items,
}) async {
  for (final item in items) {
    final category = item['category'] as String;
    final itemId = item['item_id'] as String;
    final delta = item['delta'] as int;
    final condition = item['condition'] as String;
    final table =
        category == 'ramp' ? 'inventory_ramps' : 'inventory_stairlifts';

    final existing =
        await _sb.from(table).select('current_qty').eq('item_id', itemId).maybeSingle();
    final oldQty = (existing?['current_qty'] as int?) ?? 0;
    final newQty = oldQty + delta;

    await _sb
        .from(table)
        .update({'current_qty': newQty}).eq('item_id', itemId);

    await _sb.from('inventory_changes').insert({
      'timestamp': DateTime.now().toIso8601String(),
      'user_email': userEmail,
      'user_name': userName,
      'change_type': delta < 0 ? 'Job Install' : 'Job Removal',
      'item_id': itemId,
      'brand': item['brand'] ?? '',
      'series_or_size': item['series'] ?? item['size'] ?? '',
      'orientation': item['orientation'] ?? '',
      'condition': condition,
      'old_qty': oldQty,
      'new_qty': newQty,
      'delta': delta,
      'job_ref': jobRef,
    });
  }
}

Future<void> sbUpdateStairliftNotes({
  required String itemId,
  required String notes,
}) async {
  await _sb
      .from('inventory_stairlifts')
      .update({'notes': notes}).eq('item_id', itemId);
}

Future<void> sbSubmitCcalsAdjustment({
  required String userEmail,
  required String userName,
  required String jobRef,
  required List<Map<String, dynamic>> items,
}) async {
  for (final item in items) {
    final itemId = item['item_id'] as String;
    final delta = item['delta'] as int;
    final condition = item['condition'] as String;

    final existing = await _sb
        .from('inventory_ramps')
        .select('ccals_qty')
        .eq('item_id', itemId)
        .maybeSingle();
    final oldQty = (existing?['ccals_qty'] as int?) ?? 0;
    final newQty = (oldQty + delta).clamp(0, 9999);

    await _sb
        .from('inventory_ramps')
        .update({'ccals_qty': newQty}).eq('item_id', itemId);

    await _sb.from('inventory_changes').insert({
      'timestamp': DateTime.now().toIso8601String(),
      'user_email': userEmail,
      'user_name': userName,
      'change_type': delta < 0 ? 'CCALS Job Install' : 'CCALS Job Removal',
      'item_id': itemId,
      'brand': item['brand'] ?? '',
      'series_or_size': item['size'] ?? '',
      'orientation': '',
      'condition': condition,
      'old_qty': oldQty,
      'new_qty': newQty,
      'delta': delta,
      'job_ref': jobRef,
    });
  }
}

// ---------------------------------------------------------------------------
// LIFTS MASTER
// ---------------------------------------------------------------------------

Future<List<LiftRecord>> sbFetchLifts() async {
  final raw = await _sb
      .from('lifts')
      .select()
      .not('lift_id', 'is', null)
      .order('lift_id');

  return (raw as List).map((r) {
    final map = Map<String, dynamic>.from(r as Map);
    // Convert text[] photo_urls back to comma-separated for fromJson compatibility
    final urls = map['photo_urls'];
    if (urls is List) {
      map['photo_urls'] = (urls as List<dynamic>)
          .map((u) => u.toString())
          .where((u) => u.isNotEmpty)
          .map(normalizeDrivePhotoUrl)
          .join(',');
    }
    return LiftRecord.fromJson(map);
  }).toList();
}

/// Fetches the single most-recently inserted lift (by internal row id).
/// Used to auto-link a newly created lift after the LiftFormScreen closes.
Future<LiftRecord?> sbFetchNewestLift() async {
  final raw = await _sb
      .from('lifts')
      .select()
      .not('lift_id', 'is', null)
      .order('id', ascending: false)
      .limit(1);
  final list = raw as List;
  if (list.isEmpty) return null;
  final map = Map<String, dynamic>.from(list.first as Map);
  final urls = map['photo_urls'];
  if (urls is List) {
    map['photo_urls'] = urls
        .map((u) => u.toString())
        .where((u) => u.isNotEmpty)
        .map(normalizeDrivePhotoUrl)
        .join(',');
  }
  return LiftRecord.fromJson(map);
}

Future<LiftRecord?> sbCheckDuplicateSerial(String serialNumber) async {
  if (serialNumber.trim().isEmpty) return null;
  final raw = await _sb
      .from('lifts')
      .select()
      .eq('serial_number', serialNumber.trim())
      .maybeSingle();
  if (raw == null) return null;
  return LiftRecord.fromJson(raw as Map<String, dynamic>);
}

Future<String> sbUpsertLift({
  required String userEmail,
  required String userName,
  String? liftId,
  required String serialNumber,
  required String brand,
  required String series,
  required String orientation,
  required String foldType,
  required String condition,
  required String status,
  required String preppedStatus,
  required String currentLocation,
  required String currentJob,
  required String dateAcquired,
  required String installDate,
  required String installerName,
  required String lastPrepDate,
  required String notes,
  String? binNumber,
  required String cleanBatteriesStatus,
  String railType = 'Straight',
  String acquisitionSource = '',
  String customerId = '',
  String customerName = '',
  String qbCustomerId = '',
  String warrantyExpiry = '',
  double? buybackPrice,
}) async {
  // Get previous values for history diff
  LiftRecord? prev;
  if (liftId != null && liftId.isNotEmpty) {
    final raw = await _sb
        .from('lifts')
        .select()
        .eq('lift_id', liftId)
        .maybeSingle();
    if (raw != null) prev = LiftRecord.fromJson(raw as Map<String, dynamic>);
  }

  final data = {
    'serial_number': serialNumber,
    'brand': brand,
    'series': series,
    'orientation': orientation,
    'fold_type': foldType,
    'condition': condition,
    'status': status,
    'prepped_status': preppedStatus,
    'current_location': currentLocation,
    'current_job': currentJob,
    'date_acquired': dateAcquired,
    'install_date': installDate,
    'installer_name': installerName,
    'last_prep_date': lastPrepDate,
    'notes': notes,
    'bin_number': binNumber ?? '',
    'clean_batteries_status': cleanBatteriesStatus,
    'rail_type': railType.isEmpty ? 'Straight' : railType,
    'acquisition_source': acquisitionSource,
    'customer_id': customerId.isEmpty ? null : customerId,
    'customer_name': customerName,
    'qb_customer_id': qbCustomerId,
    'buyback_price': buybackPrice,
    'updated_at': DateTime.now().toIso8601String(),
  };

  // Auto-calculate warranty_expiry (2 years from install date) if not explicitly set
  // and an install date is present.
  String resolvedWarranty = warrantyExpiry;
  if (resolvedWarranty.isEmpty && installDate.isNotEmpty) {
    try {
      // installDate may be MM/DD/YYYY or YYYY-MM-DD
      DateTime? installDt;
      if (installDate.contains('/')) {
        final p = installDate.split('/');
        if (p.length == 3) installDt = DateTime(int.parse(p[2]), int.parse(p[0]), int.parse(p[1]));
      } else {
        installDt = DateTime.tryParse(installDate);
      }
      if (installDt != null) {
        final exp = DateTime(installDt.year + 2, installDt.month, installDt.day);
        resolvedWarranty = exp.toIso8601String().substring(0, 10);
      }
    } catch (_) {}
  }
  data['warranty_expiry'] = resolvedWarranty.isEmpty ? null : resolvedWarranty;

  String resolvedLiftId;

  if (liftId != null && liftId.isNotEmpty) {
    // Update existing
    await _sb.from('lifts').update(data).eq('lift_id', liftId);
    resolvedLiftId = liftId;
  } else {
    // Create new — generate lift_id
    final maxRaw = await _sb
        .from('lifts')
        .select('lift_id')
        .order('id', ascending: false)
        .limit(1)
        .maybeSingle();
    int nextId = 1;
    if (maxRaw != null) {
      final parsed = int.tryParse(maxRaw['lift_id'].toString());
      if (parsed != null) nextId = parsed + 1;
    }
    resolvedLiftId = nextId.toString();
    data['lift_id'] = resolvedLiftId;
    data['created_at'] = DateTime.now().toIso8601String();
    await _sb.from('lifts').insert(data);
  }

  // Append history row
  await _sb.from('lift_history').insert({
    'timestamp': DateTime.now().toIso8601String(),
    'lift_id': resolvedLiftId,
    'serial_number': serialNumber,
    'event_type': prev == null ? 'Created' : 'Updated',
    'from_status': prev?.status ?? '',
    'to_status': status,
    'from_location': prev?.currentLocation ?? '',
    'to_location': currentLocation,
    'from_customer': prev?.currentJob ?? '',
    'to_customer': currentJob,
    'job_ref': currentJob,
    'note': notes,
    'user_email': userEmail,
    'user_name': userName,
  });

  return resolvedLiftId;
}

Future<void> sbDeleteLift({
  required String liftId,
  required String userEmail,
  required String userName,
}) async {
  final raw = await _sb
      .from('lifts')
      .select()
      .eq('lift_id', liftId)
      .maybeSingle();

  await _sb.from('lifts').delete().eq('lift_id', liftId);

  if (raw != null) {
    await _sb.from('lift_history').insert({
      'timestamp': DateTime.now().toIso8601String(),
      'lift_id': liftId,
      'serial_number': raw['serial_number'] ?? '',
      'event_type': 'Deleted',
      'to_status': 'Deleted',
      'user_email': userEmail,
      'user_name': userName,
    });
  }
}

// ---------------------------------------------------------------------------
// LIFT HISTORY
// ---------------------------------------------------------------------------

Future<List<LiftHistoryEvent>> sbFetchLiftHistory({
  required String serialNumber,
}) async {
  final raw = await _sb
      .from('lift_history')
      .select()
      .eq('serial_number', serialNumber)
      .order('timestamp', ascending: true);
  return (raw as List)
      .map((r) => LiftHistoryEvent.fromJson(r as Map<String, dynamic>))
      .toList();
}

/// Global audit feed — most recent events across the entire app.
Future<List<LiftHistoryEvent>> sbFetchAuditLog({int limit = 200}) async {
  final raw = await _sb
      .from('lift_history')
      .select()
      .order('timestamp', ascending: false)
      .limit(limit);
  return (raw as List)
      .map((r) => LiftHistoryEvent.fromJson(r as Map<String, dynamic>))
      .toList();
}

// ---------------------------------------------------------------------------
// LIFT SERVICE
// ---------------------------------------------------------------------------

Future<List<LiftServiceRecord>> sbFetchLiftService({
  required String serialNumber,
}) async {
  final raw = await _sb
      .from('lift_service')
      .select()
      .eq('serial_number', serialNumber)
      .order('service_date', ascending: false);

  return (raw as List).map((r) {
    final m = r as Map<String, dynamic>;
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try { return DateTime.parse(v.toString()); } catch (_) { return null; }
    }
    String s(dynamic v) => v?.toString() ?? '';
    return LiftServiceRecord(
      serviceDate: parseDate(m['service_date']) ?? parseDate(m['timestamp']),
      serviceType: s(m['service_type']),
      description: s(m['description']),
      invoiceNumber: s(m['invoice_number']),
      technicianName: s(m['technician_name']),
      jobRef: s(m['job_ref']),
      customerName: s(m['customer_name']),
      notes: s(m['notes']),
    );
  }).toList();
}

Future<void> sbAddLiftService({
  required String userEmail,
  required String userName,
  required String serialNumber,
  required String serviceDate,
  required String serviceType,
  required String description,
  required String invoiceNumber,
  required String jobRef,
  required String customerName,
  String notes = '',
}) async {
  // Look up lift_id from serial
  final liftRaw = await _sb
      .from('lifts')
      .select('lift_id')
      .eq('serial_number', serialNumber)
      .maybeSingle();
  final liftId = liftRaw?['lift_id']?.toString() ?? '';

  await _sb.from('lift_service').insert({
    'timestamp': DateTime.now().toIso8601String(),
    'lift_id': liftId,
    'serial_number': serialNumber,
    'service_date': serviceDate,
    'service_type': serviceType,
    'description': description,
    'invoice_number': invoiceNumber,
    'technician_name': userName,
    'job_ref': jobRef,
    'customer_name': customerName,
    'notes': notes,
    'entered_by_email': userEmail,
    'entered_by_name': userName,
  });
}

// ---------------------------------------------------------------------------
// PREP CHECKLISTS
// ---------------------------------------------------------------------------

Future<List<PrepChecklist>> sbFetchPrepChecklists({
  required String serialNumber,
}) async {
  final raw = await _sb
      .from('prep_checklists')
      .select()
      .eq('serial_number', serialNumber)
      .order('timestamp', ascending: false);

  return (raw as List)
      .map((r) => _prepChecklistFromRow(r as Map<String, dynamic>))
      .toList();
}

Future<List<PrepChecklist>> sbFetchAllPrepChecklists() async {
  final raw = await _sb
      .from('prep_checklists')
      .select()
      .order('timestamp', ascending: false);

  return (raw as List)
      .map((r) => _prepChecklistFromRow(r as Map<String, dynamic>))
      .toList();
}

PrepChecklist _prepChecklistFromRow(Map<String, dynamic> m) {
  DateTime? parseDate(dynamic v) {
    if (v == null) return null;
    try { return DateTime.parse(v.toString()); } catch (_) { return null; }
  }
  String s(dynamic v) => v?.toString() ?? '';

  final rawItems = m['checklist_items'];
  Map<String, bool> items = {};
  if (rawItems is Map) {
    items = rawItems.map((k, v) => MapEntry(
        k.toString(), v == true || v.toString().toLowerCase() == 'true'));
  }

  return PrepChecklist(
    checklistId: s(m['checklist_id']),
    timestamp: parseDate(m['timestamp']),
    liftId: s(m['lift_id']),
    serialNumber: s(m['serial_number']),
    brand: s(m['brand']),
    series: s(m['series']),
    prepDate: s(m['prep_date']),
    preppedByName: s(m['prepped_by_name']),
    preppedByEmail: s(m['prepped_by_email']),
    notes: s(m['notes']),
    checklistItems: items,
  );
}

Future<String> sbSavePrepChecklist({
  required Map<String, dynamic> checklistData,
}) async {
  final serialNumber = checklistData['serial_number']?.toString() ?? '';
  final liftId = checklistData['lift_id']?.toString() ?? '';
  final existingId = checklistData['checklist_id']?.toString();

  // Separate standard fields from checklist boolean items
  const standardFields = {
    'checklist_id', 'lift_id', 'serial_number', 'brand', 'series',
    'prep_date', 'prepped_by_name', 'prepped_by_email', 'notes',
  };

  final Map<String, bool> items = {};
  for (final entry in checklistData.entries) {
    if (!standardFields.contains(entry.key) && entry.value is bool) {
      items[entry.key] = entry.value as bool;
    }
  }

  final checklistId = existingId?.isNotEmpty == true
      ? existingId!
      : 'checklist_${DateTime.now().millisecondsSinceEpoch}';

  final row = {
    'checklist_id': checklistId,
    'timestamp': DateTime.now().toIso8601String(),
    'lift_id': liftId,
    'serial_number': serialNumber,
    'brand': checklistData['brand'] ?? '',
    'series': checklistData['series'] ?? '',
    'prep_date': checklistData['prep_date'] ?? '',
    'prepped_by_name': checklistData['prepped_by_name'] ?? '',
    'prepped_by_email': checklistData['prepped_by_email'] ?? '',
    'notes': checklistData['notes'] ?? '',
    'checklist_items': items,
  };

  final isNew = existingId?.isEmpty ?? true;

  if (existingId?.isNotEmpty == true) {
    await _sb
        .from('prep_checklists')
        .update(row)
        .eq('checklist_id', existingId!);
  } else {
    await _sb.from('prep_checklists').insert(row);
  }

  // Also update prepped_status + last_prep_date on the lift
  if (serialNumber.isNotEmpty) {
    final allTrue = items.values.isNotEmpty && items.values.every((v) => v);
    final preppedStatus = allTrue ? 'Prepped' : 'Needs prepping';

    await _sb.from('lifts').update({
      'prepped_status': preppedStatus,
      'last_prep_date': checklistData['prep_date'] ?? '',
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('serial_number', serialNumber);

    // Log prep checklist completion as a service record (only for new checklists)
    if (isNew && allTrue) {
      final brand = checklistData['brand'] ?? '';
      final series = checklistData['series'] ?? '';
      final prepDate = checklistData['prep_date'] ?? '';
      final preppedByName = checklistData['prepped_by_name'] ?? '';
      final preppedByEmail = checklistData['prepped_by_email'] ?? '';
      final notes = checklistData['notes'] ?? '';

      await _sb.from('lift_service').insert({
        'timestamp': DateTime.now().toIso8601String(),
        'lift_id': liftId,
        'serial_number': serialNumber,
        'service_date': prepDate,
        'service_type': 'Prep',
        'description': 'Prep checklist completed for $brand $series',
        'invoice_number': '',
        'technician_name': preppedByName,
        'job_ref': '',
        'customer_name': '',
        'notes': notes,
        'entered_by_email': preppedByEmail,
        'entered_by_name': preppedByName,
      });
    }
  }

  return checklistId;
}

// ---------------------------------------------------------------------------
// PHOTOS — Supabase Storage
// ---------------------------------------------------------------------------

Future<String> sbUploadLiftPhoto({
  required String liftId,
  required XFile imageFile,
}) async {
  final Uint8List imageBytes;
  if (kIsWeb) {
    imageBytes = await imageFile.readAsBytes();
  } else {
    final compressed = await FlutterImageCompress.compressWithFile(
      imageFile.path,
      minWidth: 1200,
      minHeight: 1200,
      quality: 85,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    if (compressed == null) throw Exception('Image compression failed');
    imageBytes = compressed;
  }

  final fileName =
      'lifts/$liftId/${DateTime.now().millisecondsSinceEpoch}.jpg';

  await _sb.storage.from(_photosBucket).uploadBinary(
        fileName,
        imageBytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false),
      );

  final url = _sb.storage.from(_photosBucket).getPublicUrl(fileName);

  // Append URL to lift's photo_urls array
  final existing = await _sb
      .from('lifts')
      .select('photo_urls')
      .eq('lift_id', liftId)
      .maybeSingle();
  final current = List<String>.from(
      (existing?['photo_urls'] as List<dynamic>?) ?? []);
  current.add(url);

  await _sb.from('lifts').update({
    'photo_urls': current,
    'updated_at': DateTime.now().toIso8601String(),
  }).eq('lift_id', liftId);

  return url;
}

Future<void> sbDeleteLiftPhoto({
  required String liftId,
  required String fileUrl,
}) async {
  // Extract storage path from public URL
  // URL format: https://xxx.supabase.co/storage/v1/object/public/lift-photos/lifts/ID/TIMESTAMP.jpg
  final uri = Uri.parse(fileUrl);
  final pathSegments = uri.pathSegments;
  final bucketIndex = pathSegments.indexOf(_photosBucket);
  if (bucketIndex >= 0 && bucketIndex < pathSegments.length - 1) {
    final storagePath = pathSegments.sublist(bucketIndex + 1).join('/');
    await _sb.storage.from(_photosBucket).remove([storagePath]);
  }

  // Remove from lift's photo_urls array
  final existing = await _sb
      .from('lifts')
      .select('photo_urls')
      .eq('lift_id', liftId)
      .maybeSingle();
  final current = List<String>.from(
      (existing?['photo_urls'] as List<dynamic>?) ?? []);
  current.remove(fileUrl);

  await _sb.from('lifts').update({
    'photo_urls': current,
    'updated_at': DateTime.now().toIso8601String(),
  }).eq('lift_id', liftId);
}

Future<List<String>> sbFetchLiftPhotos({required String liftId}) async {
  final raw = await _sb
      .from('lifts')
      .select('photo_urls')
      .eq('lift_id', liftId)
      .maybeSingle();
  if (raw == null) return [];
  return List<String>.from((raw['photo_urls'] as List<dynamic>?) ?? []);
}

// ---------------------------------------------------------------------------
// SCHEDULE EVENT PHOTOS
// ---------------------------------------------------------------------------

Future<List<String>> sbFetchEventPhotos(String eventId) async {
  final row = await _sb
      .from('app_config')
      .select('value')
      .eq('key', 'event_photos_$eventId')
      .maybeSingle();
  if (row == null) return [];
  try {
    final decoded = jsonDecode(row['value'] as String);
    if (decoded is List) return decoded.map((e) => e.toString()).toList();
  } catch (_) {}
  return [];
}

Future<String> sbUploadEventPhoto({
  required String eventId,
  required XFile imageFile,
  List<String> linkedLiftIds = const [],
  String eventTitle = '',
  DateTime? eventDate,
  String eventLocation = '',
}) async {
  final Uint8List imageBytes;
  if (kIsWeb) {
    imageBytes = await imageFile.readAsBytes();
  } else {
    final compressed = await FlutterImageCompress.compressWithFile(
      imageFile.path,
      minWidth: 1200,
      minHeight: 1200,
      quality: 85,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    if (compressed == null) throw Exception('Image compression failed');
    imageBytes = compressed;
  }

  // Build a descriptive folder/filename: events/JobTitle_YYYY-MM-DD/location_N.jpg
  String sanitize(String s) =>
      s.trim().replaceAll(RegExp(r'[^\w\s-]'), '').replaceAll(RegExp(r'\s+'), '_');

  final folderTitle = sanitize(eventTitle.isNotEmpty ? eventTitle : eventId);
  final dateStr = eventDate != null
      ? '${eventDate.year}-${eventDate.month.toString().padLeft(2, '0')}-${eventDate.day.toString().padLeft(2, '0')}'
      : DateTime.now().toIso8601String().substring(0, 10);
  final locationLabel = sanitize(eventLocation.isNotEmpty ? eventLocation : 'photo');
  final folderPath = 'events/${folderTitle}_$dateStr';

  // Fetch existing photos once — used for index and for saving the updated list
  final existing = await sbFetchEventPhotos(eventId);
  final index = existing.length + 1;

  final fileName = '$folderPath/${locationLabel}_$index.jpg';
  await _sb.storage.from(_photosBucket).uploadBinary(
        fileName,
        imageBytes,
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false),
      );
  final url = _sb.storage.from(_photosBucket).getPublicUrl(fileName);

  // Save URL to app_config
  existing.add(url);
  await _sb.from('app_config').upsert(
    {
      'key': 'event_photos_$eventId',
      'value': jsonEncode(existing),
      'updated_at': DateTime.now().toIso8601String(),
    },
    onConflict: 'key',
  );

  // Also append to each linked lift's photo_urls
  for (final liftId in linkedLiftIds) {
    final liftRow = await _sb
        .from('lifts')
        .select('photo_urls')
        .eq('lift_id', liftId)
        .maybeSingle();
    final current = List<String>.from(
        (liftRow?['photo_urls'] as List<dynamic>?) ?? []);
    current.add(url);
    await _sb.from('lifts').update({
      'photo_urls': current,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('lift_id', liftId);
  }

  return url;
}

Future<void> sbDeleteEventPhoto({
  required String eventId,
  required String fileUrl,
  List<String> linkedLiftIds = const [],
}) async {
  // Delete from storage
  final uri = Uri.parse(fileUrl);
  final pathSegments = uri.pathSegments;
  final bucketIndex = pathSegments.indexOf(_photosBucket);
  if (bucketIndex >= 0 && bucketIndex < pathSegments.length - 1) {
    final storagePath = pathSegments.sublist(bucketIndex + 1).join('/');
    await _sb.storage.from(_photosBucket).remove([storagePath]);
  }

  // Remove from app_config list
  final existing = await sbFetchEventPhotos(eventId);
  existing.remove(fileUrl);
  if (existing.isEmpty) {
    await _sb.from('app_config').delete().eq('key', 'event_photos_$eventId');
  } else {
    await _sb.from('app_config').upsert(
      {
        'key': 'event_photos_$eventId',
        'value': jsonEncode(existing),
        'updated_at': DateTime.now().toIso8601String(),
      },
      onConflict: 'key',
    );
  }

  // Remove from linked lifts' photo_urls
  for (final liftId in linkedLiftIds) {
    final liftRow = await _sb
        .from('lifts')
        .select('photo_urls')
        .eq('lift_id', liftId)
        .maybeSingle();
    final current = List<String>.from(
        (liftRow?['photo_urls'] as List<dynamic>?) ?? []);
    current.remove(fileUrl);
    await _sb.from('lifts').update({
      'photo_urls': current,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('lift_id', liftId);
  }
}

// ---------------------------------------------------------------------------
// PICKUP LIST
// ---------------------------------------------------------------------------

Future<List<Map<String, dynamic>>> sbGetPickupList() async {
  final raw = await _sb
      .from('pickup_list')
      .select()
      .order('added_at', ascending: true);
  return (raw as List).map((r) => r as Map<String, dynamic>).toList();
}

Future<void> sbAddPickupItem({
  required String item,
  required String addedBy,
}) async {
  await _sb.from('pickup_list').insert({
    'id': 'item_${DateTime.now().millisecondsSinceEpoch}',
    'item': item,
    'added_by': addedBy,
    'added_at': DateTime.now().toIso8601String(),
    'completed': false,
  });
}

Future<void> sbUpdatePickupItem({
  required String id,
  required bool completed,
  required String completedBy,
}) async {
  await _sb.from('pickup_list').update({
    'completed': completed,
    'completed_by': completed ? completedBy : null,
    'completed_at': completed ? DateTime.now().toIso8601String() : null,
  }).eq('id', id);
}

Future<void> sbDeletePickupItem({required String id}) async {
  await _sb.from('pickup_list').delete().eq('id', id);
}

// ---------------------------------------------------------------------------
// ANNUALS
// ---------------------------------------------------------------------------

Future<List<AnnualRecord>> sbFetchAnnuals() async {
  final raw = await _sb
      .from('annuals')
      .select()
      .order('date_requested', ascending: false);

  return (raw as List)
      .map((r) => AnnualRecord.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<void> sbUpsertAnnual({
  required String userEmail,
  required String userName,
  String? annualId,
  required String customerName,
  required String address,
  required String phone,
  required String liftType,
  required String lastServiceDate,
  required String dateRequested,
  required String notes,
  String liftId = '',
  String serialNumber = '',
}) async {
  final resolvedId = (annualId != null && annualId.isNotEmpty)
      ? annualId
      : 'annual_${DateTime.now().millisecondsSinceEpoch}';

  final data = <String, dynamic>{
    'annual_id': resolvedId,
    'customer_name': customerName,
    'address': address,
    'phone': phone,
    'lift_type': liftType,
    'last_service_date': lastServiceDate,
    'date_requested': dateRequested,
    'notes': notes,
    'lift_id': liftId,
    'serial_number': serialNumber,
    'updated_at': DateTime.now().toIso8601String(),
  };

  final isNew = annualId == null || annualId.isEmpty;
  if (isNew) {
    data['scheduled'] = false;
    data['created_at'] = DateTime.now().toIso8601String();
    await _sb.from('annuals').insert(data);
  } else {
    await _sb.from('annuals').update(data).eq('annual_id', annualId);
  }

  await _sb.from('annuals_history').insert({
    'timestamp': DateTime.now().toIso8601String(),
    'annual_id': resolvedId,
    'event_type': isNew ? 'Created' : 'Updated',
    'changed_by_email': userEmail,
    'changed_by_name': userName,
    'note': notes,
  });
}

Future<void> sbMarkAnnualScheduled({
  required String annualId,
  required String userEmail,
  required String userName,
  String note = '',
}) async {
  await _sb
      .from('annuals')
      .update({'scheduled': true, 'updated_at': DateTime.now().toIso8601String()})
      .eq('annual_id', annualId);

  await _sb.from('annuals_history').insert({
    'timestamp': DateTime.now().toIso8601String(),
    'annual_id': annualId,
    'event_type': 'Scheduled',
    'changed_by_email': userEmail,
    'changed_by_name': userName,
    'note': note,
  });
}

Future<void> sbDeleteAnnual({
  required String annualId,
  required String userEmail,
  required String userName,
}) async {
  await _sb.from('annuals').delete().eq('annual_id', annualId);

  await _sb.from('annuals_history').insert({
    'timestamp': DateTime.now().toIso8601String(),
    'annual_id': annualId,
    'event_type': 'Deleted',
    'changed_by_email': userEmail,
    'changed_by_name': userName,
    'note': '',
  });
}

Future<List<Map<String, dynamic>>> sbFetchAnnualHistory({
  required String annualId,
}) async {
  final raw = await _sb
      .from('annuals_history')
      .select()
      .eq('annual_id', annualId)
      .order('timestamp', ascending: true);

  return (raw as List).map((r) => r as Map<String, dynamic>).toList();
}

// ---------------------------------------------------------------------------
// SERVICE JOBS
// ---------------------------------------------------------------------------

Future<List<ServiceJobRecord>> sbFetchServiceJobs() async {
  final raw = await _sb
      .from('service_jobs')
      .select()
      .order('created_at', ascending: false);

  return (raw as List)
      .map((r) => ServiceJobRecord.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<void> sbUpsertServiceJob({
  required String userEmail,
  required String userName,
  String? jobId,
  required String jobType,
  String title = '',
  required String customerName,
  required String address,
  required String phone,
  required String liftType,
  required String dateRequested,
  String scheduledDate = '',
  required String notes,
  String liftId = '',
  String serialNumber = '',
  String fundingSource = 'Private',
}) async {
  final resolvedId = (jobId != null && jobId.isNotEmpty)
      ? jobId
      : 'job_${DateTime.now().millisecondsSinceEpoch}';

  final data = <String, dynamic>{
    'job_id': resolvedId,
    'job_type': jobType,
    'title': title,
    'customer_name': customerName,
    'address': address,
    'phone': phone,
    'lift_type': liftType,
    'date_requested': dateRequested,
    'scheduled_date': scheduledDate,
    'notes': notes,
    'lift_id': liftId,
    'serial_number': serialNumber,
    'funding_source': fundingSource,
    'updated_at': DateTime.now().toIso8601String(),
  };

  final isNew = jobId == null || jobId.isEmpty;
  if (isNew) {
    data['status'] = 'Needs Scheduling';
    data['created_at'] = DateTime.now().toIso8601String();
    await _sb.from('service_jobs').insert(data);
  } else {
    await _sb.from('service_jobs').update(data).eq('job_id', jobId);
  }
}

Future<void> sbUpdateServiceJobStatus({
  required String jobId,
  required String status,
  String scheduledDate = '',
}) async {
  final data = <String, dynamic>{
    'status': status,
    'updated_at': DateTime.now().toIso8601String(),
  };
  if (scheduledDate.isNotEmpty) data['scheduled_date'] = scheduledDate;
  await _sb.from('service_jobs').update(data).eq('job_id', jobId);
}

Future<void> sbDeleteServiceJob({required String jobId}) async {
  await _sb.from('service_jobs').delete().eq('job_id', jobId);
}

// ---------------------------------------------------------------------------
// REMOVAL JOBS
// ---------------------------------------------------------------------------

Future<List<RemovalJobRecord>> sbFetchRemovalJobs() async {
  final raw = await _sb
      .from('removal_jobs')
      .select()
      .order('created_at', ascending: false);

  return (raw as List)
      .map((r) => RemovalJobRecord.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<void> sbUpsertRemovalJob({
  required String userEmail,
  required String userName,
  String? jobId,
  String title = '',
  required String customerName,
  required String address,
  required String phone,
  required String liftType,
  String scheduledDate = '',
  required String notes,
  String liftId = '',
  String serialNumber = '',
  String fundingSource = 'Private',
}) async {
  final resolvedId = (jobId != null && jobId.isNotEmpty)
      ? jobId
      : 'removal_${DateTime.now().millisecondsSinceEpoch}';

  final data = <String, dynamic>{
    'job_id': resolvedId,
    'title': title,
    'customer_name': customerName,
    'address': address,
    'phone': phone,
    'lift_type': liftType,
    'scheduled_date': scheduledDate,
    'notes': notes,
    'lift_id': liftId,
    'serial_number': serialNumber,
    'funding_source': fundingSource,
    'updated_at': DateTime.now().toIso8601String(),
  };

  final isNew = jobId == null || jobId.isEmpty;
  if (isNew) {
    data['status'] = 'Needs Scheduling';
    data['created_at'] = DateTime.now().toIso8601String();
    await _sb.from('removal_jobs').insert(data);
  } else {
    await _sb.from('removal_jobs').update(data).eq('job_id', jobId);
  }
}

Future<void> sbUpdateRemovalJobStatus({
  required String jobId,
  required String status,
  String scheduledDate = '',
}) async {
  final data = <String, dynamic>{
    'status': status,
    'updated_at': DateTime.now().toIso8601String(),
  };
  if (scheduledDate.isNotEmpty) data['scheduled_date'] = scheduledDate;
  await _sb.from('removal_jobs').update(data).eq('job_id', jobId);
}

Future<void> sbDeleteRemovalJob({required String jobId}) async {
  await _sb.from('removal_jobs').delete().eq('job_id', jobId);
}

// ---------------------------------------------------------------------------
// LIFT STATUS (targeted update — for one-tap status change in Jobs CRM)
// ---------------------------------------------------------------------------

Future<void> sbMarkLiftStatus({
  required String liftId,
  required String newStatus,
  required String userEmail,
  required String userName,
  String note = '',
  DateTime? eventDate,
}) async {
  final raw = await _sb
      .from('lifts')
      .select()
      .eq('lift_id', liftId)
      .maybeSingle();
  debugPrint('[sbMarkLiftStatus] liftId=$liftId raw=${raw == null ? "NOT FOUND" : "found"}');
  if (raw == null) {
    debugPrint('[sbMarkLiftStatus] lift not found, aborting');
    return;
  }

  final prev = LiftRecord.fromJson(raw as Map<String, dynamic>);
  debugPrint('[sbMarkLiftStatus] updating status ${prev.status} -> $newStatus');

  final update = <String, dynamic>{
    'status': newStatus,
    'updated_at': DateTime.now().toIso8601String(),
  };

  // When marking Installed, record the event date as install_date and
  // auto-calculate warranty_expiry (2 years) if not already set.
  if (newStatus == 'Installed' && eventDate != null) {
    final iso = '${eventDate.year}-${eventDate.month.toString().padLeft(2, '0')}-${eventDate.day.toString().padLeft(2, '0')}';
    update['install_date'] = iso;
    if (prev.warrantyExpiry.isEmpty) {
      final expiry = DateTime(eventDate.year + 2, eventDate.month, eventDate.day);
      update['warranty_expiry'] = '${expiry.year}-${expiry.month.toString().padLeft(2, '0')}-${expiry.day.toString().padLeft(2, '0')}';
    }
  }

  final updateResult = await _sb.from('lifts').update(update).eq('lift_id', liftId).select();
  debugPrint('[sbMarkLiftStatus] update result: $updateResult');

  await _sb.from('lift_history').insert({
    'timestamp': DateTime.now().toIso8601String(),
    'lift_id': liftId,
    'serial_number': prev.serialNumber,
    'event_type': 'Status Change',
    'from_status': prev.status,
    'to_status': newStatus,
    'from_location': prev.currentLocation,
    'to_location': prev.currentLocation,
    'from_customer': prev.currentJob,
    'to_customer': prev.currentJob,
    'job_ref': prev.currentJob,
    'note': note,
    'user_email': userEmail,
    'user_name': userName,
  });
}

// ---------------------------------------------------------------------------
// SCHEDULE EVENT COMPLETION (stored in Supabase, not in TSheets)
// ---------------------------------------------------------------------------
// Uses the app_config table with key pattern "completed_event_<event_id>"
// so we never need a separate table.

Future<Set<String>> sbFetchCompletedEventIds() async {
  final rows = await _sb
      .from('app_config')
      .select('key')
      .like('key', 'completed_event_%');
  return {
    for (final r in rows as List)
      (r['key'] as String).replaceFirst('completed_event_', '')
  };
}

Future<void> sbSetEventCompleted({
  required String eventId,
  required bool completed,
}) async {
  final key = 'completed_event_$eventId';
  if (completed) {
    await _sb.from('app_config').upsert(
      {'key': key, 'value': 'true', 'updated_at': DateTime.now().toIso8601String()},
      onConflict: 'key',
    );
  } else {
    await _sb.from('app_config').delete().eq('key', key);
  }
}

// ---------------------------------------------------------------------------
// SCHEDULE EVENT METADATA (job type + linked lift, stored in app_config)
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> sbGetEventMeta(String eventId) async {
  final rows = await _sb
      .from('app_config')
      .select('key, value')
      .or('key.eq.event_job_type_$eventId,key.eq.event_lift_$eventId,key.eq.event_source_$eventId,key.eq.event_funding_$eventId,key.eq.event_customer_$eventId');
  final map = {for (final r in rows as List) r['key'] as String: r['value'] as String?};
  final liftRaw = map['event_lift_$eventId'];
  List<String> liftIds = [];
  if (liftRaw != null && liftRaw.isNotEmpty) {
    try {
      final decoded = jsonDecode(liftRaw);
      if (decoded is List) {
        liftIds = decoded.map((e) => e.toString()).toList();
      } else {
        liftIds = [liftRaw];
      }
    } catch (_) {
      liftIds = [liftRaw];
    }
  }
  // Customer stored as JSON: {"name":"...","qb_id":"...","customer_id":"..."}
  Map<String, String>? customer;
  final custRaw = map['event_customer_$eventId'];
  if (custRaw != null && custRaw.isNotEmpty) {
    try {
      final decoded = jsonDecode(custRaw) as Map<String, dynamic>;
      customer = {
        'name': decoded['name']?.toString() ?? '',
        'qb_id': decoded['qb_id']?.toString() ?? '',
        'customer_id': decoded['customer_id']?.toString() ?? '',
      };
    } catch (_) {}
  }
  return {
    'job_type': map['event_job_type_$eventId'],
    'lift_ids': liftIds,
    'source': map['event_source_$eventId'],
    'funding_source': map['event_funding_$eventId'] ?? 'Private',
    'customer': customer,
  };
}

Future<void> sbSetEventCustomer(String eventId, {required String name, required String qbId, String customerId = ''}) async {
  final key = 'event_customer_$eventId';
  if (name.isEmpty && qbId.isEmpty && customerId.isEmpty) {
    await _sb.from('app_config').delete().eq('key', key);
  } else {
    await _sb.from('app_config').upsert(
      {'key': key, 'value': jsonEncode({'name': name, 'qb_id': qbId, 'customer_id': customerId}), 'updated_at': DateTime.now().toIso8601String()},
      onConflict: 'key',
    );
  }
}

Future<void> sbSetEventFundingSource(String eventId, String? fundingSource) async {
  final key = 'event_funding_$eventId';
  if (fundingSource == null || fundingSource.isEmpty || fundingSource == 'Private') {
    await _sb.from('app_config').delete().eq('key', key);
  } else {
    await _sb.from('app_config').upsert(
      {'key': key, 'value': fundingSource, 'updated_at': DateTime.now().toIso8601String()},
      onConflict: 'key',
    );
  }
}

Future<void> sbSetEventSource(String eventId, String? source) async {
  final key = 'event_source_$eventId';
  if (source == null || source.isEmpty) {
    await _sb.from('app_config').delete().eq('key', key);
  } else {
    await _sb.from('app_config').upsert(
      {'key': key, 'value': source, 'updated_at': DateTime.now().toIso8601String()},
      onConflict: 'key',
    );
  }
}

Future<void> sbSetEventJobType(String eventId, String? jobType) async {
  final key = 'event_job_type_$eventId';
  if (jobType == null || jobType.isEmpty) {
    await _sb.from('app_config').delete().eq('key', key);
  } else {
    await _sb.from('app_config').upsert(
      {'key': key, 'value': jobType, 'updated_at': DateTime.now().toIso8601String()},
      onConflict: 'key',
    );
  }
}

Future<void> sbSetEventLiftIds(String eventId, List<String> liftIds) async {
  final key = 'event_lift_$eventId';
  if (liftIds.isEmpty) {
    await _sb.from('app_config').delete().eq('key', key);
  } else {
    await _sb.from('app_config').upsert(
      {'key': key, 'value': jsonEncode(liftIds), 'updated_at': DateTime.now().toIso8601String()},
      onConflict: 'key',
    );
  }
}

Future<LiftRecord?> sbFetchLiftById(String liftId) async {
  final raw = await _sb
      .from('lifts')
      .select()
      .eq('lift_id', liftId)
      .maybeSingle();
  return raw == null ? null : LiftRecord.fromJson(raw);
}

/// Bulk-fetches all event job types and lift IDs from app_config in one query.
/// Returns a map of eventId -> {'job_type': String?, 'lift_ids': List<String>}
Future<Map<String, Map<String, dynamic>>> sbGetAllEventMeta() async {
  final rows = await _sb
      .from('app_config')
      .select('key, value')
      .or('key.like.event_job_type_%,key.like.event_lift_%,key.like.event_source_%,key.like.event_funding_%');
  final result = <String, Map<String, dynamic>>{};
  for (final r in rows as List) {
    final key = r['key'] as String;
    final value = r['value'] as String?;
    String? eventId;
    String? field;
    if (key.startsWith('event_job_type_')) {
      eventId = key.substring('event_job_type_'.length);
      field = 'job_type';
    } else if (key.startsWith('event_lift_')) {
      eventId = key.substring('event_lift_'.length);
      field = 'lift_ids';
    } else if (key.startsWith('event_source_')) {
      eventId = key.substring('event_source_'.length);
      field = 'source';
    } else if (key.startsWith('event_funding_')) {
      eventId = key.substring('event_funding_'.length);
      field = 'funding_source';
    }
    if (eventId == null || field == null) continue;
    result.putIfAbsent(eventId, () => {'job_type': null, 'lift_ids': <String>[], 'source': null, 'funding_source': 'Private'});
    if (field == 'job_type') {
      result[eventId]!['job_type'] = value;
    } else if (field == 'source') {
      result[eventId]!['source'] = value;
    } else if (field == 'funding_source') {
      result[eventId]!['funding_source'] = value ?? 'Private';
    } else if (field == 'lift_ids' && value != null && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List) {
          result[eventId]!['lift_ids'] = decoded.map((e) => e.toString()).toList();
        } else {
          result[eventId]!['lift_ids'] = [value];
        }
      } catch (_) {
        result[eventId]!['lift_ids'] = [value];
      }
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// PREP CHECKLIST TEMPLATES (hardcoded — rarely changes)
// ---------------------------------------------------------------------------

const Map<String, List<String>> _prepChecklistTemplates = {
  'bruno_elan': [
    'seat_hardware',
    'carriage',
    'seatbelt',
    'footplate_hardware',
    'track_measurement',
    'double_check_track_measurement',
    'top_final_limit_cam',
    'charge_strips',
    'end_plates_hardware',
    'charge_contact',
    'joint_kit_screws',
    'rail_stand_feet_t_nuts',
    'charger_power_cord',
    'remotes_cradles',
    'seat_post_nylon_washers_retaining_clip',
    'gear_rack_for_length_of_track',
    'soft_stops_if_needed',
    'extension_brackets_if_needed',
    'folding_rail_yes',
    'folding_rail_no',
    'folding_rail_bottom_foot',
    'spacer_end_plate',
    'check_seat_armrests_stay_up',
    'check_wires_in_arm',
    'gear_rack_safety_pin',
    'paperwork',
    'owners_manual',
  ],
  'bruno_elite': [
    'seat_hardware',
    'carriage',
    'seatbelt',
    'footplate_hardware',
    'track_measurement',
    'double_check_track_measurement',
    'top_final_limit_cam',
    'charge_strips',
    'end_plates_hardware',
    'charge_contact',
    'joint_kit_screws',
    'rail_stand_feet_t_nuts',
    'charger_power_cord',
    'remotes_cradles',
    'seat_post_nylon_washers_retaining_clip',
    'gear_rack_for_length_of_track',
    'soft_stops_if_needed',
    'extension_brackets_if_needed',
    'rear_seat_support_bracket',
    'spacer_end_plate',
    'check_seat_armrests_stay_up',
    'check_wires_in_arm',
    'gear_rack_safety_pin',
    'outdoor_seat_cover',
    'paperwork',
    'owners_manual',
  ],
  'brooks_acorn': [
    'correct_handed_carriage',
    'correct_handed_seat',
    'charger_type_130_black',
    'charger_type_t700_white',
    'correct_num_feet_brackets_hardware_lags',
    'end_plate_covers_top_bottom',
    'remotes_hanging_hooks',
    'key_if_needed',
    'seat_swivel_switch_actuator',
    'two_seat_cushions',
    'seat_post_retaining_plug',
    'extension_brackets_if_needed',
    'top_final_limit_cam',
    'rack_end_stop_if_needed',
    'charge_stations',
    'hole_in_rail_for_charging_wire',
    'seat_index_plate_cover',
    'hand_winding_wheel',
    'check_seat_armrests_stay_up',
    'folding_rail_yes',
    'folding_rail_no',
    't130_remove_h_cam_from_track',
    't700_make_sure_h_cam_installed',
    'outdoor_yes',
    'outdoor_no',
    'outdoor_box_for_charger',
    'outlet_cover',
    'outdoor_seat_cover',
    'paperwork',
    'owners_manual',
  ],
};

// Groups of fields rendered side-by-side as choices (yes/no, model options, etc.)
const Map<String, List<List<String>>> _prepChecklistOptionGroups = {
  'bruno_elan': [
    ['folding_rail_yes', 'folding_rail_no'],
  ],
  'bruno_elite': [],
  'brooks_acorn': [
    ['charger_type_130_black', 'charger_type_t700_white'],
    ['folding_rail_yes', 'folding_rail_no'],
    ['t130_remove_h_cam_from_track', 't700_make_sure_h_cam_installed'],
    ['outdoor_yes', 'outdoor_no'],
  ],
};

Map<String, dynamic> sbGetPrepChecklistTemplate({
  required String brand,
  required String series,
}) {
  final b = brand.toLowerCase();
  final s = series.toLowerCase();

  String checklistType;
  if (b.contains('bruno') && s.contains('elan')) {
    checklistType = 'bruno_elan';
  } else if (b.contains('bruno') && (s.contains('elite'))) {
    // Elite Curve uses the same checklist as Elite
    checklistType = 'bruno_elite';
  } else if (b.contains('acorn') || b.contains('brooks')) {
    checklistType = 'brooks_acorn';
  } else {
    // Return empty template for unknown types rather than throwing
    return {'checklist_type': '', 'fields': <String>[]};
  }

  return {
    'checklist_type': checklistType,
    'fields': _prepChecklistTemplates[checklistType]!,
    'option_groups': _prepChecklistOptionGroups[checklistType] ?? [],
  };
}

// ---------------------------------------------------------------------------
// WEB LEADS
// ---------------------------------------------------------------------------

Future<List<WebLeadRecord>> sbFetchWebLeads() async {
  final raw = await _sb
      .from('web_leads')
      .select()
      .order('created_at', ascending: false);
  return (raw as List)
      .map((r) => WebLeadRecord.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<void> sbUpdateWebLeadStatus({
  required int id,
  required String status,
}) async {
  await _sb.from('web_leads').update({'status': status}).eq('id', id);
}

Future<void> sbDeleteWebLead({required int id}) async {
  final res = await _sb.from('web_leads').delete().eq('id', id).select();
  if ((res as List).isEmpty) {
    throw Exception('Delete blocked — check Supabase RLS policy on web_leads');
  }
}

// ---------------------------------------------------------------------------
// SCHEDULE HISTORY
// ---------------------------------------------------------------------------

QbtScheduleEvent _mapHistoryRow(dynamic r) {
  final m = r as Map<String, dynamic>;
  final rawIds = m['assigned_user_ids']?.toString() ?? '';
  final assignedIds = rawIds.isNotEmpty
      ? rawIds.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
      : <String>[];
  return QbtScheduleEvent(
    id: m['tsheets_id']?.toString() ?? '',
    title: m['title']?.toString() ?? '',
    notes: m['notes']?.toString() ?? '',
    start: DateTime.parse(m['start_time'] as String),
    end: DateTime.parse(m['end_time'] as String),
    allDay: m['all_day'] == true,
    location: m['location']?.toString() ?? '',
    color: m['color']?.toString() ?? '#2196F3',
    assignedUserIds: assignedIds,
    active: m['active'] != false,
  );
}

/// Fetch archived events for the active view.
/// [before] is the cutoff (start of the live TSheets window).
/// [after] caps how far back to fetch (e.g. 30 days ago) so we don't load years.
Future<List<QbtScheduleEvent>> sbFetchScheduleHistory({
  required DateTime before,
  DateTime? after,
}) async {
  var q = _sb
      .from('schedule_history')
      .select()
      .lt('start_time', before.toUtc().toIso8601String());
  if (after != null) {
    q = q.gte('start_time', after.toUtc().toIso8601String());
  }
  final raw = await q.order('start_time', ascending: true);
  return (raw as List).map(_mapHistoryRow).toList();
}

/// Full-text search across all historical events.
/// [query] is the remaining text after date tokens are stripped.
/// [startDate]/[endDate] are optional date bounds parsed from the query.
/// Returns at most [limit] results ordered by [newestFirst].
Future<List<QbtScheduleEvent>> sbSearchScheduleHistory({
  required String query,
  DateTime? startDate,
  DateTime? endDate,
  bool newestFirst = true,
  int limit = 200,
}) async {
  var q = _sb.from('schedule_history').select();

  if (startDate != null) {
    q = q.gte('start_time', startDate.toUtc().toIso8601String());
  }
  if (endDate != null) {
    q = q.lte('start_time', endDate.toUtc().toIso8601String());
  }

  // Each term must appear in at least one text column (AND between terms, OR across columns)
  final terms = query.trim().split(RegExp(r'\s+')).where((t) => t.length >= 2).toList();
  for (final term in terms) {
    final t = term.toLowerCase();
    q = q.or(
      'title.ilike.%$t%,'
      'notes.ilike.%$t%,'
      'location.ilike.%$t%,'
      'assigned_user_names.ilike.%$t%',
    );
  }

  final raw = await q
      .order('start_time', ascending: !newestFirst)
      .limit(limit);

  return (raw as List).map(_mapHistoryRow).toList();
}

// ---------------------------------------------------------------------------
// REVIEW REQUESTS
// ---------------------------------------------------------------------------

Future<Set<String>> sbFetchReviewDismissed() async {
  final rows = await _sb
      .from('app_config')
      .select('key')
      .like('key', 'review_dismissed_%');
  return {
    for (final r in rows as List)
      (r['key'] as String).substring('review_dismissed_'.length)
  };
}

Future<void> sbDismissReview(String liftId) async {
  await _sb.from('app_config').upsert(
    {
      'key': 'review_dismissed_$liftId',
      'value': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    },
    onConflict: 'key',
  );
}

// ---------------------------------------------------------------------------
// CUSTOMERS
// ---------------------------------------------------------------------------

Future<List<CustomerRecord>> sbFetchCustomers({String search = ''}) async {
  var q = _sb.from('customers').select();
  if (search.trim().isNotEmpty) {
    final t = search.trim().toLowerCase();
    q = q.or('name.ilike.%$t%,address.ilike.%$t%,phone.ilike.%$t%,city.ilike.%$t%');
  }
  final raw = await q.order('name', ascending: true);
  return (raw as List)
      .map((r) => CustomerRecord.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<CustomerRecord> sbUpsertCustomer(CustomerRecord c) async {
  final data = c.toJson();
  if (c.customerId.isEmpty) {
    data.remove('customer_id');
    final raw = await _sb.from('customers').insert(data).select().single();
    return CustomerRecord.fromJson(raw);
  } else {
    await _sb.from('customers').update(data).eq('customer_id', c.customerId);
    return c;
  }
}

Future<void> sbDeleteCustomer(String customerId) async {
  await _sb.from('customers').delete().eq('customer_id', customerId);
}

Future<List<LiftRecord>> sbFetchLiftsForCustomer(String customerId) async {
  final raw = await _sb
      .from('lifts')
      .select()
      .eq('customer_id', customerId)
      .order('install_date', ascending: false);
  return (raw as List)
      .map((r) => LiftRecord.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<List<LiftServiceRecord>> sbFetchServiceForCustomer(String customerId) async {
  final raw = await _sb
      .from('lift_service')
      .select()
      .eq('customer_id', customerId)
      .order('service_date', ascending: false)
      .limit(20);
  return (raw as List)
      .map((r) => LiftServiceRecord.fromJson(r as Map<String, dynamic>))
      .toList();
}

/// Fetch customers, optionally filtered by lifecycle status. Extends
/// [sbFetchCustomers] which handles the free-text search path.
Future<List<CustomerRecord>> sbFetchCustomersByStatus({
  CustomerLifecycleStatus? status,
}) async {
  var q = _sb.from('customers').select();
  if (status != null) {
    q = q.eq('lifecycle_status', customerLifecycleToString(status));
  }
  final raw = await q.order('name', ascending: true);
  return (raw as List)
      .map((r) => CustomerRecord.fromJson(r as Map<String, dynamic>))
      .toList();
}

/// Find a local customer by their QuickBooks id (used to resolve QB search
/// results to the canonical local row).
Future<CustomerRecord?> sbFindCustomerByQbId(String qbId) async {
  if (qbId.isEmpty) return null;
  final raw = await _sb
      .from('customers')
      .select()
      .eq('qb_customer_id', qbId)
      .maybeSingle();
  if (raw == null) return null;
  return CustomerRecord.fromJson(raw);
}

/// Resolve a QuickBooks customer to a canonical local `customers` row: return
/// the existing row matched by qb id, otherwise create a minimal one. Used to
/// guarantee we always have a real customer_id (never '') when linking from QB
/// search results. Extra fields (address/phone/email) fill in when available.
Future<CustomerRecord> sbResolveOrCreateCustomerByQb({
  required String name,
  required String qbId,
  String address = '',
  String phone = '',
  String email = '',
}) async {
  if (qbId.isNotEmpty) {
    final existing = await sbFindCustomerByQbId(qbId);
    if (existing != null) return existing;
  }
  return sbUpsertCustomer(CustomerRecord(
    customerId: '',
    name: name,
    address: address,
    city: extractCity(address),
    phone: phone,
    email: email,
    fundingSource: 'Private',
    qbCustomerId: qbId,
    notes: '',
    // A QB customer we're only just linking is, by default, an active owner
    // (they're already in QuickBooks / on the schedule), not a fresh lead.
    lifecycleStatus: CustomerLifecycleStatus.active,
  ));
}

Future<void> sbUpdateCustomerLifecycle(
  String customerId,
  CustomerLifecycleStatus status,
) async {
  await _sb.from('customers').update({
    'lifecycle_status': customerLifecycleToString(status),
    'last_contact_at': DateTime.now().toIso8601String(),
  }).eq('customer_id', customerId);
}

Future<void> sbSetCustomerAnnualDue(String customerId, DateTime? dueDate) async {
  await _sb.from('customers').update({
    'annual_due_date': dueDate?.toIso8601String(),
  }).eq('customer_id', customerId);
}

// ---------------------------------------------------------------------------
// CUSTOMER ACTIVITIES (reminder layer feeding ops_jobs)
// ---------------------------------------------------------------------------

Future<List<CustomerActivity>> sbFetchActivitiesForCustomer(String customerId) async {
  if (customerId.isEmpty) return [];
  final raw = await _sb
      .from('customer_activities')
      .select()
      .eq('customer_id', customerId)
      .order('created_at', ascending: false);
  return (raw as List)
      .map((r) => CustomerActivity.fromJson(r as Map<String, dynamic>))
      .toList();
}

/// Pending activities that are due (or have no due date), joined with the
/// customer name/city — drives the Follow-ups view.
Future<List<CustomerActivity>> sbFetchDueActivities() async {
  final nowIso = DateTime.now().toIso8601String();
  final raw = await _sb
      .from('customer_activities')
      .select('*, customers(name, city)')
      .eq('status', 'pending')
      .or('due_date.is.null,due_date.lte.$nowIso')
      .order('due_date', ascending: true, nullsFirst: true);
  return (raw as List)
      .map((r) => CustomerActivity.fromJson(r as Map<String, dynamic>))
      .toList();
}

/// Upcoming pending activities (due in the future) — for a "coming up" section.
Future<List<CustomerActivity>> sbFetchUpcomingActivities() async {
  final nowIso = DateTime.now().toIso8601String();
  final raw = await _sb
      .from('customer_activities')
      .select('*, customers(name, city)')
      .eq('status', 'pending')
      .gt('due_date', nowIso)
      .order('due_date', ascending: true);
  return (raw as List)
      .map((r) => CustomerActivity.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<CustomerActivity> sbCreateActivity(CustomerActivity a) async {
  final data = a.toJson()..remove('activity_id');
  if ((data['spawned_job_id'] as String?)?.isEmpty ?? true) {
    data['spawned_job_id'] = null;
  }
  final raw = await _sb.from('customer_activities').insert(data).select().single();
  return CustomerActivity.fromJson(raw);
}

/// Create an activity only if there isn't already a pending one of this type
/// for the customer (avoids duplicate reviews/annuals on re-completion).
Future<void> sbEnsurePendingActivity({
  required String customerId,
  required CustomerActivityType type,
  DateTime? dueDate,
  String sourceEventId = '',
}) async {
  final existing = await _sb
      .from('customer_activities')
      .select('activity_id')
      .eq('customer_id', customerId)
      .eq('type', customerActivityTypeToString(type))
      .eq('status', 'pending')
      .maybeSingle();
  if (existing != null) return;
  await sbCreateActivity(CustomerActivity(
    activityId: '',
    customerId: customerId,
    type: type,
    status: CustomerActivityStatus.pending,
    dueDate: dueDate,
    sourceEventId: sourceEventId,
  ));
}

Future<void> sbUpdateActivityStatus(
  String activityId,
  CustomerActivityStatus status, {
  String? spawnedJobId,
}) async {
  final data = <String, dynamic>{
    'status': customerActivityStatusToString(status),
  };
  if (status == CustomerActivityStatus.done) {
    data['completed_at'] = DateTime.now().toIso8601String();
  }
  if (spawnedJobId != null && spawnedJobId.isNotEmpty) {
    data['spawned_job_id'] = spawnedJobId;
  }
  await _sb.from('customer_activities').update(data).eq('activity_id', activityId);
}

Future<void> sbDeleteActivity(String activityId) async {
  await _sb.from('customer_activities').delete().eq('activity_id', activityId);
}

// ---------------------------------------------------------------------------
// OPERATIONS HUB
// ---------------------------------------------------------------------------

Future<List<OpsJob>> sbFetchOpsJobs({bool includeCompleted = false}) async {
  var q = _sb.from('ops_jobs').select();
  if (!includeCompleted) {
    q = q.neq('status', 'completed');
  }
  final raw = await q.order('date_requested', ascending: true);
  return (raw as List)
      .map((r) => OpsJob.fromJson(r as Map<String, dynamic>))
      .toList();
}

/// Fetches all pending work from ops_jobs + legacy service_jobs, removal_jobs,
/// and annuals tables, merged into a unified OpsJob list.
Future<List<OpsJob>> sbFetchAllOpsJobs({bool includeCompleted = false}) async {
  final results = await Future.wait([
    sbFetchOpsJobs(includeCompleted: includeCompleted),
    sbFetchServiceJobs(),
    sbFetchRemovalJobs(),
    sbFetchAnnuals(),
  ]);

  final ops = List<OpsJob>.from(results[0] as List<OpsJob>);
  final serviceJobs = results[1] as List<ServiceJobRecord>;
  final removalJobs = results[2] as List<RemovalJobRecord>;
  final annuals = results[3] as List<AnnualRecord>;

  // Convert legacy service jobs → OpsJob (skip ones already tracked in ops_jobs)
  final existingSourceIds = ops.map((j) => j.sourceId).toSet();

  for (final j in serviceJobs) {
    if (existingSourceIds.contains(j.jobId)) continue;
    if (!includeCompleted && j.status == 'Completed') continue;
    ops.add(OpsJob(
      jobId: 'svc_${j.jobId}',
      jobType: j.jobType.toLowerCase().contains('annual')
          ? OpsJobType.annualService
          : OpsJobType.stairliftService,
      status: _legacyStatusToOps(j.status),
      customerName: j.customerName,
      address: j.address,
      city: extractCity(j.address),
      phone: j.phone,
      liftType: j.liftType,
      liftId: j.liftId,
      serialNumber: j.serialNumber,
      fundingSource: j.fundingSource,
      notes: j.notes,
      dateRequested: j.dateRequested.isNotEmpty ? DateTime.tryParse(j.dateRequested) : null,
      sourceTable: 'service_jobs',
      sourceId: j.jobId,
    ));
  }

  for (final j in removalJobs) {
    if (existingSourceIds.contains(j.jobId)) continue;
    if (!includeCompleted && j.status == 'Completed') continue;
    ops.add(OpsJob(
      jobId: 'rem_${j.jobId}',
      jobType: OpsJobType.stairliftRemoval,
      status: _legacyStatusToOps(j.status),
      customerName: j.customerName,
      address: j.address,
      city: extractCity(j.address),
      phone: j.phone,
      liftType: j.liftType,
      liftId: j.liftId,
      serialNumber: j.serialNumber,
      fundingSource: j.fundingSource,
      notes: j.notes,
      sourceTable: 'removal_jobs',
      sourceId: j.jobId,
    ));
  }

  for (final a in annuals) {
    if (existingSourceIds.contains(a.annualId)) continue;
    if (!includeCompleted && a.scheduled) continue;
    ops.add(OpsJob(
      jobId: 'ann_${a.annualId}',
      jobType: OpsJobType.annualService,
      status: a.scheduled ? OpsJobStatus.scheduled : OpsJobStatus.readyToSchedule,
      customerName: a.customerName,
      address: a.address,
      city: extractCity(a.address),
      phone: a.phone,
      liftType: a.liftType,
      liftId: a.liftId,
      serialNumber: a.serialNumber,
      fundingSource: 'Private',
      notes: a.notes,
      dateRequested: a.dateRequested.isNotEmpty ? DateTime.tryParse(a.dateRequested) : null,
      sourceTable: 'annuals',
      sourceId: a.annualId,
    ));
  }

  ops.sort((a, b) {
    final aDate = a.dateRequested ?? DateTime.now();
    final bDate = b.dateRequested ?? DateTime.now();
    return aDate.compareTo(bDate);
  });
  return ops;
}

OpsJobStatus _legacyStatusToOps(String status) {
  switch (status.toLowerCase()) {
    case 'scheduled': return OpsJobStatus.scheduled;
    case 'completed': return OpsJobStatus.completed;
    default: return OpsJobStatus.readyToSchedule;
  }
}

Future<OpsJob> sbCreateOpsJob(OpsJob job) async {
  final data = job.toJson()..remove('job_id');
  // customer_id is a uuid column — an empty string is invalid, send null.
  if ((data['customer_id'] as String?)?.isEmpty ?? true) data['customer_id'] = null;
  final raw = await _sb.from('ops_jobs').insert(data).select().single();
  return OpsJob.fromJson(raw);
}

Future<void> sbUpdateOpsJobStatus(String jobId, OpsJobStatus status) async {
  await _sb.from('ops_jobs').update({
    'status': _opsStatusToString(status),
  }).eq('job_id', jobId);
}

/// Advances status for any job — native ops_jobs rows update in-place,
/// legacy rows (service_jobs, removal_jobs, annuals) get promoted to a
/// real ops_jobs row so status changes persist correctly.
Future<void> sbAdvanceOpsJobStatus(OpsJob job, OpsJobStatus newStatus) async {
  if (job.sourceTable == 'ops_jobs' || job.sourceTable.isEmpty) {
    // Native ops_jobs row — simple update
    await sbUpdateOpsJobStatus(job.jobId, newStatus);
    return;
  }
  // Legacy row — promote to ops_jobs with the new status
  final promoted = OpsJob(
    jobId: '',
    jobType: job.jobType,
    status: newStatus,
    customerName: job.customerName,
    address: job.address,
    city: job.city,
    phone: job.phone,
    liftType: job.liftType,
    liftId: job.liftId,
    serialNumber: job.serialNumber,
    fundingSource: job.fundingSource,
    notes: job.notes,
    dateRequested: job.dateRequested,
    buybackOfferPrice: job.buybackOfferPrice,
    sourceTable: job.sourceTable,
    sourceId: job.sourceId,
  );
  await sbCreateOpsJob(promoted);
}

Future<void> sbUpdateOpsJob(OpsJob job) async {
  final data = job.toJson();
  if ((data['customer_id'] as String?)?.isEmpty ?? true) data['customer_id'] = null;
  await _sb.from('ops_jobs').update(data).eq('job_id', job.jobId);
}

/// Links (or updates) a job's customer FK in place. Native ops_jobs only.
Future<void> sbSetOpsJobCustomer(String jobId, String? customerId) async {
  await _sb.from('ops_jobs').update({
    'customer_id': (customerId == null || customerId.isEmpty) ? null : customerId,
  }).eq('job_id', jobId);
}

/// All ops_jobs linked to a customer (for the customer profile Jobs card).
Future<List<OpsJob>> sbFetchJobsForCustomer(String customerId) async {
  if (customerId.isEmpty) return [];
  final raw = await _sb
      .from('ops_jobs')
      .select()
      .eq('customer_id', customerId)
      .order('date_requested', ascending: false);
  return (raw as List)
      .map((r) => OpsJob.fromJson(r as Map<String, dynamic>))
      .toList();
}

Future<void> sbDeleteOpsJob(String jobId) async {
  await _sb.from('ops_jobs').delete().eq('job_id', jobId);
}

/// Deletes an ops job regardless of whether it came from ops_jobs or a legacy table.
Future<void> sbDeleteOpsJobAny(OpsJob job) async {
  switch (job.sourceTable) {
    case 'service_jobs':
      await _sb.from('service_jobs').delete().eq('job_id', job.sourceId);
      break;
    case 'removal_jobs':
      await _sb.from('removal_jobs').delete().eq('job_id', job.sourceId);
      break;
    case 'annuals':
      await _sb.from('annuals').delete().eq('annual_id', job.sourceId);
      break;
    default:
      // Native ops_jobs row — job_id is the real PK
      await _sb.from('ops_jobs').delete().eq('job_id', job.jobId);
  }
}

// ---------------------------------------------------------------------------
// LIFT CUSTOMER HISTORY
// ---------------------------------------------------------------------------

class LiftCustomerHistoryEntry {
  final String liftId;
  final String customerName;
  final String qbCustomerId;
  final DateTime assignedAt;
  final DateTime? removedAt;

  const LiftCustomerHistoryEntry({
    required this.liftId,
    required this.customerName,
    required this.qbCustomerId,
    required this.assignedAt,
    this.removedAt,
  });

  factory LiftCustomerHistoryEntry.fromJson(Map<String, dynamic> j) {
    return LiftCustomerHistoryEntry(
      liftId: j['lift_id']?.toString() ?? '',
      customerName: j['customer_name']?.toString() ?? '',
      qbCustomerId: j['qb_customer_id']?.toString() ?? '',
      assignedAt: DateTime.parse(j['assigned_at'].toString()),
      removedAt: j['removed_at'] != null
          ? DateTime.tryParse(j['removed_at'].toString())
          : null,
    );
  }
}

Future<void> sbLiftCustomerAssigned({
  required String liftId,
  required String customerName,
  required String qbCustomerId,
}) async {
  await _sb.from('lift_customer_history').insert({
    'lift_id': liftId,
    'customer_name': customerName,
    'qb_customer_id': qbCustomerId,
    'assigned_at': DateTime.now().toIso8601String(),
  });
}

Future<void> sbLiftCustomerRemoved({required String liftId}) async {
  // Mark the most recent open entry for this lift as removed
  await _sb
      .from('lift_customer_history')
      .update({'removed_at': DateTime.now().toIso8601String()})
      .eq('lift_id', liftId)
      .isFilter('removed_at', null);
}

Future<List<LiftCustomerHistoryEntry>> sbFetchLiftCustomerHistory(String liftId) async {
  final rows = await _sb
      .from('lift_customer_history')
      .select()
      .eq('lift_id', liftId)
      .order('assigned_at', ascending: false);
  return (rows as List)
      .map((r) => LiftCustomerHistoryEntry.fromJson(r as Map<String, dynamic>))
      .toList();
}

// ---------------------------------------------------------------------------
// EMAIL REVIEW QUEUE
// ---------------------------------------------------------------------------

class EmailQueueItem {
  final String key;        // app_config key, e.g. 'email_review_<gmailId>'
  final String gmailId;
  final String from;
  final String subject;
  final String snippet;
  final String? fundingSource; // set for unmatched, null for review
  final String? customerName;
  final DateTime? scannedAt;

  const EmailQueueItem({
    required this.key,
    required this.gmailId,
    required this.from,
    required this.subject,
    required this.snippet,
    this.fundingSource,
    this.customerName,
    this.scannedAt,
  });
}

/// Fetches emails flagged for manual review (both unmatched and unrecognised).
Future<List<EmailQueueItem>> sbFetchEmailQueue() async {
  final rows = await _sb
      .from('app_config')
      .select('key, value')
      .or('key.like.email_review_%,key.like.email_unmatched_%')
      .order('updated_at', ascending: false);

  return (rows as List).map((r) {
    final key = r['key'] as String;
    final gmailId = key.contains('email_review_')
        ? key.substring('email_review_'.length)
        : key.substring('email_unmatched_'.length);
    Map<String, dynamic> data = {};
    try {
      data = Map<String, dynamic>.from(
          (r['value'] is String ? jsonDecode(r['value'] as String) : r['value']) as Map);
    } catch (_) {}
    DateTime? scanned;
    try { scanned = DateTime.tryParse(data['scannedAt'] as String? ?? ''); } catch (_) {}
    return EmailQueueItem(
      key: key,
      gmailId: gmailId,
      from: data['from'] as String? ?? '',
      subject: data['subject'] as String? ?? '',
      snippet: data['snippet'] as String? ?? '',
      fundingSource: data['fundingSource'] as String?,
      customerName: data['customerName'] as String?,
      scannedAt: scanned,
    );
  }).toList();
}

/// Removes an email from the review queue (marks it handled).
Future<void> sbDismissEmailQueueItem(String key) async {
  await _sb.from('app_config').delete().eq('key', key);
}

String _opsStatusToString(OpsJobStatus s) {
  switch (s) {
    case OpsJobStatus.needsInfo: return 'needs_info';
    case OpsJobStatus.waitingAgencyConfirmation: return 'waiting_agency_confirmation';
    case OpsJobStatus.readyToSchedule: return 'ready_to_schedule';
    case OpsJobStatus.scheduled: return 'scheduled';
    case OpsJobStatus.completed: return 'completed';
  }
}

// ---------------------------------------------------------------------------
// USER MANAGEMENT
// ---------------------------------------------------------------------------

Future<List<UserProfile>> sbFetchUserProfiles() async {
  final rows = await _sb
      .from('user_profiles')
      .select()
      .order('name', ascending: true);
  return (rows as List).map((r) => UserProfile.fromJson(r as Map<String, dynamic>)).toList();
}

Future<void> sbUpdateUserProfile(String userId, {String? name, UserRole? role}) async {
  final data = <String, dynamic>{};
  if (name != null) data['name'] = name;
  if (role != null) data['role'] = role.name;
  if (data.isEmpty) return;
  await _sb.from('user_profiles').update(data).eq('user_id', userId);
}

Future<void> sbDeleteUserProfile(String userId) async {
  await _sb.from('user_profiles').delete().eq('user_id', userId);
}

// ---------------------------------------------------------------------------
// DOCUMENT REPOSITORY
// ---------------------------------------------------------------------------

class DocRecord {
  final String path;     // full storage path, used as stable ID and for delete
  final String name;     // full path (kept for search filtering)
  final String url;      // public URL
  final int sizeBytes;
  final DateTime? updatedAt;

  const DocRecord({
    required this.path,
    required this.name,
    required this.url,
    required this.sizeBytes,
    this.updatedAt,
  });

  /// Just the filename, no folder prefix.
  String get fileName {
    final slash = name.lastIndexOf('/');
    return slash >= 0 ? name.substring(slash + 1) : name;
  }

  /// Folder name, or null if file is at root.
  String? get folderName {
    final slash = name.lastIndexOf('/');
    if (slash <= 0) return null;
    // Return only the immediate parent folder, not the full nested path.
    final folder = name.substring(0, slash);
    final parentSlash = folder.lastIndexOf('/');
    return parentSlash >= 0 ? folder.substring(parentSlash + 1) : folder;
  }

  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
  }

  bool get isPdf => extension == 'pdf';
}

Future<List<DocRecord>> sbFetchDocs() async {
  final results = <DocRecord>[];
  await _fetchDocsInFolder('', results);
  results.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  return results;
}

Future<void> _fetchDocsInFolder(String folder, List<DocRecord> out) async {
  final items = await _sb.storage.from(_docsBucket).list(path: folder);
  for (final item in items) {
    if (item.name == '.emptyFolderPlaceholder') continue;
    final fullPath = folder.isEmpty ? item.name : '$folder/${item.name}';
    // Supabase returns folders as FileObject with id == null and metadata == null
    final isFolder = item.id == null;
    if (isFolder) {
      // Recurse into the folder
      await _fetchDocsInFolder(fullPath, out);
    } else {
      final url = _sb.storage.from(_docsBucket).getPublicUrl(fullPath);
      out.add(DocRecord(
        path: fullPath,
        name: fullPath, // full path so folder structure is visible
        url: url,
        sizeBytes: item.metadata?['size'] as int? ?? 0,
        updatedAt: item.updatedAt != null ? DateTime.tryParse(item.updatedAt!) : null,
      ));
    }
  }
}

Future<String> sbUploadDoc({
  required String fileName,
  required Uint8List bytes,
  String contentType = 'application/octet-stream',
}) async {
  // Avoid collisions: prefix with timestamp if file already exists
  String safeName = fileName;
  try {
    await _sb.storage.from(_docsBucket).uploadBinary(
      safeName,
      bytes,
      fileOptions: FileOptions(contentType: contentType, upsert: false),
    );
  } on StorageException catch (e) {
    if (e.statusCode == '409' || (e.message.contains('already exists'))) {
      // File exists — upsert instead
      await _sb.storage.from(_docsBucket).uploadBinary(
        safeName,
        bytes,
        fileOptions: FileOptions(contentType: contentType, upsert: true),
      );
    } else {
      rethrow;
    }
  }
  return _sb.storage.from(_docsBucket).getPublicUrl(safeName);
}

Future<void> sbDeleteDoc(String path) async {
  await _sb.storage.from(_docsBucket).remove([path]);
}
