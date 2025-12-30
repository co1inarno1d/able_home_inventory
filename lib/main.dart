
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'prep_checklist_form.dart';

/// =======================
/// CONFIG
/// =======================

// Direct Apps Script URL (used on iOS/Android)
const String _nativeApiBaseUrl =
    'https://script.google.com/macros/s/AKfycbxfBAlm90vMrh0I1xiIh3fJtbesTmxcfHBHxcwpYmKunCIu270_xgQUE0WFbM9XdMagCg/exec';

// Netlify proxy URL (used on Web).
const String _webApiBaseUrl =
    'https://inventory.ableha.com/.netlify/functions/apps_script_proxy';

/// Use Netlify proxy on Web, direct Apps Script on native.
String get apiBaseUrl => kIsWeb ? _webApiBaseUrl : _nativeApiBaseUrl;

/// If you set an API_KEY in Apps Script, put it here. Otherwise leave as null.
const String? apiKey = null;

/// Brand color
const Color kBrandGreen = Color(0xFF2F7D46);

/// Format a DateTime to a readable date string (MM/DD/YYYY)
String formatDate(DateTime? date) {
  if (date == null) return 'Unknown date';
  return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}';
}

void main() {
  runApp(const AbleHomeInventoryApp());
}

class AbleHomeInventoryApp extends StatelessWidget {
  const AbleHomeInventoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Able Home Accessibility',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: kBrandGreen),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

/// =======================
/// MODELS
/// =======================

class StairliftItem {
  final String itemId;
  final String brand;
  final String series;
  final String orientation;
  final String foldType;
  final String condition; // "New" or "Used"
  final int currentQty;
  final int minQty;
  final bool active;
  final String notes;

  StairliftItem({
    required this.itemId,
    required this.brand,
    required this.series,
    required this.orientation,
    required this.foldType,
    required this.condition,
    required this.currentQty,
    required this.minQty,
    required this.active,
    required this.notes,
  });

  factory StairliftItem.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      return int.tryParse(v.toString()) ?? 0;
    }

    String normCondition(dynamic v) {
      final s = v?.toString().trim().toLowerCase() ?? '';
      if (s == 'used') return 'Used';
      return 'New';
    }

    return StairliftItem(
      itemId: json['item_id']?.toString() ?? '',
      brand: json['brand']?.toString() ?? '',
      series: json['series']?.toString() ?? '',
      orientation: json['orientation']?.toString() ?? '',
      foldType: json['fold_type']?.toString() ?? '',
      condition: normCondition(json['condition']),
      currentQty: parseInt(json['current_qty']),
      minQty: parseInt(json['min_qty']),
      active: (json['active'] ?? 'Y').toString().toUpperCase() == 'Y',
      notes: json['notes']?.toString() ?? '',
    );
  }
}

class RampItem {
  final String itemId;
  final String brand;
  final String size;
  final String condition; // "New" or "Used"
  final int currentQty;
  final int minQty;
  final bool active;
  final String notes;

  RampItem({
    required this.itemId,
    required this.brand,
    required this.size,
    required this.condition,
    required this.currentQty,
    required this.minQty,
    required this.active,
    required this.notes,
  });

  factory RampItem.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      return int.tryParse(v.toString()) ?? 0;
    }

    String normCondition(dynamic v) {
      final s = v?.toString().trim().toLowerCase() ?? '';
      if (s == 'used') return 'Used';
      return 'New';
    }

    return RampItem(
      itemId: json['item_id']?.toString() ?? '',
      brand: json['brand']?.toString() ?? '',
      size: json['size']?.toString() ?? '',
      condition: normCondition(json['condition']),
      currentQty: parseInt(json['current_qty']),
      minQty: parseInt(json['min_qty']),
      active: (json['active'] ?? 'Y').toString().toUpperCase() == 'Y',
      notes: json['notes']?.toString() ?? '',
    );
  }
}

class InventoryChange {
  final DateTime? timestamp;
  final String userEmail;
  final String userName;
  final String changeType;
  final String itemId;
  final String brand;
  final String seriesOrSize;
  final String orientation;
  final String condition;
  final int oldQty;
  final int newQty;
  final int delta;
  final String jobRef;
  final String note;

  InventoryChange({
    required this.timestamp,
    required this.userEmail,
    required this.userName,
    required this.changeType,
    required this.itemId,
    required this.brand,
    required this.seriesOrSize,
    required this.orientation,
    required this.condition,
    required this.oldQty,
    required this.newQty,
    required this.delta,
    required this.jobRef,
    required this.note,
  });

  factory InventoryChange.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    int parseInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      return int.tryParse(v.toString()) ?? 0;
    }

    return InventoryChange(
      timestamp: parseDate(json['timestamp']),
      userEmail: json['user_email']?.toString() ?? '',
      userName: json['user_name']?.toString() ?? '',
      changeType: json['change_type']?.toString() ?? '',
      itemId: json['item_id']?.toString() ?? '',
      brand: json['brand']?.toString() ?? '',
      seriesOrSize: json['series_or_size']?.toString() ?? '',
      orientation: json['orientation']?.toString() ?? '',
      condition: json['condition']?.toString() ?? '',
      oldQty: parseInt(json['old_qty']),
      newQty: parseInt(json['new_qty']),
      delta: parseInt(json['delta']),
      jobRef: json['job_ref']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
    );
  }
}

/// Per-lift record
class LiftRecord {
  final String liftId;
  final String serialNumber;
  final String brand;
  final String series;
  final String orientation;
  final String foldType;
  final String condition;
  final String dateAcquired;
  final String status; // e.g. In Stock, Assigned, Installed, Removed, Scrapped
  final String currentLocation; // address or short label
  final String currentJob;
  final String installDate;
  final String installerName;
  final String preppedStatus; // Needs prepping / Prepped / Not applicable
  final String lastPrepDate;
  final String notes;

  LiftRecord({
    required this.liftId,
    required this.serialNumber,
    required this.brand,
    required this.series,
    required this.orientation,
    required this.foldType,
    required this.condition,
    required this.dateAcquired,
    required this.status,
    required this.currentLocation,
    required this.currentJob,
    required this.installDate,
    required this.installerName,
    required this.preppedStatus,
    required this.lastPrepDate,
    required this.notes,
  });

  factory LiftRecord.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';

    return LiftRecord(
      liftId: s(json['lift_id']),
      serialNumber: s(json['serial_number']),
      brand: s(json['brand']),
      series: s(json['series']),
      orientation: s(json['orientation']),
      foldType: s(json['fold_type']),
      condition: s(json['condition']),
      dateAcquired: s(json['date_acquired']),
      status: s(json['status']),
      currentLocation: s(json['current_location']),
      currentJob: s(json['current_job']),
      installDate: s(json['install_date']),
      installerName: s(json['installer_name']),
      preppedStatus: s(json['prepped_status']),
      lastPrepDate: s(json['last_prep_date']),
      notes: s(json['notes']),
    );
  }
}

/// Single movement/location history entry for a lift
class LiftHistoryEvent {
  final DateTime? timestamp;
  final String status; // e.g. In Stock, Assigned, Installed, Removed, Scrapped
  final String location; // customer/address / shop / etc.
  final String jobRef;
  final String note;

  LiftHistoryEvent({
    required this.timestamp,
    required this.status,
    required this.location,
    required this.jobRef,
    required this.note,
  });

  factory LiftHistoryEvent.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    String s(dynamic v) => v?.toString() ?? '';

    return LiftHistoryEvent(
      timestamp: parseDate(json['timestamp']),
      status: s(json['status']),
      location: s(json['location']),
      jobRef: s(json['job_ref']),
      note: s(json['note']),
    );
  }
}

/// Service history entry for a lift
class LiftServiceRecord {
  final DateTime? serviceDate;
  final String serviceType;
  final String description;
  final String invoiceNumber;
  final String technicianName;
  final String jobRef;
  final String customerName;
  final String notes;

  LiftServiceRecord({
    required this.serviceDate,
    required this.serviceType,
    required this.description,
    required this.invoiceNumber,
    required this.technicianName,
    required this.jobRef,
    required this.customerName,
    required this.notes,
  });

  factory LiftServiceRecord.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    String s(dynamic v) => v?.toString() ?? '';

    return LiftServiceRecord(
      serviceDate: parseDate(json['service_date']),
      serviceType: s(json['service_type']),
      description: s(json['description']),
      invoiceNumber: s(json['invoice_number']),
      technicianName: s(json['technician_name']),
      jobRef: s(json['job_ref']),
      customerName: s(json['customer_name']),
      notes: s(json['notes']),
    );
  }
}

class PrepChecklist {
  final String checklistId;
  final DateTime? timestamp;
  final String liftId;
  final String serialNumber;
  final String brand;
  final String series;
  final String prepDate;
  final String preppedByName;
  final String preppedByEmail;
  final String notes;
  final Map<String, bool> checklistItems;

  PrepChecklist({
    required this.checklistId,
    this.timestamp,
    required this.liftId,
    required this.serialNumber,
    required this.brand,
    required this.series,
    required this.prepDate,
    required this.preppedByName,
    required this.preppedByEmail,
    required this.notes,
    required this.checklistItems,
  });

  factory PrepChecklist.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';

    DateTime? parseDate(dynamic v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return null;
      }
    }

    // Extract checklist items (all boolean fields)
    final checklistItems = <String, bool>{};
    json.forEach((key, value) {
      if (value == true || value == 'TRUE' || value == false || value == 'FALSE') {
        checklistItems[key] = (value == true || value == 'TRUE');
      }
    });

    return PrepChecklist(
      checklistId: s(json['checklist_id']),
      timestamp: parseDate(json['timestamp']),
      liftId: s(json['lift_id']),
      serialNumber: s(json['serial_number']),
      brand: s(json['brand']),
      series: s(json['series']),
      prepDate: s(json['prep_date']),
      preppedByName: s(json['prepped_by_name']),
      preppedByEmail: s(json['prepped_by_email']),
      notes: s(json['notes']),
      checklistItems: checklistItems,
    );
  }
}

class InventoryData {
  final List<StairliftItem> stairlifts;
  final List<RampItem> ramps;

  InventoryData({
    required this.stairlifts,
    required this.ramps,
  });
}

/// =======================
/// API HELPERS
/// =======================

