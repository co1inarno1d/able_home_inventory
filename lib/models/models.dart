// lib/models/models.dart
//
// All data model classes for the Able Home Inventory app.
// Extracted from main.dart to keep the codebase maintainable.

import '../utils/utils.dart';

// ---------------------------------------------------------------------------
// INVENTORY MODELS
// ---------------------------------------------------------------------------

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
      if (s == 'cut') return 'Cut';
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
  final int ccalsQty;
  final bool active;
  final String notes;

  RampItem({
    required this.itemId,
    required this.brand,
    required this.size,
    required this.condition,
    required this.currentQty,
    required this.minQty,
    this.ccalsQty = 0,
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
      ccalsQty: parseInt(json['ccals_qty']),
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
    int parseInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      return int.tryParse(v.toString()) ?? 0;
    }

    return InventoryChange(
      timestamp: parseJsonDate(json['timestamp']),
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

class InventoryData {
  final List<StairliftItem> stairlifts;
  final List<RampItem> ramps;

  InventoryData({
    required this.stairlifts,
    required this.ramps,
  });
}

// ---------------------------------------------------------------------------
// LIFT MODELS
// ---------------------------------------------------------------------------

class LiftRecord {
  final String liftId;
  final String serialNumber;
  final String brand;
  final String series;
  final String orientation;
  final String foldType;
  final String condition;
  final String dateAcquired;
  final String status;
  final String currentLocation;
  final String currentJob;
  final String installDate;
  final String installerName;
  final String preppedStatus;
  final String lastPrepDate;
  final String notes;
  final String binNumber;
  final String cleanBatteriesStatus;
  final List<String> photoUrls;
  final String railType;
  final String acquisitionSource;
  /// UUID of the linked customer record (empty for unlinked lifts).
  final String customerId;
  /// Denormalized customer name for quick display without a join.
  final String customerName;
  /// QuickBooks customer ID for deep-linking and note-writing.
  final String qbCustomerId;
  /// ISO date string (YYYY-MM-DD) or empty. Auto-calculated as installDate + 2 years
  /// but can be overridden. Populated when a lift is marked Installed.
  final String warrantyExpiry;
  /// Amount paid to customer for a buyback acquisition (null for non-buybacks).
  final double? buybackPrice;

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
    required this.binNumber,
    this.cleanBatteriesStatus = '',
    this.photoUrls = const [],
    this.railType = 'Straight',
    this.acquisitionSource = '',
    this.customerId = '',
    this.customerName = '',
    this.qbCustomerId = '',
    this.warrantyExpiry = '',
    this.buybackPrice,
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
      binNumber: s(json['bin_number']),
      currentJob: s(json['current_job']),
      installDate: s(json['install_date']),
      installerName: s(json['installer_name']),
      preppedStatus: s(json['prepped_status']),
      lastPrepDate: s(json['last_prep_date']),
      notes: s(json['notes']),
      cleanBatteriesStatus: s(json['clean_batteries_status']),
      photoUrls: s(json['photo_urls']).isEmpty
          ? []
          : s(json['photo_urls'])
              .split(',')
              .map((u) => u.trim())
              .where((u) => u.isNotEmpty)
              .map(normalizeDrivePhotoUrl)
              .toList(),
      railType:
          s(json['rail_type']).isEmpty ? 'Straight' : s(json['rail_type']),
      acquisitionSource: s(json['acquisition_source']),
      customerId: s(json['customer_id']),
      customerName: s(json['customer_name']),
      qbCustomerId: s(json['qb_customer_id']),
      warrantyExpiry: s(json['warranty_expiry']),
      buybackPrice: json['buyback_price'] != null
          ? double.tryParse(json['buyback_price'].toString())
          : null,
    );
  }

  /// Whether the warranty is currently active (not expired, expiry date set).
  bool get isWarrantyActive {
    if (warrantyExpiry.isEmpty) return false;
    try {
      final exp = DateTime.parse(warrantyExpiry);
      return exp.isAfter(DateTime.now());
    } catch (_) {
      return false;
    }
  }

  /// Days until warranty expires (negative if expired).
  int get daysUntilWarrantyExpiry {
    if (warrantyExpiry.isEmpty) return -9999;
    try {
      final exp = DateTime.parse(warrantyExpiry);
      return exp.difference(DateTime.now()).inDays;
    } catch (_) {
      return -9999;
    }
  }
}

