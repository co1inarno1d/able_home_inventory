// lib/hub_jobs.dart
//
// The Operations Hub's data source: schedule events presented as units of
// work.
//
// The hub used to read four legacy job tables (ops_jobs, service_jobs,
// removal_jobs, annuals) and never looked at the schedule, so the two were
// separate systems that drifted apart — a job could exist in one and not the
// other. Everything here derives from the schedule instead, so the hub is a
// different VIEW of the same events rather than a parallel set of records.

import 'qbt_api.dart';
import 'supabase_api.dart';
import 'utils/utils.dart';

/// Hub buckets. These are a presentation of the schedule, not a separate set
/// of records: every bucket is derived from a schedule event, and every
/// schedule event lands in exactly one bucket.
enum HubBucket {
  straightInstall,
  curveInstall,
  rampInstall,
  straightRemoval,
  curveRemoval,
  rampRemoval,
  service,
  annualService,
  needsScheduling,
  reminder,
  lead,
  other,
}

String hubBucketLabel(HubBucket b) {
  switch (b) {
    case HubBucket.straightInstall: return 'Straight SL Install';
    case HubBucket.curveInstall: return 'Curve SL Install';
    case HubBucket.rampInstall: return 'Ramp Install';
    case HubBucket.straightRemoval: return 'Straight SL Removal';
    case HubBucket.curveRemoval: return 'Curve SL Removal';
    case HubBucket.rampRemoval: return 'Ramp Removal';
    case HubBucket.service: return 'Service';
    case HubBucket.annualService: return 'Annual Service';
    case HubBucket.needsScheduling: return 'Needs Scheduling';
    case HubBucket.reminder: return 'Reminder';
    case HubBucket.lead: return 'Lead';
    case HubBucket.other: return 'Other';
  }
}

/// A schedule event presented as a unit of work for the hub.
///
/// Deliberately wraps the event rather than copying it: the hub and the
/// schedule must never hold separate state for the same job. `event` is the
/// single source of truth, and tapping through to the detail screen hands over
/// this same object.
class HubJob {
  final QbtScheduleEvent event;
  final HubBucket bucket;
  final String? jobType;
  final String fundingSource;
  final bool completed;
  final List<String> liftIds;
  final String customerName;
  final String customerId;
  final String assignedNames;

  const HubJob({
    required this.event,
    required this.bucket,
    required this.jobType,
    required this.fundingSource,
    required this.completed,
    required this.liftIds,
    required this.customerName,
    required this.customerId,
    required this.assignedNames,
  });

  /// Display name: the linked customer if there is one, else the event title,
  /// which by convention is usually the customer's name.
  String get displayName =>
      customerName.isNotEmpty ? customerName : event.title;

  DateTime get date => event.start;
  String get location => event.location;
  String get notes => event.notes;
  bool get isAgencyFunded => requiresAgencyConfirmation(fundingSource);
}

/// Classifies a schedule event into exactly one hub bucket.
///
/// Order matters: an explicit stored job type wins, because someone chose it.
/// Only when none is stored does this fall back to reading the title.
HubBucket classifyHubBucket({
  required String title,
  String? jobType,
  String? liftRailType,
}) {
  final jt = normalizeJobType(jobType);

  // No stored type: the title is all there is. Check the to-do shape first,
  // since "Set up Dartmouth removal" is a reminder to book work, not a removal.
  if (jt == null) {
    if (titleLooksUnscheduled(title)) return HubBucket.needsScheduling;
    final inferred = normalizeJobType(inferJobTypeFromTitle(title));
    if (inferred == null) return HubBucket.other;
    return classifyHubBucket(
        title: title, jobType: inferred, liftRailType: liftRailType);
  }

  final curved = isCurvedRailJob(liftRailType: liftRailType, title: title);

  switch (jt) {
    case 'Stairlift Install':
      return curved ? HubBucket.curveInstall : HubBucket.straightInstall;
    case 'Stairlift Removal':
    case 'Stairlift Buyback / Buyout':
      return curved ? HubBucket.curveRemoval : HubBucket.straightRemoval;
    case 'Ramp Install':
      return HubBucket.rampInstall;
    case 'Ramp Removal':
      return HubBucket.rampRemoval;
    case 'Stairlift Service':
      return HubBucket.service;
    case 'Stairlift Annual Service':
      return HubBucket.annualService;
    case 'Needs Scheduling':
      return HubBucket.needsScheduling;
    case 'Reminder':
      // A "reminder" whose title reads as a to-do is really unscheduled work.
      return titleLooksUnscheduled(title)
          ? HubBucket.needsScheduling
          : HubBucket.reminder;
    default:
      return HubBucket.other;
  }
}

