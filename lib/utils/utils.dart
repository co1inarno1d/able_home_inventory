// lib/utils/utils.dart
//
// Shared utility functions, constants, and helpers.

import 'package:flutter/material.dart';

import '../qbt_api.dart';

// ---------------------------------------------------------------------------
// COLORS & THEME
// ---------------------------------------------------------------------------

const Color kBrandGreen = Color(0xFF2F7D46);
const Color kBrandGreenDark = Color(0xFF1A4728);
const Color kSurface = Color(0xFFF0F2F0);
const Color kCardSurface = Color(0xFFFFFFFF);
const Color kHeaderText = Color(0xFFE8F5E9);

// ---------------------------------------------------------------------------
// AUTH
// ---------------------------------------------------------------------------

const String kAppPassword = '403marshallst!';
const Duration kAuthCacheDuration = Duration(days: 90);
const String kAuthUntilKey = 'auth_until';

// ---------------------------------------------------------------------------
// DATE HELPERS
// ---------------------------------------------------------------------------

/// Format a DateTime to MM/DD/YYYY.
String formatDate(DateTime? date) {
  if (date == null) return 'Unknown date';
  return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}';
}

/// Parse a date from a JSON value (ISO8601 string or null).
DateTime? parseJsonDate(dynamic v) {
  if (v == null) return null;
  try {
    return DateTime.parse(v.toString());
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// STRING HELPERS
// ---------------------------------------------------------------------------

/// Normalizes bin number display: "43", "bin43", "bin #43" → "Bin 43".
String normalizeBinDisplay(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return s;
  final match = RegExp(r'^bin\s*#?\s*(.+)$', caseSensitive: false).firstMatch(s);
  final number = match != null ? match.group(1)!.trim() : s;
  if (RegExp(r'^\d+$').hasMatch(number)) return 'Bin $number';
  if (match != null) return 'Bin $number';
  return s;
}

/// Extracts the city/town from an address string.
/// Handles "123 Main St, Needham, MA 02492" → "Needham"
/// Falls back to the full address if parsing fails.
String extractCity(String address) {
  if (address.isEmpty) return '';
  // Try comma-delimited: "Street, City, State ZIP"
  final parts = address.split(',').map((p) => p.trim()).toList();
  if (parts.length >= 2) {
    // Second part is usually city
    final candidate = parts[1].trim();
    if (candidate.isNotEmpty && !RegExp(r'^\d').hasMatch(candidate)) {
      return candidate;
    }
  }
  return address;
}

// ---------------------------------------------------------------------------
// PHOTO URL HELPERS
// ---------------------------------------------------------------------------

/// Convert any Drive URL format to the thumbnail format Flutter can load.
String normalizeDrivePhotoUrl(String url) {
  if (url.contains('drive.google.com/thumbnail')) return url;
  final ucMatch = RegExp(r'[?&]id=([^&]+)').firstMatch(url);
  if (ucMatch != null) {
    return 'https://drive.google.com/thumbnail?id=${ucMatch.group(1)}&sz=w1200';
  }
  final fileMatch = RegExp(r'/file/d/([^/]+)').firstMatch(url);
  if (fileMatch != null) {
    return 'https://drive.google.com/thumbnail?id=${fileMatch.group(1)}&sz=w1200';
  }
  return url;
}

// ---------------------------------------------------------------------------
// JOB TYPE HELPERS
// ---------------------------------------------------------------------------

/// Returns true if the schedule event is a ramp job.
bool eventIsRampJob(QbtScheduleEvent event) {
  final combined = '${event.title} ${event.notes}'.toLowerCase();
  return combined.contains('ramp');
}

/// Infer job type from a schedule event title.
///
/// This is the ONLY copy. It previously existed here and in main.dart with
/// divergent logic — this copy had lost the buyback/buyout branch, so a
/// "Smith buyback" event classified as untyped for any caller importing from
/// here while main.dart classified it as a removal.
///
/// Returns values that may need [normalizeJobType] before display: 'Eval',
/// 'Schedule Service' and 'Schedule Removal' are not in [kJobTypes].
String? inferJobTypeFromTitle(String title) {
  final t = title.toLowerCase();

  // Evals / measures / assessments → not a trackable job
  if (t.contains('eval') || t.contains('measure') || t.contains('assessment')) {
    return 'Eval';
  }

  // Scheduling notes: "set up …" or "schedule …" at the start
  final isSetupNote = t.startsWith('set up') ||
      t.startsWith('set-up') ||
      t.startsWith('schedule ');
  if (isSetupNote) {
    if (t.contains('service') || t.contains('annual')) return 'Schedule Service';
    if (t.contains('removal') || t.contains('remove')) return 'Schedule Removal';
    return null; // other setup notes (ramp rental setup, etc.) — ignore
  }

  final hasRamp = t.contains('ramp') &&
      !t.contains('adjustment') &&
      !t.contains('meeting');

  // Explicit installs
  if (t.contains('install')) return hasRamp ? 'Ramp Install' : 'Stairlift Install';

  // Buybacks and buyouts are removals: the lift comes back to us.
  if (t.contains('buyback') || t.contains('buyout')) return 'Stairlift Removal';

  if (t.contains('removal') || t.contains('remove')) {
    return hasRamp ? 'Ramp Removal' : 'Stairlift Removal';
  }

  // Ramp jobs with no explicit install/removal keyword
  if (hasRamp) return 'Ramp Install';

  // Service calls
  if (t.contains('annual')) return 'Stairlift Annual Service';
  if (t.contains('service')) return 'Stairlift Service';

  return null;
}

// ---------------------------------------------------------------------------
// INVENTORY HELPERS
// ---------------------------------------------------------------------------

bool isFoldingRailByBrandSeries(String brand, String series) {
  final b = brand.toLowerCase();
  final s = series.toLowerCase();
  if (b.contains('bruno')) return s.contains('manual fold') || s.contains('power fold');
  if (b.contains('harmar')) return s.contains('auto fold');
  if (b.contains('acorn') || b.contains('brooks')) return s.contains('fold');
  return false;
}

const List<String> kSeriesOrder = [
  'Elan 5000', 'Elan 3050', 'Elan 3000', 'Elite', 'Elite Curve', 'Outdoor Elite',
  '120', '130', 'T700', 'Outdoor 120', 'Outdoor 130', 'Outdoor T700',
  'SL300', 'SL600',
];

const Map<String, List<String>> kSeriesByBrand = {
  'Acorn': ['T700', '130', '120', 'Outdoor T700', 'Outdoor 130', 'Outdoor 120'],
  'Brooks': ['T700', '130', '120', 'Outdoor T700', 'Outdoor 130', 'Outdoor 120'],
  'Bruno': ['Elan 5000', 'Elan 3050', 'Elan 3000', 'Elite', 'Elite Curve', 'Outdoor Elite'],
  'Harmar': ['SL300', 'SL600', 'Helix'],
};

List<String> sortSeriesList(List<String> series) {
  final ordered = <String>[];
  for (final s in kSeriesOrder) {
    if (series.contains(s)) ordered.add(s);
  }
  final remaining = series.where((s) => !kSeriesOrder.contains(s)).toList()..sort();
  return [...ordered, ...remaining];
}

int compareRampBrands(String a, String b) {
  final aIsEz = a.toLowerCase().contains('ez access');
  final bIsEz = b.toLowerCase().contains('ez access');
  if (aIsEz && !bIsEz) return -1;
  if (!aIsEz && bIsEz) return 1;
  return a.compareTo(b);
}

int compareRampSizes(String a, String b) {
  final aNum = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), ''));
  final bNum = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), ''));
  final aLower = a.toLowerCase();
  final bLower = b.toLowerCase();
  final aIsPlatform = aLower.contains('platform');
  final bIsPlatform = bLower.contains('platform');
  final aIsLowProf = aLower.contains('low prof') || aLower.contains('low-prof');
  final bIsLowProf = bLower.contains('low prof') || bLower.contains('low-prof');

  if (!aIsPlatform && bIsPlatform) return -1;
  if (aIsPlatform && !bIsPlatform) return 1;
  if (aIsPlatform && bIsPlatform) {
    if (!aIsLowProf && bIsLowProf) return -1;
    if (aIsLowProf && !bIsLowProf) return 1;
    return a.compareTo(b);
  }
  if (aNum != null && bNum != null) return aNum.compareTo(bNum);
  return a.compareTo(b);
}