class LiftHistoryEvent {
  final DateTime? timestamp;
  final String status;
  final String location;
  final String jobRef;
  final String note;
  final String userName;
  final String userEmail;
  final String eventType;
  final String serialNumber;
  final String liftId;

  LiftHistoryEvent({
    required this.timestamp,
    required this.status,
    required this.location,
    required this.jobRef,
    required this.note,
    this.userName = '',
    this.userEmail = '',
    this.eventType = '',
    this.serialNumber = '',
    this.liftId = '',
  });

  factory LiftHistoryEvent.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';
    return LiftHistoryEvent(
      timestamp: parseJsonDate(json['timestamp']),
      status: s(json['to_status']).isNotEmpty ? s(json['to_status']) : s(json['from_status']),
      location: s(json['to_location']).isNotEmpty ? s(json['to_location']) : s(json['from_location']),
      jobRef: s(json['job_ref']),
      note: s(json['note']),
      userName: s(json['user_name']),
      userEmail: s(json['user_email']),
      eventType: s(json['event_type']),
      serialNumber: s(json['serial_number']),
      liftId: s(json['lift_id']),
    );
  }
}

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
    String s(dynamic v) => v?.toString() ?? '';
    return LiftServiceRecord(
      serviceDate: parseJsonDate(json['service_date']),
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

    final checklistItems = <String, bool>{};
    json.forEach((key, value) {
      if (value == true ||
          value == 'TRUE' ||
          value == false ||
          value == 'FALSE') {
        checklistItems[key] = (value == true || value == 'TRUE');
      }
    });

    return PrepChecklist(
      checklistId: s(json['checklist_id']),
      timestamp: parseJsonDate(json['timestamp']),
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

// ---------------------------------------------------------------------------
// JOB MODELS
// ---------------------------------------------------------------------------

class AnnualRecord {
  final String annualId;
  final String customerName;
  final String address;
  final String phone;
  final String liftType;
  final String lastServiceDate;
  final String dateRequested;
  final String notes;
  final bool scheduled;
  final String liftId;
  final String serialNumber;

  AnnualRecord({
    required this.annualId,
    required this.customerName,
    required this.address,
    required this.phone,
    required this.liftType,
    required this.lastServiceDate,
    required this.dateRequested,
    required this.notes,
    required this.scheduled,
    this.liftId = '',
    this.serialNumber = '',
  });

  factory AnnualRecord.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';
    final sched = s(json['scheduled']).toLowerCase();
    return AnnualRecord(
      annualId: s(json['annual_id']),
      customerName: s(json['customer_name']),
      address: s(json['address']),
      phone: s(json['phone']),
      liftType: s(json['lift_type']),
      lastServiceDate: s(json['last_service_date']),
      dateRequested: s(json['date_requested']),
      notes: s(json['notes']),
      scheduled: sched == 'true' || sched == 'yes' || sched == '1',
      liftId: s(json['lift_id']),
      serialNumber: s(json['serial_number']),
    );
  }
}

class ServiceJobRecord {
  final String jobId;
  final String jobType;
  final String status;
  final String title;
  final String customerName;
  final String address;
  final String phone;
  final String liftType;
  final String liftId;
  final String serialNumber;
  final String dateRequested;
  final String scheduledDate;
  final String notes;
  final String fundingSource;

  ServiceJobRecord({
    required this.jobId,
    required this.jobType,
    required this.status,
    this.title = '',
    required this.customerName,
    required this.address,
    required this.phone,
    required this.liftType,
    this.liftId = '',
    this.serialNumber = '',
    required this.dateRequested,
    required this.scheduledDate,
    required this.notes,
    this.fundingSource = 'Private',
  });

  factory ServiceJobRecord.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';
    return ServiceJobRecord(
      jobId: s(json['job_id']),
      jobType: s(json['job_type']),
      status: s(json['status']),
      title: s(json['title']),
      customerName: s(json['customer_name']),
      address: s(json['address']),
      phone: s(json['phone']),
      liftType: s(json['lift_type']),
      liftId: s(json['lift_id']),
      serialNumber: s(json['serial_number']),
      dateRequested: s(json['date_requested']),
      scheduledDate: s(json['scheduled_date']),
      notes: s(json['notes']),
      fundingSource: s(json['funding_source']).isEmpty ? 'Private' : s(json['funding_source']),
    );
  }
}

