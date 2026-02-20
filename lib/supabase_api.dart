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

import 'main.dart'
    show
        InventoryChange,
        InventoryData,
        LiftHistoryEvent,
        LiftRecord,
        LiftServiceRecord,
        PrepChecklist,
        RampItem,
        StairliftItem,
        normalizeDrivePhotoUrl;

// ---------------------------------------------------------------------------
// CONFIG
// ---------------------------------------------------------------------------

const String _supabaseUrl = 'https://kaujczbhtajqfrjgbxft.supabase.co';
const String _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImthdWpjemJodGFqcWZyamdieGZ0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0NDI3NjYsImV4cCI6MjA4NzAxODc2Nn0.WbxeNDGKlOVEy7_2F_VBoa0oRv0JHqK1NdpP1G6LDbk';

const String _photosBucket = 'lift-photos';

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

Future<void> sbUpsertLift({
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
    'updated_at': DateTime.now().toIso8601String(),
  };

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

  return (raw as List).map((r) {
    final m = r as Map<String, dynamic>;
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try { return DateTime.parse(v.toString()); } catch (_) { return null; }
    }
    String s(dynamic v) => v?.toString() ?? '';
    return LiftHistoryEvent(
      timestamp: parseDate(m['timestamp']),
      status: s(m['to_status']).isNotEmpty ? s(m['to_status']) : s(m['from_status']),
      location: s(m['to_location']).isNotEmpty ? s(m['to_location']) : s(m['from_location']),
      jobRef: s(m['job_ref']),
      note: s(m['note']),
    );
  }).toList();
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
    await _sb.from('lifts').update({
      'prepped_status': allTrue ? 'Prepped' : 'Needs prepping',
      'last_prep_date': checklistData['prep_date'] ?? '',
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('serial_number', serialNumber);
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
