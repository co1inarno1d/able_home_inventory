import 'dart:convert';
import 'package:http/http.dart' as http;

/// =======================
/// QuickBooks Time API
/// =======================
///
/// Uses a static Bearer token (stored here, never committed to source if repo
/// is public — move to Supabase app_config if needed in the future).
///
/// Base URL:  https://rest.tsheets.com/api/v1
/// Calendar:  Matthew (id 123571)

const String _qbtToken =
    'S.6__bc39aa448aae631d140c82d5a694c54b4fd94ebd';
const String _qbtBase = 'https://rest.tsheets.com/api/v1';

/// The single shared schedule calendar ID for Able Home.
const String _calendarId = '123571';

Map<String, String> get _headers => {
      'Authorization': 'Bearer $_qbtToken',
      'Content-Type': 'application/json',
    };

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class QbtUser {
  final String id;
  final String firstName;
  final String lastName;

  const QbtUser({
    required this.id,
    required this.firstName,
    required this.lastName,
  });

  String get displayName => '$firstName $lastName'.trim();

  factory QbtUser.fromJson(String id, Map<String, dynamic> j) => QbtUser(
        id: id,
        firstName: j['first_name']?.toString() ?? '',
        lastName: j['last_name']?.toString() ?? '',
      );
}

class QbtScheduleEvent {
  final String id;
  final String title;
  final String notes;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String location;
  final String color;
  final List<String> assignedUserIds;
  final bool active;

  const QbtScheduleEvent({
    required this.id,
    required this.title,
    required this.notes,
    required this.start,
    required this.end,
    required this.allDay,
    required this.location,
    required this.color,
    required this.assignedUserIds,
    required this.active,
  });

  factory QbtScheduleEvent.fromJson(Map<String, dynamic> j) {
    // assigned_user_ids can be a comma-separated string or empty string
    final rawAssigned = j['assigned_user_ids']?.toString() ?? '';
    final assignedIds = rawAssigned.isNotEmpty
        ? rawAssigned.split(',').map((s) => s.trim()).toList()
        : <String>[];

    return QbtScheduleEvent(
      id: j['id']?.toString() ?? '',
      title: j['title']?.toString() ?? '',
      notes: j['notes']?.toString() ?? '',
      start: DateTime.parse(j['start'] as String),
      end: DateTime.parse(j['end'] as String),
      allDay: j['all_day'] == true,
      location: j['location']?.toString() ?? '',
      color: j['color']?.toString() ?? '#2196F3',
      assignedUserIds: assignedIds,
      active: j['active'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'schedule_calendar_id': int.parse(_calendarId),
        'title': title,
        'notes': notes,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'all_day': allDay,
        'location': location,
        'draft': false,
        'assigned_user_ids': assignedUserIds.join(','),
      };
}

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

/// Fetch all active users from QBT. Returns a map of user_id → QbtUser.
Future<Map<String, QbtUser>> qbtFetchUsers() async {
  final uri = Uri.parse('$_qbtBase/users?active=yes&per_page=200');
  final resp = await http.get(uri, headers: _headers);
  _checkStatus(resp);

  final body = jsonDecode(resp.body) as Map<String, dynamic>;
  final usersMap =
      (body['results']?['users'] as Map<String, dynamic>?) ?? {};

  return {
    for (final entry in usersMap.entries)
      entry.key: QbtUser.fromJson(entry.key, entry.value as Map<String, dynamic>)
  };
}

// ---------------------------------------------------------------------------
// Schedule Events
// ---------------------------------------------------------------------------

/// Fetch all schedule events for the given date range (inclusive).
/// [start] and [end] are local dates — we extend end by 1 day to be inclusive.
Future<List<QbtScheduleEvent>> qbtFetchScheduleEvents({
  required DateTime start,
  required DateTime end,
}) async {
  // QBT needs ISO-8601 with time component
  final startIso = '${_dateOnly(start)}T00:00:00+00:00';
  final endIso = '${_dateOnly(end)}T23:59:59+00:00';

  final uri = Uri.parse(
    '$_qbtBase/schedule_events'
    '?schedule_calendar_ids=$_calendarId'
    '&start=${Uri.encodeComponent(startIso)}'
    '&end=${Uri.encodeComponent(endIso)}'
    '&active=both'
    '&per_page=200',
  );

  final resp = await http.get(uri, headers: _headers);
  _checkStatus(resp);

  final body = jsonDecode(resp.body) as Map<String, dynamic>;
  final eventsMap =
      (body['results']?['schedule_events'] as Map<String, dynamic>?) ?? {};

  final events = eventsMap.values
      .map((e) => QbtScheduleEvent.fromJson(e as Map<String, dynamic>))
      .where((e) => e.active)
      .toList();

  // Sort by start time
  events.sort((a, b) => a.start.compareTo(b.start));
  return events;
}

/// Create a new schedule event. Returns the created event.
Future<QbtScheduleEvent> qbtCreateScheduleEvent(QbtScheduleEvent event) async {
  final uri = Uri.parse('$_qbtBase/schedule_events');
  final resp = await http.post(
    uri,
    headers: _headers,
    body: jsonEncode({'data': [event.toJson()]}),
  );
  _checkStatus(resp);

  final body = jsonDecode(resp.body) as Map<String, dynamic>;
  final eventsMap =
      (body['results']?['schedule_events'] as Map<String, dynamic>?) ?? {};
  final created = eventsMap.values.first as Map<String, dynamic>;
  return QbtScheduleEvent.fromJson(created);
}

/// Update an existing schedule event. Returns the updated event.
Future<QbtScheduleEvent> qbtUpdateScheduleEvent(QbtScheduleEvent event) async {
  final uri = Uri.parse('$_qbtBase/schedule_events');
  final payload = event.toJson()..['id'] = int.parse(event.id);
  final resp = await http.put(
    uri,
    headers: _headers,
    body: jsonEncode({'data': [payload]}),
  );
  _checkStatus(resp);

  final body = jsonDecode(resp.body) as Map<String, dynamic>;
  final eventsMap =
      (body['results']?['schedule_events'] as Map<String, dynamic>?) ?? {};
  final updated = eventsMap.values.first as Map<String, dynamic>;
  return QbtScheduleEvent.fromJson(updated);
}

/// Delete (deactivate) a schedule event.
Future<void> qbtDeleteScheduleEvent(String eventId) async {
  final uri = Uri.parse('$_qbtBase/schedule_events');
  final resp = await http.delete(
    uri,
    headers: _headers,
    body: jsonEncode({'data': [int.parse(eventId)]}),
  );
  _checkStatus(resp);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _dateOnly(DateTime dt) =>
    '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

void _checkStatus(http.Response resp) {
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    String message = 'QBT API error ${resp.statusCode}';
    try {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      message = body['error']?['message']?.toString() ?? message;
    } catch (_) {}
    throw Exception(message);
  }
}