class RemovalJobRecord {
  final String jobId;
  final String status;
  final String title;
  final String customerName;
  final String address;
  final String phone;
  final String liftType;
  final String liftId;
  final String serialNumber;
  final String scheduledDate;
  final String notes;
  final String fundingSource;

  RemovalJobRecord({
    required this.jobId,
    required this.status,
    this.title = '',
    required this.customerName,
    required this.address,
    required this.phone,
    required this.liftType,
    this.liftId = '',
    this.serialNumber = '',
    required this.scheduledDate,
    required this.notes,
    this.fundingSource = 'Private',
  });

  factory RemovalJobRecord.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';
    return RemovalJobRecord(
      jobId: s(json['job_id']),
      status: s(json['status']),
      title: s(json['title']),
      customerName: s(json['customer_name']),
      address: s(json['address']),
      phone: s(json['phone']),
      liftType: s(json['lift_type']),
      liftId: s(json['lift_id']),
      serialNumber: s(json['serial_number']),
      scheduledDate: s(json['scheduled_date']),
      notes: s(json['notes']),
      fundingSource: s(json['funding_source']).isEmpty ? 'Private' : s(json['funding_source']),
    );
  }
}

class WebLeadRecord {
  final int id;
  final DateTime createdAt;
  final String name;
  final String email;
  final String phone;
  final String message;
  final String source;
  final String status;

  WebLeadRecord({
    required this.id,
    required this.createdAt,
    required this.name,
    required this.email,
    required this.phone,
    required this.message,
    required this.source,
    required this.status,
  });

  factory WebLeadRecord.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';
    return WebLeadRecord(
      id: (json['id'] as num).toInt(),
      createdAt: DateTime.parse(json['created_at'].toString()),
      name: s(json['name']),
      email: s(json['email']),
      phone: s(json['phone']),
      message: s(json['message']),
      source: s(json['source']),
      status: s(json['status']),
    );
  }
}

// ---------------------------------------------------------------------------
// CUSTOMER MODEL
// ---------------------------------------------------------------------------

class CustomerRecord {
  final String customerId;
  final String name;
  final String address;
  final String city;
  final String phone;
  final String email;
  final String fundingSource;
  final String qbCustomerId;
  final String notes;
  final DateTime? createdAt;

  const CustomerRecord({
    required this.customerId,
    required this.name,
    required this.address,
    required this.city,
    required this.phone,
    required this.email,
    required this.fundingSource,
    required this.qbCustomerId,
    required this.notes,
    this.createdAt,
  });