Future<InventoryData> fetchInventory() async {
  final query = {
    'action': 'get_inventory',
    if (apiKey != null) 'api_key': apiKey!,
  };

  final uri = Uri.parse(apiBaseUrl).replace(queryParameters: query);
  final response = await http.get(uri);

  if (response.statusCode != 200) {
    throw Exception('Failed to load inventory: ${response.statusCode}');
  }

  final data = json.decode(response.body);
  if (data['status'] != 'ok') {
    throw Exception('API error: ${data['message']}');
  }

  final stairliftsJson = (data['stairlifts'] as List<dynamic>? ?? []);
  final rampsJson = (data['ramps'] as List<dynamic>? ?? []);

  final stairlifts = stairliftsJson
      .map((e) => StairliftItem.fromJson(e as Map<String, dynamic>))
      .toList();
  final ramps = rampsJson
      .map((e) => RampItem.fromJson(e as Map<String, dynamic>))
      .toList();

  return InventoryData(stairlifts: stairlifts, ramps: ramps);
}

Future<List<InventoryChange>> fetchChanges({int limit = 200}) async {
  final query = {
    'action': 'get_changes',
    'limit': limit.toString(),
    if (apiKey != null) 'api_key': apiKey!,
  };

  final uri = Uri.parse(apiBaseUrl).replace(queryParameters: query);
  final response = await http.get(uri);

  if (response.statusCode != 200) {
    throw Exception('Failed to load changes: ${response.statusCode}');
  }

  final data = json.decode(response.body);
  if (data['status'] != 'ok') {
    throw Exception('API error: ${data['message']}');
  }

  final changesJson = (data['changes'] as List<dynamic>? ?? []);
  return changesJson
      .map((e) => InventoryChange.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<List<LiftRecord>> fetchLifts() async {
  final query = {
    'action': 'get_lifts',
    if (apiKey != null) 'api_key': apiKey!,
  };

  final uri = Uri.parse(apiBaseUrl).replace(queryParameters: query);
  final response = await http.get(uri);

  if (response.statusCode != 200) {
    throw Exception('Failed to load lifts: ${response.statusCode}');
  }

  final data = json.decode(response.body);
  if (data['status'] != 'ok') {
    throw Exception('API error: ${data['message']}');
  }

  final liftsJson = (data['lifts'] as List<dynamic>? ?? []);
  return liftsJson
      .map((e) => LiftRecord.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<List<LiftHistoryEvent>> fetchLiftHistory({
  required String serialNumber,
}) async {
  final queryParams = {
    'action': 'get_lift_history',
    'serial_number': serialNumber,
    if (apiKey != null) 'api_key': apiKey!,
  };

  final uri = Uri.parse(apiBaseUrl).replace(queryParameters: queryParams);

  debugPrint('Fetching history for serial: $serialNumber');
  debugPrint('History request URI: $uri');

  final response = await http.get(uri);

  debugPrint('History response status: ${response.statusCode}');
  debugPrint('History response body: ${response.body}');

  // Apps Script sometimes returns 302 for redirects with no JSON.
  if (response.statusCode == 302) {
    return [];
  }

  if (response.statusCode != 200) {
    throw Exception('Failed to load lift history: ${response.statusCode}');
  }

  final data = json.decode(response.body);
  if (data['status'] != 'ok') {
    throw Exception('API error: ${data['message']}');
  }

  final histJson = (data['history'] as List<dynamic>? ?? []);
  debugPrint('Found ${histJson.length} history records');
  return histJson
      .map((e) => LiftHistoryEvent.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<List<LiftServiceRecord>> fetchLiftService({
  required String serialNumber,
}) async {
  final queryParams = {
    'action': 'get_lift_service',
    'serial_number': serialNumber,
    if (apiKey != null) 'api_key': apiKey!,
  };

  final uri = Uri.parse(apiBaseUrl).replace(queryParameters: queryParams);

  debugPrint('Fetching service records for serial: $serialNumber');
  debugPrint('Service request URI: $uri');

  final response = await http.get(uri);

  debugPrint('Service response status: ${response.statusCode}');
  debugPrint('Service response body: ${response.body}');

  // Treat 302 (redirect) as "no service records" instead of an error.
  if (response.statusCode == 302) {
    return [];
  }

  if (response.statusCode != 200) {
    throw Exception('Failed to load lift service: ${response.statusCode}');
  }

  final data = json.decode(response.body);
  if (data['status'] != 'ok') {
    throw Exception('API error: ${data['message']}');
  }

  final svcJson = (data['service'] as List<dynamic>? ?? []);
  debugPrint('Found ${svcJson.length} service records');
  return svcJson
      .map((e) => LiftServiceRecord.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<List<PrepChecklist>> fetchPrepChecklists({
  required String serialNumber,
}) async {
  final queryParams = {
    'action': 'get_prep_checklists',
    'serial_number': serialNumber,
    if (apiKey != null) 'api_key': apiKey!,
  };

  final uri = Uri.parse(apiBaseUrl).replace(queryParameters: queryParams);

  debugPrint('Fetching prep checklists for serial: $serialNumber');

  final response = await http.get(uri);

  debugPrint('Prep checklists response status: ${response.statusCode}');

  if (response.statusCode != 200) {
    throw Exception('Failed to load prep checklists: ${response.statusCode}');
  }

  final data = json.decode(response.body);
  if (data['status'] != 'ok') {
    throw Exception('API error: ${data['message']}');
  }

  final checklistsJson = (data['checklists'] as List<dynamic>? ?? []);
  debugPrint('Found ${checklistsJson.length} prep checklists');
  return checklistsJson
      .map((e) => PrepChecklist.fromJson(e as Map<String, dynamic>))
      .toList();
}

Future<String> savePrepChecklist({
  required Map<String, dynamic> checklistData,
}) async {
  final uri = Uri.parse(apiBaseUrl);

  debugPrint('Saving prep checklist');

  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: json.encode({
      'action': 'save_prep_checklist',
      ...checklistData,
      if (apiKey != null) 'api_key': apiKey,
    }),
  );

  debugPrint('Save prep checklist response: ${response.statusCode}');

  if (response.statusCode != 200) {
    throw Exception('Failed to save prep checklist: ${response.statusCode}');
  }

  final data = json.decode(response.body);
  if (data['status'] != 'ok') {
    throw Exception('API error: ${data['message']}');
  }

  return data['checklist_id']?.toString() ?? '';
}

Future<Map<String, dynamic>> getPrepChecklistTemplate({
  required String brand,
  required String series,
}) async {
  final queryParams = {
    'action': 'get_prep_checklist_template',
    'brand': brand,
    'series': series,
    if (apiKey != null) 'api_key': apiKey!,
  };

  final uri = Uri.parse(apiBaseUrl).replace(queryParameters: queryParams);

  debugPrint('Fetching prep checklist template for: $brand $series');

  final response = await http.get(uri);

  if (response.statusCode != 200) {
    throw Exception(
        'Failed to load prep checklist template: ${response.statusCode}');
  }

  final data = json.decode(response.body);
  if (data['status'] != 'ok') {
    throw Exception('API error: ${data['message']}');
  }

  return {
    'checklist_type': data['checklist_type'],
    'fields': List<String>.from(data['fields'] ?? []),
  };
}

Future<void> submitFullCheck({
  required String userEmail,
  required String userName,
  required List<Map<String, dynamic>> items,
}) async {
  if (items.isEmpty) return;

  final uri = Uri.parse(apiBaseUrl);
  final body = {
    'action': 'full_check',
    'user_email': userEmail,
    'user_name': userName,
    'items': items,
    if (apiKey != null) 'api_key': apiKey,
  };

  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: json.encode(body),
  );

  if (response.statusCode == 200) {
    try {
      final data = json.decode(response.body);
      if (data is Map &&
          data['status'] != null &&
          data['status'].toString() != 'ok') {
        throw Exception('API error: ${data['message']}');
      }
    } catch (_) {
      // Non-JSON but 200: assume success
    }
  } else if (response.statusCode == 302) {
    return;
  } else {
    throw Exception('Failed to submit full check: ${response.statusCode}');
  }
}

Future<void> submitJobAdjustment({
  required String userEmail,
  required String userName,
  required String jobRef,
  required List<Map<String, dynamic>> items,
}) async {
  if (items.isEmpty) return;

  final uri = Uri.parse(apiBaseUrl);
  final body = {
    'action': 'job_adjustment',
    'user_email': userEmail,
    'user_name': userName,
    'job_ref': jobRef,
    'items': items,
    if (apiKey != null) 'api_key': apiKey,
  };

  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: json.encode(body),
  );

  if (response.statusCode == 200) {
    try {
      final data = json.decode(response.body);
      if (data is Map &&
          data['status'] != null &&
          data['status'].toString() != 'ok') {
        throw Exception('API error: ${data['message']}');
      }
    } catch (_) {
      // Non-JSON but 200: assume success
    }
  } else if (response.statusCode == 302) {
    return;
  } else {
    throw Exception('Failed to submit job adjustment: ${response.statusCode}');
  }
}

/// Create or update a lift row in Lifts_Master
Future<void> upsertLift({
  required String userEmail,
  required String userName,
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
  String? dateAcquired,
  String? installDate,
  String? installerName,
  String? lastPrepDate,
  String? notes,
}) async {
  final uri = Uri.parse(apiBaseUrl);

  final body = {
    'action': 'upsert_lift',
    'user_email': userEmail,
    'user_name': userName,
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
    if (dateAcquired != null) 'date_acquired': dateAcquired,
    if (installDate != null) 'install_date': installDate,
    if (installerName != null) 'installer_name': installerName,
    if (lastPrepDate != null) 'last_prep_date': lastPrepDate,
    if (notes != null) 'notes': notes,
    if (apiKey != null) 'api_key': apiKey,
  };

  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: json.encode(body),
  );

  if (response.statusCode != 200 && response.statusCode != 302) {
    throw Exception('Failed to save lift: ${response.statusCode}');
  }

  if (response.statusCode == 200) {
    try {
      final data = json.decode(response.body);
      if (data is Map &&
          data['status'] != null &&
          data['status'].toString() != 'ok') {
        throw Exception('API error: ${data['message']}');
      }
    } catch (_) {
      // Non-JSON but 200: assume success
    }
  }
}

/// Add a service entry for a specific lift
Future<void> addLiftService({
  required String userEmail,
  required String userName,
  required String serialNumber,
  required String serviceDate,
  required String serviceType,
  required String description,
  required String invoiceNumber,
  required String jobRef,
  required String customerName,
  String? notes,
}) async {
  final uri = Uri.parse(apiBaseUrl);

  final body = {
    'action': 'add_lift_service',
    'user_email': userEmail,
    'user_name': userName,
    'serial_number': serialNumber,
    'service_date': serviceDate,
    'service_type': serviceType,
    'description': description,
    'invoice_number': invoiceNumber,
    'job_ref': jobRef,
    'customer_name': customerName,
    if (notes != null) 'notes': notes,
    if (apiKey != null) 'api_key': apiKey,
  };

  final response = await http.post(
    uri,
    headers: {'Content-Type': 'application/json'},
    body: json.encode(body),
  );

  if (response.statusCode != 200 && response.statusCode != 302) {
    throw Exception('Failed to add service record: ${response.statusCode}');
  }

  if (response.statusCode == 200) {
    try {
      final data = json.decode(response.body);
      if (data is Map &&
          data['status'] != null &&
          data['status'].toString() != 'ok') {
        throw Exception('API error: ${data['message']}');
      }
    } catch (_) {
      // Non-JSON but 200: assume success
    }
  }
}

/// =======================
/// HOME SHELL (BOTTOM NAV)
/// =======================

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// Minimal PickupListScreen placeholder. If you already have a full
/// implementation elsewhere, remove this small placeholder and point
/// _pages to your existing PickupListScreen instead.
class PickupListScreen extends StatefulWidget {
  const PickupListScreen({super.key});

  @override
  State<PickupListScreen> createState() => _PickupListScreenState();
}

class _PickupListScreenState extends State<PickupListScreen> {
  final TextEditingController _controller = TextEditingController();
  late Future<void> _initialLoad;
  List<Map<String, dynamic>> _items = []; // each item: {id, item, added_by, added_at, completed, completed_by, completed_at}
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _initialLoad = _fetchItems();
  }

  Future<void> _fetchItems() async {
    setState(() {
      _loading = true;
    });

    try {
      final uri = Uri.parse(apiBaseUrl).replace(queryParameters: {
        'action': 'get_pickup_list',
        if (apiKey != null) 'api_key': apiKey!,
      });

      final resp = await http.get(uri);
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        if (data is Map && data['status'] == 'ok') {
          final list = (data['items'] as List<dynamic>? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          setState(() {
            _items = list;
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to load pickup list: \$e');
    } finally {
      if (mounted) setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _addItem() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final addedBy = prefs.getString('user_name') ?? 'Unknown';

    // Optimistic UI: add locally first with temporary id
    final tempId = DateTime.now().millisecondsSinceEpoch.toString();
    final newItem = {
      'id': tempId,
      'item': text,
      'added_by': addedBy,
      'added_at': DateTime.now().toIso8601String(),
      'completed': false,
      'completed_by': '',
      'completed_at': ''
    };

    setState(() {
      _items.insert(0, newItem);
      _controller.clear();
    });

    try {
      final uri = Uri.parse(apiBaseUrl);
      final body = {
        'action': 'add_pickup_item',
        'item': text,
        'added_by': addedBy,
        if (apiKey != null) 'api_key': apiKey,
      };

      final resp = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode(body),
      );

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body);
        if (data is Map && data['status'] == 'ok' && data['id'] != null) {
          // Replace temp id with real id returned by server
          final serverId = data['id'].toString();
          setState(() {
            final idx = _items.indexWhere((i) => i['id'] == tempId);
            if (idx >= 0) {
              _items[idx]['id'] = serverId;
            }
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to add pickup item: \$e');
      // keep optimistic item; user can retry via refresh
    }
  }

  Future<void> _toggleComplete(Map<String, dynamic> item, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    final user = prefs.getString('user_name') ?? 'Unknown';

    final id = item['id']?.toString() ?? '';
    if (id.isEmpty) return;

    // Optimistic update
    setState(() {
      item['completed'] = value;
      item['completed_by'] = value ? user : '';
      item['completed_at'] = value ? DateTime.now().toIso8601String() : '';
    });

    try {
      final queryParams = {
        'action': 'update_pickup_item',
        'id': id,
        'completed': value ? 'TRUE' : 'FALSE',
        'completed_by': value ? user : '',
        if (apiKey != null) 'api_key': apiKey!,
      };

      final uri = Uri.parse(apiBaseUrl).replace(queryParameters: queryParams);

      debugPrint('Sending update request for id: $id, completed: ${value ? 'TRUE' : 'FALSE'}');
      debugPrint('Request URI: $uri');

      final resp = await http.get(uri);

      debugPrint('Response status: ${resp.statusCode}');
      debugPrint('Response body: ${resp.body}');

      if (resp.statusCode != 200) {
        throw Exception('Server error: ${resp.statusCode}');
      }

      final data = json.decode(resp.body);
      if (data is Map && data['status'] != 'ok') {
        throw Exception('API error: ${data['message'] ?? 'unknown'}');
      }
    } catch (e) {
      debugPrint('Failed to update pickup item: $e');
      // Revert optimistic update on failure
      setState(() {
        item['completed'] = !value;
        item['completed_by'] = item['completed'] ? (prefs.getString('user_name') ?? '') : '';
        item['completed_at'] = item['completed'] ? DateTime.now().toIso8601String() : '';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update item: $e')),
        );
      }
    }
  }

  Future<void> _refresh() async => _fetchItems();

  Future<void> _openUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final userName = prefs.getString('user_name') ?? '';
    final userEmail = prefs.getString('user_email') ?? '';

    final nameController = TextEditingController(text: userName);
    final emailController = TextEditingController(text: userEmail);

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('User Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration:
                    const InputDecoration(labelText: 'Your name (for logs)'),
              ),
              TextField(
                controller: emailController,
                decoration:
                    const InputDecoration(labelText: 'Your email (for logs)'),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kBrandGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
              onPressed: () async {
                await prefs.setString('user_name', nameController.text.trim());
                await prefs.setString('user_email', emailController.text.trim());
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pickup List'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'User settings',
            onPressed: _openUserSettings,
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initialLoad,
        builder: (context, snap) {
          if (_loading && _items.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.add),
                          hintText: 'Add pickup item (e.g., 2x 2x4, screws)',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _addItem(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _addItem,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kBrandGreen,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _items.isEmpty
                    ? const Center(child: Text('No pickup items.'))
                    : RefreshIndicator(
                        onRefresh: _refresh,
                        child: ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final it = _items[index];
                            final completed = it['completed'] == true || it['completed'] == 'TRUE';
                            return CheckboxListTile(
                              value: completed,
                              onChanged: (v) => _toggleComplete(it, v ?? false),
                              title: Text(it['item']?.toString() ?? ''),
                              subtitle: Text("Added by: ${it['added_by'] ?? ''}"),
                              secondary: completed
                                  ? const Icon(Icons.check_circle)
                                  : const Icon(Icons.inventory_2),
                            );
                          },
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  // Keep pages in the same order as the bottom navigation bar.
  // Use only widgets that exist in this file (or the local placeholder above).
  final List<Widget> _pages = [
    const LiftsScreen(),
    const RampsScreen(),
    const PickupListScreen(),
  ];

  void _onItemTapped(int index) {
    if (_selectedIndex == index) return;
    setState(() {
      _selectedIndex = index;
    });
  }

  String _titleForIndex(int i) {
    switch (i) {
      case 0:
        return 'Lifts';
      case 1:
        return 'Ramps Inventory';
      case 2:
      default:
        return 'Pickup List';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: kBrandGreen,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.list_alt),
            label: 'Lifts',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.stairs),
            label: 'Ramps',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.check_box),
            label: 'Pickup',
          ),
        ],
      ),
    );
  }
}

/// =======================
/// RAMPS SCREEN (inventory-style)
/// =======================

class RampsScreen extends StatefulWidget {
  const RampsScreen({super.key});

  @override
  State<RampsScreen> createState() => _RampsScreenState();
}

class _RampsScreenState extends State<RampsScreen> {
  late Future<InventoryData> _future;

  String _searchQuery = '';
  String _rampConditionFilter = 'New';
  bool _showBelowMinOnlyRamps = false;
  String? _rampBrandFilter;

  String _userName = '';
  String _userEmail = '';

  @override
  void initState() {
    super.initState();
    _future = fetchInventory();
    _loadUserPrefs();
  }

  Future<void> _loadUserPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userName = prefs.getString('user_name') ?? '';
      _userEmail = prefs.getString('user_email') ?? '';
    });
  }

  Future<void> _saveUserPrefs(String name, String email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', name);
    await prefs.setString('user_email', email);
    setState(() {
      _userName = name;
      _userEmail = email;
    });
  }

  void _refresh() {
    setState(() {
      _future = fetchInventory();
    });
  }

  Future<void> _openUserSettings() async {
    final nameController = TextEditingController(text: _userName);
    final emailController = TextEditingController(text: _userEmail);

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('User Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration:
                    const InputDecoration(labelText: 'Your name (for logs)'),
              ),
              TextField(
                controller: emailController,
                decoration:
                    const InputDecoration(labelText: 'Your email (for logs)'),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kBrandGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
              onPressed: () async {
                await _saveUserPrefs(
                  nameController.text.trim(),
                  emailController.text.trim(),
                );
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _openFullCheck() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FullInventoryCheckScreen(),
      ),
    );
    if (result == true) {
      _refresh();
    }
  }

  void _openJobAdjustment() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const JobAdjustmentScreen(),
      ),
    );
    if (result == true) {
      _refresh();
    }
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChangeHistoryScreen(),
      ),
    );
  }

  Widget _buildSummaryRow({
    required int totalUnits,
    required int totalNew,
    required int totalUsed,
    required int belowMinCount,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ramps Summary',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _SummaryStat(
                      label: 'Total units',
                      value: totalUnits.toString(),
                    ),
                  ),
                  Expanded(
                    child: _SummaryStat(
                      label: 'New',
                      value: totalNew.toString(),
                    ),
                  ),
                  Expanded(
                    child: _SummaryStat(
                      label: 'Used',
                      value: totalUsed.toString(),
                    ),
                  ),
                  Expanded(
                    child: _SummaryStat(
                      label: 'Below min',
                      value: belowMinCount.toString(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterRow() {
    final conditionValue = _rampConditionFilter;
    final belowMinValue = _showBelowMinOnlyRamps;

    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('New'),
                selected: conditionValue == 'New',
                onSelected: (_) {
                  setState(() {
                    _rampConditionFilter = 'New';
                  });
                },
                selectedColor: kBrandGreen.withOpacity(0.2),
              ),
              ChoiceChip(
                label: const Text('Used'),
                selected: conditionValue == 'Used',
                onSelected: (_) {
                  setState(() {
                    _rampConditionFilter = 'Used';
                  });
                },
                selectedColor: kBrandGreen.withOpacity(0.2),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: belowMinValue,
              onChanged: (val) {
                setState(() {
                  _showBelowMinOnlyRamps = val;
                });
              },
              activeColor: kBrandGreen,
            ),
            const Text(
              'Below min only',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRampsList(List<RampItem> items, List<String> brands) {
    final condition = _rampConditionFilter;
    final belowMinOnly = _showBelowMinOnlyRamps;
    final brandFilter = _rampBrandFilter;

    final filtered = items.where((item) {
      if (item.condition != condition) return false;
      if (belowMinOnly &&
          !(item.currentQty < item.minQty && item.minQty > 0)) {
        return false;
      }
      if (brandFilter != null && brandFilter.isNotEmpty) {
        if (item.brand != brandFilter) return false;
      }
      if (_searchQuery.isNotEmpty) {
        final haystack = '${item.brand} ${item.size}'.toLowerCase();
        if (!haystack.contains(_searchQuery)) return false;
      }
      return true;
    }).toList();

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by brand, size...',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value.trim().toLowerCase();
              });
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: _buildFilterRow(),
        ),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: DropdownButton<String>(
              value: _rampBrandFilter ?? '',
              hint: const Text('All brands'),
              items: <DropdownMenuItem<String>>[
                const DropdownMenuItem<String>(
                  value: '',
                  child: Text('All brands'),
                ),
                ...brands.map(
                  (brand) => DropdownMenuItem<String>(
                    value: brand,
                    child: Text(brand),
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _rampBrandFilter =
                      (value == null || value.isEmpty) ? null : value;
                });
              },
            ),
          ),
        ),
        const SizedBox(height: 4),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(child: Text('No ramps found.')),
          )
        else
          ...filtered.map((item) {
            final belowMin =
                item.currentQty < item.minQty && item.minQty > 0;

            return Card(
              margin:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: belowMin ? Colors.red.shade50 : null,
              child: ListTile(
                title: Text(
                  '${item.brand} – ${item.size}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: belowMin ? Colors.red.shade700 : null,
                  ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Condition: ${item.condition}'),
                    if (item.notes.isNotEmpty) Text('Notes: ${item.notes}'),
                  ],
                ),
                trailing: SizedBox(
                  width: 60,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'Qty',
                          style: TextStyle(
                              fontSize: 11, color: Colors.black54),
                        ),
                        Text(
                          '${item.currentQty}',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: belowMin
                                ? Colors.red.shade700
                                : Colors.black,
                          ),
                        ),
                        Text(
                          'Min ${item.minQty}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ramps Inventory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Change history',
            onPressed: _openHistory,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'User settings',
            onPressed: _openUserSettings,
          ),
        ],
      ),
      body: FutureBuilder<InventoryData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading inventory:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          final data = snapshot.data!;
          final ramps = data.ramps;

          final rampBrands =
              (ramps.map((e) => e.brand).toSet().toList()..sort());

          int rampTotalUnits = 0;
          int rampNewUnits = 0;
          int rampUsedUnits = 0;
          int rampBelowMinCount = 0;
          for (final r in ramps) {
            rampTotalUnits += r.currentQty;
            if (r.condition == 'New') rampNewUnits += r.currentQty;
            if (r.condition == 'Used') rampUsedUnits += r.currentQty;
            if (r.currentQty < r.minQty && r.minQty > 0) {
              rampBelowMinCount++;
            }
          }

          return Column(
            children: [
              _buildSummaryRow(
                totalUnits: rampTotalUnits,
                totalNew: rampNewUnits,
                totalUsed: rampUsedUnits,
                belowMinCount: rampBelowMinCount,
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    setState(() {
                      _future = fetchInventory();
                    });
                    await _future;
                  },
                  child: _buildRampsList(ramps, rampBrands),
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 12.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const SizedBox(width: 16),
            FloatingActionButton.extended(
              heroTag: 'job_adjustment_fab_ramps',
              onPressed: _openJobAdjustment,
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Job Adjustment'),
            ),
            FloatingActionButton.extended(
              heroTag: 'full_check_fab_ramps',
              onPressed: _openFullCheck,
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.fact_check),
              label: const Text('Full Check'),
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

class _SummaryStat extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryStat({required this.label, required this.value, super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style:
              const TextStyle(fontSize: 11, color: Colors.black54),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// =======================
/// FULL INVENTORY CHECK – RAMPS ONLY
/// =======================

class FullInventoryCheckScreen extends StatefulWidget {
  FullInventoryCheckScreen({super.key});

  @override
  State<FullInventoryCheckScreen> createState() =>
      _FullInventoryCheckScreenState();
}

class _FullInventoryCheckScreenState extends State<FullInventoryCheckScreen> {
  late Future<InventoryData> _future;
  final Map<String, String> _newQuantities = {}; // key: itemId|condition
  bool _submitting = false;

  String _rampCondition = 'New';

  @override
  void initState() {
    super.initState();
    _future = fetchInventory();
  }

  String _keyFor(String itemId, String condition) => '$itemId|$condition';

  void _onQtyChanged(String itemId, String condition, String value) {
    final key = _keyFor(itemId, condition);
    setState(() {
      if (value.trim().isEmpty) {
        _newQuantities.remove(key);
      } else {
        _newQuantities[key] = value.trim();
      }
    });
  }

  Future<Map<String, String>> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString('user_name') ?? '',
      'email': prefs.getString('user_email') ?? '',
    };
  }

  Future<void> _submit() async {
    if (_submitting) return;

    setState(() {
      _submitting = true;
    });

    try {
      final user = await _loadUser();
      final userEmail = user['email'] ?? '';
      final userName = user['name'] ?? '';
      if (userEmail.isEmpty || userName.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please set your name & email in the main screen.')),
        );
        setState(() {
          _submitting = false;
        });
        return;
      }

      final data = await _future;
      final List<Map<String, dynamic>> items = [];
      int parseInt(String v) => int.tryParse(v) ?? 0;

      // Ramps only - only send items that have values entered
      for (final item in data.ramps) {
        final key = _keyFor(item.itemId, item.condition);
        final raw = _newQuantities[key];
        if (raw == null || raw.isEmpty) continue;
        items.add({
          'item_id': item.itemId,
          'category': 'ramp',
          'new_qty': parseInt(raw),
          'condition': item.condition,
        });
      }

      if (items.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter at least one new quantity')),
        );
        setState(() {
          _submitting = false;
        });
        return;
      }

      await submitFullCheck(
        userEmail: userEmail,
        userName: userName,
        items: items,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Inventory updated')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error submitting: $e')),
      );
      setState(() {
        _submitting = false;
      });
    }
  }

  Widget _buildConditionToggle(
      String currentValue, ValueChanged<String> onChanged) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ChoiceChip(
          label: const Text('New'),
          selected: currentValue == 'New',
          onSelected: (_) => onChanged('New'),
          selectedColor: kBrandGreen.withOpacity(0.2),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('Used'),
          selected: currentValue == 'Used',
          onSelected: (_) => onChanged('Used'),
          selectedColor: kBrandGreen.withOpacity(0.2),
        ),
      ],
    );
  }

  Widget _buildRampList(List<RampItem> items, String condition) {
    final filtered = items.where((i) => i.condition == condition).toList();
    if (filtered.isEmpty) {
      return const Center(child: Text('No ramps for this condition.'));
    }

    final Map<String, List<RampItem>> byBrand = {};
    for (final item in filtered) {
      byBrand.putIfAbsent(item.brand, () => []).add(item);
    }
    final brands = byBrand.keys.toList()..sort();

    return ListView(
      children: brands.map((brand) {
        final brandItems = byBrand[brand]!;
        return ExpansionTile(
          title: Text(
            brand,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          children: brandItems.map((item) {
            final key = _keyFor(item.itemId, condition);
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: ListTile(
                title: Text(item.size),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Current: ${item.currentQty} (Min: ${item.minQty})'),
                    TextField(
                      key: ValueKey(key),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'New quantity',
                      ),
                      onChanged: (v) =>
                          _onQtyChanged(item.itemId, condition, v),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Full Inventory Check – Ramps'),
      ),
      body: FutureBuilder<InventoryData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading inventory:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          final data = snapshot.data!;
          return Column(
            children: [
              const SizedBox(height: 8),
              _buildConditionToggle(_rampCondition, (value) {
                setState(() {
                  _rampCondition = value;
                });
              }),
              const SizedBox(height: 8),
              Expanded(
                child: _buildRampList(data.ramps, _rampCondition),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: ElevatedButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: Text(_submitting ? 'Submitting...' : 'Submit Full Check'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// =======================
/// JOB ADJUSTMENT – RAMPS ONLY
/// =======================

class JobAdjustmentScreen extends StatefulWidget {
  const JobAdjustmentScreen({super.key});

  @override
  State<JobAdjustmentScreen> createState() => _JobAdjustmentScreenState();
}

class _JobAdjustmentScreenState extends State<JobAdjustmentScreen>
    with SingleTickerProviderStateMixin {
  late Future<InventoryData> _future;
  final Map<String, String> _quantities = {}; // key: itemId|condition
  bool _submitting = false;

  late TabController _tabController; // 0 = Install, 1 = Removal
  String _installCondition = 'New';
  String _jobRef = '';

  @override
  void initState() {
    super.initState();
    _future = fetchInventory();
    _tabController = TabController(length: 2, vsync: this);
  }

  String _keyFor(String itemId, String condition) => '$itemId|$condition';

  void _onQtyChanged(String itemId, String condition, String value) {
    final key = _keyFor(itemId, condition);
    setState(() {
      if (value.trim().isEmpty) {
        _quantities.remove(key);
      } else {
        _quantities[key] = value.trim();
      }
    });
  }

  Future<Map<String, String>> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString('user_name') ?? '',
      'email': prefs.getString('user_email') ?? '',
    };
  }

  Future<void> _submit() async {
    if (_submitting) return;

    setState(() {
      _submitting = true;
    });

    try {
      final user = await _loadUser();
      final userEmail = user['email'] ?? '';
      final userName = user['name'] ?? '';
      if (userEmail.isEmpty || userName.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please set your name & email in the main screen.')),
        );
        setState(() {
          _submitting = false;
        });
        return;
      }

      if (_jobRef.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a job reference.')),
        );
        setState(() {
          _submitting = false;
        });
        return;
      }

      final data = await _future;
      final List<Map<String, dynamic>> items = [];
      int parseInt(String v) => int.tryParse(v) ?? 0;

      final isInstall = _tabController.index == 0;

      // Ramps only
      final effectiveCondition = isInstall ? _installCondition : 'Used';
      for (final item in data.ramps) {
        if (item.condition != effectiveCondition) continue;

        final key = _keyFor(item.itemId, effectiveCondition);
        final raw = _quantities[key];
        if (raw == null || raw.isEmpty) continue;
        final qty = parseInt(raw);
        if (qty <= 0) continue;

        final delta = isInstall ? -qty : qty;
        items.add({
          'item_id': item.itemId,
          'category': 'ramp',
          'delta': delta,
          'condition': effectiveCondition,
        });
      }

      if (items.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter at least one quantity')),
        );
        setState(() {
          _submitting = false;
        });
        return;
      }

      await submitJobAdjustment(
        userEmail: userEmail,
        userName: userName,
        jobRef: _jobRef.trim(),
        items: items,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Job adjustment submitted')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error submitting: $e')),
      );
      setState(() {
        _submitting = false;
      });
    }
  }

  Widget _buildConditionToggle() {
    // Only used on Install tab
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ChoiceChip(
          label: const Text('New'),
          selected: _installCondition == 'New',
          onSelected: (_) {
            setState(() {
              _installCondition = 'New';
            });
          },
          selectedColor: kBrandGreen.withOpacity(0.2),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('Used'),
          selected: _installCondition == 'Used',
          onSelected: (_) {
            setState(() {
              _installCondition = 'Used';
            });
          },
          selectedColor: kBrandGreen.withOpacity(0.2),
        ),
      ],
    );
  }

  Widget _buildRampList(List<RampItem> items, bool isInstall) {
    final effectiveCondition = isInstall ? _installCondition : 'Used';
    final filtered =
        items.where((i) => i.condition == effectiveCondition).toList();

    final Map<String, List<RampItem>> byBrand = {};
    for (final item in filtered) {
      byBrand.putIfAbsent(item.brand, () => []).add(item);
    }
    final brands = byBrand.keys.toList()..sort();

    return SingleChildScrollView(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Text(
              'Ramps',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          ...brands.map((brand) {
            final brandItems = byBrand[brand]!;
            return ExpansionTile(
              title: Text(
                brand,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              children: brandItems.map((item) {
                final condition = effectiveCondition;
                final key = _keyFor(item.itemId, condition);
                final controllerValue = _quantities[key] ?? '';
                final controller = TextEditingController(text: controllerValue);

                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: ListTile(
                    title: Text(item.size),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Current $condition: ${item.currentQty}'),
                        TextField(
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Quantity',
                          ),
                          controller: controller,
                          onChanged: (v) =>
                              _onQtyChanged(item.itemId, condition, v),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            );
          }).toList(),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isInstall = _tabController.index == 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Job Adjustment – Ramps'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Install'),
            Tab(text: 'Removal'),
          ],
        ),
      ),
      body: FutureBuilder<InventoryData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading inventory:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          final data = snapshot.data!;
          return Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Job reference (e.g., customer name / location)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    setState(() {
                      _jobRef = v;
                    });
                  },
                ),
              ),
              if (isInstall) _buildConditionToggle(),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildRampList(data.ramps, true),
                    _buildRampList(data.ramps, false),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: ElevatedButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: Text(_submitting ? 'Submitting...' : 'Submit Adjustment'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

/// =======================
/// LIFTS (per-lift view)
/// =======================

class LiftsScreen extends StatefulWidget {
  const LiftsScreen({super.key});

  @override
  State<LiftsScreen> createState() => _LiftsScreenState();
}

class _LiftsScreenState extends State<LiftsScreen> {
  late Future<List<LiftRecord>> _future;
  String _search = '';
  String? _statusFilter;

  @override
  void initState() {
    super.initState();
    _future = fetchLifts();
  }

  void _refresh() {
    setState(() {
      _future = fetchLifts();
    });
  }

  void _openLiftForm({LiftRecord? lift}) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LiftFormScreen(existing: lift),
      ),
    );
    if (result == true) {
      _refresh();
    }
  }

  void _openStairliftQuantities() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StairliftQuantitiesScreen(),
      ),
    );
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChangeHistoryScreen(),
      ),
    );
  }

  Future<void> _openUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final userName = prefs.getString('user_name') ?? '';
    final userEmail = prefs.getString('user_email') ?? '';

    final nameController = TextEditingController(text: userName);
    final emailController = TextEditingController(text: userEmail);

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('User Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration:
                    const InputDecoration(labelText: 'Your name (for logs)'),
              ),
              TextField(
                controller: emailController,
                decoration:
                    const InputDecoration(labelText: 'Your email (for logs)'),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kBrandGreen,
                foregroundColor: Colors.white,
              ),
              child: const Text('Save'),
              onPressed: () async {
                await prefs.setString('user_name', nameController.text.trim());
                await prefs.setString('user_email', emailController.text.trim());
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lifts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt),
            tooltip: 'Stairlift quantities',
            onPressed: _openStairliftQuantities,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'User settings',
            onPressed: _openUserSettings,
          ),
        ],
      ),
      body: FutureBuilder<List<LiftRecord>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading lifts:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          final lifts = snapshot.data ?? [];
          final statuses = (lifts
                  .map((l) => l.status.trim())
                  .where((s) => s.isNotEmpty)
                  .toSet()
                  .toList()
                ..sort());

          final filtered = lifts.where((l) {
            if (_statusFilter != null &&
                _statusFilter!.isNotEmpty &&
                l.status.trim() != _statusFilter) {
              return false;
            }

            if (_search.isNotEmpty) {
              final haystack = [
                l.serialNumber,
                l.brand,
                l.series,
                l.currentLocation,
                l.currentJob,
              ].join(' ').toLowerCase();
              if (!haystack.contains(_search)) return false;
            }

            return true;
          }).toList();

          return Column(
            children: [
              _buildLiftsFilters(statuses),
              if (filtered.isEmpty)
                const Expanded(
                  child: Center(
                    child: Text('No lifts found with current filters.'),
                  ),
                )
              else
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () async {
                      setState(() {
                        _future = fetchLifts();
                      });
                      await _future;
                    },
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final l = filtered[index];
                        final status = l.status.isEmpty ? 'Unknown' : l.status;
                        final loc = l.currentLocation.isEmpty
                            ? 'Location: N/A'
                            : 'Location: ${l.currentLocation}';
                        final job = l.currentJob.isEmpty
                            ? 'Job: N/A'
                            : 'Job: ${l.currentJob}';

                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: ListTile(
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => LiftDetailScreen(
                                    lift: l,
                                  ),
                                ),
                              );
                            },
                            title: Text(
                              '${l.brand}${l.series.isNotEmpty ? ' – ${l.series}' : ''}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('SN: ${l.serialNumber.isNotEmpty ? l.serialNumber : 'N/A'}'),
                                Text('Status: $status'),
                                Text(loc),
                                Text(job),
                                if (l.preppedStatus.isNotEmpty)
                                  Text('Prep: ${l.preppedStatus}'),
                                if (l.notes.isNotEmpty)
                                  Text('Notes: ${l.notes}'),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openLiftForm(),
        backgroundColor: kBrandGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Lift'),
      ),
    );
  }

  Widget _buildLiftsFilters(List<String> statuses) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by serial, brand, or location...',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() {
                _search = value.trim().toLowerCase();
              });
            },
          ),
        ),
        if (statuses.isNotEmpty)
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DropdownButton<String>(
                value: _statusFilter ?? '',
                hint: const Text('All statuses'),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('All statuses'),
                  ),
                  ...statuses.map(
                    (s) => DropdownMenuItem<String>(
                      value: s,
                      child: Text(s),
                    ),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _statusFilter =
                        (value == null || value.isEmpty) ? null : value;
                  });
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// =======================
/// STAIRLIFT QUANTITIES (read-only)
/// =======================