/// How long a completed job stays visible behind the "show completed" toggle.
const Duration kHubCompletedWindow = Duration(days: 7);

/// Builds the hub's job list from schedule events.
///
/// This is the whole point of the hub rewrite: it reads the SAME events the
/// schedule shows, so nothing can exist in one view and not the other. It
/// replaces sbFetchAllOpsJobs, which unioned four legacy job tables and never
/// looked at the schedule at all.
///
/// [events] comes from the caller (which already loaded them for the schedule)
/// so this does not refetch TSheets.
Future<List<HubJob>> buildHubJobs({
  required List<QbtScheduleEvent> events,
  required Map<String, QbtUser> users,
  bool includeCompleted = false,
}) async {
  final meta = await sbGetAllEventMeta();
  final completedIds = await sbFetchCompletedEventIds();

  // Rail type needs the linked lift. Fetch only the lifts actually referenced
  // by a stairlift job, once each, rather than per event.
  final neededLiftIds = <String>{};
  for (final e in events) {
    final ids = (meta[e.id]?['lift_ids'] as List<String>?) ?? const [];
    neededLiftIds.addAll(ids);
  }
  final railTypes = <String, String>{};
  if (neededLiftIds.isNotEmpty) {
    try {
      final lifts = await sbFetchLifts();
      for (final l in lifts) {
        if (neededLiftIds.contains(l.liftId)) railTypes[l.liftId] = l.railType;
      }
    } catch (_) {
      // Rail type is a refinement, not a requirement — fall back to the title.
    }
  }

  final cutoff = DateTime.now().subtract(kHubCompletedWindow);
  final jobs = <HubJob>[];

  for (final e in events) {
    final m = meta[e.id];
    final isDone = completedIds.contains(e.id);

    // Completed jobs linger briefly so a tech can see what they just finished,
    // then drop out so the hub stays a list of what still needs doing.
    if (isDone) {
      if (!includeCompleted) continue;
      if (e.start.isBefore(cutoff)) continue;
    }

    final liftIds = (m?['lift_ids'] as List<String>?) ?? const <String>[];
    final railType = liftIds
        .map((id) => railTypes[id])
        .firstWhere((rt) => rt != null && rt.isNotEmpty, orElse: () => null);

    final customer = m?['customer'] as Map<String, String>?;

    jobs.add(HubJob(
      event: e,
      bucket: classifyHubBucket(
        title: e.title,
        jobType: m?['job_type'] as String?,
        liftRailType: railType,
      ),
      jobType: normalizeJobType(m?['job_type'] as String?),
      fundingSource:
          normalizeFundingSource(m?['funding_source'] as String?),
      completed: isDone,
      liftIds: liftIds,
      customerName: customer?['name'] ?? '',
      customerId: customer?['customer_id'] ?? '',
      assignedNames: e.assignedUserIds
          .map((id) => users[id]?.displayName ?? '')
          .where((n) => n.isNotEmpty)
          .join(', '),
    ));
  }

  // Soonest first: the hub answers "what needs doing", so the next job is the
  // most useful thing at the top.
  jobs.sort((a, b) => a.date.compareTo(b.date));
  return jobs;
}