  factory CustomerRecord.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';
    return CustomerRecord(
      customerId: s(json['customer_id']),
      name: s(json['name']),
      address: s(json['address']),
      city: s(json['city']).isEmpty ? extractCity(s(json['address'])) : s(json['city']),
      phone: s(json['phone']),
      email: s(json['email']),
      fundingSource: s(json['funding_source']).isEmpty ? 'Private' : s(json['funding_source']),
      qbCustomerId: s(json['qb_customer_id']),
      notes: s(json['notes']),
      createdAt: parseJsonDate(json['created_at']),
    );
  }

  Map<String, dynamic> toJson() => {
    'customer_id': customerId,
    'name': name,
    'address': address,
    'city': city,
    'phone': phone,
    'email': email,
    'funding_source': fundingSource,
    'qb_customer_id': qbCustomerId,
    'notes': notes,
  };

  String get qbUrl => qbCustomerId.isNotEmpty
      ? 'https://app.qbo.intuit.com/app/customerdetail?nameId=$qbCustomerId'
      : 'https://app.qbo.intuit.com/app/customers';
}

// ---------------------------------------------------------------------------
// OPERATIONS HUB MODEL
// ---------------------------------------------------------------------------

/// Unified job type for the Operations Hub.
/// All pending work flows through this model regardless of origin.
enum OpsJobType {
  stairliftInstall,
  stairliftRemoval,
  buyback,
  stairliftService,
  rampInstall,
  rampRemoval,
  annualService,
  webLead,
}

/// Status pipeline for Operations Hub jobs.
enum OpsJobStatus {
  needsInfo,
  waitingAgencyConfirmation,
  readyToSchedule,
  scheduled,
  completed,
}

class OpsJob {
  final String jobId;
  final OpsJobType jobType;
  OpsJobStatus status;
  final String customerName;
  final String address;
  final String city; // extracted from address for display + geo clustering
  final String phone;
  final String liftType;
  final String liftId;
  final String serialNumber;
  final String fundingSource; // 'Private', 'VA', 'CCALS', 'NaviCare', 'Summit', 'Fallon', 'Mass Health', 'Other'
  final String notes;
  final DateTime? dateRequested;
  final DateTime? scheduledDate;
  // Buyback-specific
  final double? buybackOfferPrice;
  // Source reference for linking back to original record
  final String sourceTable; // 'service_jobs', 'removal_jobs', 'annuals', 'web_leads', 'ops_jobs'
  final String sourceId;

  OpsJob({
    required this.jobId,
    required this.jobType,
    required this.status,
    required this.customerName,
    required this.address,
    required this.city,
    required this.phone,
    required this.liftType,
    this.liftId = '',
    this.serialNumber = '',
    required this.fundingSource,
    required this.notes,
    this.dateRequested,
    this.scheduledDate,
    this.buybackOfferPrice,
    required this.sourceTable,
    required this.sourceId,
  });

  factory OpsJob.fromJson(Map<String, dynamic> json) {
    String s(dynamic v) => v?.toString() ?? '';

    OpsJobType parseType(String v) {
      switch (v) {
        case 'stairlift_install': return OpsJobType.stairliftInstall;
        case 'stairlift_removal': return OpsJobType.stairliftRemoval;
        case 'buyback': return OpsJobType.buyback;
        case 'stairlift_service': return OpsJobType.stairliftService;
        case 'ramp_install': return OpsJobType.rampInstall;
        case 'ramp_removal': return OpsJobType.rampRemoval;
        case 'annual_service': return OpsJobType.annualService;
        case 'web_lead': return OpsJobType.webLead;
        default: return OpsJobType.stairliftService;
      }
    }

    OpsJobStatus parseStatus(String v) {
      switch (v) {
        case 'needs_info': return OpsJobStatus.needsInfo;
        case 'waiting_agency_confirmation': return OpsJobStatus.waitingAgencyConfirmation;
        case 'ready_to_schedule': return OpsJobStatus.readyToSchedule;
        case 'scheduled': return OpsJobStatus.scheduled;
        case 'completed': return OpsJobStatus.completed;
        default: return OpsJobStatus.readyToSchedule;
      }
    }

    double? parseDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return OpsJob(
      jobId: s(json['job_id']),
      jobType: parseType(s(json['job_type'])),
      status: parseStatus(s(json['status'])),
      customerName: s(json['customer_name']),
      address: s(json['address']),
      city: s(json['city']),
      phone: s(json['phone']),
      liftType: s(json['lift_type']),
      liftId: s(json['lift_id']),
      serialNumber: s(json['serial_number']),
      fundingSource: s(json['funding_source']).isEmpty ? 'Private' : s(json['funding_source']),
      notes: s(json['notes']),
      dateRequested: parseJsonDate(json['date_requested']),
      scheduledDate: parseJsonDate(json['scheduled_date']),
      buybackOfferPrice: parseDouble(json['buyback_offer_price']),
      sourceTable: s(json['source_table']),
      sourceId: s(json['source_id']),
    );
  }