String getRampDisplayTitle(String brand, String size, String notes) {
  String title = '$brand – $size';
  final b = brand.toLowerCase();
  final s = size.toLowerCase();
  final n = notes.toLowerCase();
  if (b.contains('ez access') && b.contains('3g')) {
    if ((s.contains('4x4') || s.contains('5x4') || s.contains('5x5')) &&
        n.contains('low_prof')) {
      title += ' (Low Prof)';
    }
  }
  return title;
}

// ---------------------------------------------------------------------------
// UI HELPERS
// ---------------------------------------------------------------------------

/// Reusable confirmation dialog. Returns true if user taps the confirm button.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = 'Delete',
  Color confirmColor = Colors.red,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: confirmColor),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

// ---------------------------------------------------------------------------
// FUNDING SOURCE OPTIONS
// ---------------------------------------------------------------------------

const List<String> kFundingSources = [
  'Private',
  'VA',
  'CCALS',
  'NaviCare',
  'Summit',
  'Fallon',
  'Mass Health',
  'Other',
];

/// The default funding source. Stored as NULL rather than this string — see
/// sbSetEventFundingSource — so reads must fall back to it.
const String kDefaultFundingSource = 'Private';

/// Normalizes a stored funding source onto [kFundingSources].
///
/// Historical rows carry casing variants: one screen wrote 'Navicare' while
/// another wrote 'NaviCare', and the schema has no check constraints to stop
/// it. Without normalizing, a dropdown guarded by `contains()` falls through
/// to null and shows a stored value as unset.
String normalizeFundingSource(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return kDefaultFundingSource;
  for (final s in kFundingSources) {
    if (s.toLowerCase() == v.toLowerCase()) return s;
  }
  return 'Other';
}