class StairliftQuantitiesScreen extends StatefulWidget {
  StairliftQuantitiesScreen({super.key});

  @override
  State<StairliftQuantitiesScreen> createState() =>
      _StairliftQuantitiesScreenState();
}

class _StairliftQuantitiesScreenState
    extends State<StairliftQuantitiesScreen> {
  late Future<List<LiftRecord>> _liftsFuture;
  late Future<InventoryData> _inventoryFuture; // Still need for min_qty from old sheet

  String _searchQuery = '';
  String _stairliftConditionFilter = 'New';
  bool _showBelowMinOnlyStairlifts = false;
  String? _stairliftBrandFilter;

  @override
  void initState() {
    super.initState();
    _liftsFuture = fetchLifts();
    _inventoryFuture = fetchInventory();
  }

  void _refresh() {
    setState(() {
      _liftsFuture = fetchLifts();
      _inventoryFuture = fetchInventory();
    });
  }

  Widget _buildFilterRow() {
    final conditionValue = _stairliftConditionFilter;
    final belowMinValue = _showBelowMinOnlyStairlifts;

    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('New'),
                selected: conditionValue == 'New',
                onSelected: (_) {
                  setState(() {
                    _stairliftConditionFilter = 'New';
                  });
                },
                selectedColor: kBrandGreen.withOpacity(0.2),
              ),
              ChoiceChip(
                label: const Text('Used'),
                selected: conditionValue == 'Used',
                onSelected: (_) {
                  setState(() {
                    _stairliftConditionFilter = 'Used';
                  });
                },
                selectedColor: kBrandGreen.withOpacity(0.2),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: belowMinValue,
              onChanged: (val) {
                setState(() {
                  _showBelowMinOnlyStairlifts = val;
                });
              },
              activeColor: kBrandGreen,
            ),
            const Text(
              'Below min only',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSummaryRow({
    required int totalUnits,
    required int totalNew,
    required int totalUsed,
    required int belowMinCount,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Stairlifts Summary',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: _SummaryStat(
                      label: 'Total units',
                      value: totalUnits.toString(),
                    ),
                  ),
                  Expanded(
                    child: _SummaryStat(
                      label: 'New',
                      value: totalNew.toString(),
                    ),
                  ),
                  Expanded(
                    child: _SummaryStat(
                      label: 'Used',
                      value: totalUsed.toString(),
                    ),
                  ),
                  Expanded(
                    child: _SummaryStat(
                      label: 'Below min',
                      value: belowMinCount.toString(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStairliftList(List<StairliftItem> items, String condition) {
    final filtered = items.where((i) => i.condition == condition).toList();
    if (filtered.isEmpty) {
      return const Center(child: Text('No stairlifts for this condition.'));
    }

    final Map<String, List<StairliftItem>> byBrand = {};
    for (final item in filtered) {
      byBrand.putIfAbsent(item.brand, () => []).add(item);
    }
    final brands = byBrand.keys.toList()..sort();

    return ListView(
      children: [
        Padding(
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  child: TextField(
    decoration: const InputDecoration(
      prefixIcon: Icon(Icons.search),
      hintText: 'Search by brand, series...',
      border: OutlineInputBorder(),
    ),
    onChanged: (value) {
      setState(() {
        _searchQuery = value.trim().toLowerCase();
      });
    },
  ),
),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by brand, series...',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value.trim().toLowerCase();
              });
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: _buildFilterRow(),
        ),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: DropdownButton<String>(
              value: _stairliftBrandFilter ?? '',
              hint: const Text('All brands'),
              items: <DropdownMenuItem<String>>[
                const DropdownMenuItem<String>(
                  value: '',
                  child: Text('All brands'),
                ),
                ...brands.map(
                  (brand) => DropdownMenuItem<String>(
                    value: brand,
                    child: Text(brand),
                  ),
                ),
              ],
              onChanged: (value) {
                setState(() {
                  _stairliftBrandFilter =
                      (value == null || value.isEmpty) ? null : value;
                });
              },
            ),
          ),
        ),
        const SizedBox(height: 4),
        ...brands.expand((brand) {
          final brandItems = byBrand[brand]!;
          final visibleItems = brandItems.where((item) {
            if (_stairliftBrandFilter != null &&
                _stairliftBrandFilter!.isNotEmpty &&
                item.brand != _stairliftBrandFilter) {
              return false;
            }
            if (_showBelowMinOnlyStairlifts &&
                !(item.currentQty < item.minQty && item.minQty > 0)) {
              return false;
            }
            if (_searchQuery.isNotEmpty) {
              final haystack =
                  '${item.brand} ${item.series} ${item.orientation}'
                      .toLowerCase();
              if (!haystack.contains(_searchQuery)) return false;
            }
            return true;
          }).toList();

          if (visibleItems.isEmpty) return <Widget>[];

          return [
            ExpansionTile(
              title: Text(
                brand,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              children: visibleItems.map((item) {
                final belowMin =
                    item.currentQty < item.minQty && item.minQty > 0;
                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  color: belowMin ? Colors.red.shade50 : null,
                  child: ListTile(
                    title: Text(
                      item.series.isEmpty ? item.itemId : item.series,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: belowMin ? Colors.red.shade700 : null,
                      ),
                    ),
                    subtitle: Text(
                        'Condition: ${item.condition} • ${item.orientation}'),
                    trailing: SizedBox(
                      width: 60,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                              'Qty',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.black54),
                            ),
                            Text(
                              '${item.currentQty}',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: belowMin
                                    ? Colors.red.shade700
                                    : Colors.black,
                              ),
                            ),
                            Text(
                              'Min ${item.minQty}',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ];
        }).toList(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stairlift Quantities'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: Future.wait([_liftsFuture, _inventoryFuture]),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading data:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          final lifts = snapshot.data![0] as List<LiftRecord>;
          final inventoryData = snapshot.data![1] as InventoryData;

          // Calculate stairlift quantities from lifts with status "In Stock"
          final inStockLifts = lifts.where((l) => l.status == 'In Stock').toList();

          // Group by brand + series + condition and count
          final Map<String, int> counts = {};
          for (final lift in inStockLifts) {
            final key = '${lift.brand}|${lift.series}|${lift.orientation}|${lift.condition}';
            counts[key] = (counts[key] ?? 0) + 1;
          }

          // Get min_qty values from the old inventory sheet
          final Map<String, int> minQtyMap = {};
          for (final s in inventoryData.stairlifts) {
            final key = '${s.brand}|${s.series}|${s.orientation}|${s.condition}';
            minQtyMap[key] = s.minQty;
          }

          // Build StairliftItem list from calculated counts
          final List<StairliftItem> stairlifts = [];
          final allKeys = {...counts.keys, ...minQtyMap.keys};

          for (final key in allKeys) {
            final parts = key.split('|');
            if (parts.length != 4) continue;

            final brand = parts[0];
            final series = parts[1];
            final orientation = parts[2];
            final condition = parts[3];
            final currentQty = counts[key] ?? 0;
            final minQty = minQtyMap[key] ?? 0;

            stairlifts.add(StairliftItem(
              itemId: key,
              brand: brand,
              series: series,
              orientation: orientation,
              foldType: '',
              condition: condition,
              minQty: minQty,
              currentQty: currentQty,
              active: true,
              notes: '',
            ));
          }

          int totalUnits = 0;
          int totalNew = 0;
          int totalUsed = 0;
          int belowMinCount = 0;
          for (final s in stairlifts) {
            totalUnits += s.currentQty;
            if (s.condition == 'New') totalNew += s.currentQty;
            if (s.condition == 'Used') totalUsed += s.currentQty;
            if (s.currentQty < s.minQty && s.minQty > 0) {
              belowMinCount++;
            }
          }

          return Column(
            children: [
              _buildSummaryRow(
                totalUnits: totalUnits,
                totalNew: totalNew,
                totalUsed: totalUsed,
                belowMinCount: belowMinCount,
              ),
              Expanded(
                child: _buildStairliftList(
                    stairlifts, _stairliftConditionFilter),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// =======================
/// CHANGE HISTORY (grouped per submission)
/// =======================

class ChangeHistoryScreen extends StatefulWidget {
  const ChangeHistoryScreen({super.key});

  @override
  State<ChangeHistoryScreen> createState() => _ChangeHistoryScreenState();
}

class _ChangeHistoryScreenState extends State<ChangeHistoryScreen> {
  late Future<List<InventoryChange>> _future;

  @override
  void initState() {
    super.initState();
    _future = fetchChanges();
  }

  void _refresh() {
    setState(() {
      _future = fetchChanges();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Change History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<InventoryChange>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading changes:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          final changes = snapshot.data ?? [];

          // Group by (changeType + timestamp + jobRef) so all rows from one
          // submission appear on a single tile.
          final Map<String, List<InventoryChange>> grouped = {};
          for (final c in changes) {
            final tsKey = c.timestamp?.toIso8601String() ?? '';
            final key = '${c.changeType}|$tsKey|${c.jobRef}';
            grouped.putIfAbsent(key, () => []).add(c);
          }

          final groups = grouped.values.toList()
            ..sort((a, b) {
              final ta = a.first.timestamp?.millisecondsSinceEpoch ?? 0;
              final tb = b.first.timestamp?.millisecondsSinceEpoch ?? 0;
              return tb.compareTo(ta);
            });

          if (groups.isEmpty) {
            return const Center(child: Text('No changes logged yet.'));
          }

          return ListView.builder(
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final group = groups[index];
              final first = group.first;
              final ts = formatDate(first.timestamp);

              final titleSuffix = first.jobRef.isNotEmpty
                  ? first.jobRef
                  : (group.length == 1 ? first.itemId : 'Multiple items');

              return Card(
                margin:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${first.changeType} – $titleSuffix',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        ts,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 6),
                      ...group.map((c) {
                        final itemLabel = [
                          c.brand,
                          c.seriesOrSize,
                          if (c.orientation.isNotEmpty) c.orientation,
                        ].where((s) => s.isNotEmpty).join(' ');
                        final displayItem =
                            itemLabel.isEmpty ? c.itemId : itemLabel;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: Text(
                            '• $displayItem (${c.condition}): '
                            'Changed from ${c.oldQty} to ${c.newQty}',
                            style: const TextStyle(fontSize: 13),
                          ),
                        );
                      }).toList(),
                      const SizedBox(height: 6),
                      if (first.note.isNotEmpty)
                        Text(
                          'Note: ${first.note}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      Text(
                        'By: ${first.userName} (${first.userEmail})',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black87),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// =======================
/// LIFT DETAIL (with history + service tabs)
/// =======================

class LiftDetailScreen extends StatefulWidget {
  final LiftRecord lift;

  const LiftDetailScreen({super.key, required this.lift});

  @override
  State<LiftDetailScreen> createState() => _LiftDetailScreenState();
}

class _LiftDetailScreenState extends State<LiftDetailScreen> {
  late Future<List<LiftHistoryEvent>> _historyFuture;
  late Future<List<LiftServiceRecord>> _serviceFuture;
  late Future<List<PrepChecklist>> _prepChecklistsFuture;

  String get _liftIdForApi => widget.lift.liftId;
  String get _serialForApi => widget.lift.serialNumber;

  @override
  void initState() {
    super.initState();

    // History is now keyed purely by serial number
    _historyFuture = fetchLiftHistory(
      serialNumber: _serialForApi,
    );

    // Service is also keyed purely by serial number
    _serviceFuture = fetchLiftService(
      serialNumber: _serialForApi,
    );

    // Prep checklists are also keyed by serial number
    _prepChecklistsFuture = fetchPrepChecklists(
      serialNumber: _serialForApi,
    );
  }

  void _openEdit() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LiftFormScreen(existing: widget.lift),
      ),
    );
    if (result == true && mounted) {
      Navigator.of(context).pop(); // back to list; it will refresh there
    }
  }

  Future<void> _refreshService() async {
    try {
      // Re-fetch the service records for this lift (keyed by serial number)
      _serviceFuture = fetchLiftService(
        serialNumber: _serialForApi,
      );
      // Trigger a rebuild so UI reflects the new future
      if (mounted) setState(() {});
    } catch (e, st) {
      debugPrint('Failed to refresh services: \$e\n\$st');
      if (mounted) setState(() {});
    }
  }

  void _openAddService() async {

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LiftServiceFormScreen(lift: widget.lift),
      ),
    );
    if (result == true && mounted) {
      _refreshService();
    }
  }

  Widget _buildDetailsTab() {
    final lift = widget.lift;
    final fields = <String, String>{
      'Serial number': lift.serialNumber,
      'Brand': lift.brand,
      'Series': lift.series,
      'Orientation': lift.orientation,
      'Fold type': lift.foldType,
      'Condition': lift.condition,
      'Status': lift.status,
      'Prepped status': lift.preppedStatus,
      'Current location': lift.currentLocation,
      'Current job': lift.currentJob,
      'Date acquired': lift.dateAcquired,
      'Install date': lift.installDate,
      'Installer name': lift.installerName,
      'Last prep date': lift.lastPrepDate,
      'Notes': lift.notes,
    };

    return ListView(
      padding: const EdgeInsets.all(12.0),
      children: fields.entries
          .where((e) => e.value.isNotEmpty)
          .map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.key,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    e.value,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _buildHistoryTab() {
    return FutureBuilder<List<LiftHistoryEvent>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading history:\n${snapshot.error}',
              textAlign: TextAlign.center,
            ),
          );
        }

        final events = snapshot.data ?? [];
        if (events.isEmpty) {
          return const Center(
            child: Text('No movement history recorded for this lift yet.'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12.0),
          itemCount: events.length,
          itemBuilder: (context, index) {
            final e = events[index];
            final ts = formatDate(e.timestamp);
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(e.status.isEmpty ? 'Status change' : e.status),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ts),
                    if (e.location.isNotEmpty) Text('Location: ${e.location}'),
                    if (e.jobRef.isNotEmpty) Text('Job: ${e.jobRef}'),
                    if (e.note.isNotEmpty) Text('Note: ${e.note}'),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildServiceTab() {
    return FutureBuilder<List<LiftServiceRecord>>(
      future: _serviceFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading service records:\n${snapshot.error}',
              textAlign: TextAlign.center,
            ),
          );
        }

        final records = snapshot.data ?? [];
        if (records.isEmpty) {
          return const Center(
            child: Text('No service records for this lift yet.'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12.0),
          itemCount: records.length,
          itemBuilder: (context, index) {
            final r = records[index];
            final ts = formatDate(r.serviceDate);
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(
                    r.serviceType.isEmpty ? 'Service visit' : r.serviceType),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ts),
                    if (r.description.isNotEmpty)
                      Text('Description: ${r.description}'),
                    if (r.invoiceNumber.isNotEmpty)
                      Text('Invoice: ${r.invoiceNumber}'),
                    if (r.technicianName.isNotEmpty)
                      Text('Tech: ${r.technicianName}'),
                    if (r.jobRef.isNotEmpty) Text('Job: ${r.jobRef}'),
                    if (r.customerName.isNotEmpty)
                      Text('Customer: ${r.customerName}'),
                    if (r.notes.isNotEmpty) Text('Notes: ${r.notes}'),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPrepHistoryTab() {
    return FutureBuilder<List<PrepChecklist>>(
      future: _prepChecklistsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading prep checklists:\n${snapshot.error}',
              textAlign: TextAlign.center,
            ),
          );
        }

        final checklists = snapshot.data ?? [];
        if (checklists.isEmpty) {
          return const Center(
            child: Text('No prep checklists for this lift yet.'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12.0),
          itemCount: checklists.length,
          itemBuilder: (context, index) {
            final c = checklists[index];
            final prepDate = formatDate(c.timestamp);
            final completedCount = c.checklistItems.values.where((v) => v).length;
            final totalCount = c.checklistItems.length;

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text('${c.brand} ${c.series}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(prepDate),
                    Text('Prepped by: ${c.preppedByName}'),
                    Text('Completed: $completedCount/$totalCount items'),
                    if (c.notes.isNotEmpty) Text('Notes: ${c.notes}'),
                  ],
                ),
                onTap: () async {
                  // Open the checklist form in view/edit mode
                  final result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => PrepChecklistFormScreen(
                        lift: widget.lift,
                        existingChecklist: c,
                      ),
                    ),
                  );
                  if (result == true && mounted) {
                    // Refresh the prep checklists
                    setState(() {
                      _prepChecklistsFuture = fetchPrepChecklists(
                        serialNumber: _serialForApi,
                      );
                    });
                  }
                },
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.lift.serialNumber.isNotEmpty
        ? 'Lift ${widget.lift.serialNumber}'
        : 'Lift details';

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: _openEdit,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Details'),
              Tab(text: 'Locations'),
              Tab(text: 'Service'),
              Tab(text: 'Prep History'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildDetailsTab(),
            _buildHistoryTab(),
            _buildServiceTab(),
            _buildPrepHistoryTab(),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _openAddService,
          backgroundColor: kBrandGreen,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.build),
          label: const Text('Add Service'),
        ),
      ),
    );
  }
}

/// =======================
/// LIFT SERVICE FORM
/// =======================

class LiftServiceFormScreen extends StatefulWidget {
  final LiftRecord lift;

  const LiftServiceFormScreen({super.key, required this.lift});

  @override
  State<LiftServiceFormScreen> createState() => _LiftServiceFormScreenState();
}

class _LiftServiceFormScreenState extends State<LiftServiceFormScreen> {
  final _formKey = GlobalKey<FormState>();

  final _dateController = TextEditingController();
  final _typeController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _invoiceController = TextEditingController();
  final _jobRefController = TextEditingController();
  final _customerController = TextEditingController();
  final _notesController = TextEditingController();

  bool _saving = false;

  String get _liftIdForApi => widget.lift.liftId;
  String get _serialForApi => widget.lift.serialNumber;

  @override
  void dispose() {
    _dateController.dispose();
    _typeController.dispose();
    _descriptionController.dispose();
    _invoiceController.dispose();
    _jobRefController.dispose();
    _customerController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString('user_name') ?? '',
      'email': prefs.getString('user_email') ?? '',
    };
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final user = await _loadUser();
    final userEmail = user['email'] ?? '';
    final userName = user['name'] ?? '';
    if (userEmail.isEmpty || userName.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Please set your name & email from the main screens.')),
      );
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await addLiftService(
        userEmail: userEmail,
        userName: userName,
        serialNumber: _serialForApi,
        serviceDate: _dateController.text.trim(),
        serviceType: _typeController.text.trim(),
        description: _descriptionController.text.trim(),
        invoiceNumber: _invoiceController.text.trim(),
        jobRef: _jobRefController.text.trim(),
        customerName: _customerController.text.trim(),
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Service record added')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving service record: $e')),
      );
      setState(() {
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final liftLabel = widget.lift.serialNumber.isNotEmpty
        ? widget.lift.serialNumber
        : '${widget.lift.brand} ${widget.lift.series}';

    return Scaffold(
      appBar: AppBar(
        title: Text('Add Service – $liftLabel'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(12.0),
          children: [
            Text(
              'Lift: $liftLabel',
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _dateController,
              decoration: const InputDecoration(
                labelText: 'Service date (YYYY-MM-DD)',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Service date is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _typeController,
              decoration: const InputDecoration(
                labelText: 'Service type (e.g., PM, Repair)',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Service type is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _invoiceController,
              decoration: const InputDecoration(
                labelText: 'Invoice number',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _jobRefController,
              decoration: const InputDecoration(
                labelText: 'Job reference',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _customerController,
              decoration: const InputDecoration(
                labelText: 'Customer name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving...' : 'Save Service Record'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: kBrandGreen,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// =======================
/// LIFT FORM (new / edit)
/// =======================

class LiftFormScreen extends StatefulWidget {
  final LiftRecord? existing;

  const LiftFormScreen({super.key, this.existing});

  @override
  State<LiftFormScreen> createState() => _LiftFormScreenState();
}

class _LiftFormScreenState extends State<LiftFormScreen> {
  final _formKey = GlobalKey<FormState>();

  bool _loadingInventory = true;
  String? _inventoryError;

  // Brand/series/orientation/fold maps derived from stairlift inventory sheet.
  List<String> _brands = [];
  Map<String, List<String>> _seriesByBrand = {};
  Map<String, List<String>> _orientationByBrandSeries = {};
  Map<String, List<String>> _foldByBrandSeriesOrientation = {};

  String? _selectedBrand;
  String? _selectedSeries;
  String? _selectedOrientation;
  String? _selectedFoldType;

  String _condition = 'New';
  String _status = 'In Stock';
  String _preppedStatus = 'Needs prepping';

  final _serialController = TextEditingController();
  final _dateAcquiredController = TextEditingController();
  final _currentLocationController = TextEditingController();
  final _currentJobController = TextEditingController();
  final _installDateController = TextEditingController();
  final _installerNameController = TextEditingController();
  final _lastPrepDateController = TextEditingController();
  final _notesController = TextEditingController();

  bool _saving = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();

    final existing = widget.existing;
    if (existing != null) {
      _serialController.text = existing.serialNumber;
      _dateAcquiredController.text = existing.dateAcquired;
      _currentLocationController.text = existing.currentLocation;
      _currentJobController.text = existing.currentJob;
      _installDateController.text = existing.installDate;
      _installerNameController.text = existing.installerName;
      _lastPrepDateController.text = existing.lastPrepDate;
      _notesController.text = existing.notes;

      if (existing.condition.toLowerCase() == 'used') {
        _condition = 'Used';
      } else {
        _condition = 'New';
      }
      _status = existing.status.isNotEmpty ? existing.status : 'In Stock';
      _preppedStatus = existing.preppedStatus.isNotEmpty
          ? existing.preppedStatus
          : 'Needs prepping';
    }

    _loadInventory();
  }

  Future<void> _loadInventory() async {
    try {
      final data = await fetchInventory();

      final activeStairlifts =
          data.stairlifts.where((s) => s.active).toList();

      final brandsSet = <String>{};
      final Map<String, Set<String>> seriesSets = {};
      final Map<String, Set<String>> orientationSets = {};
      final Map<String, Set<String>> foldSets = {};

      for (final s in activeStairlifts) {
        if (s.brand.isEmpty || s.series.isEmpty) continue;
        brandsSet.add(s.brand);

        seriesSets.putIfAbsent(s.brand, () => <String>{}).add(s.series);

        final bsKey = '${s.brand}||${s.series}';
        orientationSets.putIfAbsent(bsKey, () => <String>{});
        if (s.orientation.isNotEmpty) {
          orientationSets[bsKey]!.add(s.orientation);
        }

        final bsoKey = '${s.brand}||${s.series}||${s.orientation}';
        foldSets.putIfAbsent(bsoKey, () => <String>{});
        if (s.foldType.isNotEmpty) {
          foldSets[bsoKey]!.add(s.foldType);
        }
      }

      final brands = brandsSet.toList()..sort();
      final seriesByBrand = <String, List<String>>{};
      final orientationByBrandSeries = <String, List<String>>{};
      final foldByBrandSeriesOrientation = <String, List<String>>{};

      for (final entry in seriesSets.entries) {
        final list = entry.value.toList()..sort();
        seriesByBrand[entry.key] = list;
      }
      for (final entry in orientationSets.entries) {
        final list = entry.value.toList()..sort();
        orientationByBrandSeries[entry.key] = list;
      }
      for (final entry in foldSets.entries) {
        final list = entry.value.toList()..sort();
        foldByBrandSeriesOrientation[entry.key] = list;
      }

      String? selectedBrand;
      String? selectedSeries;
      String? selectedOrientation;
      String? selectedFoldType;

      if (widget.existing != null) {
        final e = widget.existing!;
        if (brands.contains(e.brand)) {
          selectedBrand = e.brand;
        }

        final seriesList = seriesByBrand[e.brand] ?? [];
        if (seriesList.contains(e.series)) {
          selectedSeries = e.series;
        }

        final keyBS = '${e.brand}||${e.series}';
        final orientList = orientationByBrandSeries[keyBS] ?? [];
        if (orientList.contains(e.orientation)) {
          selectedOrientation = e.orientation;
        }

        final keyFull = '${e.brand}||${e.series}||${e.orientation}';
        final foldList = foldByBrandSeriesOrientation[keyFull] ?? [];
        if (foldList.contains(e.foldType)) {
          selectedFoldType = e.foldType;
        }
      }

      setState(() {
        _brands = brands;
        _seriesByBrand = seriesByBrand;
        _orientationByBrandSeries = orientationByBrandSeries;
        _foldByBrandSeriesOrientation = foldByBrandSeriesOrientation;

        _selectedBrand =
            selectedBrand ?? (brands.isNotEmpty ? brands.first : null);

        if (_selectedBrand != null) {
          final seriesList = _seriesByBrand[_selectedBrand!] ?? [];
          _selectedSeries =
              selectedSeries ?? (seriesList.isNotEmpty ? seriesList.first : null);
          final keyBS = '${_selectedBrand}||${_selectedSeries ?? ''}';
          final orientList = _orientationByBrandSeries[keyBS] ?? [];
          _selectedOrientation = selectedOrientation ??
              (orientList.isNotEmpty ? orientList.first : null);
          final keyFull =
              '${_selectedBrand}||${_selectedSeries ?? ''}||${_selectedOrientation ?? ''}';
          final foldList = _foldByBrandSeriesOrientation[keyFull] ?? [];
          _selectedFoldType =
              selectedFoldType ?? (foldList.isNotEmpty ? foldList.first : null);
        }

        _loadingInventory = false;
      });
    } catch (e) {
      setState(() {
        _inventoryError = e.toString();
        _loadingInventory = false;
      });
    }
  }

  Future<Map<String, String>> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString('user_name') ?? '',
      'email': prefs.getString('user_email') ?? '',
    };
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedBrand == null ||
        _selectedSeries == null ||
        _selectedOrientation == null ||
        _selectedFoldType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select brand, series, and type.')),
      );
      return;
    }

    final user = await _loadUser();
    final userEmail = user['email'] ?? '';
    final userName = user['name'] ?? '';
    if (userEmail.isEmpty || userName.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Please set your name & email from the main screens.')),
      );
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await upsertLift(
        userEmail: userEmail,
        userName: userName,
        serialNumber: _serialController.text.trim(),
        brand: _selectedBrand!,
        series: _selectedSeries!,
        orientation: _selectedOrientation!,
        foldType: _selectedFoldType!,
        condition: _condition,
        status: _status,
        preppedStatus: _preppedStatus,
        currentLocation: _currentLocationController.text.trim(),
        currentJob: _currentJobController.text.trim(),
        dateAcquired: _dateAcquiredController.text.trim().isEmpty
            ? null
            : _dateAcquiredController.text.trim(),
        installDate: _installDateController.text.trim().isEmpty
            ? null
            : _installDateController.text.trim(),
        installerName: _installerNameController.text.trim().isEmpty
            ? null
            : _installerNameController.text.trim(),
        lastPrepDate: _lastPrepDateController.text.trim().isEmpty
            ? null
            : _lastPrepDateController.text.trim(),
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isEditing ? 'Lift updated' : 'New lift added'),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving lift: $e')),
      );
      setState(() {
        _saving = false;
      });
    }
  }

  @override
  void dispose() {
    _serialController.dispose();
    _dateAcquiredController.dispose();
    _currentLocationController.dispose();
    _currentJobController.dispose();
    _installDateController.dispose();
    _installerNameController.dispose();
    _lastPrepDateController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = _isEditing ? 'Edit Lift' : 'New Lift';

    if (_loadingInventory) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_inventoryError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: Text(
            'Error loading lift options:\n$_inventoryError',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(12.0),
          children: [
            TextFormField(
              controller: _serialController,
              decoration: const InputDecoration(
                labelText: 'Serial number',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Serial number is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedBrand,
              items: _brands
                  .map((b) => DropdownMenuItem<String>(
                        value: b,
                        child: Text(b),
                      ))
                  .toList(),
              decoration: const InputDecoration(
                labelText: 'Brand',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _selectedBrand = value;
                  _selectedSeries = null;
                  _selectedOrientation = null;
                  _selectedFoldType = null;
                });
              },
              validator: (v) =>
                  v == null || v.isEmpty ? 'Select a brand' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedSeries,
              items: (_selectedBrand != null
                      ? _seriesByBrand[_selectedBrand!] ?? []
                      : <String>[])
                  .map((s) => DropdownMenuItem<String>(
                        value: s,
                        child: Text(s),
                      ))
                  .toList(),
              decoration: const InputDecoration(
                labelText: 'Series',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _selectedSeries = value;
                  _selectedOrientation = null;
                  _selectedFoldType = null;
                });
              },
              validator: (v) =>
                  v == null || v.isEmpty ? 'Select a series' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedOrientation,
              items: (() {
                if (_selectedBrand == null || _selectedSeries == null) {
                  return <String>[];
                }
                final key = '${_selectedBrand}||${_selectedSeries}';
                return _orientationByBrandSeries[key] ?? [];
              })()
                  .map((o) => DropdownMenuItem<String>(
                        value: o,
                        child: Text(o),
                      ))
                  .toList(),
              decoration: const InputDecoration(
                labelText: 'Orientation',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _selectedOrientation = value;
                  _selectedFoldType = null;
                });
              },
              validator: (v) =>
                  v == null || v.isEmpty ? 'Select an orientation' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedFoldType,
              items: (() {
                if (_selectedBrand == null ||
                    _selectedSeries == null ||
                    _selectedOrientation == null) {
                  return <String>[];
                }
                final key =
                    '${_selectedBrand}||${_selectedSeries}||${_selectedOrientation}';
                return _foldByBrandSeriesOrientation[key] ?? [];
              })()
                  .map((f) => DropdownMenuItem<String>(
                        value: f,
                        child: Text(f),
                      ))
                  .toList(),
              decoration: const InputDecoration(
                labelText: 'Fold type',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _selectedFoldType = value;
                });
              },
              validator: (v) =>
                  v == null || v.isEmpty ? 'Select a fold type' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _condition,
              items: const [
                DropdownMenuItem<String>(
                  value: 'New',
                  child: Text('New'),
                ),
                DropdownMenuItem<String>(
                  value: 'Used',
                  child: Text('Used'),
                ),
              ],
              decoration: const InputDecoration(
                labelText: 'Condition',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _condition = value ?? 'New';
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _status,
              items: const [
                DropdownMenuItem<String>(
                  value: 'In Stock',
                  child: Text('In Stock'),
                ),
                DropdownMenuItem<String>(
                  value: 'Assigned',
                  child: Text('Assigned'),
                ),
                DropdownMenuItem<String>(
                  value: 'Installed',
                  child: Text('Installed'),
                ),
                DropdownMenuItem<String>(
                  value: 'Removed',
                  child: Text('Removed'),
                ),
                DropdownMenuItem<String>(
                  value: 'Scrapped',
                  child: Text('Scrapped'),
                ),
              ],
              decoration: const InputDecoration(
                labelText: 'Status',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _status = value ?? 'In Stock';
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _preppedStatus,
              items: const [
                DropdownMenuItem<String>(
                  value: 'Needs prepping',
                  child: Text('Needs prepping'),
                ),
                DropdownMenuItem<String>(
                  value: 'Prepped',
                  child: Text('Prepped'),
                ),
                DropdownMenuItem<String>(
                  value: 'Not applicable',
                  child: Text('Not applicable'),
                ),
              ],
              decoration: const InputDecoration(
                labelText: 'Prepped status',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) async {
                // If changing from "Needs prepping" to "Prepped", open checklist
                if (_preppedStatus == 'Needs prepping' && value == 'Prepped') {
                  // Need to have brand and series selected to determine checklist type
                  if (_selectedBrand == null || _selectedSeries == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Please select brand and series first'),
                      ),
                    );
                    return;
                  }

                  // Create a temporary LiftRecord for the checklist form
                  final tempLift = LiftRecord(
                    liftId: widget.existing?.liftId ?? '',
                    serialNumber: _serialController.text.trim(),
                    brand: _selectedBrand!,
                    series: _selectedSeries!,
                    orientation: _selectedOrientation ?? '',
                    foldType: _selectedFoldType ?? '',
                    condition: _condition,
                    dateAcquired: _dateAcquiredController.text.trim(),
                    status: _status,
                    currentLocation: _currentLocationController.text.trim(),
                    currentJob: _currentJobController.text.trim(),
                    installDate: _installDateController.text.trim(),
                    installerName: _installerNameController.text.trim(),
                    preppedStatus: _preppedStatus,
                    lastPrepDate: _lastPrepDateController.text.trim(),
                    notes: _notesController.text.trim(),
                  );

                  // Open prep checklist form
                  final result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => PrepChecklistFormScreen(lift: tempLift),
                    ),
                  );

                  // Only update status if checklist was saved
                  if (result == true && mounted) {
                    setState(() {
                      _preppedStatus = 'Prepped';
                      _lastPrepDateController.text = DateTime.now().toString().split(' ')[0];
                    });
                  }
                } else {
                  // Normal status change
                  setState(() {
                    _preppedStatus = value ?? 'Needs prepping';
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _currentLocationController,
              decoration: const InputDecoration(
                labelText: 'Current location',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _currentJobController,
              decoration: const InputDecoration(
                labelText: 'Current job',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _dateAcquiredController,
              decoration: const InputDecoration(
                labelText: 'Date acquired (YYYY-MM-DD)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _installDateController,
              decoration: const InputDecoration(
                labelText: 'Install date (YYYY-MM-DD)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _installerNameController,
              decoration: const InputDecoration(
                labelText: 'Installer name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _lastPrepDateController,
              decoration: const InputDecoration(
                labelText: 'Last prep date (YYYY-MM-DD)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_saving ? 'Saving...' : 'Save Lift'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: kBrandGreen,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