  Map<String, dynamic> toJson() => {
    'job_id': jobId,
    'job_type': _jobTypeToString(jobType),
    'status': _statusToString(status),
    'customer_name': customerName,
    'address': address,
    'city': city,
    'phone': phone,
    'lift_type': liftType,
    'lift_id': liftId,
    'serial_number': serialNumber,
    'funding_source': fundingSource,
    'notes': notes,
    'date_requested': dateRequested?.toIso8601String(),
    'scheduled_date': scheduledDate?.toIso8601String(),
    'buyback_offer_price': buybackOfferPrice,
    'source_table': sourceTable,
    'source_id': sourceId,
  };

  static String _jobTypeToString(OpsJobType t) {
    switch (t) {
      case OpsJobType.stairliftInstall: return 'stairlift_install';
      case OpsJobType.stairliftRemoval: return 'stairlift_removal';
      case OpsJobType.buyback: return 'buyback';
      case OpsJobType.stairliftService: return 'stairlift_service';
      case OpsJobType.rampInstall: return 'ramp_install';
      case OpsJobType.rampRemoval: return 'ramp_removal';
      case OpsJobType.annualService: return 'annual_service';
      case OpsJobType.webLead: return 'web_lead';
    }
  }

  static String _statusToString(OpsJobStatus s) {
    switch (s) {
      case OpsJobStatus.needsInfo: return 'needs_info';
      case OpsJobStatus.waitingAgencyConfirmation: return 'waiting_agency_confirmation';
      case OpsJobStatus.readyToSchedule: return 'ready_to_schedule';
      case OpsJobStatus.scheduled: return 'scheduled';
      case OpsJobStatus.completed: return 'completed';
    }
  }

  /// Days since job was requested — used for aging indicators.
  int get daysWaiting {
    if (dateRequested == null) return 0;
    return DateTime.now().difference(dateRequested!).inDays;
  }

  /// Human-readable job type label.
  String get jobTypeLabel {
    switch (jobType) {
      case OpsJobType.stairliftInstall: return 'Stairlift Install';
      case OpsJobType.stairliftRemoval: return 'Stairlift Removal';
      case OpsJobType.buyback: return 'Buyback';
      case OpsJobType.stairliftService: return 'Service Call';
      case OpsJobType.rampInstall: return 'Ramp Install';
      case OpsJobType.rampRemoval: return 'Ramp Removal';
      case OpsJobType.annualService: return 'Annual Service';
      case OpsJobType.webLead: return 'Web Lead';
    }
  }

  /// Human-readable status label.
  String get statusLabel {
    switch (status) {
      case OpsJobStatus.needsInfo: return 'Needs Info';
      case OpsJobStatus.waitingAgencyConfirmation: return 'Waiting Confirmation';
      case OpsJobStatus.readyToSchedule: return 'Ready to Schedule';
      case OpsJobStatus.scheduled: return 'Scheduled';
      case OpsJobStatus.completed: return 'Completed';
    }
  }

  bool get isAgencyFunded => fundingSource != 'Private' && fundingSource.isNotEmpty;

  /// Returns true if this job is active (not completed).
  bool get isActive => status != OpsJobStatus.completed;
}