// ---------------------------------------------------------------------------
// JOB TYPES
// ---------------------------------------------------------------------------

/// The job types a schedule event can carry.
///
/// This was hardcoded inline in four places (the event form and three times in
/// the detail screen's dropdown). A value stored in app_config that is missing
/// from the list it is rendered against silently displays as "unset", so there
/// must be exactly one list.
const List<String> kJobTypes = [
  'Stairlift Install',
  'Stairlift Removal',
  'Stairlift Buyback / Buyout',
  'Stairlift Service',
  'Stairlift Annual Service',
  'Ramp Install',
  'Ramp Removal',
  'Needs Scheduling',
  'Reminder',
  'Other',
];

/// Values [inferJobTypeFromTitle] can return that are NOT offered in the
/// dropdown, mapped onto one that is.
///
/// The inference function predates the dropdown list and emits 'Eval',
/// 'Schedule Service' and 'Schedule Removal'. Those were persisted to
/// app_config and then rendered against a list that does not contain them, so
/// the dropdown fell through to null and showed a stored job type as unset.
const Map<String, String> kJobTypeAliases = {
  'Schedule Service': 'Needs Scheduling',
  'Schedule Removal': 'Needs Scheduling',
  'Eval': 'Other',
};

/// Maps any stored or inferred job type onto [kJobTypes].
/// Returns null only when there is genuinely no type.
String? normalizeJobType(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return null;
  for (final t in kJobTypes) {
    if (t.toLowerCase() == v.toLowerCase()) return t;
  }
  final alias = kJobTypeAliases[v];
  if (alias != null) return alias;
  for (final entry in kJobTypeAliases.entries) {
    if (entry.key.toLowerCase() == v.toLowerCase()) return entry.value;
  }
  return 'Other';
}

/// True when the title reads like a to-do rather than a booked job —
/// "Set up Leominster service", "Schedule the Dartmouth removal". These are
/// the office's own reminders to book something, and they belong in the hub's
/// Needs Scheduling bucket.
bool titleLooksUnscheduled(String title) {
  final t = title.toLowerCase().trimLeft();
  return t.startsWith('set up') ||
      t.startsWith('set-up') ||
      t.startsWith('setup') ||
      t.startsWith('schedule ') ||
      t.startsWith('need to schedule') ||
      t.startsWith('needs scheduling') ||
      t.startsWith('call ') ||
      t.startsWith('book ');
}

/// True when a stairlift job involves a curved rail.
///
/// Prefers the linked lift's rail type, which is authoritative. Falls back to
/// the event title, because on a new install the lift is usually not linked
/// until the work is done — exactly the jobs the hub most needs to show.
/// Defaults to straight, which is the common case.
bool isCurvedRailJob({String? liftRailType, String title = ''}) {
  final rt = (liftRailType ?? '').trim().toLowerCase();
  if (rt.isNotEmpty) return rt.startsWith('curv');
  final t = title.toLowerCase();
  return t.contains('curve') || t.contains('curved');
}

/// Returns true if the funding source requires agency confirmation before scheduling.
bool requiresAgencyConfirmation(String fundingSource) {
  return fundingSource != 'Private' && fundingSource.isNotEmpty;
}
