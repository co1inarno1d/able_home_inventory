// lib/utils/schedule_search.dart
//
// Date parsing for schedule search, shared by the mobile list view
// (ScheduleScreen in main.dart) and the desktop week grid
// (ScheduleDesktopView). It lived in both files as a verbatim copy, so fixes
// landed in one and not the other; keep it here.

// Month name → number map used for date parsing
const Map<String, int> kMonthNameToNumber = {
  'jan': 1, 'january': 1,
  'feb': 2, 'february': 2,
  'mar': 3, 'march': 3,
  'apr': 4, 'april': 4,
  'may': 5,
  'jun': 6, 'june': 6,
  'jul': 7, 'july': 7,
  'aug': 8, 'august': 8,
  'sep': 9, 'sept': 9, 'september': 9,
  'oct': 10, 'october': 10,
  'nov': 11, 'november': 11,
  'dec': 12, 'december': 12,
};

/// Parse a date range out of [query].
/// Returns `((startDate, endDate)?, remainingText)`.
/// If no date is detected, the first element is null and the full query is returned as text.
///
/// Handles: "today", "yesterday", "2026-10-22", "april 21 2025",
///          "oct 30 2019", "4/21/25", "4/21/2025", "4/21" (current year),
///          "april 21" (current year), "april 2025" (whole month),
///          "2024" (whole year).
((DateTime, DateTime)?, String) parseScheduleDateRange(String query) {
  var q = query.toLowerCase().trim();

  String strip(String src, Pattern pat) =>
      src.replaceAll(pat, ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();

  (DateTime, DateTime) dayRange(int y, int mo, int d) =>
      (DateTime(y, mo, d), DateTime(y, mo, d, 23, 59, 59));

  final nowYear = DateTime.now().year;

  // Relative days — what someone actually types when checking recent work.
  for (final entry in <String, int>{'today': 0, 'yesterday': -1, 'tomorrow': 1}.entries) {
    final pat = RegExp(r'\b' + entry.key + r'\b');
    if (pat.hasMatch(q)) {
      final d = DateTime.now().add(Duration(days: entry.value));
      return (dayRange(d.year, d.month, d.day), strip(q, pat));
    }
  }

  // ISO: 2026-10-22
  final iso = RegExp(r'\b(20\d{2})-(\d{1,2})-(\d{1,2})\b');
  var mIso = iso.firstMatch(q);
  if (mIso != null) {
    return (
      dayRange(int.parse(mIso.group(1)!), int.parse(mIso.group(2)!),
          int.parse(mIso.group(3)!)),
      strip(q, iso),
    );
  }

  // MM/DD/YY or MM/DD/YYYY
  final slash = RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b');
  var m = slash.firstMatch(q);
  if (m != null) {
    var y = int.parse(m.group(3)!);
    if (y < 100) y += 2000;
    return (dayRange(y, int.parse(m.group(1)!), int.parse(m.group(2)!)), strip(q, slash));
  }

  // Month name patterns
  for (final entry in kMonthNameToNumber.entries) {
    final mn = entry.key;
    final mo = entry.value;

    // "april 21 2025"
    final pat1 = RegExp(r'\b' + mn + r'\s+(\d{1,2})\s+(20\d{2})\b');
    m = pat1.firstMatch(q);
    if (m != null) {
      return (dayRange(int.parse(m.group(2)!), mo, int.parse(m.group(1)!)), strip(q, pat1));
    }

    // "21 april 2025"
    final pat2 = RegExp(r'\b(\d{1,2})\s+' + mn + r'\s+(20\d{2})\b');
    m = pat2.firstMatch(q);
    if (m != null) {
      return (dayRange(int.parse(m.group(2)!), mo, int.parse(m.group(1)!)), strip(q, pat2));
    }

    // "april 2025" → whole month
    final pat3 = RegExp(r'\b' + mn + r'\s+(20\d{2})\b');
    m = pat3.firstMatch(q);
    if (m != null) {
      final y = int.parse(m.group(1)!);
      final lastDay = DateTime(y, mo + 1, 0).day;
      return (
        (DateTime(y, mo, 1), DateTime(y, mo, lastDay, 23, 59, 59)),
        strip(q, pat3),
      );
    }
  }

  // Year-less forms, assumed to mean the current year. Tried only after every
  // month has been checked against the year-bearing patterns above, so
  // "april 21 2025" is never mis-read as "april 21" of this year.

  // "4/21" → current year. Requires the whole query to be the date: titles
  // and part numbers contain things like "bruno 2/3 rail", and silently
  // date-filtering that search would hide every result.
  final slashNoYear = RegExp(r'^(\d{1,2})/(\d{1,2})$');
  m = slashNoYear.firstMatch(q.trim());
  if (m != null) {
    final mo = int.parse(m.group(1)!);
    final d = int.parse(m.group(2)!);
    if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
      return (dayRange(nowYear, mo, d), '');
    }
  }

  for (final entry in kMonthNameToNumber.entries) {
    final mn = entry.key;
    final mo = entry.value;

    // "april 21" / "21 april" → current year. Whole-query only, for the
    // same reason as "4/21" above — a bare number next to a month name is
    // too easy to hit by accident inside a longer search.
    final dayFirst = RegExp(r'^' + mn + r'\s+(\d{1,2})$');
    m = dayFirst.firstMatch(q.trim());
    if (m != null) {
      return (dayRange(nowYear, mo, int.parse(m.group(1)!)), '');
    }
    final dayLast = RegExp(r'^(\d{1,2})\s+' + mn + r'$');
    m = dayLast.firstMatch(q.trim());
    if (m != null) {
      return (dayRange(nowYear, mo, int.parse(m.group(1)!)), '');
    }
  }

  // "2024" → whole year
  final yearPat = RegExp(r'\b(20\d{2})\b');
  m = yearPat.firstMatch(q);
  if (m != null) {
    final y = int.parse(m.group(1)!);
    return ((DateTime(y, 1, 1), DateTime(y, 12, 31, 23, 59, 59)), strip(q, yearPat));
  }

  // Bare month name ("april") → that month in the current year.
  // Last resort: only when nothing else matched, since many job titles
  // contain words like "may" that are not dates. Requires the month to be
  // the ENTIRE query, so "may service call" stays a text search.
  final bareMonth = kMonthNameToNumber[q.trim()];
  if (bareMonth != null) {
    final lastDay = DateTime(nowYear, bareMonth + 1, 0).day;
    return (
      (DateTime(nowYear, bareMonth, 1),
          DateTime(nowYear, bareMonth, lastDay, 23, 59, 59)),
      '',
    );
  }

  // No date found — full query is text
  return (null, q);
}
