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
String? inferJobTypeFromTitle(String title) {
  final t = title.toLowerCase();

  if (t.contains('eval') || t.contains('measure') || t.contains('assessment')) {
    return 'Eval';
  }

  final isSetupNote = t.startsWith('set up') ||
      t.startsWith('set-up') ||
      t.startsWith('schedule ');
  if (isSetupNote) {
    if (t.contains('service') || t.contains('annual')) return 'Schedule Service';
    if (t.contains('removal') || t.contains('remove')) return 'Schedule Removal';
    return null;
  }

  final hasRamp = t.contains('ramp') &&
      !t.contains('adjustment') &&
      !t.contains('meeting');

  if (t.contains('install')) return hasRamp ? 'Ramp Install' : 'Stairlift Install';
  if (t.contains('removal') || t.contains('remove')) {
    return hasRamp ? 'Ramp Removal' : 'Stairlift Removal';
  }
  if (hasRamp) return 'Ramp Install';
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

/// Returns true if the funding source requires agency confirmation before scheduling.
bool requiresAgencyConfirmation(String fundingSource) {
  return fundingSource != 'Private' && fundingSource.isNotEmpty;
}
