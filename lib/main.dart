
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:url_launcher/url_launcher.dart';

import 'auth/auth.dart';
import 'initials_avatar.dart';
import 'models/models.dart';
import 'prep_checklist_form.dart';
import 'qbt_api.dart';
import 'schedule_desktop.dart';
import 'screens/bin_whiteboard_screen.dart';
import 'screens/customers_screen.dart';
import 'screens/inventory_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/operations_hub_screen.dart';
import 'screens/schedule_event_form_screen.dart';
import 'screens/audit_log_screen.dart';
import 'screens/documents_screen.dart';
import 'screens/user_management_screen.dart';
import 'integrations/quickbooks_service.dart';
import 'supabase_api.dart';
import 'utils/utils.dart' show extractCity;

/// =======================
/// CONFIG
/// =======================

/// App password — kept for legacy reference only; auth now uses Supabase Auth.
const String kAppPassword = '403marshallst!';

/// How long a successful login is cached before prompting again.
const Duration kAuthCacheDuration = Duration(days: 90);

/// SharedPreferences key that stores the expiry timestamp (ms since epoch).
const String _kAuthUntilKey = 'auth_until';

/// Brand color
const Color kBrandGreen = Color(0xFF2F7D46);
const Color kBrandGreenDark = Color(0xFF1A4728);
const Color kSurface = Color(0xFFF0F2F0);
const Color kCardSurface = Color(0xFFFFFFFF);
const Color kHeaderText = Color(0xFFE8F5E9);

/// Format a DateTime to a readable date string (MM/DD/YYYY)
String formatDate(DateTime? date) {
  if (date == null) return 'Unknown date';
  return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}';
}

/// Normalizes a bin number field to display as "Bin XX" regardless of how it was entered.
/// Handles: "43", "bin43", "bin 43", "Bin43", "Bin 43", "bin#43", "Bin #43", etc.
/// Returns the raw value unchanged if no numeric portion is found.
String normalizeBinDisplay(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return s;
  // Strip any leading "bin" (case-insensitive) + optional space/# characters, keep the rest
  final match = RegExp(r'^bin\s*#?\s*(.+)$', caseSensitive: false).firstMatch(s);
  final number = match != null ? match.group(1)!.trim() : s;
  // If the extracted part looks purely numeric, format as "Bin XX"
  // Otherwise just display as-is (don't corrupt odd entries)
  if (RegExp(r'^\d+$').hasMatch(number)) return 'Bin $number';
  // It already had "bin" stripped and isn't purely numeric — show "Bin <rest>"
  if (match != null) return 'Bin $number';
  return s;
}

/// Returns true if the schedule event is a ramp job (title or notes contains "ramp").
/// Used to trigger the Job Adjustment form instead of the lift status flow.
bool eventIsRampJob(QbtScheduleEvent event) {
  final combined = '${event.title} ${event.notes}'.toLowerCase();
  return combined.contains('ramp');
}

/// Infer job type from a schedule event title.
/// Returns one of: 'Stairlift Install', 'Stairlift Removal', 'Stairlift Service',
/// 'Stairlift Annual Service', 'Ramp Install', 'Ramp Removal',
/// 'Schedule Service', 'Schedule Removal', 'Eval', or null (unknown/untracked).
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

  final hasRamp = t.contains('ramp') && !t.contains('adjustment') && !t.contains('meeting');

  // Explicit installs
  if (t.contains('install')) return hasRamp ? 'Ramp Install' : 'Stairlift Install';

  // Explicit removals
  if (t.contains('removal') || t.contains('remove')) return hasRamp ? 'Ramp Removal' : 'Stairlift Removal';

  // Ramp jobs with no explicit install/removal keyword
  if (hasRamp) return 'Ramp Install';

  // Service calls
  if (t.contains('annual')) return 'Stairlift Annual Service';
  if (t.contains('service')) return 'Stairlift Service';

  return null;
}

/// Convert any Drive URL format to the thumbnail format that Flutter can load.
/// The /uc?export=view endpoint no longer serves image bytes reliably.
String normalizeDrivePhotoUrl(String url) {
  // Already thumbnail format
  if (url.contains('drive.google.com/thumbnail')) return url;
  // Extract file ID from /uc?export=view&id=ID or /file/d/ID/...
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

/// Normalize a stored date string to MM/DD/YYYY display format.
/// Handles YYYY-MM-DD, ISO 8601, and already-formatted MM/DD/YYYY.
String normalizeDateDisplay(String raw) {
  if (raw.isEmpty) return raw;
  // Already MM/DD/YYYY
  if (RegExp(r'^\d{1,2}/\d{1,2}/\d{4}$').hasMatch(raw)) return raw;
  // YYYY-MM-DD
  final ymd = RegExp(r'^(\d{4})-(\d{2})-(\d{2})');
  final m = ymd.firstMatch(raw);
  if (m != null) {
    return '${m.group(2)}/${m.group(3)}/${m.group(1)}';
  }
  // ISO 8601 — parse and reformat
  try {
    final dt = DateTime.parse(raw);
    return '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}/${dt.year}';
  } catch (_) {}
  return raw;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initSupabase();
  runApp(const AbleHomeInventoryApp());
}

/// Shared user menu — shows current user name/role and a sign-out button.
/// Call from any screen's app bar person icon.
/// After marking a lift as Installed, offer to create or link a customer record.
/// Shows a bottom sheet; skippable with no side-effects.
Future<void> _offerCreateCustomerForLift(
    BuildContext context, LiftRecord lift, dynamic event) async {
  final shouldCreate = await showModalBottomSheet<bool>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.person_add_outlined, color: kBrandGreen),
            const SizedBox(width: 10),
            Text('Create customer record?',
                style: GoogleFonts.nunito(fontSize: 16, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          Text(
            'No customer is linked to this lift yet. Add one now to track warranty, service history, and reviews.',
            style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Skip'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Customer'),
              ),
            ),
          ]),
        ],
      ),
    ),
  );
  if (shouldCreate == true && context.mounted) {
    // Pre-fill with location from the event if available
    final location = (event as dynamic).location as String? ?? '';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerFormScreen(
          existing: CustomerRecord(
            customerId: '',
            name: '',
            address: location,
            city: extractCity(location),
            phone: '',
            email: '',
            fundingSource: 'Private',
            qbCustomerId: '',
            notes: '',
          ),
        ),
      ),
    );
  }
}

Future<void> showUserMenu(BuildContext context) async {
  final auth = AuthService.instance;
  final profile = auth.profile;
  final prefs = await SharedPreferences.getInstance();

  if (!context.mounted) return;
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Account'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (profile != null) ...[
            Text(profile.name.isNotEmpty ? profile.name : profile.email,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 4),
            Text(profile.role.label,
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 4),
            Text(profile.email,
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const Divider(height: 24),
          ],
          Text('Display name (used in logs)',
              style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          const SizedBox(height: 6),
          TextField(
            controller: TextEditingController(
                text: prefs.getString('user_name') ??
                    profile?.name ?? ''),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => prefs.setString('user_name', v),
          ),
        ],
      ),
      actions: [
        if (profile?.canSeeSettings == true) ...[
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const UserManagementScreen(),
              ));
            },
            child: const Text('Manage Team'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const AuditLogScreen(),
              ));
            },
            child: const Text('Audit Log'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const DocumentsScreen(),
              ));
            },
            child: const Text('Documents'),
          ),
          _QbConnectButton(parentCtx: context, onClose: () => Navigator.of(ctx).pop()),
        ],
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          onPressed: () async {
            Navigator.of(ctx).pop();
            await AuthService.instance.signOut();
          },
          child: const Text('Sign Out'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// QB Connect Button — shown in the account menu for admins
// ---------------------------------------------------------------------------

class _QbConnectButton extends StatefulWidget {
  final BuildContext parentCtx;
  final VoidCallback onClose;
  const _QbConnectButton({required this.parentCtx, required this.onClose});

  @override
  State<_QbConnectButton> createState() => _QbConnectButtonState();
}

class _QbConnectButtonState extends State<_QbConnectButton> {
  bool _loading = true;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    final status = await QuickBooksService.getStatus();
    if (mounted) setState(() { _connected = status.connected; _loading = false; });
  }

  Future<void> _connect() async {
    widget.onClose();
    final err = await QuickBooksService.startOAuthFlow();
    if (err != null && widget.parentCtx.mounted) {
      ScaffoldMessenger.of(widget.parentCtx).showSnackBar(
        SnackBar(content: Text('QB connect failed: $err')),
      );
    }
  }

  Future<void> _disconnect() async {
    await QuickBooksService.disconnect();
    if (mounted) setState(() => _connected = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    if (_connected) {
      return TextButton.icon(
        icon: Icon(Icons.check_circle, size: 14, color: Colors.green[600]),
        label: const Text('QuickBooks Connected'),
        style: TextButton.styleFrom(foregroundColor: Colors.green[700]),
        onPressed: () async {
          final disconnect = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Disconnect QuickBooks?'),
              content: const Text('Customer search will stop working until reconnected.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          );
          if (disconnect == true) _disconnect();
        },
      );
    }
    return TextButton.icon(
      icon: const Icon(Icons.link, size: 14),
      label: const Text('Connect QuickBooks'),
      onPressed: _connect,
    );
  }
}

// ---------------------------------------------------------------------------
// QB OAuth callback handler — call from app init when URL has ?code=&realmId=
// ---------------------------------------------------------------------------

Future<void> handleQbCallback(BuildContext context) async {
  final uri = Uri.base;
  final code = uri.queryParameters['code'];
  final realmId = uri.queryParameters['realmId'];
  if (code == null || realmId == null) return;

  final err = await QuickBooksService.completeOAuthFlow(code: code, realmId: realmId);

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(err == null
        ? 'QuickBooks connected successfully!'
        : 'QB connect failed: $err'),
    backgroundColor: err == null ? Colors.green[700] : Colors.red[700],
  ));
}

class AbleHomeInventoryApp extends StatelessWidget {
  const AbleHomeInventoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Able Home Accessibility',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: kBrandGreen,
          brightness: Brightness.light,
          surface: kSurface,
        ),
        scaffoldBackgroundColor: kSurface,
        useMaterial3: true,
        textTheme: GoogleFonts.nunitoTextTheme(),
        appBarTheme: AppBarTheme(
          backgroundColor: kBrandGreenDark,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: GoogleFonts.nunito(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
          iconTheme: const IconThemeData(color: Colors.white),
          actionsIconTheme: const IconThemeData(color: Colors.white),
          toolbarHeight: 60,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: kCardSurface,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.grey.shade200, width: 1),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: kBrandGreen,
          foregroundColor: Colors.white,
          elevation: 3,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white.withValues(alpha: 0.45),
          backgroundColor: kBrandGreenDark,
          elevation: 0,
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w700),
          unselectedLabelStyle: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w400),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kBrandGreen, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          hintStyle: GoogleFonts.nunito(color: Colors.grey.shade400, fontSize: 14),
          prefixIconColor: Colors.grey.shade400,
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          labelStyle: GoogleFonts.nunito(fontSize: 12, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          side: BorderSide(color: Colors.grey.shade300),
        ),
        dividerTheme: DividerThemeData(color: Colors.grey.shade200, thickness: 1, space: 1),
        listTileTheme: ListTileThemeData(
          tileColor: kCardSurface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        ),
        tabBarTheme: TabBarThemeData(
          labelStyle: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w700),
          unselectedLabelStyle: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w500),
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white.withValues(alpha: 0.55),
          dividerColor: Colors.transparent,
        ),
      ),
      home: AuthGate(
        builder: (profile) => HomeShell(profile: profile),
        onQbCallback: handleQbCallback,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PasswordGate — shows a login screen until the correct password is entered.
// Once authenticated, the result is cached for kAuthCacheDuration so the user
// isn't prompted again until the cache expires.
// ─────────────────────────────────────────────────────────────────────────────

class PasswordGate extends StatefulWidget {
  final Widget child;
  const PasswordGate({super.key, required this.child});

  @override
  State<PasswordGate> createState() => _PasswordGateState();
}

class _PasswordGateState extends State<PasswordGate> {
  bool _checking = true;
  bool _authenticated = false;

  final _ctrl = TextEditingController();
  final _focusNode = FocusNode();
  bool _obscure = true;
  bool _wrong = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _checkCache();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _checkCache() async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_kAuthUntilKey) ?? 0;
    final valid = DateTime.fromMillisecondsSinceEpoch(until).isAfter(DateTime.now());
    if (!mounted) return;
    setState(() {
      _authenticated = valid;
      _checking = false;
    });
    // Auto-focus the password field if not authenticated
    if (!valid) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final entered = _ctrl.text.trim();
    if (entered == kAppPassword) {
      setState(() => _submitting = true);
      final prefs = await SharedPreferences.getInstance();
      final until = DateTime.now().add(kAuthCacheDuration).millisecondsSinceEpoch;
      await prefs.setInt(_kAuthUntilKey, until);
      if (!mounted) return;
      setState(() {
        _authenticated = true;
        _submitting = false;
      });
    } else {
      setState(() => _wrong = true);
      _ctrl.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        backgroundColor: kBrandGreenDark,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    if (_authenticated) return widget.child;
    return _buildLoginScreen();
  }

  Widget _buildLoginScreen() {
    return Scaffold(
      backgroundColor: kBrandGreenDark,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo / brand
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.home_work_rounded,
                      size: 38, color: Colors.white),
                ),
                const SizedBox(height: 20),
                Text(
                  'Able Home Accessibility',
                  style: GoogleFonts.nunito(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  'Enter your password to continue',
                  style: GoogleFonts.nunito(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 36),
                // Password card
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _ctrl,
                        focusNode: _focusNode,
                        obscureText: _obscure,
                        style: GoogleFonts.nunito(fontSize: 16),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          labelStyle: TextStyle(color: Colors.grey.shade600),
                          errorText: _wrong ? 'Incorrect password' : null,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure ? Icons.visibility_off : Icons.visibility,
                              color: Colors.grey.shade500,
                            ),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: kBrandGreen, width: 2),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: Colors.red, width: 1.5),
                          ),
                          focusedErrorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide:
                                const BorderSide(color: Colors.red, width: 2),
                          ),
                          filled: true,
                          fillColor: Colors.grey.shade50,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 14),
                        ),
                        autocorrect: false,
                        enableSuggestions: false,
                        onChanged: (_) {
                          if (_wrong) setState(() => _wrong = false);
                        },
                        onSubmitted: (_) => _submit(),
                        textInputAction: TextInputAction.done,
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: _submitting ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kBrandGreen,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            elevation: 0,
                          ),
                          child: _submitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2),
                                )
                              : Text(
                                  'Sign In',
                                  style: GoogleFonts.nunito(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'You\'ll stay signed in for 90 days',
                  style: GoogleFonts.nunito(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}



/// =======================
/// UTILITY FUNCTIONS
/// =======================

/// Custom comparator for ramp brands: EZ Access first, then alphabetically
int _compareRampBrands(String a, String b) {
  final aLower = a.toLowerCase();
  final bLower = b.toLowerCase();
  final aIsEz = aLower.contains('ez access');
  final bIsEz = bLower.contains('ez access');

  if (aIsEz && !bIsEz) return -1;
  if (!aIsEz && bIsEz) return 1;
  return a.compareTo(b);
}

/// Custom comparator for ramp sizes within a brand
/// Order: 2ft, 3ft, 4ft, 5ft, 6ft, 7ft, 8ft, 10ft, platforms, low profile platforms
int _compareRampSizes(String a, String b) {
  // Extract numeric value if present (e.g., "2ft" -> 2, "10ft" -> 10)
  final aNum = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), ''));
  final bNum = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), ''));

  final aLower = a.toLowerCase();
  final bLower = b.toLowerCase();
  final aIsPlatform = aLower.contains('platform');
  final bIsPlatform = bLower.contains('platform');
  final aIsLowProf = aLower.contains('low prof') || aLower.contains('low-prof');
  final bIsLowProf = bLower.contains('low prof') || bLower.contains('low-prof');

  // Platforms come after numeric sizes
  if (!aIsPlatform && bIsPlatform) return -1;
  if (aIsPlatform && !bIsPlatform) return 1;

  // Within platforms: regular platforms before low profile
  if (aIsPlatform && bIsPlatform) {
    if (!aIsLowProf && bIsLowProf) return -1;
    if (aIsLowProf && !bIsLowProf) return 1;
    return a.compareTo(b);
  }

  // Both are numeric sizes
  if (aNum != null && bNum != null) {
    return aNum.compareTo(bNum);
  }

  // Fallback to alphabetical
  return a.compareTo(b);
}

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

/// Check if a stairlift item is a folding rail type (quantity-based, no serial numbers)
bool isFoldingRail(StairliftItem item) {
  final brand = item.brand.toLowerCase();
  final series = item.series.toLowerCase();

  if (brand.contains('bruno')) {
    return series.contains('manual fold') || series.contains('power fold');
  }
  if (brand.contains('harmar')) {
    return series.contains('auto fold');
  }
  // Acorn and Brooks folding rails
  if (brand.contains('acorn') || brand.contains('brooks')) {
    return series.contains('fold');
  }

  return false;
}

/// Check if a lift record represents a folding rail (by brand/series)
bool isLiftRecordFoldingRail(LiftRecord lift) {
  final brand = lift.brand.toLowerCase();
  final series = lift.series.toLowerCase();

  if (brand.contains('bruno')) {
    return series.contains('manual fold') || series.contains('power fold');
  }
  if (brand.contains('harmar')) {
    return series.contains('auto fold');
  }
  if (brand.contains('acorn') || brand.contains('brooks')) {
    return series.contains('fold');
  }

  return false;
}

/// Custom sort order for stairlift series names
const _seriesOrder = [
  'Elan 5000', 'Elan 3050', 'Elan 3000', 'Elite', 'Elite Curve', 'Outdoor Elite',
  '120', '130', 'T700', 'Outdoor 120', 'Outdoor 130', 'Outdoor T700',
  'SL300', 'SL600',
];

/// Hardcoded series per brand for the Lifts filter.
const Map<String, List<String>> _seriesByBrandHardcoded = {
  'Acorn': ['T700', '130', '120', 'Outdoor T700', 'Outdoor 130', 'Outdoor 120'],
  'Brooks': ['T700', '130', '120', 'Outdoor T700', 'Outdoor 130', 'Outdoor 120'],
  'Bruno': ['Elan 5000', 'Elan 3050', 'Elan 3000', 'Elite', 'Elite Curve', 'Outdoor Elite'],
  'Harmar': ['SL300', 'SL600', 'Helix'],
};

List<String> sortSeriesList(List<String> series) {
  final ordered = <String>[];
  for (final s in _seriesOrder) {
    if (series.contains(s)) ordered.add(s);
  }
  // Any series not in the ordered list go at the end, alphabetically
  final remaining = series.where((s) => !_seriesOrder.contains(s)).toList()..sort();
  return [...ordered, ...remaining];
}

/// Get display title for a ramp, adding "(Low Prof)" suffix for low-profile EZ Access 3G platforms
String getRampDisplayTitle(RampItem item) {
  String title = '${item.brand} – ${item.size}';

  // Check if this is a low-profile EZ Access 3G platform
  final brand = item.brand.toLowerCase();
  final size = item.size.toLowerCase();
  final notes = item.notes.toLowerCase();

  // EZ Access 3G platforms: 4x4, 5x4, 5x5 can be low-profile
  // The indicator is in the notes field as "LOW_PROF" or similar
  if (brand.contains('ez access') && brand.contains('3g')) {
    if ((size.contains('4x4') || size.contains('5x4') || size.contains('5x5')) &&
        notes.contains('low_prof')) {
      title += ' (Low Prof)';
    }
  }

  return title;
}

/// =======================
/// HOME SHELL (BOTTOM NAV)
/// =======================

class HomeShell extends StatefulWidget {
  final UserProfile profile;
  const HomeShell({super.key, required this.profile});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// =======================
/// PREP SCREEN (dedicated prep workflow)
/// =======================

class PrepScreen extends StatefulWidget {
  const PrepScreen({super.key});

  @override
  State<PrepScreen> createState() => _PrepScreenState();
}

class _PrepScreenState extends State<PrepScreen> {
  late Future<List<LiftRecord>> _liftsFuture;
  String? _statusFilter;

  @override
  void initState() {
    super.initState();
    _liftsFuture = sbFetchLifts();
  }

  void _refresh() {
    setState(() {
      _liftsFuture = sbFetchLifts();
    });
  }

  void _openPrepHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const PrepHistoryScreen(),
      ),
    );
  }

  Future<void> _openPrepChecklist(LiftRecord lift) async {
    // Load any existing in-progress checklist so the user can resume
    PrepChecklist? existing;
    if (lift.serialNumber.isNotEmpty) {
      final checklists = await sbFetchPrepChecklists(serialNumber: lift.serialNumber);
      if (checklists.isNotEmpty) existing = checklists.first;
    }
    if (!mounted) return;

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PrepChecklistFormScreen(lift: lift, existingChecklist: existing),
      ),
    );

    if (result == true && mounted) {
      _refresh();
    }
  }

  Future<void> _openServiceForm(LiftRecord lift) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LiftServiceFormScreen(lift: lift),
      ),
    );

    if (result == true && mounted) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prep'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Prep history',
            onPressed: _openPrepHistory,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<LiftRecord>>(
        future: _liftsFuture,
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

          // Derive available statuses for the filter
          final statuses = lifts
              .map((l) => l.status.trim())
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

          // Apply status filter before grouping
          final filtered = _statusFilter == null
              ? lifts
              : lifts.where((l) => l.status.trim() == _statusFilter).toList();

          // Group filtered lifts by prep status; assigned lifts sort to top within each group
          int assignedFirst(LiftRecord a, LiftRecord b) {
            final aAssigned = a.status.toLowerCase() == 'assigned' ? 0 : 1;
            final bAssigned = b.status.toLowerCase() == 'assigned' ? 0 : 1;
            return aAssigned.compareTo(bAssigned);
          }
          final needsPrepping = filtered
              .where((l) => l.preppedStatus.toLowerCase() == 'needs prepping')
              .toList()..sort(assignedFirst);
          final needsRepair = filtered
              .where((l) => l.preppedStatus.toLowerCase() == 'needs repair')
              .toList()..sort(assignedFirst);

          return RefreshIndicator(
            onRefresh: () async {
              setState(() {
                _liftsFuture = sbFetchLifts();
              });
              await _liftsFuture;
            },
            child: ListView(
              padding: const EdgeInsets.all(12.0),
              children: [
                // Status filter
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: DropdownButtonFormField<String>(
                    initialValue: _statusFilter,
                    decoration: const InputDecoration(
                      labelText: 'Filter by status',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('All statuses')),
                      ...statuses.map((s) => DropdownMenuItem(value: s, child: Text(s))),
                    ],
                    onChanged: (value) => setState(() => _statusFilter = value),
                  ),
                ),

                // Needs Prepping Section
                _buildSection(
                  title: 'Needs Prepping',
                  lifts: needsPrepping,
                  emptyMessage: 'No lifts need prepping',
                  onTap: _openPrepChecklist,
                ),
                const SizedBox(height: 16),

                // Needs Repair Section
                _buildSection(
                  title: 'Needs Repair',
                  lifts: needsRepair,
                  emptyMessage: 'No lifts need repair',
                  onTap: _openServiceForm,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required List<LiftRecord> lifts,
    required String emptyMessage,
    required Future<void> Function(LiftRecord)? onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: kBrandGreen.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${lifts.length}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: kBrandGreen,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (lifts.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              emptyMessage,
              style: TextStyle(
                color: Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          ...lifts.map((lift) {
                final isAssigned = lift.status.trim().toLowerCase() == 'assigned';
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: isAssigned ? Colors.amber.shade50 : null,
                  shape: isAssigned
                      ? RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.amber.shade300, width: 1),
                        )
                      : null,
                  child: ListTile(
                    onTap: onTap != null ? () => onTap(lift) : null,
                    title: Text(
                      '${lift.brand}${lift.series.isNotEmpty ? ' – ${lift.series}' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('SN: ${lift.serialNumber.isNotEmpty ? lift.serialNumber : 'N/A'}'),
                        if (lift.currentLocation.isNotEmpty)
                          Text('Location: ${lift.currentLocation}'),
                        Row(
                          children: [
                            Text('Status: ${lift.status.isEmpty ? 'Unknown' : lift.status}'),
                            if (isAssigned) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade100,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.amber.shade400),
                                ),
                                child: Text(
                                  'Assigned to job',
                                  style: TextStyle(fontSize: 10, color: Colors.amber.shade800, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                    trailing: onTap != null
                        ? const Icon(Icons.chevron_right)
                        : null,
                  ),
                );
              }),
      ],
    );
  }
}

/// =======================
/// PREP HISTORY SCREEN
/// =======================

class PrepHistoryScreen extends StatefulWidget {
  const PrepHistoryScreen({super.key});

  @override
  State<PrepHistoryScreen> createState() => _PrepHistoryScreenState();
}

class _PrepHistoryScreenState extends State<PrepHistoryScreen> {
  late Future<List<PrepChecklist>> _future;
  String _sortBy = 'date'; // date, brand, or serial
  String _search = '';

  @override
  void initState() {
    super.initState();
    _future = sbFetchAllPrepChecklists();
  }

  void _refresh() {
    setState(() {
      _future = sbFetchAllPrepChecklists();
    });
  }

  List<PrepChecklist> _sortChecklists(List<PrepChecklist> checklists) {
    final sorted = List<PrepChecklist>.from(checklists);

    switch (_sortBy) {
      case 'brand':
        sorted.sort((a, b) {
          final brandCompare = a.brand.compareTo(b.brand);
          if (brandCompare != 0) return brandCompare;
          return a.series.compareTo(b.series);
        });
        break;
      case 'serial':
        sorted.sort((a, b) => a.serialNumber.compareTo(b.serialNumber));
        break;
      case 'date':
      default:
        sorted.sort((a, b) {
          if (a.timestamp == null && b.timestamp == null) return 0;
          if (a.timestamp == null) return 1;
          if (b.timestamp == null) return -1;
          return b.timestamp!.compareTo(a.timestamp!); // Most recent first
        });
    }

    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prep History'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort by',
            onSelected: (value) {
              setState(() {
                _sortBy = value;
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'date',
                child: Text('Sort by Date'),
              ),
              const PopupMenuItem(
                value: 'brand',
                child: Text('Sort by Brand'),
              ),
              const PopupMenuItem(
                value: 'serial',
                child: Text('Sort by Serial'),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<PrepChecklist>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error loading prep history:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }

          final sorted = _sortChecklists(snapshot.data ?? []);

          final checklists = _search.isEmpty
              ? sorted
              : sorted.where((c) {
                  final haystack = [
                    c.brand,
                    c.series,
                    c.serialNumber,
                    c.preppedByName,
                    c.prepDate,
                  ].join(' ').toLowerCase();
                  return haystack.contains(_search);
                }).toList();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search by brand, serial, prepped by...',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
                ),
              ),
              if (checklists.isEmpty)
                const Expanded(
                  child: Center(child: Text('No prep history found')),
                )
              else
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    setState(() { _future = sbFetchAllPrepChecklists(); });
                    await _future;
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12.0),
              itemCount: checklists.length,
              itemBuilder: (context, index) {
                final checklist = checklists[index];
                final dateStr = checklist.timestamp != null
                    ? formatDate(checklist.timestamp)
                    : normalizeDateDisplay(checklist.prepDate);

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    title: Text(
                      '${checklist.brand}${checklist.series.isNotEmpty ? ' – ${checklist.series}' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('SN: ${checklist.serialNumber}'),
                        Text('Date: $dateStr'),
                        Text('Prepped by: ${checklist.preppedByName}'),
                        if (checklist.notes.isNotEmpty)
                          Text('Notes: ${checklist.notes}'),
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => PrepChecklistDetailScreen(checklist: checklist),
                        ),
                      );
                    },
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
    );
  }
}

/// =======================
/// PREP CHECKLIST DETAIL SCREEN
/// =======================

class PrepChecklistDetailScreen extends StatelessWidget {
  final PrepChecklist checklist;

  const PrepChecklistDetailScreen({super.key, required this.checklist});

  @override
  Widget build(BuildContext context) {
    final dateStr = checklist.timestamp != null
        ? formatDate(checklist.timestamp)
        : normalizeDateDisplay(checklist.prepDate);

    // Sort checklist items alphabetically for consistent display
    final sortedItems = checklist.checklistItems.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Prep Checklist Details'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header Card with lift info
            Card(
              color: kBrandGreen.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${checklist.brand}${checklist.series.isNotEmpty ? ' – ${checklist.series}' : ''}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Serial Number: ${checklist.serialNumber}'),
                    Text('Date: $dateStr'),
                    Text('Prepped by: ${checklist.preppedByName}'),
                    if (checklist.notes.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Notes:',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(checklist.notes),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Checklist Items Section
            const Text(
              'Checklist Items',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),

            // Display all checklist items with checkboxes (read-only)
            ...sortedItems.map((entry) {
              final itemName = entry.key;
              final isChecked = entry.value;

              return Card(
                margin: const EdgeInsets.symmetric(vertical: 2),
                child: CheckboxListTile(
                  value: isChecked,
                  onChanged: null, // Read-only
                  title: Text(
                    _formatChecklistItemName(itemName),
                  ),
                  secondary: Icon(
                    isChecked ? Icons.check_circle : Icons.circle_outlined,
                    color: isChecked ? Colors.green : Colors.grey,
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Format checklist item names to be more readable
  /// Example: "rails_in_good_condition" -> "Rails In Good Condition"
  String _formatChecklistItemName(String name) {
    return name
        .split('_')
        .map((word) => word.isEmpty ? '' : word[0].toUpperCase() + word.substring(1))
        .join(' ');
  }
}


// =======================
// ANNUALS SCREEN
// =======================

class AnnualsScreen extends StatefulWidget {
  const AnnualsScreen({super.key});

  @override
  State<AnnualsScreen> createState() => _AnnualsScreenState();
}

class _AnnualsScreenState extends State<AnnualsScreen> {
  late Future<List<AnnualRecord>> _future;
  String _search = '';
  String? _scheduledFilter; // null=all, 'pending'=not scheduled, 'scheduled'=scheduled

  @override
  void initState() {
    super.initState();
    _future = sbFetchAnnuals();
  }

  void _refresh() => setState(() => _future = sbFetchAnnuals());

  Future<Map<String, String>> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
      'email': AuthService.instance.profile?.email ?? '',
    };
  }

  Future<void> _openForm({AnnualRecord? existing}) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AnnualFormScreen(existing: existing)),
    );
    if (result == true) _refresh();
  }

  Future<void> _markScheduled(AnnualRecord record) async {
    final user = await _loadUser();
    if (user['name']!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please set your name in the main screen.')),
      );
      return;
    }
    try {
      await sbMarkAnnualScheduled(
        annualId: record.annualId,
        userName: user['name']!,
        userEmail: user['email'] ?? '',
      );
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _delete(AnnualRecord record) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete record?',
      content: 'Remove ${record.customerName} from annuals?',
    );
    if (!confirmed) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await sbDeleteAnnual(
        annualId: record.annualId,
        userEmail: AuthService.instance.profile?.email ?? '',
        userName: prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
      );
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _openDetail(AnnualRecord record) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AnnualDetailScreen(record: record, onChanged: _refresh)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Annuals'),
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<AnnualRecord>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final all = snapshot.data ?? [];

          // Filter
          var filtered = all.where((r) {
            if (_search.isNotEmpty) {
              final q = _search.toLowerCase();
              if (!r.customerName.toLowerCase().contains(q) &&
                  !r.address.toLowerCase().contains(q) &&
                  !r.phone.toLowerCase().contains(q) &&
                  !r.liftType.toLowerCase().contains(q)) {
                return false;
              }
            }
            if (_scheduledFilter == 'pending' && r.scheduled) return false;
            if (_scheduledFilter == 'scheduled' && !r.scheduled) return false;
            return true;
          }).toList();

          // Sort: unscheduled first, then by date requested oldest first
          filtered.sort((a, b) {
            if (a.scheduled != b.scheduled) return a.scheduled ? 1 : -1;
            if (a.dateRequested.isNotEmpty && b.dateRequested.isNotEmpty) {
              return a.dateRequested.compareTo(b.dateRequested);
            }
            return a.customerName.compareTo(b.customerName);
          });

          return Column(
            children: [
              // Search bar
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search customers...',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    isDense: true,
                    suffixIcon: _search.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(() => _search = ''),
                          )
                        : null,
                  ),
                  onChanged: (v) => setState(() => _search = v.trim()),
                ),
              ),
              // Filter chips
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    _filterChip('All', null),
                    const SizedBox(width: 8),
                    _filterChip('Needs scheduling', 'pending'),
                    const SizedBox(width: 8),
                    _filterChip('Scheduled', 'scheduled'),
                  ],
                ),
              ),
              const Divider(height: 1),
              // Count
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(
                  children: [
                    Text('${filtered.length} record${filtered.length == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.black54, fontSize: 13)),
                  ],
                ),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(child: Text('No records found.'))
                    : RefreshIndicator(
                        onRefresh: () async => _refresh(),
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 80),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) =>
                              _buildCard(filtered[index]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        backgroundColor: kBrandGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Annual'),
      ),
    );
  }

  Widget _filterChip(String label, String? value) {
    final selected = _scheduledFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      selectedColor: kBrandGreen.withOpacity(0.2),
      onSelected: (_) => setState(() => _scheduledFilter = value),
    );
  }

  Widget _buildCard(AnnualRecord r) {
    final Color statusColor = r.scheduled
        ? Colors.green.shade700
        : Colors.orange.shade700;
    final String statusLabel = r.scheduled ? 'Scheduled' : 'Needs scheduling';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _openDetail(r),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      r.customerName,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: statusColor.withOpacity(0.4)),
                    ),
                    child: Text(statusLabel,
                        style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (r.address.isNotEmpty)
                Row(children: [
                  const Icon(Icons.location_on_outlined, size: 14, color: Colors.black45),
                  const SizedBox(width: 4),
                  Expanded(child: Text(r.address, style: const TextStyle(fontSize: 13))),
                ]),
              if (r.phone.isNotEmpty)
                Row(children: [
                  const Icon(Icons.phone_outlined, size: 14, color: Colors.black45),
                  const SizedBox(width: 4),
                  Text(r.phone, style: const TextStyle(fontSize: 13)),
                ]),
              if (r.liftType.isNotEmpty)
                Row(children: [
                  const Icon(Icons.stairs, size: 14, color: Colors.black45),
                  const SizedBox(width: 4),
                  Expanded(child: Text(r.liftType, style: const TextStyle(fontSize: 13))),
                  if (r.liftId.isNotEmpty)
                    const Tooltip(
                      message: 'Linked to lift in system',
                      child: Icon(Icons.link, size: 14, color: kBrandGreen),
                    ),
                ]),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (r.lastServiceDate.isNotEmpty)
                    Text('Last service: ${normalizeDateDisplay(r.lastServiceDate)}',
                        style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  if (r.lastServiceDate.isNotEmpty && r.dateRequested.isNotEmpty)
                    const Text('  ·  ', style: TextStyle(color: Colors.black38)),
                  if (r.dateRequested.isNotEmpty)
                    Text('Requested: ${normalizeDateDisplay(r.dateRequested)}',
                        style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
              ),
              if (r.notes.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(r.notes,
                    style: const TextStyle(fontSize: 12, color: Colors.black45),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
              // Action buttons
              if (!r.scheduled) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _markScheduled(r),
                      icon: const Icon(Icons.check_circle_outline, size: 16),
                      label: const Text('Mark Scheduled'),
                      style: TextButton.styleFrom(foregroundColor: kBrandGreen),
                    ),
                    const SizedBox(width: 4),
                    TextButton.icon(
                      onPressed: () => _openForm(existing: r),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit'),
                      style: TextButton.styleFrom(foregroundColor: Colors.black54),
                    ),
                    TextButton.icon(
                      onPressed: () => _delete(r),
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Delete'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                  ],
                ),
              ] else ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () => _openForm(existing: r),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit'),
                      style: TextButton.styleFrom(foregroundColor: Colors.black54),
                    ),
                    TextButton.icon(
                      onPressed: () => _delete(r),
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Delete'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =======================
// ANNUAL DETAIL SCREEN
// =======================

class AnnualDetailScreen extends StatefulWidget {
  final AnnualRecord record;
  final VoidCallback onChanged;
  const AnnualDetailScreen({super.key, required this.record, required this.onChanged});

  @override
  State<AnnualDetailScreen> createState() => _AnnualDetailScreenState();
}

class _AnnualDetailScreenState extends State<AnnualDetailScreen> {
  late Future<List<Map<String, dynamic>>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _historyFuture = sbFetchAnnualHistory(annualId: widget.record.annualId);
  }

  Future<Map<String, String>> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'name': prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
      'email': AuthService.instance.profile?.email ?? '',
    };
  }

  Future<void> _markScheduled() async {
    final user = await _loadUser();
    if (user['name']!.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please set your name in the main screen.')),
      );
      return;
    }
    try {
      await sbMarkAnnualScheduled(
        annualId: widget.record.annualId,
        userName: user['name']!,
        userEmail: user['email'] ?? '',
      );
      widget.onChanged();
      if (!mounted) return;

      // If a lift is linked, offer to log a service record
      final r = widget.record;
      if (r.liftId.isNotEmpty) {
        final logService = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Log service record?'),
            content: Text(
                'Would you like to log an annual service record for ${r.liftType.isNotEmpty ? r.liftType : "SN: ${r.serialNumber}"}?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Skip'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                child: const Text('Log Service'),
              ),
            ],
          ),
        );
        if (logService == true && mounted) {
          // Find the linked lift record
          LiftRecord? linkedLift;
          try {
            final lifts = await sbFetchLifts();
            linkedLift = lifts.where((l) => l.liftId == r.liftId).firstOrNull;
          } catch (_) {}
          if (linkedLift != null && mounted) {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LiftServiceFormScreen(
                  lift: linkedLift!,
                  prefillServiceType: 'Annual Service',
                  prefillCustomerName: r.customerName,
                  prefillDate: formatDate(DateTime.now()),
                ),
              ),
            );
          }
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final statusColor = r.scheduled ? Colors.green.shade700 : Colors.orange.shade700;

    return Scaffold(
      appBar: AppBar(
        title: Text(r.customerName),
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              final result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => AnnualFormScreen(existing: r)),
              );
              if (result == true) {
                widget.onChanged();
                if (mounted) Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: statusColor.withOpacity(0.4)),
              ),
              child: Text(
                r.scheduled ? 'Scheduled' : 'Needs scheduling',
                style: TextStyle(color: statusColor, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 16),
            _detailRow(Icons.person_outline, 'Customer', r.customerName),
            if (r.address.isNotEmpty) _detailRow(Icons.location_on_outlined, 'Address', r.address),
            if (r.phone.isNotEmpty) _detailRow(Icons.phone_outlined, 'Phone', r.phone),
            if (r.liftType.isNotEmpty) _detailRow(Icons.stairs, 'Lift type', r.liftType),
            if (r.liftId.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: InkWell(
                  onTap: () async {
                    final nav = Navigator.of(context);
                    try {
                      final lifts = await sbFetchLifts();
                      final linked = lifts.where((l) => l.liftId == r.liftId).firstOrNull;
                      if (linked != null) {
                        nav.push(MaterialPageRoute(
                          builder: (_) => LiftDetailScreen(lift: linked),
                        ));
                      }
                    } catch (_) {}
                  },
                  child: Row(
                    children: [
                      const Icon(Icons.link, size: 18, color: kBrandGreen),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Linked lift',
                                style: TextStyle(fontSize: 11, color: Colors.black45)),
                            Text('Tap to view lift details',
                                style: TextStyle(fontSize: 15, color: kBrandGreen)),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: kBrandGreen),
                    ],
                  ),
                ),
              ),
            if (r.lastServiceDate.isNotEmpty)
              _detailRow(Icons.history, 'Last service', normalizeDateDisplay(r.lastServiceDate)),
            if (r.dateRequested.isNotEmpty)
              _detailRow(Icons.calendar_today_outlined, 'Date requested', normalizeDateDisplay(r.dateRequested)),
            if (r.notes.isNotEmpty) _detailRow(Icons.notes_outlined, 'Notes', r.notes),
            const SizedBox(height: 24),
            // Mark scheduled button
            if (!r.scheduled)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _markScheduled,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Mark Scheduled'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kBrandGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            // History
            const Text('History',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _historyFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final history = snap.data ?? [];
                if (history.isEmpty) {
                  return const Text('No history yet.',
                      style: TextStyle(color: Colors.black45));
                }
                return Column(
                  children: history.map((h) {
                    final ts = normalizeDateDisplay(h['timestamp']?.toString() ?? '');
                    final event = h['event']?.toString() ?? '';
                    final user = h['user_name']?.toString() ?? '';
                    final note = h['note']?.toString() ?? '';
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.check_circle, color: kBrandGreen),
                        title: Text(event, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(ts),
                            if (user.isNotEmpty) Text('By: $user'),
                            if (note.isNotEmpty) Text(note),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.black45),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontSize: 11, color: Colors.black45)),
                Text(value, style: const TextStyle(fontSize: 15)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =======================
// LIFT PICKER DIALOG
// =======================

class _LiftPickerDialog extends StatefulWidget {
  const _LiftPickerDialog();

  @override
  State<_LiftPickerDialog> createState() => _LiftPickerDialogState();
}

class _LiftPickerDialogState extends State<_LiftPickerDialog> {
  final _searchController = TextEditingController();
  List<LiftRecord> _all = [];
  List<LiftRecord> _filtered = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(_filter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final lifts = await sbFetchLifts();
      // Only show lifts that can be linked: exclude Installed and Scrapped
      const linkableStatuses = ['New', 'Removed', 'Assigned'];
      final linkable = lifts.where((l) => linkableStatuses.contains(l.status)).toList();
      if (mounted) {
        setState(() {
          _all = linkable;
          _filtered = linkable;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _filter() {
    final q = _searchController.text.toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _all
          : _all.where((l) {
              final haystack = [l.serialNumber, l.brand, l.series, l.currentLocation, l.liftId].join(' ').toLowerCase();
              return q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).every((t) => haystack.contains(t));
            }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 40),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: kBrandGreen,
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.search, color: Colors.white),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Select a lift',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          // Search box
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(color: Colors.black),
              decoration: const InputDecoration(
                hintText: 'Search by serial, brand, series, location...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          // List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filtered.isEmpty
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('No lifts found.',
                              style: TextStyle(color: Colors.black45)),
                          const SizedBox(height: 16),
                          TextButton.icon(
                            onPressed: () async {
                              Navigator.of(context).pop();
                              // Caller will handle opening LiftFormScreen
                            },
                            icon: const Icon(Icons.add),
                            label: const Text('Add new lift'),
                          ),
                        ],
                      )
                    : ListView.builder(
                        itemCount: _filtered.length,
                        itemBuilder: (context, i) {
                          final l = _filtered[i];
                          final title = [l.brand, l.series, l.orientation]
                              .where((s) => s.isNotEmpty)
                              .join(' ');
                          return ListTile(
                            leading: const Icon(Icons.stairs, color: kBrandGreen),
                            title: Text(title,
                                style: const TextStyle(fontWeight: FontWeight.w500)),
                            subtitle: Text([
                              if (l.serialNumber.isNotEmpty) 'SN: ${l.serialNumber}',
                              if (l.currentLocation.isNotEmpty) l.currentLocation,
                              l.status,
                            ].where((s) => s.isNotEmpty).join(' · ')),
                            onTap: () => Navigator.of(context).pop(l),
                          );
                        },
                      ),
          ),
          // Add new lift button (always visible at bottom)
          Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(const _AddNewLiftSentinel()),
              icon: const Icon(Icons.add),
              label: const Text('Lift not in system — add it now'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
                foregroundColor: kBrandGreen,
                side: const BorderSide(color: kBrandGreen),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sentinel return value from _LiftPickerDialog meaning "add a new lift".
class _AddNewLiftSentinel {
  const _AddNewLiftSentinel();
}

// =======================
// ANNUAL FORM SCREEN
// =======================

class AnnualFormScreen extends StatefulWidget {
  final AnnualRecord? existing;
  const AnnualFormScreen({super.key, this.existing});

  @override
  State<AnnualFormScreen> createState() => _AnnualFormScreenState();
}

class _AnnualFormScreenState extends State<AnnualFormScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _phoneController;
  late final TextEditingController _liftTypeController;
  late final TextEditingController _lastServiceController;
  late final TextEditingController _dateRequestedController;
  late final TextEditingController _notesController;

  // Linked lift state
  String? _linkedLiftId;
  String? _linkedSerialNumber;
  String? _linkedLiftLabel; // display string, e.g. "Bruno Elan 3000 LH — SN: 12345"

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameController = TextEditingController(text: e?.customerName ?? '');
    _addressController = TextEditingController(text: e?.address ?? '');
    _phoneController = TextEditingController(text: e?.phone ?? '');
    _liftTypeController = TextEditingController(text: e?.liftType ?? '');
    _lastServiceController = TextEditingController(
        text: e != null ? normalizeDateDisplay(e.lastServiceDate) : '');
    _dateRequestedController = TextEditingController(
        text: e != null ? normalizeDateDisplay(e.dateRequested) : '');
    _notesController = TextEditingController(text: e?.notes ?? '');
    // Restore linked lift if editing
    if (e != null && e.liftId.isNotEmpty) {
      _linkedLiftId = e.liftId;
      _linkedSerialNumber = e.serialNumber;
      _linkedLiftLabel = e.liftType.isNotEmpty ? e.liftType : 'SN: ${e.serialNumber}';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _liftTypeController.dispose();
    _lastServiceController.dispose();
    _dateRequestedController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _linkLift(LiftRecord lift) {
    final label = [
      lift.brand,
      lift.series,
      if (lift.orientation.isNotEmpty && lift.orientation != 'N/A') lift.orientation,
    ].where((s) => s.isNotEmpty).join(' ') + (lift.serialNumber.isNotEmpty ? ' — SN: ${lift.serialNumber}' : '');
    setState(() {
      _linkedLiftId = lift.liftId;
      _linkedSerialNumber = lift.serialNumber;
      _linkedLiftLabel = label;
      _liftTypeController.text = label;
    });
  }

  void _unlinkLift() {
    setState(() {
      _linkedLiftId = null;
      _linkedSerialNumber = null;
      _linkedLiftLabel = null;
      _liftTypeController.clear();
    });
  }

  Future<void> _openLiftPicker() async {
    final result = await showDialog(
      context: context,
      builder: (_) => const _LiftPickerDialog(),
    );
    if (result is LiftRecord) {
      _linkLift(result);
    } else if (result is _AddNewLiftSentinel) {
      if (!mounted) return;
      // Open add-lift form; on success, reload and try to auto-link by serial
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const LiftFormScreen()),
      );
      if (saved == true) {
        // Fetch lifts again and pick the most recently added one
        try {
          final lifts = await sbFetchLifts();
          if (lifts.isNotEmpty) _linkLift(lifts.last);
        } catch (_) {}
      }
    }
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    DateTime initial = now;
    // Try to parse existing value
    if (controller.text.isNotEmpty) {
      try {
        final parts = controller.text.split('/');
        if (parts.length == 3) {
          initial = DateTime(int.parse(parts[2]), int.parse(parts[0]), int.parse(parts[1]));
        }
      } catch (_) {}
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      controller.text = formatDate(picked);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';
      final userEmail = AuthService.instance.profile?.email ?? '';

      await sbUpsertAnnual(
        userEmail: userEmail,
        userName: userName,
        annualId: widget.existing?.annualId,
        customerName: _nameController.text.trim(),
        address: _addressController.text.trim(),
        phone: _phoneController.text.trim(),
        liftType: _liftTypeController.text.trim(),
        lastServiceDate: _lastServiceController.text.trim(),
        dateRequested: _dateRequestedController.text.trim(),
        notes: _notesController.text.trim(),
        liftId: _linkedLiftId ?? '',
        serialNumber: _linkedSerialNumber ?? '',
      );

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _dateField(String label, TextEditingController controller) {
    return TextFormField(
      controller: controller,
      readOnly: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        suffixIcon: const Icon(Icons.calendar_today_outlined),
      ),
      onTap: () => _pickDate(controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Annual' : 'Add Annual'),
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                    labelText: 'Customer name *', border: OutlineInputBorder()),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _addressController,
                decoration: const InputDecoration(
                    labelText: 'Address', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                    labelText: 'Phone', border: OutlineInputBorder()),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              // Lift picker / manual entry
              if (_linkedLiftLabel != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: kBrandGreen),
                    borderRadius: BorderRadius.circular(8),
                    color: kBrandGreen.withOpacity(0.05),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.stairs, color: kBrandGreen, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_linkedLiftLabel!,
                            style: const TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Unlink lift',
                        onPressed: _unlinkLift,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                OutlinedButton.icon(
                  onPressed: _openLiftPicker,
                  icon: const Icon(Icons.link),
                  label: const Text('Link a lift from system'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    foregroundColor: kBrandGreen,
                    side: const BorderSide(color: kBrandGreen),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _liftTypeController,
                  decoration: const InputDecoration(
                      labelText: 'Or type lift description manually',
                      border: OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: 12),
              _dateField('Last service date', _lastServiceController),
              const SizedBox(height: 12),
              _dateField('Date requested', _dateRequestedController),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                    labelText: 'Notes', border: OutlineInputBorder()),
                maxLines: 3,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kBrandGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(isEditing ? 'Save changes' : 'Add annual'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    setState(() => _loading = true);
    try {
      final list = await sbGetPickupList();
      if (mounted) setState(() => _items = list);
    } catch (e) {
      debugPrint('Failed to load pickup list: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addItem() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final addedBy = prefs.getString('user_name') ?? 'Unknown';

    // Optimistic UI: add locally first
    final tempId = 'item_${DateTime.now().millisecondsSinceEpoch}';
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
      await sbAddPickupItem(item: text, addedBy: addedBy);
      // Refresh to get the server-assigned id
      final list = await sbGetPickupList();
      if (mounted) setState(() => _items = list);
    } catch (e) {
      debugPrint('Failed to add pickup item: $e');
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
      await sbUpdatePickupItem(id: id, completed: value, completedBy: user);
    } catch (e) {
      debugPrint('Failed to update pickup item: $e');
      // Revert optimistic update on failure
      setState(() {
        item['completed'] = !value;
        item['completed_by'] = !value ? user : '';
        item['completed_at'] = !value ? DateTime.now().toIso8601String() : '';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update item: $e')),
        );
      }
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final itemId = item['id']?.toString() ?? '';
    if (itemId.isEmpty) return;

    // Show confirmation dialog
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete Item',
      content: 'Are you sure you want to delete "${item['item']}"?',
    );
    if (!confirmed) return;

    // Optimistic update: remove from list immediately
    final itemIndex = _items.indexWhere((it) => it['id'] == itemId);
    final removedItem = item;
    setState(() {
      _items.removeAt(itemIndex);
    });

    try {
      await sbDeletePickupItem(id: itemId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Item deleted')),
        );
      }
    } catch (e) {
      debugPrint('Failed to delete pickup item: $e');
      // Revert optimistic update on failure
      setState(() {
        _items.insert(itemIndex, removedItem);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete item: $e')),
        );
      }
    }
  }

  Future<void> _refresh() async => _fetchItems();

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
                            return ListTile(
                              leading: completed
                                  ? const Icon(Icons.check_circle)
                                  : const Icon(Icons.inventory_2),
                              title: Text(it['item']?.toString() ?? ''),
                              subtitle: Text("Added by: ${it['added_by'] ?? ''}"),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Checkbox(
                                    value: completed,
                                    onChanged: (v) => _toggleComplete(it, v ?? false),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                                    onPressed: () => _deleteItem(it),
                                  ),
                                ],
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
    );
  }
}

// =======================
// JOBS SCREEN (CRM)
// =======================

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<QbtScheduleEvent> _events = [];
  Map<String, QbtUser> _users = {};
  Map<String, Map<String, dynamic>> _allMeta = {};
  Set<String> _completedIds = {};
  Map<String, List<LiftRecord>> _liftsByEvent = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final start = now.subtract(const Duration(days: 90));
      final end = now.add(const Duration(days: 90));
      final results = await Future.wait([
        qbtFetchScheduleEvents(start: start, end: end),
        qbtFetchUsers(),
        sbGetAllEventMeta(),
        sbFetchCompletedEventIds(),
      ]);
      if (!mounted) return;
      final events = results[0] as List<QbtScheduleEvent>;
      final allMeta = results[2] as Map<String, Map<String, dynamic>>;

      // Fetch lifts for all events that have linked lift IDs
      final liftsByEvent = <String, List<LiftRecord>>{};
      final liftFutures = <Future<void>>[];
      for (final event in events) {
        final meta = allMeta[event.id];
        if (meta == null) continue;
        final liftIds = (meta['lift_ids'] as List?)?.cast<String>() ?? [];
        if (liftIds.isEmpty) continue;
        liftFutures.add(() async {
          final lifts = <LiftRecord>[];
          for (final id in liftIds) {
            final l = await sbFetchLiftById(id);
            if (l != null) lifts.add(l);
          }
          liftsByEvent[event.id] = lifts;
        }());
      }
      await Future.wait(liftFutures);

      if (!mounted) return;
      setState(() {
        _events = events;
        _users = results[1] as Map<String, QbtUser>;
        _allMeta = allMeta;
        _completedIds = results[3] as Set<String>;
        _liftsByEvent = liftsByEvent;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  // Schedule-note types don't have a meaningful date window — show all unconverted ones.
  static const _scheduleNoteTypes = {'Schedule Service', 'Schedule Removal'};

  List<QbtScheduleEvent> _eventsForType(List<String> types) {
    final now = DateTime.now();
    final windowStart = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 7));
    final windowEnd = DateTime(now.year, now.month, now.day, 23, 59, 59).add(const Duration(days: 7));
    return _events.where((e) {
      String? jobType = _allMeta[e.id]?['job_type'] as String?;
      if (jobType == null || jobType.isEmpty) {
        jobType = inferJobTypeFromTitle(e.title);
      }
      if (jobType == null || !types.contains(jobType)) return false;
      // Schedule notes: skip date window — show until converted
      if (_scheduleNoteTypes.contains(jobType)) return true;
      final eventDate = e.start.toLocal();
      return !eventDate.isBefore(windowStart) && !eventDate.isAfter(windowEnd);
    }).toList();
  }

  String _assignedNames(QbtScheduleEvent event) {
    if (event.assignedUserIds.isEmpty) return '';
    return event.assignedUserIds
        .map((id) => _users[id]?.displayName ?? 'Unknown')
        .join(', ');
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final m = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  Color _parseEventColor(QbtScheduleEvent event) {
    try {
      final h = event.color.replaceAll('#', '');
      return Color(int.parse('FF$h', radix: 16));
    } catch (_) {
      return kBrandGreen;
    }
  }

  Future<void> _onToggleComplete(QbtScheduleEvent event, bool next) async {
    setState(() {
      if (next) {
        _completedIds.add(event.id);
      } else {
        _completedIds.remove(event.id);
      }
    });
    await sbSetEventCompleted(eventId: event.id, completed: next);
    if (next && mounted) {
      final meta = _allMeta[event.id];
      final jobType = meta?['job_type'] as String?;
      final liftIds = (meta?['lift_ids'] as List?)?.cast<String>() ?? [];

      // Ramp job: explicit Ramp Install or Ramp Removal type
      if ((jobType == 'Ramp Install' || jobType == 'Ramp Removal') && liftIds.isEmpty && mounted) {
        final isInstall = jobType == 'Ramp Install';
        final fundingSource = (meta?['funding_source'] as String?) ?? 'Private';
        final isCcals = fundingSource == 'CCALS';
        final confirm = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(isInstall ? 'Record ramp install?' : 'Record ramp removal?'),
            content: Text(
              isInstall
                  ? 'Select the ramps and quantities used on this job to deduct them from ${isCcals ? 'CCALS' : 'Able Home'} inventory.'
                  : 'Select the ramps and quantities recovered on this job to add them back to ${isCcals ? 'CCALS' : 'Able Home'} inventory.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                child: const Text('Open Form'),
              ),
            ],
          ),
        );
        if (confirm == true && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => JobAdjustmentScreen(
                initialJobRef: event.title,
                initialTabIndex: isInstall ? 0 : 1,
                isCcals: isCcals,
              ),
            ),
          );
        }
      }

      if (jobType != null && liftIds.isNotEmpty && mounted) {
        final prefs = await SharedPreferences.getInstance();
        final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';
        final userEmail = AuthService.instance.profile?.email ?? '';
        for (final liftId in liftIds) {
          final lift = await sbFetchLiftById(liftId);
          if (lift == null || !mounted) continue;
          String? newStatus;
          String dialogTitle = '';
          String dialogBody = '';
          String confirmLabel = '';
          if (jobType == 'Stairlift Install') {
            newStatus = 'Installed';
            dialogTitle = 'Mark lift as Installed?';
            dialogBody = 'Update ${lift.brand} ${lift.series} (SN: ${lift.serialNumber}) to Installed?';
            confirmLabel = 'Mark Installed';
          } else if (jobType == 'Stairlift Removal') {
            newStatus = 'Removed';
            dialogTitle = 'Mark lift as Removed?';
            dialogBody = 'Update ${lift.brand} ${lift.series} (SN: ${lift.serialNumber}) to Removed?';
            confirmLabel = 'Mark Removed';
          }
          if (newStatus != null && mounted) {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(dialogTitle),
                content: Text(dialogBody),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                    child: Text(confirmLabel),
                  ),
                ],
              ),
            );
            if (confirm == true && mounted) {
              await sbMarkLiftStatus(
                liftId: lift.liftId,
                newStatus: newStatus,
                userEmail: userEmail,
                userName: userName,
                note: 'Marked $newStatus via schedule event: ${event.title}',
                eventDate: newStatus == 'Installed' ? event.start : null,
              );
              if (newStatus == 'Installed' && lift.customerId.isEmpty && mounted) {
                await _offerCreateCustomerForLift(context, lift, event);
              }
            }
          } else if ((jobType == 'Stairlift Service' || jobType == 'Stairlift Annual Service') && mounted) {
            final serviceType = jobType == 'Stairlift Annual Service' ? 'Annual Service' : 'Service Call';
            final confirm = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Log service record?'),
                content: Text('Create a $serviceType record for ${lift.brand} ${lift.series}?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                    child: const Text('Log Service'),
                  ),
                ],
              ),
            );
            if (confirm == true && mounted) {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LiftServiceFormScreen(
                    lift: lift,
                    prefillServiceType: serviceType,
                    prefillCustomerName: event.title,
                    prefillDate: formatDate(DateTime.now()),
                    offerInvoicePhoto: true,
                  ),
                ),
              );
            }
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jobs'),
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: 'Installs'),
            Tab(text: 'Removals'),
            Tab(text: 'Service'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _InstallsTab(
                      events: _eventsForType(['Stairlift Install', 'Ramp Install']),
                      allMeta: _allMeta,
                      completedIds: _completedIds,
                      liftsByEvent: _liftsByEvent,
                      users: _users,
                      onRefresh: _load,
                      onToggleComplete: _onToggleComplete,
                      formatTime: _formatTime,
                      parseEventColor: _parseEventColor,
                      assignedNames: _assignedNames,
                    ),
                    _RemovalsTab(
                      events: _eventsForType(['Stairlift Removal', 'Ramp Removal', 'Schedule Removal']),
                      allMeta: _allMeta,
                      completedIds: _completedIds,
                      liftsByEvent: _liftsByEvent,
                      users: _users,
                      onRefresh: _load,
                      onToggleComplete: _onToggleComplete,
                      formatTime: _formatTime,
                      parseEventColor: _parseEventColor,
                      assignedNames: _assignedNames,
                    ),
                    _ServiceTab(
                      events: _eventsForType(['Stairlift Service', 'Stairlift Annual Service', 'Schedule Service']),
                      allMeta: _allMeta,
                      completedIds: _completedIds,
                      liftsByEvent: _liftsByEvent,
                      users: _users,
                      onRefresh: _load,
                      onToggleComplete: _onToggleComplete,
                      formatTime: _formatTime,
                      parseEventColor: _parseEventColor,
                      assignedNames: _assignedNames,
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => ScheduleEventFormScreen(
                users: _users,
                initialDate: DateTime.now(),
              ),
            ),
          );
          if (created == true) _load();
        },
        backgroundColor: kBrandGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add to Schedule'),
      ),
    );
  }
}

// -----------------------
// SHARED JOBS TAB HELPERS
// -----------------------

/// Shared card widget used by all three jobs tabs.
class _JobEventCard extends StatelessWidget {
  final QbtScheduleEvent event;
  final bool completed;
  final List<LiftRecord> lifts;
  final String assignedNames;
  final Color color;
  final String Function(DateTime) formatTime;
  final Future<void> Function(QbtScheduleEvent, bool) onToggleComplete;
  /// Label shown on the badge when the event is completed (e.g. 'Installed', 'Removed', 'Serviced')
  final String completedLabel;

  const _JobEventCard({
    required this.event,
    required this.completed,
    required this.lifts,
    required this.assignedNames,
    required this.color,
    required this.formatTime,
    required this.onToggleComplete,
    required this.completedLabel,
  });

  @override
  Widget build(BuildContext context) {
    final local = event.start.toLocal();
    final dateStr =
        '${local.month}/${local.day}/${local.year}  ${formatTime(event.start)}';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final changed = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => ScheduleEventDetailScreen(
                event: event,
                users: const {},
                assignedNames: assignedNames,
                color: color,
                formatTime: formatTime,
              ),
            ),
          );
          if (changed == true && context.mounted) {
            // Refresh is handled by the parent via onToggleComplete indirectly;
            // for full refresh the parent passes onRefresh to the tab.
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row + status badge
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      event.title.isNotEmpty ? event.title : 'Untitled event',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (completed)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.green.shade700.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: Colors.green.shade700.withOpacity(0.4)),
                      ),
                      child: Text(
                        completedLabel,
                        style: TextStyle(
                            color: Colors.green.shade700,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              // Date/time
              Row(children: [
                Icon(Icons.schedule, size: 13, color: Colors.grey[500]),
                const SizedBox(width: 4),
                Text(dateStr,
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey[600])),
              ]),
              // Assigned names — shown as initials avatars
              if (assignedNames.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: assignedNames
                      .split(', ')
                      .map((name) => Tooltip(
                            message: name,
                            child: InitialsAvatar(name: name, size: 30),
                          ))
                      .toList(),
                ),
              ],
              // Location
              if (event.location.isNotEmpty) ...[
                const SizedBox(height: 2),
                Row(children: [
                  Icon(Icons.location_on_outlined,
                      size: 13, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(event.location,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey[600])),
                  ),
                ]),
              ],
              const SizedBox(height: 8),
              // Lift section
              if (lifts.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: Colors.grey.shade400,
                        style: BorderStyle.solid),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey.shade50,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.link_off,
                          size: 14, color: Colors.grey.shade500),
                      const SizedBox(width: 6),
                      Text('No lift assigned',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade500)),
                    ],
                  ),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: lifts.map((lift) {
                    final label =
                        '${lift.brand} ${lift.series} — SN: ${lift.serialNumber}';
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.orange.shade200),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(label,
                              style: const TextStyle(fontSize: 12)),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: completed
                                  ? Colors.green.shade700
                                      .withOpacity(0.15)
                                  : Colors.orange.shade700
                                      .withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              completed ? completedLabel : 'Assigned',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: completed
                                    ? Colors.green.shade700
                                    : Colors.orange.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              // Complete toggle row
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () =>
                        onToggleComplete(event, !completed),
                    icon: Icon(
                      completed
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 16,
                      color: completed ? Colors.green : Colors.black54,
                    ),
                    label: Text(
                      completed ? 'Completed' : 'Mark Complete',
                      style: TextStyle(
                        color:
                            completed ? Colors.green : Colors.black54,
                        fontSize: 13,
                      ),
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
}

Widget _jobSectionHeader(String title) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
    child: Text(title,
        style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: Colors.black54)),
  );
}

// -----------------------
// SCHEDULE NOTE CARD
// A compact card for "To Be Scheduled" entries with a Convert button.
// -----------------------

class _ScheduleNoteCard extends StatelessWidget {
  final QbtScheduleEvent event;
  final Color color;
  final String Function(DateTime) formatTime;
  final String assignedNames;
  final String convertLabel;
  final VoidCallback onConvert;

  const _ScheduleNoteCard({
    required this.event,
    required this.color,
    required this.formatTime,
    required this.assignedNames,
    required this.convertLabel,
    required this.onConvert,
  });

  @override
  Widget build(BuildContext context) {
    final local = event.start.toLocal();
    final dateStr = '${local.month}/${local.day}/${local.year}';
    final timeStr = event.allDay ? 'All day' : formatTime(event.start);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.amber.shade300, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.amber.shade600,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$dateStr · $timeStr'
                    '${assignedNames.isNotEmpty ? ' · $assignedNames' : ''}',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                  if (event.notes.isNotEmpty)
                    Text(
                      event.notes,
                      style: const TextStyle(color: Colors.black45, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onConvert,
              style: TextButton.styleFrom(
                foregroundColor: kBrandGreen,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(convertLabel, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------
// INSTALLS TAB
// -----------------------

class _InstallsTab extends StatelessWidget {
  final List<QbtScheduleEvent> events;
  final Map<String, Map<String, dynamic>> allMeta;
  final Set<String> completedIds;
  final Map<String, List<LiftRecord>> liftsByEvent;
  final Map<String, QbtUser> users;
  final Future<void> Function() onRefresh;
  final Future<void> Function(QbtScheduleEvent, bool) onToggleComplete;
  final String Function(DateTime) formatTime;
  final Color Function(QbtScheduleEvent) parseEventColor;
  final String Function(QbtScheduleEvent) assignedNames;

  const _InstallsTab({
    required this.events,
    required this.allMeta,
    required this.completedIds,
    required this.liftsByEvent,
    required this.users,
    required this.onRefresh,
    required this.onToggleComplete,
    required this.formatTime,
    required this.parseEventColor,
    required this.assignedNames,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final oneWeekAgo = now.subtract(const Duration(days: 7));
    final oneWeekAhead = now.add(const Duration(days: 7));
    final pending = events
        .where((e) => !completedIds.contains(e.id) && !e.start.isAfter(oneWeekAhead))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final completed = events
        .where((e) => completedIds.contains(e.id) && e.start.isAfter(oneWeekAgo))
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
        children: [
          _jobSectionHeader('Pending Installs (${pending.length})'),
          if (pending.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No pending installs.',
                  style: TextStyle(color: Colors.black45)),
            )
          else
            ...pending.map((e) => _JobEventCard(
                  event: e,
                  completed: false,
                  lifts: liftsByEvent[e.id] ?? [],
                  assignedNames: assignedNames(e),
                  color: parseEventColor(e),
                  formatTime: formatTime,
                  onToggleComplete: onToggleComplete,
                  completedLabel: 'Installed',
                )),
          const SizedBox(height: 8),
          _jobSectionHeader('Completed Installs (${completed.length})'),
          if (completed.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No completed installs.',
                  style: TextStyle(color: Colors.black45)),
            )
          else
            ...completed.map((e) => _JobEventCard(
                  event: e,
                  completed: true,
                  lifts: liftsByEvent[e.id] ?? [],
                  assignedNames: assignedNames(e),
                  color: parseEventColor(e),
                  formatTime: formatTime,
                  onToggleComplete: onToggleComplete,
                  completedLabel: 'Installed',
                )),
        ],
      ),
    );
  }
}

// -----------------------
// REMOVALS TAB
// -----------------------

class _RemovalsTab extends StatefulWidget {
  final List<QbtScheduleEvent> events;
  final Map<String, Map<String, dynamic>> allMeta;
  final Set<String> completedIds;
  final Map<String, List<LiftRecord>> liftsByEvent;
  final Map<String, QbtUser> users;
  final Future<void> Function() onRefresh;
  final Future<void> Function(QbtScheduleEvent, bool) onToggleComplete;
  final String Function(DateTime) formatTime;
  final Color Function(QbtScheduleEvent) parseEventColor;
  final String Function(QbtScheduleEvent) assignedNames;

  const _RemovalsTab({
    required this.events,
    required this.allMeta,
    required this.completedIds,
    required this.liftsByEvent,
    required this.users,
    required this.onRefresh,
    required this.onToggleComplete,
    required this.formatTime,
    required this.parseEventColor,
    required this.assignedNames,
  });

  @override
  State<_RemovalsTab> createState() => _RemovalsTabState();
}

class _RemovalsTabState extends State<_RemovalsTab> {
  String _resolvedJobType(QbtScheduleEvent e) {
    final jt = widget.allMeta[e.id]?['job_type'] as String?;
    if (jt != null && jt.isNotEmpty) return jt;
    return inferJobTypeFromTitle(e.title) ?? '';
  }

  Future<void> _convertToRemoval(BuildContext context, QbtScheduleEvent event) async {
    final prefs = await SharedPreferences.getInstance();
    final userEmail = AuthService.instance.profile?.email ?? '';
    final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';

    final nameCtrl = TextEditingController(text: event.title);
    final addrCtrl = TextEditingController(text: event.location);
    final phoneCtrl = TextEditingController();
    final notesCtrl = TextEditingController(text: event.notes);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Convert to Removal'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Customer name')),
              const SizedBox(height: 8),
              TextField(controller: addrCtrl, decoration: const InputDecoration(labelText: 'Address')),
              const SizedBox(height: 8),
              TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone')),
              const SizedBox(height: 8),
              TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes'), maxLines: 3),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
            child: const Text('Create Removal'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await sbUpsertRemovalJob(
      userEmail: userEmail,
      userName: userName,
      customerName: nameCtrl.text.trim(),
      address: addrCtrl.text.trim(),
      phone: phoneCtrl.text.trim(),
      liftType: '',
      notes: notesCtrl.text.trim(),
    );
    // Upgrade the event's job type so it shows as an actual removal
    await sbSetEventJobType(event.id, 'Removal');
    await widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final oneWeekAgo = now.subtract(const Duration(days: 7));
    final oneWeekAhead = now.add(const Duration(days: 7));

    final toSchedule = widget.events
        .where((e) => !widget.completedIds.contains(e.id) && _resolvedJobType(e) == 'Schedule Removal')
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final pending = widget.events
        .where((e) => !widget.completedIds.contains(e.id) &&
            !e.start.isAfter(oneWeekAhead) &&
            _resolvedJobType(e) != 'Schedule Removal')
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final completed = widget.events
        .where((e) => widget.completedIds.contains(e.id) &&
            e.start.isAfter(oneWeekAgo) &&
            _resolvedJobType(e) != 'Schedule Removal')
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 80),
        children: [
          if (toSchedule.isNotEmpty) ...[
            _jobSectionHeader('To Be Scheduled (${toSchedule.length})'),
            ...toSchedule.map((e) => _ScheduleNoteCard(
                  event: e,
                  color: widget.parseEventColor(e),
                  formatTime: widget.formatTime,
                  assignedNames: widget.assignedNames(e),
                  convertLabel: 'Convert to Removal',
                  onConvert: () => _convertToRemoval(context, e),
                )),
            const SizedBox(height: 8),
          ],
          _jobSectionHeader('Pending Removals (${pending.length})'),
          if (pending.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No pending removals.',
                  style: TextStyle(color: Colors.black45)),
            )
          else
            ...pending.map((e) => _JobEventCard(
                  event: e,
                  completed: false,
                  lifts: widget.liftsByEvent[e.id] ?? [],
                  assignedNames: widget.assignedNames(e),
                  color: widget.parseEventColor(e),
                  formatTime: widget.formatTime,
                  onToggleComplete: widget.onToggleComplete,
                  completedLabel: 'Removed',
                )),
          const SizedBox(height: 8),
          _jobSectionHeader('Completed Removals (${completed.length})'),
          if (completed.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No completed removals.',
                  style: TextStyle(color: Colors.black45)),
            )
          else
            ...completed.map((e) => _JobEventCard(
                  event: e,
                  completed: true,
                  lifts: widget.liftsByEvent[e.id] ?? [],
                  assignedNames: widget.assignedNames(e),
                  color: widget.parseEventColor(e),
                  formatTime: widget.formatTime,
                  onToggleComplete: widget.onToggleComplete,
                  completedLabel: 'Removed',
                )),
        ],
      ),
    );
  }
}

// -----------------------
// SERVICE TAB
// -----------------------

class _ServiceTab extends StatefulWidget {
  final List<QbtScheduleEvent> events;
  final Map<String, Map<String, dynamic>> allMeta;
  final Set<String> completedIds;
  final Map<String, List<LiftRecord>> liftsByEvent;
  final Map<String, QbtUser> users;
  final Future<void> Function() onRefresh;
  final Future<void> Function(QbtScheduleEvent, bool) onToggleComplete;
  final String Function(DateTime) formatTime;
  final Color Function(QbtScheduleEvent) parseEventColor;
  final String Function(QbtScheduleEvent) assignedNames;

  const _ServiceTab({
    required this.events,
    required this.allMeta,
    required this.completedIds,
    required this.liftsByEvent,
    required this.users,
    required this.onRefresh,
    required this.onToggleComplete,
    required this.formatTime,
    required this.parseEventColor,
    required this.assignedNames,
  });

  @override
  State<_ServiceTab> createState() => _ServiceTabState();
}

class _ServiceTabState extends State<_ServiceTab> {
  String _search = '';

  String _resolvedJobType(QbtScheduleEvent e) {
    final jt = widget.allMeta[e.id]?['job_type'] as String?;
    if (jt != null && jt.isNotEmpty) return jt;
    return inferJobTypeFromTitle(e.title) ?? '';
  }

  Future<void> _convertToServiceCall(BuildContext context, QbtScheduleEvent event) async {
    final prefs = await SharedPreferences.getInstance();
    final userEmail = AuthService.instance.profile?.email ?? '';
    final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';

    final nameCtrl = TextEditingController(text: event.title);
    final addrCtrl = TextEditingController(text: event.location);
    final phoneCtrl = TextEditingController();
    final notesCtrl = TextEditingController(text: event.notes);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Convert to Service Call'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Customer name')),
              const SizedBox(height: 8),
              TextField(controller: addrCtrl, decoration: const InputDecoration(labelText: 'Address')),
              const SizedBox(height: 8),
              TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone')),
              const SizedBox(height: 8),
              TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes'), maxLines: 3),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
            child: const Text('Create Service Call'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await sbUpsertServiceJob(
      userEmail: userEmail,
      userName: userName,
      jobType: 'Service Call',
      customerName: nameCtrl.text.trim(),
      address: addrCtrl.text.trim(),
      phone: phoneCtrl.text.trim(),
      liftType: '',
      dateRequested: formatDate(DateTime.now()),
      notes: notesCtrl.text.trim(),
    );
    // Upgrade the event's job type so it shows as an actual service call
    await sbSetEventJobType(event.id, 'Service');
    await widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final allEvents = widget.events;
    final filtered = allEvents.where((e) {
      if (_search.isEmpty) return true;
      return e.title.toLowerCase().contains(_search.toLowerCase()) ||
          e.location.toLowerCase().contains(_search.toLowerCase());
    }).toList();

    final now = DateTime.now();
    final oneWeekAgo = now.subtract(const Duration(days: 7));
    final oneWeekAhead = now.add(const Duration(days: 7));

    // Split: scheduling notes vs actual service calls
    final toSchedule = filtered
        .where((e) => !widget.completedIds.contains(e.id) && _resolvedJobType(e) == 'Schedule Service')
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final pending = filtered
        .where((e) => !widget.completedIds.contains(e.id) &&
            !e.start.isAfter(oneWeekAhead) &&
            _resolvedJobType(e) != 'Schedule Service')
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final completed = filtered
        .where((e) => widget.completedIds.contains(e.id) &&
            e.start.isAfter(oneWeekAgo) &&
            _resolvedJobType(e) != 'Schedule Service')
        .toList()
      ..sort((a, b) => b.start.compareTo(a.start));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            style: const TextStyle(color: Colors.black),
            decoration: InputDecoration(
              hintText: 'Search...',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              isDense: true,
              suffixIcon: _search.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _search = ''),
                    )
                  : null,
            ),
            onChanged: (v) => setState(() => _search = v.trim()),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: widget.onRefresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 80),
              children: [
                if (toSchedule.isNotEmpty) ...[
                  _jobSectionHeader('To Be Scheduled (${toSchedule.length})'),
                  ...toSchedule.map((e) => _ScheduleNoteCard(
                        event: e,
                        color: widget.parseEventColor(e),
                        formatTime: widget.formatTime,
                        assignedNames: widget.assignedNames(e),
                        convertLabel: 'Convert to Service Call',
                        onConvert: () => _convertToServiceCall(context, e),
                      )),
                  const SizedBox(height: 8),
                ],
                _jobSectionHeader('Pending Service (${pending.length})'),
                if (pending.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No pending service jobs.',
                        style: TextStyle(color: Colors.black45)),
                  )
                else
                  ...pending.map((e) => _JobEventCard(
                        event: e,
                        completed: false,
                        lifts: widget.liftsByEvent[e.id] ?? [],
                        assignedNames: widget.assignedNames(e),
                        color: widget.parseEventColor(e),
                        formatTime: widget.formatTime,
                        onToggleComplete: widget.onToggleComplete,
                        completedLabel: 'Serviced',
                      )),
                const SizedBox(height: 8),
                _jobSectionHeader('Completed Service (${completed.length})'),
                if (completed.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No completed service jobs.',
                        style: TextStyle(color: Colors.black45)),
                  )
                else
                  ...completed.map((e) => _JobEventCard(
                        event: e,
                        completed: true,
                        lifts: widget.liftsByEvent[e.id] ?? [],
                        assignedNames: widget.assignedNames(e),
                        color: widget.parseEventColor(e),
                        formatTime: widget.formatTime,
                        onToggleComplete: widget.onToggleComplete,
                        completedLabel: 'Serviced',
                      )),
              ],
            ),
          ),
        ),
      ],
    );
  }
}


// =======================
// REMOVAL JOB FORM SCREEN
// =======================

class RemovalJobFormScreen extends StatefulWidget {
  final RemovalJobRecord? existing;
  const RemovalJobFormScreen({super.key, this.existing});

  @override
  State<RemovalJobFormScreen> createState() => _RemovalJobFormScreenState();
}

class _RemovalJobFormScreenState extends State<RemovalJobFormScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  String _fundingSource = 'Private';

  late final TextEditingController _titleController;
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _phoneController;
  late final TextEditingController _liftTypeController;
  late final TextEditingController _scheduledDateController;
  late final TextEditingController _notesController;

  String? _linkedLiftId;
  String? _linkedSerialNumber;
  String? _linkedLiftLabel;

  static const _fundingSources = ['Private', 'VA', 'CCALS', 'NaviCare', 'Summit', 'Fallon', 'Mass Health', 'Other'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _fundingSource = e?.fundingSource ?? 'Private';
    _titleController = TextEditingController(text: e?.title ?? '');
    _nameController = TextEditingController(text: e?.customerName ?? '');
    _addressController = TextEditingController(text: e?.address ?? '');
    _phoneController = TextEditingController(text: e?.phone ?? '');
    _liftTypeController = TextEditingController(text: e?.liftType ?? '');
    _scheduledDateController = TextEditingController(
        text: e != null ? normalizeDateDisplay(e.scheduledDate) : '');
    _notesController = TextEditingController(text: e?.notes ?? '');
    if (e != null && e.liftId.isNotEmpty) {
      _linkedLiftId = e.liftId;
      _linkedSerialNumber = e.serialNumber;
      _linkedLiftLabel = e.liftType.isNotEmpty ? e.liftType : 'SN: ${e.serialNumber}';
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _liftTypeController.dispose();
    _scheduledDateController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _linkLift(LiftRecord lift) {
    final label = [lift.brand, lift.series,
      if (lift.orientation.isNotEmpty && lift.orientation != 'N/A') lift.orientation,
    ].where((s) => s.isNotEmpty).join(' ') +
        (lift.serialNumber.isNotEmpty ? ' — SN: ${lift.serialNumber}' : '');
    setState(() {
      _linkedLiftId = lift.liftId;
      _linkedSerialNumber = lift.serialNumber;
      _linkedLiftLabel = label;
      _liftTypeController.text = label;
    });
  }

  void _unlinkLift() {
    setState(() {
      _linkedLiftId = null;
      _linkedSerialNumber = null;
      _linkedLiftLabel = null;
      _liftTypeController.clear();
    });
  }

  Future<void> _openLiftPicker() async {
    final result = await showDialog(
      context: context,
      builder: (_) => const _LiftPickerDialog(),
    );
    if (result is LiftRecord) {
      _linkLift(result);
    } else if (result is _AddNewLiftSentinel) {
      if (!mounted) return;
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const LiftFormScreen()),
      );
      if (saved == true) {
        try {
          final lifts = await sbFetchLifts();
          if (lifts.isNotEmpty) _linkLift(lifts.last);
        } catch (_) {}
      }
    }
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    DateTime initial = now;
    if (controller.text.isNotEmpty) {
      try {
        final parts = controller.text.split('/');
        if (parts.length == 3) {
          initial = DateTime(int.parse(parts[2]), int.parse(parts[0]), int.parse(parts[1]));
        }
      } catch (_) {}
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) controller.text = formatDate(picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await sbUpsertRemovalJob(
        userEmail: AuthService.instance.profile?.email ?? '',
        userName: prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
        jobId: widget.existing?.jobId,
        title: _titleController.text.trim(),
        customerName: _nameController.text.trim(),
        address: _addressController.text.trim(),
        phone: _phoneController.text.trim(),
        liftType: _liftTypeController.text.trim(),
        scheduledDate: _scheduledDateController.text.trim(),
        notes: _notesController.text.trim(),
        liftId: _linkedLiftId ?? '',
        serialNumber: _linkedSerialNumber ?? '',
        fundingSource: _fundingSource,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Removal Job' : 'Add Removal Job'),
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                value: _fundingSource,
                decoration: const InputDecoration(labelText: 'Funding source', border: OutlineInputBorder()),
                items: _fundingSources.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (v) => setState(() => _fundingSource = v ?? 'Private'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                    labelText: 'Title *', border: OutlineInputBorder()),
                textCapitalization: TextCapitalization.sentences,
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                    labelText: 'Customer name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _addressController,
                decoration: const InputDecoration(
                    labelText: 'Address', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                    labelText: 'Phone', border: OutlineInputBorder()),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              if (_linkedLiftLabel != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: kBrandGreen),
                    borderRadius: BorderRadius.circular(8),
                    color: kBrandGreen.withOpacity(0.05),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.stairs, color: kBrandGreen, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_linkedLiftLabel!,
                            style: const TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Unlink lift',
                        onPressed: _unlinkLift,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                OutlinedButton.icon(
                  onPressed: _openLiftPicker,
                  icon: const Icon(Icons.link),
                  label: const Text('Link a lift from system'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    foregroundColor: kBrandGreen,
                    side: const BorderSide(color: kBrandGreen),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _liftTypeController,
                  decoration: const InputDecoration(
                      labelText: 'Or type lift description manually',
                      border: OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _scheduledDateController,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Scheduled date (optional)',
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                onTap: () => _pickDate(_scheduledDateController),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                    labelText: 'Notes', border: OutlineInputBorder()),
                maxLines: 3,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kBrandGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(isEditing ? 'Save changes' : 'Add removal job'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =======================
// SERVICE JOB FORM SCREEN
// =======================

// =======================
// WEB LEADS SCREEN + WIDGETS
// =======================

class WebLeadsScreen extends StatefulWidget {
  const WebLeadsScreen({super.key});

  @override
  State<WebLeadsScreen> createState() => _WebLeadsScreenState();
}

class _WebLeadsScreenState extends State<WebLeadsScreen> {
  List<WebLeadRecord> _leads = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final leads = await sbFetchWebLeads();
      if (mounted) setState(() { _leads = leads; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Web Leads'),
            if (_leads.any((l) => l.status == 'New')) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: kBrandGreen, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  '${_leads.where((l) => l.status == 'New').length} new',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _WebLeadsTab(leads: _leads, onRefresh: _load),
    );
  }
}

class _WebLeadsTab extends StatelessWidget {
  final List<WebLeadRecord> leads;
  final Future<void> Function() onRefresh;

  const _WebLeadsTab({required this.leads, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (leads.isEmpty) {
      return const Center(child: Text('No web leads yet.', style: TextStyle(color: Colors.grey)));
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: leads.length,
        itemBuilder: (context, i) => _WebLeadCard(lead: leads[i], onRefresh: onRefresh),
      ),
    );
  }
}

class _WebLeadCard extends StatelessWidget {
  final WebLeadRecord lead;
  final Future<void> Function() onRefresh;

  const _WebLeadCard({required this.lead, required this.onRefresh});

  Color get _statusColor {
    switch (lead.status) {
      case 'Contacted': return Colors.blue;
      case 'Closed': return Colors.grey;
      default: return kBrandGreen;
    }
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete lead?'),
        content: Text('Remove the lead from ${lead.name}? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await sbDeleteWebLead(id: lead.id);
      await onRefresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dt = lead.createdAt.toLocal();
    final dateStr = '${dt.month}/${dt.day}/${dt.year}';

    return Dismissible(
      key: ValueKey(lead.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(color: Colors.red.shade600, borderRadius: BorderRadius.circular(14)),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 26),
      ),
      confirmDismiss: (_) async {
        await _delete(context);
        return false;
      },
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(lead.name,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _statusColor.withValues(alpha: 0.4)),
                    ),
                    child: Text(lead.status,
                        style: TextStyle(color: _statusColor, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(lead.email, style: const TextStyle(color: Colors.blue, fontSize: 13)),
              if (lead.phone.isNotEmpty) Text(lead.phone, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 6),
              Text(lead.message, maxLines: 3, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '$dateStr · ${lead.source == 'hero_form' ? 'Hero Form' : 'Contact Form'}',
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                  Row(
                    children: [
                      PopupMenuButton<String>(
                        onSelected: (status) async {
                          await sbUpdateWebLeadStatus(id: lead.id, status: status);
                          await onRefresh();
                        },
                        itemBuilder: (_) => ['New', 'Contacted', 'Closed']
                            .map((s) => PopupMenuItem(value: s, child: Text(s)))
                            .toList(),
                        child: const Text('Update Status',
                            style: TextStyle(color: Colors.blue, fontSize: 12)),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => _delete(context),
                        child: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =======================
// SERVICE JOB FORM SCREEN
// =======================

class ServiceJobFormScreen extends StatefulWidget {
  final ServiceJobRecord? existing;
  const ServiceJobFormScreen({super.key, this.existing});

  @override
  State<ServiceJobFormScreen> createState() => _ServiceJobFormScreenState();
}

class _ServiceJobFormScreenState extends State<ServiceJobFormScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  String _jobType = 'Service';
  String _fundingSource = 'Private';

  late final TextEditingController _titleController;
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _phoneController;
  late final TextEditingController _liftTypeController;
  late final TextEditingController _dateRequestedController;
  late final TextEditingController _scheduledDateController;
  late final TextEditingController _notesController;

  String? _linkedLiftId;
  String? _linkedSerialNumber;
  String? _linkedLiftLabel;

  static const _fundingSources = ['Private', 'VA', 'CCALS', 'NaviCare', 'Summit', 'Fallon', 'Mass Health', 'Other'];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _jobType = e?.jobType ?? 'Service';
    _fundingSource = e?.fundingSource ?? 'Private';
    _titleController = TextEditingController(text: e?.title ?? '');
    _nameController = TextEditingController(text: e?.customerName ?? '');
    _addressController = TextEditingController(text: e?.address ?? '');
    _phoneController = TextEditingController(text: e?.phone ?? '');
    _liftTypeController = TextEditingController(text: e?.liftType ?? '');
    _dateRequestedController = TextEditingController(
        text: e != null ? normalizeDateDisplay(e.dateRequested) : '');
    _scheduledDateController = TextEditingController(
        text: e != null ? normalizeDateDisplay(e.scheduledDate) : '');
    _notesController = TextEditingController(text: e?.notes ?? '');
    if (e != null && e.liftId.isNotEmpty) {
      _linkedLiftId = e.liftId;
      _linkedSerialNumber = e.serialNumber;
      _linkedLiftLabel = e.liftType.isNotEmpty ? e.liftType : 'SN: ${e.serialNumber}';
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _liftTypeController.dispose();
    _dateRequestedController.dispose();
    _scheduledDateController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _linkLift(LiftRecord lift) {
    final label = [lift.brand, lift.series,
      if (lift.orientation.isNotEmpty && lift.orientation != 'N/A') lift.orientation,
    ].where((s) => s.isNotEmpty).join(' ') +
        (lift.serialNumber.isNotEmpty ? ' — SN: ${lift.serialNumber}' : '');
    setState(() {
      _linkedLiftId = lift.liftId;
      _linkedSerialNumber = lift.serialNumber;
      _linkedLiftLabel = label;
      _liftTypeController.text = label;
    });
  }

  void _unlinkLift() {
    setState(() {
      _linkedLiftId = null;
      _linkedSerialNumber = null;
      _linkedLiftLabel = null;
      _liftTypeController.clear();
    });
  }

  Future<void> _openLiftPicker() async {
    final result = await showDialog(
      context: context,
      builder: (_) => const _LiftPickerDialog(),
    );
    if (result is LiftRecord) {
      _linkLift(result);
    } else if (result is _AddNewLiftSentinel) {
      if (!mounted) return;
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const LiftFormScreen()),
      );
      if (saved == true) {
        try {
          final lifts = await sbFetchLifts();
          if (lifts.isNotEmpty) _linkLift(lifts.last);
        } catch (_) {}
      }
    }
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    DateTime initial = now;
    if (controller.text.isNotEmpty) {
      try {
        final parts = controller.text.split('/');
        if (parts.length == 3) {
          initial = DateTime(int.parse(parts[2]), int.parse(parts[0]), int.parse(parts[1]));
        }
      } catch (_) {}
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) controller.text = formatDate(picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await sbUpsertServiceJob(
        userEmail: AuthService.instance.profile?.email ?? '',
        userName: prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
        jobId: widget.existing?.jobId,
        jobType: _jobType,
        title: _titleController.text.trim(),
        customerName: _nameController.text.trim(),
        address: _addressController.text.trim(),
        phone: _phoneController.text.trim(),
        liftType: _liftTypeController.text.trim(),
        dateRequested: _dateRequestedController.text.trim(),
        scheduledDate: _scheduledDateController.text.trim(),
        notes: _notesController.text.trim(),
        liftId: _linkedLiftId ?? '',
        serialNumber: _linkedSerialNumber ?? '',
        fundingSource: _fundingSource,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Service Job' : 'Add Service Job'),
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                value: _jobType,
                decoration: const InputDecoration(
                    labelText: 'Service type', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'Service', child: Text('Service')),
                  DropdownMenuItem(
                      value: 'Annual Service', child: Text('Annual Service')),
                ],
                onChanged: (v) => setState(() => _jobType = v ?? 'Service'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _fundingSource,
                decoration: const InputDecoration(labelText: 'Funding source', border: OutlineInputBorder()),
                items: _fundingSources.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (v) => setState(() => _fundingSource = v ?? 'Private'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                    labelText: 'Title *', border: OutlineInputBorder()),
                textCapitalization: TextCapitalization.sentences,
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                    labelText: 'Customer name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _addressController,
                decoration: const InputDecoration(
                    labelText: 'Address', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                    labelText: 'Phone', border: OutlineInputBorder()),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              if (_linkedLiftLabel != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border.all(color: kBrandGreen),
                    borderRadius: BorderRadius.circular(8),
                    color: kBrandGreen.withOpacity(0.05),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.stairs, color: kBrandGreen, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_linkedLiftLabel!,
                            style: const TextStyle(fontWeight: FontWeight.w500)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: 'Unlink lift',
                        onPressed: _unlinkLift,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
              ] else ...[
                OutlinedButton.icon(
                  onPressed: _openLiftPicker,
                  icon: const Icon(Icons.link),
                  label: const Text('Link a lift from system'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    foregroundColor: kBrandGreen,
                    side: const BorderSide(color: kBrandGreen),
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _liftTypeController,
                  decoration: const InputDecoration(
                      labelText: 'Or type lift description manually',
                      border: OutlineInputBorder()),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _dateRequestedController,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Date requested',
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                onTap: () => _pickDate(_dateRequestedController),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _scheduledDateController,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Scheduled date (optional)',
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                onTap: () => _pickDate(_scheduledDateController),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                    labelText: 'Notes', border: OutlineInputBorder()),
                maxLines: 3,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kBrandGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(isEditing ? 'Save changes' : 'Add service job'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  static const double _desktopBreakpoint = 700;

  bool _isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= _desktopBreakpoint;

  /// Full item list for desktop — all tabs shown.
  List<({IconData icon, String label, Widget page})> get _desktopItems {
    final p = widget.profile;
    return [
      if (p.canSeeDashboard)
        (icon: Icons.dashboard_rounded, label: 'Dashboard', page: const DashboardScreen()),
      (icon: Icons.calendar_month_rounded, label: 'Schedule', page: const ScheduleScreen()),
      if (p.canSeeOpsHub)
        (icon: Icons.pending_actions_rounded, label: 'Hub', page: const OperationsHubScreen()),
      if (p.canSeeLifts)
        (icon: Icons.list_alt_rounded, label: 'Lifts', page: const LiftsScreen()),
      if (p.canSeeRamps)
        (icon: Icons.stairs_rounded, label: 'Ramps', page: const RampsScreen()),
      if (p.canSeeCustomers)
        (icon: Icons.people_outline_rounded, label: 'Customers', page: const CustomersScreen()),
      if (p.canSeePrepScreen)
        (icon: Icons.build_rounded, label: 'Prep', page: const PrepScreen()),
      if (p.canSeeSettings)
        (icon: Icons.folder_outlined, label: 'Docs', page: const DocumentsScreen()),
    ];
  }

  /// Mobile item list — Lifts+Ramps grouped as Inventory; Docs+Prep move to Account menu.
  List<({IconData icon, String label, Widget page})> get _mobileItems {
    final p = widget.profile;
    if (p.isAdmin) {
      return [
        (icon: Icons.dashboard_rounded, label: 'Dashboard', page: const DashboardScreen()),
        (icon: Icons.pending_actions_rounded, label: 'Hub', page: const OperationsHubScreen()),
        (icon: Icons.calendar_month_rounded, label: 'Schedule', page: const ScheduleScreen()),
        (icon: Icons.inventory_2_outlined, label: 'Inventory', page: InventoryScreen(
          onLifts: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LiftsScreen())),
          onRamps: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RampsScreen())),
        )),
        if (p.canSeeCustomers)
          (icon: Icons.people_outline_rounded, label: 'Customers', page: const CustomersScreen()),
      ];
    } else {
      // Installer — Hub, Schedule, Inventory, Customers, Prep
      return [
        (icon: Icons.pending_actions_rounded, label: 'Hub', page: const OperationsHubScreen()),
        (icon: Icons.calendar_month_rounded, label: 'Schedule', page: const ScheduleScreen()),
        (icon: Icons.inventory_2_outlined, label: 'Inventory', page: InventoryScreen(
          onLifts: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LiftsScreen())),
          onRamps: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RampsScreen())),
        )),
        if (p.canSeeCustomers)
          (icon: Icons.people_outline_rounded, label: 'Customers', page: const CustomersScreen()),
        if (p.canSeePrepScreen)
          (icon: Icons.build_rounded, label: 'Prep', page: const PrepScreen()),
      ];
    }
  }

  void _onItemTapped(int index) {
    if (_selectedIndex == index) return;
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final desktop = _isDesktop(context);
    final items = desktop ? _desktopItems : _mobileItems;
    final safeIndex = _selectedIndex.clamp(0, items.length - 1);
    return Scaffold(
      body: IndexedStack(
        index: safeIndex,
        children: items.map((e) => e.page).toList(),
      ),
      bottomNavigationBar: _FloatingNavBar(
        items: items.map((e) => (e.icon, e.label)).toList(),
        currentIndex: safeIndex,
        onTap: _onItemTapped,
        onAccountTap: () => showUserMenu(context),
      ),
    );
  }
}

class _FloatingNavBar extends StatelessWidget {
  final List<(IconData, String)> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final VoidCallback onAccountTap;

  const _FloatingNavBar({
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.onAccountTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBrandGreenDark,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              // Nav items
              ...List.generate(items.length, (i) {
                final selected = i == currentIndex;
                final (icon, label) = items[i];
                return Expanded(
                  child: GestureDetector(
                    onTap: () => onTap(i),
                    behavior: HitTestBehavior.opaque,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                          decoration: selected
                              ? BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(10),
                                )
                              : const BoxDecoration(),
                          child: Icon(icon, size: 22,
                              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.4)),
                        ),
                        const SizedBox(height: 2),
                        Text(label,
                            style: GoogleFonts.nunito(
                              fontSize: 10,
                              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                              color: selected ? Colors.white : Colors.white.withValues(alpha: 0.4),
                            )),
                      ],
                    ),
                  ),
                );
              }),
              // Account icon — always visible on the right
              GestureDetector(
                onTap: onAccountTap,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.account_circle_outlined, size: 22,
                          color: Colors.white.withValues(alpha: 0.7)),
                      const SizedBox(height: 2),
                      Text('Account',
                          style: GoogleFonts.nunito(
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            color: Colors.white.withValues(alpha: 0.7),
                          )),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
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
  String? _rampBrandFilter;   // 'EZ Access', 'Prairie View', etc.
  String? _rampEzSubFilter;   // '2G' or '3G' — only active when _rampBrandFilter == 'EZ Access'
  bool _showCcals = false;    // Toggle between Able Home and CCALS pool

  String _userName = '';

  @override
  void initState() {
    super.initState();
    _future = sbFetchInventory();
    _loadUserPrefs();
  }

  Future<void> _loadUserPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';
    });
  }

  Future<void> _saveUserPrefs(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', name);
    setState(() {
      _userName = name;
    });
  }

  void _refresh() {
    setState(() {
      _future = sbFetchInventory();
    });
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

  Widget _buildRampsList(List<RampItem> items, List<String> brands, {bool isCcals = false}) {
    // CCALS only tracks used ramps; ignore condition filter and min logic
    final condition = isCcals ? 'Used' : _rampConditionFilter;
    final belowMinOnly = _showBelowMinOnlyRamps && !isCcals;
    final brandFilter = _rampBrandFilter;
    final ezSub = _rampEzSubFilter; // '2G', '3G', or null

    // Derive the parent brand list: collapse "EZ Access 2G" / "EZ Access 3G" -> "EZ Access"
    final parentBrands = brands.map((b) {
      final lower = b.toLowerCase();
      if (lower.contains('ez access')) return 'EZ Access';
      return b;
    }).toSet().toList()..sort();

    final filtered = items.where((item) {
      if (item.condition != condition) return false;
      if (belowMinOnly &&
          !(item.currentQty < item.minQty && item.minQty > 0)) {
        return false;
      }
      if (brandFilter != null && brandFilter.isNotEmpty) {
        if (brandFilter == 'EZ Access') {
          // Match any EZ Access variant
          if (!item.brand.toLowerCase().contains('ez access')) return false;
          // Apply sub-filter if selected
          if (ezSub != null && ezSub.isNotEmpty) {
            if (!item.brand.toLowerCase().contains(ezSub.toLowerCase())) return false;
          }
        } else {
          if (item.brand != brandFilter) return false;
        }
      }
      if (_searchQuery.isNotEmpty) {
        final haystack = '${item.brand} ${item.size}'.toLowerCase();
        if (!haystack.contains(_searchQuery)) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final brandCmp = _compareRampBrands(a.brand, b.brand);
        if (brandCmp != 0) return brandCmp;
        return _compareRampSizes(a.size, b.size);
      });

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
        if (!isCcals)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: _buildFilterRow(),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Row(
            children: [
              DropdownButton<String>(
                value: _rampBrandFilter ?? '',
                hint: const Text('All brands'),
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text('All brands'),
                  ),
                  ...parentBrands.map(
                    (brand) => DropdownMenuItem<String>(
                      value: brand,
                      child: Text(brand),
                    ),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _rampBrandFilter = (value == null || value.isEmpty) ? null : value;
                    _rampEzSubFilter = null; // reset sub-filter on brand change
                  });
                },
              ),
              if (_rampBrandFilter == 'EZ Access') ...[
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _rampEzSubFilter ?? '',
                  items: const [
                    DropdownMenuItem(value: '', child: Text('All EZ Access')),
                    DropdownMenuItem(value: '2G', child: Text('2G')),
                    DropdownMenuItem(value: '3G', child: Text('3G')),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _rampEzSubFilter = (value == null || value.isEmpty) ? null : value;
                    });
                  },
                ),
              ],
            ],
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
                !isCcals && item.currentQty < item.minQty && item.minQty > 0;

            final displayQty = isCcals ? item.ccalsQty : item.currentQty;
            return Card(
              margin:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: belowMin ? Colors.red.shade50 : null,
              child: ListTile(
                title: Text(
                  getRampDisplayTitle(item),
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
                          '$displayQty',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: belowMin
                                ? Colors.red.shade700
                                : Colors.black,
                          ),
                        ),
                        if (!isCcals)
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

  void _openCcalsAdjustment() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const JobAdjustmentScreen(isCcals: true),
      ),
    );
    if (result == true) _refresh();
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
        ],
      ),
      body: Column(
        children: [
          // Pool toggle — lives in body so it doesn't fight the AppBar on mobile
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Able Home')),
                ButtonSegment(value: true, label: Text('CCALS')),
              ],
              selected: {_showCcals},
              onSelectionChanged: (sel) => setState(() => _showCcals = sel.first),
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) return kBrandGreen;
                  return null;
                }),
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) return Colors.white;
                  return null;
                }),
              ),
            ),
            ),
          ),
          Expanded(
            child: FutureBuilder<InventoryData>(
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

          if (_showCcals) {
            // CCALS pool view — used ramps only
            int ccalsTotalUnits = 0;
            for (final r in ramps) {
              if (r.condition == 'Used') ccalsTotalUnits += r.ccalsQty;
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                  child: Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('CCALS Inventory', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(child: _SummaryStat(label: 'Total units (used)', value: ccalsTotalUnits.toString())),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () async {
                      setState(() { _future = sbFetchInventory(); });
                      await _future;
                    },
                    child: _buildRampsList(ramps, rampBrands, isCcals: true),
                  ),
                ),
              ],
            );
          }

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
                      _future = sbFetchInventory();
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
          ),
        ],
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
              onPressed: _showCcals ? _openCcalsAdjustment : _openJobAdjustment,
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.swap_horiz),
              label: Text(_showCcals ? 'CCALS Adjustment' : 'Job Adjustment'),
            ),
            if (!_showCcals)
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
    _future = sbFetchInventory();
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
      'name': prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
      'email': AuthService.instance.profile?.email ?? '',
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
      if (userName.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please set your name in the main screen.')),
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
          'brand': item.brand,
          'size': item.size,
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

      await sbSubmitFullCheck(
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
    final brands = byBrand.keys.toList()..sort(_compareRampBrands);

    // Sort items within each brand by size
    for (final brand in brands) {
      byBrand[brand]!.sort((a, b) => _compareRampSizes(a.size, b.size));
    }

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
  /// When provided, pre-fills the job reference field (e.g. from a schedule event title).
  final String? initialJobRef;

  /// Which tab to open first. 0 = Install (default), 1 = Removal.
  final int initialTabIndex;

  /// When true, adjustments apply to the CCALS pool (ccals_qty) instead of Able Home (current_qty).
  final bool isCcals;

  const JobAdjustmentScreen({
    super.key,
    this.initialJobRef,
    this.initialTabIndex = 0,
    this.isCcals = false,
  });

  @override
  State<JobAdjustmentScreen> createState() => _JobAdjustmentScreenState();
}

class _JobAdjustmentScreenState extends State<JobAdjustmentScreen>
    with SingleTickerProviderStateMixin {
  late Future<InventoryData> _future;
  final Map<String, String> _quantities = {}; // key: itemId|condition
  bool _submitting = false;

  late TabController _tabController; // 0 = Install, 1 = Removal
  late TextEditingController _jobRefController;
  String _installCondition = 'New';
  String _jobRef = '';

  @override
  void initState() {
    super.initState();
    _future = sbFetchInventory();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTabIndex.clamp(0, 1),
    );
    final initial = widget.initialJobRef ?? '';
    _jobRef = initial;
    _jobRefController = TextEditingController(text: initial);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _jobRefController.dispose();
    super.dispose();
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
      'name': prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
      'email': AuthService.instance.profile?.email ?? '',
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
      if (userName.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Please set your name in the main screen.')),
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
          'brand': item.brand,
          'size': item.size,
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

      if (widget.isCcals) {
        await sbSubmitCcalsAdjustment(
          userEmail: userEmail,
          userName: userName,
          jobRef: _jobRef.trim(),
          items: items,
        );
      } else {
        await sbSubmitJobAdjustment(
          userEmail: userEmail,
          userName: userName,
          jobRef: _jobRef.trim(),
          items: items,
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.isCcals ? 'CCALS adjustment submitted' : 'Job adjustment submitted')),
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
    final brands = byBrand.keys.toList()..sort(_compareRampBrands);

    // Sort items within each brand by size
    for (final brand in brands) {
      byBrand[brand]!.sort((a, b) => _compareRampSizes(a.size, b.size));
    }

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

                final displayQty = widget.isCcals ? item.ccalsQty : item.currentQty;
                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: ListTile(
                    title: Text(item.size),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${widget.isCcals ? 'CCALS' : 'Current'} $condition: $displayQty'),
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
        title: Text(widget.isCcals ? 'CCALS Adjustment' : 'Job Adjustment – Ramps'),
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
              // Instruction banner — shown when opened from a schedule event
              if (widget.initialJobRef != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: kBrandGreen.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: kBrandGreen.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 18, color: kBrandGreen),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          isInstall
                              ? 'Select the ramp sections and quantities installed for this job. Each item entered will be deducted from inventory.'
                              : 'Select the ramp sections and quantities recovered from this job. Each item entered will be added back to inventory.',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: TextField(
                  controller: _jobRefController,
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

/// Small pill badge used in lift cards and elsewhere.
class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _LiftsScreenState extends State<LiftsScreen> {
  late Future<List<LiftRecord>> _future;
  String _search = '';
  String? _conditionFilter;
  String? _statusFilter;
  String? _brandFilter;
  String? _seriesFilter;
  String? _orientationFilter;
  String? _prepStatusFilter;
  String? _railTypeFilter;
  String? _sourceFilter;
  String? _sortOption; // null = default (newest acquired first)

  @override
  void initState() {
    super.initState();
    _future = sbFetchLifts();
  }

  void _refresh() {
    setState(() {
      _future = sbFetchLifts();
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

  void _openFoldingRails() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const FoldingRailsScreen(),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lifts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More',
            onSelected: (v) {
              switch (v) {
                case 'folding_rails': _openFoldingRails(); break;
                case 'quantities':   _openStairliftQuantities(); break;
                case 'bins':
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BinWhiteboardScreen()),
                  );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'folding_rails', child: Text('Folding Rails')),
              PopupMenuItem(value: 'quantities',   child: Text('Stairlift Quantities')),
              PopupMenuItem(value: 'bins',         child: Text('Bin Whiteboard')),
            ],
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

          final allLifts = snapshot.data ?? [];

          // Filter out folding rail individual entries from lifts list
          final lifts = allLifts.where((l) => !isLiftRecordFoldingRail(l)).toList();

          // All filter lists are hardcoded so options always appear
          const statuses = ['New', 'Assigned', 'Installed', 'Removed', 'Scrapped'];
          const brands = ['Acorn', 'Brooks', 'Bruno', 'Harmar'];
          const orientations = ['LH', 'RH', 'N/A'];

          // Series: hardcoded per brand when brand filter active, else all series
          final List<String> allSeries;
          if (_brandFilter != null && _seriesByBrandHardcoded.containsKey(_brandFilter)) {
            allSeries = _seriesByBrandHardcoded[_brandFilter]!;
          } else {
            allSeries = sortSeriesList([
              ..._seriesByBrandHardcoded.values.expand((s) => s).toSet(),
            ]);
          }

          // Clamp series filter if it doesn't exist in the (possibly brand-scoped) series list
          if (_seriesFilter != null && !allSeries.contains(_seriesFilter)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() { _seriesFilter = null; });
            });
          }

          // Single filtering pipeline with AND logic
          final filtered = lifts.where((l) {
            // Condition filter — 'Used' matches all used sub-conditions
            if (_conditionFilter != null && _conditionFilter!.isNotEmpty) {
              final lc = l.condition.trim().toLowerCase();
              final fc = _conditionFilter!.toLowerCase();
              if (fc == 'used') {
                if (!lc.startsWith('used')) return false;
              } else {
                if (lc != fc) return false;
              }
            }

            // Status filter — case-insensitive
            if (_statusFilter != null &&
                _statusFilter!.isNotEmpty &&
                l.status.trim().toLowerCase() != _statusFilter!.toLowerCase()) {
              return false;
            }

            // Brand filter — case-insensitive
            if (_brandFilter != null &&
                _brandFilter!.isNotEmpty &&
                l.brand.trim().toLowerCase() != _brandFilter!.toLowerCase()) {
              return false;
            }

            // Series filter — case-insensitive
            if (_seriesFilter != null &&
                _seriesFilter!.isNotEmpty &&
                l.series.trim().toLowerCase() != _seriesFilter!.toLowerCase()) {
              return false;
            }

            // Orientation filter — LH/RH also shows N/A (non-handed) lifts
            if (_orientationFilter != null && _orientationFilter!.isNotEmpty) {
              final lo = l.orientation.trim().toLowerCase();
              final fo = _orientationFilter!.toLowerCase();
              final isNonHanded = lo == 'n/a' || lo.isEmpty;
              final filterIsHanded = fo == 'lh' || fo == 'rh';
              // Pass if: exact match OR (non-handed lift AND filter is LH/RH)
              final passesFilter = lo == fo || (isNonHanded && filterIsHanded);
              if (!passesFilter) return false;
            }

            // Prep Status filter — case-insensitive
            if (_prepStatusFilter != null &&
                _prepStatusFilter!.isNotEmpty &&
                l.preppedStatus.trim().toLowerCase() != _prepStatusFilter!.toLowerCase()) {
              return false;
            }

            // Rail type filter
            if (_railTypeFilter != null && _railTypeFilter!.isNotEmpty) {
              if (l.railType.toLowerCase() != _railTypeFilter!.toLowerCase()) return false;
            }

            // Source filter
            if (_sourceFilter != null && _sourceFilter!.isNotEmpty) {
              if (l.acquisitionSource.toLowerCase() != _sourceFilter!.toLowerCase()) return false;
            }

            // Search filter (applies to multiple fields)
            if (_search.isNotEmpty) {
              // Normalize queries like "bin 24", "bin#24", "bin# 24" → just "24"
              String effectiveSearch = _search;
              final binPattern = RegExp(r'^bin\s*#?\s*(\w+)$', caseSensitive: false);
              final binMatch = binPattern.firstMatch(_search.trim());
              if (binMatch != null) effectiveSearch = binMatch.group(1)!.toLowerCase();

              final haystack = [
                l.serialNumber,
                l.binNumber,
                l.brand,
                l.series,
                l.currentLocation,
                l.currentJob,
              ].join(' ').toLowerCase();

              // Token-based matching: every word in the query must appear somewhere
              // in the combined haystack, enabling searches like "Acorn 130" or "Bruno Elite"
              final tokens = effectiveSearch.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
              if (!tokens.every((token) => haystack.contains(token))) return false;
            }

            return true;
          }).toList();

          // Sort (applied after filtering; search ranking overrides when search is active)
          if (_search.isEmpty) {
            switch (_sortOption) {
              case 'Newest Added':
                filtered.sort((a, b) {
                  final da = DateTime.tryParse(a.dateAcquired) ?? DateTime(2000);
                  final db = DateTime.tryParse(b.dateAcquired) ?? DateTime(2000);
                  return db.compareTo(da);
                });
                break;
              case 'Oldest Added':
                filtered.sort((a, b) {
                  final da = DateTime.tryParse(a.dateAcquired) ?? DateTime(2000);
                  final db = DateTime.tryParse(b.dateAcquired) ?? DateTime(2000);
                  return da.compareTo(db);
                });
                break;
              case 'Brand A–Z':
                filtered.sort((a, b) => a.brand.toLowerCase().compareTo(b.brand.toLowerCase()));
                break;
              case 'Series A–Z':
                filtered.sort((a, b) => a.series.toLowerCase().compareTo(b.series.toLowerCase()));
                break;
              case 'Status':
                const order = ['New', 'Assigned', 'Installed', 'Removed', 'Scrapped'];
                filtered.sort((a, b) {
                  final ia = order.indexOf(a.status);
                  final ib = order.indexOf(b.status);
                  return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
                });
                break;
              case 'Bin # Asc':
                filtered.sort((a, b) {
                  final na = int.tryParse(a.binNumber.replaceAll(RegExp(r'[^0-9]'), ''));
                  final nb = int.tryParse(b.binNumber.replaceAll(RegExp(r'[^0-9]'), ''));
                  if (na == null && nb == null) return 0;
                  if (na == null) return 1;
                  if (nb == null) return -1;
                  return na.compareTo(nb);
                });
                break;
              case 'Bin # Desc':
                filtered.sort((a, b) {
                  final na = int.tryParse(a.binNumber.replaceAll(RegExp(r'[^0-9]'), ''));
                  final nb = int.tryParse(b.binNumber.replaceAll(RegExp(r'[^0-9]'), ''));
                  if (na == null && nb == null) return 0;
                  if (na == null) return 1;
                  if (nb == null) return -1;
                  return nb.compareTo(na);
                });
                break;
              default:
                // Default: newest acquired first
                filtered.sort((a, b) {
                  final da = DateTime.tryParse(a.dateAcquired) ?? DateTime(2000);
                  final db = DateTime.tryParse(b.dateAcquired) ?? DateTime(2000);
                  return db.compareTo(da);
                });
            }
          }

          // Search ranking: exact bin/serial matches float to top
          if (_search.isNotEmpty) {
            // Normalize for ranking too
            String effectiveSearch = _search;
            final binPattern = RegExp(r'^bin\s*#?\s*(\w+)$', caseSensitive: false);
            final binMatch = binPattern.firstMatch(_search.trim());
            if (binMatch != null) effectiveSearch = binMatch.group(1)!.toLowerCase();

            filtered.sort((a, b) {
              int rank(LiftRecord r) {
                final s = effectiveSearch;
                if (r.binNumber.toLowerCase() == s) return 0;
                if (r.serialNumber.toLowerCase() == s) return 1;
                if (r.binNumber.toLowerCase().startsWith(s)) return 2;
                if (r.serialNumber.toLowerCase().startsWith(s)) return 3;
                return 4;
              }
              return rank(a).compareTo(rank(b));
            });
          }

          return Column(
            children: [
              _buildLiftsFilters(
                statuses: statuses,
                brands: brands,
                series: allSeries,
                orientations: orientations,
                conditions: const [
                  'New', 'Used',
                  'Used - Like New', 'Used - Standard', 'Used - Not Great', 'Used - Shit',
                ],
                sortOptions: const [
                  'Newest Added',
                  'Oldest Added',
                  'Brand A–Z',
                  'Series A–Z',
                  'Status',
                  'Bin # Asc',
                  'Bin # Desc',
                ],
              ),
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
                        _future = sbFetchLifts();
                      });
                      await _future;
                    },
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final l = filtered[index];
                        final status = l.status.isEmpty ? 'Unknown' : l.status;

                        // Determine clean status text color
                        Color? cbColor;
                        if (l.cleanBatteriesStatus == 'Clean') {
                          cbColor = Colors.green.shade700;
                        } else if (l.cleanBatteriesStatus == 'Needs Cleaning') {
                          cbColor = Colors.red.shade700;
                        }

                        // Status accent color
                        final Color accentColor = switch (l.status.toLowerCase()) {
                          'in stock'   => kBrandGreen,
                          'assigned'   => Colors.amber.shade700,
                          'installed'  => Colors.blue.shade600,
                          'removed'    => Colors.grey.shade500,
                          'scrapped'   => Colors.red.shade400,
                          _            => Colors.grey.shade400,
                        };

                        return GestureDetector(
                          onTap: () async {
                            final saved = await Navigator.of(context).push<bool>(
                              MaterialPageRoute(builder: (_) => LiftFormScreen(existing: l)),
                            );
                            if (saved == true) _refresh();
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                            decoration: BoxDecoration(
                              color: kCardSurface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Left accent bar
                                  Container(
                                    width: 5,
                                    decoration: BoxDecoration(
                                      color: accentColor,
                                      borderRadius: const BorderRadius.only(
                                        topLeft: Radius.circular(14),
                                        bottomLeft: Radius.circular(14),
                                      ),
                                    ),
                                  ),
                                  // Content
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  [
                                                    l.brand,
                                                    if (l.series.isNotEmpty) l.series,
                                                    if (l.orientation.isNotEmpty && l.orientation.toLowerCase() != 'n/a') l.orientation,
                                                  ].join(' · '),
                                                  style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 15),
                                                ),
                                              ),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: accentColor.withValues(alpha: 0.12),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  status,
                                                  style: GoogleFonts.nunito(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w700,
                                                    color: accentColor,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Text(
                                                'SN: ${l.serialNumber.isNotEmpty ? l.serialNumber : 'N/A'}',
                                                style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey.shade600),
                                              ),
                                              if (l.condition.trim().toLowerCase().startsWith('used') && l.binNumber.isNotEmpty) ...[
                                                const SizedBox(width: 12),
                                                Text(
                                                  normalizeBinDisplay(l.binNumber),
                                                  style: GoogleFonts.nunito(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.blueGrey.shade700),
                                                ),
                                              ],
                                            ],
                                          ),
                                          if (l.currentLocation.isNotEmpty) ...[
                                            const SizedBox(height: 3),
                                            Text(
                                              'Location: ${l.currentLocation}',
                                              style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey.shade600),
                                            ),
                                          ],
                                          if (l.currentJob.isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              'Job: ${l.currentJob}',
                                              style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey.shade600),
                                            ),
                                          ],
                                          if (l.notes.isNotEmpty) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              'Notes: ${l.notes}',
                                              style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey.shade500),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                          if (l.preppedStatus.isNotEmpty || l.cleanBatteriesStatus.isNotEmpty || l.railType == 'Curved' || l.acquisitionSource.isNotEmpty) ...[
                                            const SizedBox(height: 8),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 4,
                                              children: [
                                                if (l.preppedStatus.isNotEmpty)
                                                  _StatusPill(
                                                    label: l.preppedStatus,
                                                    color: l.preppedStatus == 'Needs repair'
                                                        ? Colors.red.shade600
                                                        : l.preppedStatus == 'Needs prepping'
                                                            ? Colors.orange.shade700
                                                            : Colors.green.shade700,
                                                  ),
                                                if (l.cleanBatteriesStatus.isNotEmpty)
                                                  _StatusPill(label: l.cleanBatteriesStatus, color: cbColor ?? Colors.grey),
                                                if (l.railType == 'Curved')
                                                  _StatusPill(label: 'Curved', color: Colors.purple.shade600),
                                                if (l.acquisitionSource.isNotEmpty)
                                                  _StatusPill(label: l.acquisitionSource, color: Colors.indigo.shade400),
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC), size: 20),
                                  const SizedBox(width: 8),
                                ],
                              ),
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

  Widget _buildLiftsFilters({
    required List<String> statuses,
    required List<String> brands,
    required List<String> series,
    required List<String> orientations,
    required List<String> conditions,
    required List<String> sortOptions,
  }) {
    const sources = ['VA', 'Private Pay'];
    const railTypes = ['Straight', 'Curved'];

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            style: const TextStyle(color: Colors.black),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search by serial, bin #, brand, series, location...',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              setState(() {
                _search = value.trim().toLowerCase();
              });
            },
          ),
        ),

        // Filters - Three rows of three
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Column(
            children: [
              // Row 1: Condition, Brand, Series
              Row(
                children: [
                  Expanded(
                    child: _buildCompactDropdown(
                      value: _conditionFilter,
                      hint: 'Condition',
                      items: conditions,
                      onChanged: (value) => setState(() => _conditionFilter = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCompactDropdown(
                      value: _brandFilter,
                      hint: 'Brand',
                      items: brands,
                      onChanged: (value) => setState(() {
                        _brandFilter = value;
                        _seriesFilter = null;
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCompactDropdown(
                      value: series.contains(_seriesFilter) ? _seriesFilter : null,
                      hint: 'Series',
                      items: series,
                      onChanged: (value) => setState(() => _seriesFilter = value),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Row 2: Status, Orientation, Sort
              Row(
                children: [
                  Expanded(
                    child: _buildCompactDropdown(
                      value: _statusFilter,
                      hint: 'Status',
                      items: statuses,
                      onChanged: (value) => setState(() => _statusFilter = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCompactDropdown(
                      value: orientations.contains(_orientationFilter) ? _orientationFilter : null,
                      hint: 'Orient.',
                      items: orientations,
                      onChanged: (value) => setState(() => _orientationFilter = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCompactDropdown(
                      value: _sortOption,
                      hint: 'Sort',
                      items: sortOptions,
                      onChanged: (value) => setState(() => _sortOption = value),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Row 3: Rail Type, Source
              Row(
                children: [
                  Expanded(
                    child: _buildCompactDropdown(
                      value: _railTypeFilter,
                      hint: 'Rail Type',
                      items: railTypes,
                      onChanged: (value) => setState(() => _railTypeFilter = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCompactDropdown(
                      value: _sourceFilter,
                      hint: 'Job Type',
                      items: sources,
                      onChanged: (value) => setState(() => _sourceFilter = value),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCompactDropdown({
    required String? value,
    required String hint,
    required List<String> items,
    required void Function(String?) onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          hint: Text(hint, style: const TextStyle(fontSize: 14)),
          isExpanded: true,
          isDense: true,
          items: <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(
              value: null,
              child: Text('All $hint', style: const TextStyle(fontSize: 14)),
            ),
            ...items.map(
              (item) => DropdownMenuItem<String>(
                value: item,
                child: Text(item, style: const TextStyle(fontSize: 14)),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// =======================
/// FOLDING RAILS SCREEN (with New/Used tabs)
/// =======================

class FoldingRailsScreen extends StatefulWidget {
  const FoldingRailsScreen({super.key});

  @override
  State<FoldingRailsScreen> createState() => _FoldingRailsScreenState();
}

class _FoldingRailsScreenState extends State<FoldingRailsScreen>
    with SingleTickerProviderStateMixin {
  late Future<InventoryData> _future;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _future = sbFetchInventory();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _future = sbFetchInventory();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Folding Rails'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'New'),
            Tab(text: 'Used'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
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

          final data = snapshot.data;
          if (data == null) {
            return const Center(child: Text('No data available'));
          }

          // Get folding rails only
          final allFoldingRails = data.stairlifts
              .where((item) => item.active && isFoldingRail(item))
              .toList();

          final newFoldingRails = allFoldingRails
              .where((item) => item.condition == 'New')
              .toList();
          final usedFoldingRails = allFoldingRails
              .where((item) => item.condition == 'Used')
              .toList();
          final cutFoldingRails = allFoldingRails
              .where((item) => item.condition == 'Cut')
              .toList();

          return TabBarView(
            controller: _tabController,
            children: [
              _buildFoldingRailList(newFoldingRails, 'New'),
              _buildUsedFoldingRailTab(usedFoldingRails, cutFoldingRails),
            ],
          );
        },
      ),
    );
  }

  Widget _buildUsedFoldingRailTab(
      List<StairliftItem> usedRails, List<StairliftItem> cutRails) {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() {
          _future = sbFetchInventory();
        });
        await _future;
      },
      child: ListView(
        padding: const EdgeInsets.all(12.0),
        children: [
          // --- Used section ---
          if (usedRails.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                'Used',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            ...usedRails.map((item) => _buildFoldingRailTile(item)),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: Text('No used folding rails',
                  style: TextStyle(color: Colors.grey)),
            ),

          const Divider(height: 24),

          // --- Cut section ---
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Text(
              'Cut Folding Rails',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          if (cutRails.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4.0),
              child: Text('No cut folding rails',
                  style: TextStyle(color: Colors.grey)),
            )
          else
            ...cutRails.map((item) => _buildCutFoldingRailTile(item)),
        ],
      ),
    );
  }

  Future<void> _editCutRailNotes(StairliftItem item) async {
    final controller = TextEditingController(text: item.notes);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${item.brand} ${item.series}'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Notes',
            hintText: 'Enter details about this cut rail...',
            border: OutlineInputBorder(),
          ),
          maxLines: 4,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await sbUpdateStairliftNotes(
        itemId: item.itemId,
        notes: controller.text.trim(),
      );
      _refresh();
    } catch (_) {
      // Best-effort — refresh anyway to show current state
      _refresh();
    }
  }

  Widget _buildCutFoldingRailTile(StairliftItem item) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: Colors.orange.shade50,
      child: InkWell(
        onTap: () => _editCutRailNotes(item),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.content_cut, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${item.brand} ${item.series} - ${item.orientation}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: item.currentQty > 0
                            ? () => _adjustFoldingRailQuantity(item, -1)
                            : null,
                      ),
                      Text(
                        '${item.currentQty}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: () => _adjustFoldingRailQuantity(item, 1),
                      ),
                    ],
                  ),
                ],
              ),
              if (item.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    'Notes: ${item.notes}',
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                  ),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(top: 4.0),
                  child: Text(
                    'Tap to add notes...',
                    style: TextStyle(fontSize: 12, color: Colors.black38),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFoldingRailList(List<StairliftItem> items, String condition) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          'No $condition folding rails',
          style: const TextStyle(fontSize: 16, color: Colors.grey),
        ),
      );
    }

    // Group by brand + series + orientation
    final Map<String, List<StairliftItem>> grouped = {};
    for (final item in items) {
      final key = '${item.brand}|${item.series}|${item.orientation}';
      grouped.putIfAbsent(key, () => []).add(item);
    }

    return RefreshIndicator(
      onRefresh: () async {
        setState(() {
          _future = sbFetchInventory();
        });
        await _future;
      },
      child: ListView.builder(
        padding: const EdgeInsets.all(12.0),
        itemCount: grouped.length,
        itemBuilder: (context, index) {
          final key = grouped.keys.elementAt(index);
          final groupItems = grouped[key]!;
          final item = groupItems.first;

          return _buildFoldingRailTile(item);
        },
      ),
    );
  }

  Widget _buildFoldingRailTile(StairliftItem item) {
    // Determine color based on condition
    final color = item.condition == 'New' ? Colors.green : Colors.blue;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: color.shade50,
      child: ListTile(
        leading: Icon(Icons.format_list_numbered, color: color),
        title: Text(
          '${item.brand} ${item.series}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Orientation: ${item.orientation}'),
            Text('Condition: ${item.condition}'),
            Text('${item.currentQty} units',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: item.currentQty > 0
                  ? () => _adjustFoldingRailQuantity(item, -1)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _adjustFoldingRailQuantity(item, 1),
            ),
          ],
        ),
        onTap: () => _showFoldingRailQuantityDialog(item),
      ),
    );
  }

  Future<void> _adjustFoldingRailQuantity(StairliftItem item, int delta) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';
      final userEmail = AuthService.instance.profile?.email ?? '';

      if (userName.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please set your name in settings'),
          ),
        );
        return;
      }

      await sbSubmitJobAdjustment(
        userEmail: userEmail,
        userName: userName,
        jobRef: 'Folding Rail Adjustment',
        items: [
          {
            'item_id': item.itemId,
            'category': 'stairlift',
            'brand': item.brand,
            'series': item.series,
            'orientation': item.orientation,
            'delta': delta,
            'condition': item.condition,
          }
        ],
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Updated ${item.brand} ${item.series} (${item.orientation}) by ${delta > 0 ? '+' : ''}$delta',
          ),
        ),
      );

      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error adjusting quantity: $e')),
      );
    }
  }

  Future<void> _showFoldingRailQuantityDialog(StairliftItem item) async {
    final controller = TextEditingController(text: item.currentQty.toString());

    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${item.brand} ${item.series}\n${item.orientation} - ${item.condition}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Quantity',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final qty = int.tryParse(controller.text);
              Navigator.of(context).pop(qty);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result != item.currentQty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';
        final userEmail = AuthService.instance.profile?.email ?? '';

        if (userName.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Please set your name in settings'),
            ),
          );
          return;
        }

        await sbSubmitFullCheck(
          userEmail: userEmail,
          userName: userName,
          items: [
            {
              'item_id': item.itemId,
              'category': 'stairlift',
              'brand': item.brand,
              'series': item.series,
              'orientation': item.orientation,
              'condition': item.condition,
              'new_qty': result,
            }
          ],
        );

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Set ${item.brand} ${item.series} (${item.orientation}) to $result units'),
          ),
        );

        _refresh();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error setting quantity: $e')),
        );
      }
    }
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
    _liftsFuture = sbFetchLifts();
    _inventoryFuture = sbFetchInventory();
  }

  void _refresh() {
    setState(() {
      _liftsFuture = sbFetchLifts();
      _inventoryFuture = sbFetchInventory();
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

          // Count all non-folding-rail lifts from master list.
          // New: only New status. Used: all statuses (used units out in field still count).
          final eligibleLifts = lifts.where((l) => !isLiftRecordFoldingRail(l)).toList();

          // Group by brand + series + condition and count
          final Map<String, int> counts = {};
          for (final lift in eligibleLifts) {
            final cond = lift.condition.trim();
            final status = lift.status.trim();
            // For New units, only count New status; for Used, count all statuses
            if (cond == 'New' && status != 'New') continue;
            final key = '${lift.brand.trim()}|${lift.series.trim()}|${lift.orientation.trim()}|$cond';
            counts[key] = (counts[key] ?? 0) + 1;
          }

          // Get min_qty values from the old inventory sheet
          final Map<String, int> minQtyMap = {};
          for (final s in inventoryData.stairlifts) {
            final key = '${s.brand.trim()}|${s.series.trim()}|${s.orientation.trim()}|${s.condition.trim()}';
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
            // Skip fold items — those are tracked in the Folding Rails screen
            if (series.trim().toLowerCase().contains('fold')) continue;
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
    _future = sbFetchChanges();
  }

  void _refresh() {
    setState(() {
      _future = sbFetchChanges();
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

              final isMulti = group.length > 1;

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                clipBehavior: Clip.hardEdge,
                child: isMulti
                    ? ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                        title: Text(
                          '${first.changeType} – $titleSuffix',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        subtitle: Text(
                          '$ts · ${group.length} items · By: ${first.userName}',
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        children: [
                          ...group.map((c) {
                            final itemLabel = [
                              c.brand,
                              c.seriesOrSize,
                              if (c.orientation.isNotEmpty) c.orientation,
                            ].where((s) => s.isNotEmpty).join(' ');
                            final displayItem = itemLabel.isEmpty ? c.itemId : itemLabel;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2.0),
                              child: Text(
                                '• $displayItem (${c.condition}): ${c.oldQty} → ${c.newQty}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            );
                          }),
                          if (first.note.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text('Note: ${first.note}', style: const TextStyle(fontSize: 13)),
                          ],
                        ],
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${first.changeType} – $titleSuffix',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                            const SizedBox(height: 4),
                            Text(ts, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                            const SizedBox(height: 6),
                            () {
                              final c = group.first;
                              final itemLabel = [
                                c.brand,
                                c.seriesOrSize,
                                if (c.orientation.isNotEmpty) c.orientation,
                              ].where((s) => s.isNotEmpty).join(' ');
                              final displayItem = itemLabel.isEmpty ? c.itemId : itemLabel;
                              return Text(
                                '• $displayItem (${c.condition}): ${c.oldQty} → ${c.newQty}',
                                style: const TextStyle(fontSize: 13),
                              );
                            }(),
                            if (first.note.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('Note: ${first.note}', style: const TextStyle(fontSize: 13)),
                            ],
                            const SizedBox(height: 4),
                            Text(
                              'By: ${first.userName}',
                              style: const TextStyle(fontSize: 12, color: Colors.black87),
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

// ---------------------------------------------------------------------------
// Shared lift history event tile — used in both history tabs and inline views.
// ---------------------------------------------------------------------------

class _LiftHistoryTile extends StatelessWidget {
  final LiftHistoryEvent event;
  const _LiftHistoryTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final who = event.userName.isNotEmpty ? event.userName : event.userEmail;
    final ts = formatDate(event.timestamp);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    event.status.isEmpty ? (event.eventType.isNotEmpty ? event.eventType : 'Update') : event.status,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
                Text(ts, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
              ],
            ),
            if (event.location.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Location: ${event.location}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700])),
              ),
            if (event.jobRef.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Job: ${event.jobRef}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[700])),
              ),
            if (event.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(event.note,
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ),
            if (who.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  children: [
                    Icon(Icons.person_outline, size: 12, color: Colors.grey[500]),
                    const SizedBox(width: 3),
                    Text(who, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                  ],
                ),
              ),
          ],
        ),
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
  late Future<List<LiftCustomerHistoryEntry>> _customerHistoryFuture;

  // Photos state — starts from the LiftRecord, refreshed after upload/delete
  late List<String> _photoUrls;
  bool _uploadingPhoto = false;

  String get _liftIdForApi => widget.lift.liftId;
  String get _serialForApi => widget.lift.serialNumber;

  @override
  void initState() {
    super.initState();

    _photoUrls = List<String>.from(widget.lift.photoUrls);

    // History is now keyed purely by serial number
    _historyFuture = sbFetchLiftHistory(
      serialNumber: _serialForApi,
    );

    // Service is also keyed purely by serial number
    _serviceFuture = sbFetchLiftService(
      serialNumber: _serialForApi,
    );

    // Prep checklists are also keyed by serial number
    _prepChecklistsFuture = sbFetchPrepChecklists(
      serialNumber: _serialForApi,
    );

    _customerHistoryFuture = sbFetchLiftCustomerHistory(_liftIdForApi);
  }

  void _openEdit() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => LiftFormScreen(existing: widget.lift),
      ),
    );
    if (result == true && mounted) {
      // Pop back — the caller (list or schedule detail) will reload on return
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _deleteLift() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete Lift',
      content: 'Remove ${widget.lift.brand} ${widget.lift.series} (SN: ${widget.lift.serialNumber}) from the lifts master?\n\nThis cannot be undone.',
    );
    if (confirmed != true || !mounted) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';
      final userEmail = AuthService.instance.profile?.email ?? '';

      await sbDeleteLift(
        liftId: widget.lift.liftId,
        userEmail: userEmail,
        userName: userName,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lift removed from master list')),
        );
        Navigator.of(context).pop(true); // return true so list refreshes
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  Future<void> _refreshService() async {
    try {
      // Re-fetch the service records for this lift (keyed by serial number)
      _serviceFuture = sbFetchLiftService(
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

  Future<void> _addPhoto() async {
    if (_liftIdForApi.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the lift first before adding photos')),
      );
      return;
    }

    // On web, only file picker is supported (no camera access via image_picker)
    final ImageSource source;
    if (kIsWeb) {
      source = ImageSource.gallery;
    } else {
      final picked = await showModalBottomSheet<ImageSource>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take photo'),
                onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from library'),
                onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      source = picked;
    }

    final picker = ImagePicker();
    final imageFile = await picker.pickImage(source: source, imageQuality: 90);
    if (imageFile == null || !mounted) return;

    setState(() => _uploadingPhoto = true);
    try {
      await sbUploadLiftPhoto(liftId: _liftIdForApi, imageFile: imageFile);
      // Refresh photo list from server
      final urls = await sbFetchLiftPhotos(liftId: _liftIdForApi);
      if (mounted) {
        setState(() {
          _photoUrls = urls;
          _uploadingPhoto = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo added')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _uploadingPhoto = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  Future<void> _deletePhoto(String url) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete photo?',
      content: 'This cannot be undone.',
    );
    if (!confirmed || !mounted) return;

    try {
      await sbDeleteLiftPhoto(liftId: _liftIdForApi, fileUrl: url);
      final urls = await sbFetchLiftPhotos(liftId: _liftIdForApi);
      if (mounted) setState(() => _photoUrls = urls);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  void _viewPhoto(BuildContext context, String url) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _PhotoViewScreen(url: url),
    ));
  }

  Widget _buildCustomerTab() {
    final lift = widget.lift;
    return FutureBuilder<List<LiftCustomerHistoryEntry>>(
      future: _customerHistoryFuture,
      builder: (context, snap) {
        final history = snap.data ?? [];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Current customer
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: kCardSurface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Current Customer',
                      style: GoogleFonts.nunito(
                          fontSize: 12, fontWeight: FontWeight.w800,
                          color: Colors.grey[600])),
                  const SizedBox(height: 8),
                  if (lift.customerName.isNotEmpty) ...[
                    Text(lift.customerName,
                        style: GoogleFonts.nunito(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    if (lift.qbCustomerId.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: () => launchUrl(
                          Uri.parse(
                              'https://app.qbo.intuit.com/app/customerdetail?nameId=${lift.qbCustomerId}'),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.open_in_new, size: 14, color: kBrandGreen),
                            const SizedBox(width: 5),
                            Text('View in QuickBooks',
                                style: GoogleFonts.nunito(
                                    fontSize: 13,
                                    color: kBrandGreen,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ] else
                    Text('No customer linked yet.',
                        style: GoogleFonts.nunito(
                            color: Colors.grey[500], fontSize: 13)),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: Text(lift.customerName.isNotEmpty
                        ? 'Change Customer'
                        : 'Link Customer',
                        style: GoogleFonts.nunito(fontSize: 13)),
                    onPressed: _openEdit,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            // Customer history
            Text('Customer History',
                style: GoogleFonts.nunito(
                    fontSize: 13, fontWeight: FontWeight.w800,
                    color: Colors.grey[700])),
            const SizedBox(height: 8),
            if (snap.connectionState == ConnectionState.waiting)
              const Center(child: CircularProgressIndicator())
            else if (history.isEmpty)
              Text('No previous customers.',
                  style: GoogleFonts.nunito(
                      color: Colors.grey[500], fontSize: 13))
            else
              ...history.map((e) {
                final assigned = '${e.assignedAt.month}/${e.assignedAt.day}/${e.assignedAt.year}';
                final removed = e.removedAt != null
                    ? '${e.removedAt!.month}/${e.removedAt!.day}/${e.removedAt!.year}'
                    : 'Current';
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: kCardSurface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.person_outline,
                          size: 18, color: Colors.grey[500]),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.customerName,
                                style: GoogleFonts.nunito(
                                    fontWeight: FontWeight.w700, fontSize: 14)),
                            Text('$assigned → $removed',
                                style: GoogleFonts.nunito(
                                    fontSize: 11, color: Colors.grey[500])),
                          ],
                        ),
                      ),
                      if (e.qbCustomerId.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.open_in_new, size: 16),
                          color: kBrandGreen,
                          tooltip: 'View in QB',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () => launchUrl(
                            Uri.parse(
                                'https://app.qbo.intuit.com/app/customerdetail?nameId=${e.qbCustomerId}'),
                            mode: LaunchMode.externalApplication,
                          ),
                        ),
                    ],
                  ),
                );
              }),
          ],
        );
      },
    );
  }

  Widget _buildPhotosTab() {
    return Column(
      children: [
        Expanded(
          child: _photoUrls.isEmpty && !_uploadingPhoto
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      const Text('No photos yet', style: TextStyle(color: Colors.black54)),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: _addPhoto,
                        icon: const Icon(Icons.add_a_photo),
                        label: const Text('Add photo'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kBrandGreen,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: _photoUrls.length + (_uploadingPhoto ? 1 : 0),
                  itemBuilder: (context, index) {
                    // Last tile while uploading = spinner placeholder
                    if (_uploadingPhoto && index == _photoUrls.length) {
                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Center(child: CircularProgressIndicator()),
                      );
                    }
                    final url = _photoUrls[index];
                    return GestureDetector(
                      onTap: () => _viewPhoto(context, url),
                      onLongPress: () => _deletePhoto(url),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              url,
                              fit: BoxFit.cover,
                              loadingBuilder: (_, child, progress) => progress == null
                                  ? child
                                  : Container(
                                      color: Colors.grey.shade200,
                                      child: const Center(child: CircularProgressIndicator()),
                                    ),
                              errorBuilder: (_, __, e) => Container(
                                color: Colors.grey.shade200,
                                child: const Icon(Icons.broken_image, color: Colors.grey),
                              ),
                            ),
                          ),
                          // Delete button overlay
                          Positioned(
                            top: 4,
                            right: 4,
                            child: GestureDetector(
                              onTap: () => _deletePhoto(url),
                              child: Container(
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                padding: const EdgeInsets.all(4),
                                child: const Icon(Icons.close, color: Colors.white, size: 16),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        // Add photo button at the bottom when photos exist
        if (_photoUrls.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: ElevatedButton.icon(
              onPressed: _uploadingPhoto ? null : _addPhoto,
              icon: const Icon(Icons.add_a_photo),
              label: const Text('Add photo'),
              style: ElevatedButton.styleFrom(
                backgroundColor: kBrandGreen,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 44),
              ),
            ),
          ),
      ],
    );
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
      'Clean/Batteries': lift.cleanBatteriesStatus,
      'Current location': lift.currentLocation,
      'Current job': lift.currentJob,
      'Date acquired': normalizeDateDisplay(lift.dateAcquired),
      'Install date': normalizeDateDisplay(lift.installDate),
      'Installer name': lift.installerName,
      'Last prep date': normalizeDateDisplay(lift.lastPrepDate),
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

        final allEvents = snapshot.data ?? [];

        // Only show rows where status, location, or jobRef changed
        final filtered = <LiftHistoryEvent>[];
        String prevStatus = '';
        String prevLocation = '';
        String prevJobRef = '';
        for (final e in allEvents) {
          if (e.status != prevStatus ||
              e.location != prevLocation ||
              e.jobRef != prevJobRef) {
            filtered.add(e);
            prevStatus = e.status;
            prevLocation = e.location;
            prevJobRef = e.jobRef;
          }
        }

        if (filtered.isEmpty) {
          return const Center(
            child: Text('No movement history recorded for this lift yet.'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12.0),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final e = filtered[index];
            return _LiftHistoryTile(event: e);
          },
        );
      },
    );
  }

  Widget _buildChangeHistoryTab() {
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
            child: Text('No change history recorded for this lift yet.'),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(12.0),
          itemCount: events.length,
          itemBuilder: (context, index) => _LiftHistoryTile(event: events[index]),
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
                      _prepChecklistsFuture = sbFetchPrepChecklists(
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
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: Colors.red,
              tooltip: 'Delete lift',
              onPressed: _deleteLift,
            ),
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: _openEdit,
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Details'),
              Tab(text: 'Customer'),
              Tab(text: 'Locations'),
              Tab(text: 'Service'),
              Tab(text: 'Prep History'),
              Tab(text: 'Photos'),
              Tab(text: 'All Changes'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildDetailsTab(),
            _buildCustomerTab(),
            _buildHistoryTab(),
            _buildServiceTab(),
            _buildPrepHistoryTab(),
            _buildPhotosTab(),
            _buildChangeHistoryTab(),
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
/// PHOTO FULL-SCREEN VIEWER
/// =======================

class _PhotoViewScreen extends StatelessWidget {
  final String url;
  const _PhotoViewScreen({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const Center(child: CircularProgressIndicator(color: Colors.white)),
            errorBuilder: (_, __, e) => const Center(
              child: Icon(Icons.broken_image, color: Colors.white, size: 64),
            ),
          ),
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
  final String? prefillServiceType;
  final String? prefillCustomerName;
  final String? prefillDate;
  final bool offerInvoicePhoto;

  const LiftServiceFormScreen({
    super.key,
    required this.lift,
    this.prefillServiceType,
    this.prefillCustomerName,
    this.prefillDate,
    this.offerInvoicePhoto = false,
  });

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

  XFile? _invoicePhoto;
  bool _uploadingPhoto = false;
  bool _saving = false;
  bool _generatingSummary = false;

  String get _serialForApi => widget.lift.serialNumber;

  Future<void> _generateSummary() async {
    final qbId = widget.lift.qbCustomerId;
    if (qbId.isEmpty) return;
    setState(() => _generatingSummary = true);
    try {
      final summary = await QuickBooksService.fetchCustomerSummary(qbId);
      if (!mounted) return;
      if (summary == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not fetch QB data — check connection')),
        );
        return;
      }
      final lift = widget.lift;
      final liftDesc = [lift.brand, lift.series, lift.orientation]
          .where((s) => s.isNotEmpty && s != 'N/A').join(' ');
      final lines = <String>[
        '=== Service Call Summary ===',
        if (liftDesc.isNotEmpty) 'Lift: $liftDesc',
        if (lift.serialNumber.isNotEmpty) 'Serial: ${lift.serialNumber}',
        if (lift.installDate.isNotEmpty) 'Installed: ${lift.installDate}',
        if (lift.warrantyExpiry.isNotEmpty) 'Warranty expires: ${lift.warrantyExpiry}',
        '',
        'Customer: ${summary.customerName}',
        if (summary.balance > 0)
          'Outstanding balance: \$${summary.balance.toStringAsFixed(2)}',
        if (summary.notes.isNotEmpty) ...[
          '',
          'QB Notes:',
          summary.notes,
        ],
        if (summary.invoices.isNotEmpty) ...[
          '',
          'Recent invoices:',
          ...summary.invoices.map((inv) =>
            '  ${inv.date}  \$${inv.amount.toStringAsFixed(2)}'
            '${inv.balance > 0 ? '  (balance \$${inv.balance.toStringAsFixed(2)})' : ''}'
            '${inv.note.isNotEmpty ? ' — ${inv.note}' : ''}'),
        ],
      ];
      final generated = lines.join('\n');
      final existing = _notesController.text.trim();
      _notesController.text = existing.isEmpty ? generated : '$existing\n\n$generated';
    } finally {
      if (mounted) setState(() => _generatingSummary = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.prefillServiceType != null) _typeController.text = widget.prefillServiceType!;
    if (widget.prefillCustomerName != null) _customerController.text = widget.prefillCustomerName!;
    if (widget.prefillDate != null) _dateController.text = widget.prefillDate!;
  }

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
      'name': prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
      'email': AuthService.instance.profile?.email ?? '',
    };
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final user = await _loadUser();
    final userEmail = user['email'] ?? '';
    final userName = user['name'] ?? '';
    if (userName.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Please set your name from the main screens.')),
      );
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      await sbAddLiftService(
        userEmail: userEmail,
        userName: userName,
        serialNumber: _serialForApi,
        serviceDate: _dateController.text.trim(),
        serviceType: _typeController.text.trim(),
        description: _descriptionController.text.trim(),
        invoiceNumber: _invoiceController.text.trim(),
        jobRef: _jobRefController.text.trim(),
        customerName: _customerController.text.trim(),
        notes: _notesController.text.trim(),
      );

      if (!mounted) return;

      // If there's already a photo selected, upload it now
      if (_invoicePhoto != null) {
        setState(() => _uploadingPhoto = true);
        try {
          await sbUploadLiftPhoto(
            liftId: widget.lift.liftId,
            imageFile: _invoicePhoto!,
          );
        } catch (_) {
          // Non-fatal — record was already saved
        } finally {
          if (mounted) setState(() => _uploadingPhoto = false);
        }
      } else if (widget.offerInvoicePhoto) {
        // Offer to attach photo now
        final attach = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Attach invoice photo?'),
            content: const Text('Would you like to attach a photo of the invoice to this lift record?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                child: const Text('Attach Photo'),
              ),
            ],
          ),
        );
        if (attach == true && mounted) {
          final picked = await ImagePicker().pickImage(source: ImageSource.camera);
          if (picked != null && mounted) {
            setState(() => _uploadingPhoto = true);
            try {
              await sbUploadLiftPhoto(
                liftId: widget.lift.liftId,
                imageFile: picked,
              );
            } catch (_) {
              // Non-fatal
            } finally {
              if (mounted) setState(() => _uploadingPhoto = false);
            }
          }
        }
      }

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
      setState(() => _saving = false);
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
              maxLines: 6,
            ),
            if (widget.lift.qbCustomerId.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: _generatingSummary
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome_outlined, size: 16),
                  label: Text(
                    _generatingSummary ? 'Generating…' : 'Generate Customer Summary',
                    style: GoogleFonts.nunito(fontSize: 13),
                  ),
                  onPressed: _generatingSummary ? null : _generateSummary,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kBrandGreen,
                    side: BorderSide(color: kBrandGreen.withValues(alpha: 0.5)),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            // Invoice photo picker
            if (widget.offerInvoicePhoto || _invoicePhoto != null) ...[
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await ImagePicker().pickImage(source: ImageSource.camera);
                  if (picked != null) setState(() => _invoicePhoto = picked);
                },
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(_invoicePhoto != null ? 'Invoice photo selected ✓' : 'Attach invoice photo'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                  foregroundColor: _invoicePhoto != null ? kBrandGreen : null,
                  side: _invoicePhoto != null ? const BorderSide(color: kBrandGreen) : null,
                ),
              ),
              const SizedBox(height: 12),
            ],
            ElevatedButton.icon(
              onPressed: _saving || _uploadingPhoto ? null : _save,
              icon: _saving || _uploadingPhoto
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: Text(_uploadingPhoto ? 'Uploading photo...' : _saving ? 'Saving...' : 'Save Service Record'),
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

  // Brand/series/fold maps derived from stairlift inventory sheet.
  List<String> _brands = [];
  Map<String, List<String>> _seriesByBrand = {};
  Map<String, List<String>> _foldByBrandSeriesOrientation = {};

  String? _selectedBrand;
  String? _selectedSeries;
  String? _selectedOrientation;
  String? _selectedFoldType;

  String _condition = 'New';
  String _status = 'New';
  String _preppedStatus = 'Needs prepping';
  String _cleanBatteriesStatus = '';
  String _railType = 'Straight';
  String? _acquisitionSource = 'Private Pay';

  // Customer link
  String? _linkedCustomerId;
  String? _linkedCustomerName;
  String? _linkedQbCustomerId;

  final _serialController = TextEditingController();
  final _binNumberController = TextEditingController();
  final _dateAcquiredController = TextEditingController();
  final _currentLocationController = TextEditingController();
  final _currentJobController = TextEditingController();
  final _installDateController = TextEditingController();
  final _installerNameController = TextEditingController();
  final _lastPrepDateController = TextEditingController();
  final _notesController = TextEditingController();
  final _buybackPriceController = TextEditingController();

  bool _saving = false;

  bool get _isEditing => widget.existing != null;

  Future<void> _deleteLift() async {
    final lift = widget.existing!;
    final label = [lift.brand, lift.series].where((s) => s.isNotEmpty).join(' ');
    final snLabel = lift.serialNumber.isNotEmpty ? ' (SN: ${lift.serialNumber})' : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete lift?'),
        content: Text(
          'Permanently delete $label$snLabel from the system?\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await sbDeleteLift(
        liftId: lift.liftId,
        userEmail: AuthService.instance.profile?.email ?? '',
        userName: prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lift deleted')));
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  void initState() {
    super.initState();

    final existing = widget.existing;
    if (existing != null) {
      _serialController.text = existing.serialNumber;
      _binNumberController.text = existing.binNumber;
      _dateAcquiredController.text = normalizeDateDisplay(existing.dateAcquired);
      _currentLocationController.text = existing.currentLocation;
      _currentJobController.text = existing.currentJob;
      _installDateController.text = normalizeDateDisplay(existing.installDate);
      _installerNameController.text = existing.installerName;
      _lastPrepDateController.text = normalizeDateDisplay(existing.lastPrepDate);
      _notesController.text = existing.notes;

      const validConditions = [
        'New', 'Used - Like New', 'Used - Standard', 'Used - Not Great', 'Used - Shit',
      ];
      _condition = validConditions.contains(existing.condition) ? existing.condition : 'New';
      _status = existing.status.isNotEmpty ? existing.status : 'New';
      _preppedStatus = existing.preppedStatus.isNotEmpty
          ? existing.preppedStatus
          : 'Needs prepping';
      _cleanBatteriesStatus = existing.cleanBatteriesStatus;
      _railType = existing.railType.isEmpty ? 'Straight' : existing.railType;
      _acquisitionSource = existing.acquisitionSource.isEmpty ? 'Private Pay' : existing.acquisitionSource;
      if (existing.buybackPrice != null) {
        _buybackPriceController.text = existing.buybackPrice!.toStringAsFixed(0);
      }
      _linkedCustomerId = existing.customerId.isEmpty ? null : existing.customerId;
      _linkedCustomerName = existing.customerName.isEmpty ? null : existing.customerName;
      _linkedQbCustomerId = existing.qbCustomerId.isEmpty ? null : existing.qbCustomerId;
    }

    _loadInventory();
  }

  Future<void> _loadInventory() async {
    try {
      final data = await sbFetchInventory();

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
          // Brooks/Acorn folds don't use handedness
          final isAcornBrooks = s.brand.toLowerCase().contains('acorn') ||
              s.brand.toLowerCase().contains('brooks');
          final isHandedness = s.foldType.toLowerCase() == 'left' ||
              s.foldType.toLowerCase() == 'right';
          if (!(isAcornBrooks && isHandedness)) {
            foldSets[bsoKey]!.add(s.foldType);
          }
        }
      }

      final brands = brandsSet.toList()..sort();
      final seriesByBrand = <String, List<String>>{};
      final orientationByBrandSeries = <String, List<String>>{};
      final foldByBrandSeriesOrientation = <String, List<String>>{};

      // Use hardcoded series lists instead of inventory-derived (ensures all series appear)
      for (final brand in brandsSet) {
        if (_seriesByBrandHardcoded.containsKey(brand)) {
          seriesByBrand[brand] = _seriesByBrandHardcoded[brand]!;
        } else {
          // Fallback to inventory-derived if brand not in hardcoded map
          seriesByBrand[brand] = sortSeriesList((seriesSets[brand] ?? <String>{}).toList());
        }
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

        // Orientation is always LH / RH / N/A — restore directly
        if (['LH', 'RH', 'N/A'].contains(e.orientation)) {
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
        _foldByBrandSeriesOrientation = foldByBrandSeriesOrientation;

        _selectedBrand =
            selectedBrand ?? (brands.isNotEmpty ? brands.first : null);

        if (_selectedBrand != null) {
          final seriesList = _seriesByBrand[_selectedBrand!] ?? [];
          _selectedSeries =
              selectedSeries ?? (seriesList.isNotEmpty ? seriesList.first : null);
          // Orientation is always LH / RH / N/A
          _selectedOrientation = selectedOrientation ?? 'LH';
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
      'name': prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
      'email': AuthService.instance.profile?.email ?? '',
    };
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedBrand == null ||
        _selectedSeries == null ||
        _selectedOrientation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select brand, series, and orientation.')),
      );
      return;
    }

    final user = await _loadUser();
    final userEmail = user['email'] ?? '';
    final userName = user['name'] ?? '';
    if (userName.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Please set your name from the main screens.')),
      );
      return;
    }

    // Check for serial number edit confirmation (only if editing and serial changed)
    if (_isEditing) {
      final originalSerial = widget.existing!.serialNumber;
      final newSerial = _serialController.text.trim();

      if (originalSerial.isNotEmpty &&
          newSerial.isNotEmpty &&
          originalSerial != newSerial) {
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm Serial Number Change'),
            content: Text(
              'You are changing the serial number from "$originalSerial" to "$newSerial".\n\n'
              'This will affect the lift history and tracking. Are you sure you want to continue?'
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );

        if (confirmed != true) return;
      }
    }

    // Check for duplicate serial number (only for new lifts)
    if (!_isEditing) {
      final serialNumber = _serialController.text.trim();
      if (serialNumber.isNotEmpty) {
        setState(() {
          _saving = true;
        });

        try {
          final existingLift = await sbCheckDuplicateSerial(serialNumber);

          if (existingLift != null) {
            if (!mounted) {
              setState(() {
                _saving = false;
              });
              return;
            }

            final action = await showDialog<String>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Duplicate Serial Number'),
                content: Text(
                  'A lift with serial number "$serialNumber" already exists.\n\n'
                  'Brand: ${existingLift.brand}\n'
                  'Series: ${existingLift.series}\n'
                  'Status: ${existingLift.status}\n\n'
                  'Would you like to edit the existing lift instead?'
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop('cancel'),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop('edit'),
                    child: const Text('Go to Existing Lift'),
                  ),
                ],
              ),
            );

            setState(() {
              _saving = false;
            });

            if (action == 'edit') {
              if (!mounted) return;
              // Close this form and open the existing lift's form
              Navigator.of(context).pop(false);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LiftFormScreen(existing: existingLift),
                ),
              );
            }
            return;
          }
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error checking serial number: $e')),
          );
          setState(() {
            _saving = false;
          });
          return;
        }
      }
    }

    setState(() {
      _saving = true;
    });

    try {
      final previousStatus = widget.existing?.status ?? '';
      final savedLiftId = await sbUpsertLift(
        userEmail: userEmail,
        userName: userName,
        liftId: widget.existing?.liftId,
        serialNumber: _serialController.text.trim(),
        brand: _selectedBrand!,
        series: _selectedSeries!,
        orientation: _selectedOrientation!,
        foldType: _selectedFoldType ?? '',
        condition: _condition,
        status: _status,
        preppedStatus: _preppedStatus,
        currentLocation: _currentLocationController.text.trim(),
        currentJob: _currentJobController.text.trim(),
        dateAcquired: _dateAcquiredController.text.trim(),
        installDate: _installDateController.text.trim(),
        installerName: _installerNameController.text.trim(),
        lastPrepDate: _lastPrepDateController.text.trim(),
        notes: _notesController.text.trim(),
        binNumber: _binNumberController.text.trim(),
        cleanBatteriesStatus: _cleanBatteriesStatus,
        railType: _railType,
        acquisitionSource: _acquisitionSource ?? '',
        customerId: _linkedCustomerId ?? '',
        customerName: _linkedCustomerName ?? '',
        qbCustomerId: _linkedQbCustomerId ?? '',
        buybackPrice: double.tryParse(_buybackPriceController.text.trim()),
      );

      // Customer history + QB note — fire-and-forget, don't block save
      final prevCustomer = widget.existing?.qbCustomerId ?? '';
      final newQbId = _linkedQbCustomerId ?? '';
      final newName = _linkedCustomerName ?? '';
      if (newQbId != prevCustomer) {
        if (prevCustomer.isNotEmpty) {
          // Customer changed — mark old one as removed
          unawaited(sbLiftCustomerRemoved(liftId: savedLiftId));
        }
        if (newQbId.isNotEmpty) {
          // New customer assigned — write history and append QB note
          unawaited(sbLiftCustomerAssigned(
            liftId: savedLiftId,
            customerName: newName,
            qbCustomerId: newQbId,
          ));
          final brand = _selectedBrand ?? '';
          final series = _selectedSeries ?? '';
          final serial = _serialController.text.trim();
          final note = 'Lift assigned: $brand $series'
              '${serial.isNotEmpty ? ' (SN $serial)' : ''}'
              '${_installDateController.text.trim().isNotEmpty ? ', installed ${_installDateController.text.trim()}' : ''}';
          unawaited(QuickBooksService.appendNoteToCustomer(
            qbCustomerId: newQbId,
            note: note,
          ));
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isEditing ? 'Lift updated' : 'New lift added'),
        ),
      );

      // If status was changed to Assigned, offer to link to a schedule job
      final statusChangedToAssigned = _status == 'Assigned' && previousStatus != 'Assigned';
      final isNewAssigned = !_isEditing && _status == 'Assigned';
      if ((statusChangedToAssigned || isNewAssigned) && mounted) {
        final linkNow = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Attach to a schedule job?'),
            content: const Text(
              'This lift is now Assigned. Would you like to link it to an upcoming install job in the schedule?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Later'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                child: const Text('Link to Job'),
              ),
            ],
          ),
        );
        if (linkNow == true && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _LinkLiftToJobScreen(liftId: savedLiftId),
            ),
          );
        }
      }

      if (!mounted) return;
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
    _binNumberController.dispose();
    _dateAcquiredController.dispose();
    _currentLocationController.dispose();
    _currentJobController.dispose();
    _installDateController.dispose();
    _installerNameController.dispose();
    _lastPrepDateController.dispose();
    _notesController.dispose();
    _buybackPriceController.dispose();
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
        actions: [
          if (_isEditing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: Colors.red.shade300,
              tooltip: 'Delete lift',
              onPressed: _deleteLift,
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(12.0),
          children: [
            Row(
              children: [
                Expanded(
                  flex: _condition != 'New' ? 2 : 1,
                  child: TextFormField(
                    controller: _serialController,
                    decoration: const InputDecoration(
                      labelText: 'Serial number',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (_condition != 'New') ...[
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: TextFormField(
                      controller: _binNumberController,
                      decoration: const InputDecoration(
                        labelText: 'Bin #',
                        border: OutlineInputBorder(),
                        hintText: 'Optional',
                      ),
                    ),
                  ),
                ],
              ],
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
                  // Harmar Helix is always curved
                  if (_selectedBrand == 'Harmar' && value == 'Helix') {
                    _railType = 'Curved';
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            // Rail type toggle (Straight / Curved)
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'Straight', label: Text('Straight')),
                      ButtonSegment(value: 'Curved', label: Text('Curved')),
                    ],
                    selected: {_railType},
                    onSelectionChanged: (sel) => setState(() => _railType = sel.first),
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) return kBrandGreen;
                        return null;
                      }),
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) return Colors.white;
                        return null;
                      }),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Job type (payer) dropdown
            DropdownButtonFormField<String>(
              value: _acquisitionSource,
              items: const [
                DropdownMenuItem(value: 'VA', child: Text('VA')),
                DropdownMenuItem(value: 'CCALS', child: Text('CCALS')),
                DropdownMenuItem(value: 'NaviCare', child: Text('NaviCare')),
                DropdownMenuItem(value: 'Summit', child: Text('Summit')),
                DropdownMenuItem(value: 'Fallon', child: Text('Fallon')),
                DropdownMenuItem(value: 'Mass Health', child: Text('Mass Health')),
                DropdownMenuItem(value: 'Private Pay', child: Text('Private Pay')),
                DropdownMenuItem(value: 'Buyback', child: Text('Buyback')),
                DropdownMenuItem(value: 'Other', child: Text('Other')),
              ],
              decoration: const InputDecoration(
                labelText: 'Acquisition Source (optional)',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _acquisitionSource = value),
            ),
            if (_acquisitionSource == 'Buyback') ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _buybackPriceController,
                decoration: const InputDecoration(
                  labelText: 'Buyback Price Paid (\$)',
                  border: OutlineInputBorder(),
                  prefixText: '\$ ',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
            ],
            const SizedBox(height: 12),
            // Customer link
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () async {
                final result = await showSearch<_QbCustomerResult?>(
                  context: context,
                  delegate: _CustomerSearchDelegate(),
                );
                if (result != null) {
                  setState(() {
                    _linkedCustomerId = null; // QB-linked lifts use qbCustomerId, not local UUID
                    _linkedCustomerName = result.name;
                    _linkedQbCustomerId = result.qbCustomerId;
                  });
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Linked Customer (optional)',
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.search),
                ),
                child: Text(
                  _linkedCustomerName ?? 'Tap to search customers…',
                  style: TextStyle(
                    color: _linkedCustomerName != null ? Colors.black87 : Colors.grey[500],
                  ),
                ),
              ),
            ),
            if (_linkedCustomerId != null) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() {
                    _linkedCustomerId = null;
                    _linkedCustomerName = null;
                    _linkedQbCustomerId = null;
                  }),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.red,
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Remove link', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedOrientation,
              items: const ['LH', 'RH', 'N/A']
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
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedFoldType,
              items: const [
                DropdownMenuItem<String>(value: '', child: Text('— None —')),
                DropdownMenuItem<String>(value: 'No Fold', child: Text('No Fold')),
                DropdownMenuItem<String>(value: 'Auto Fold', child: Text('Auto Fold')),
                DropdownMenuItem<String>(value: 'Manual Fold', child: Text('Manual Fold')),
              ],
              decoration: const InputDecoration(
                labelText: 'Fold type (optional)',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _selectedFoldType = value == '' ? null : value;
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _condition,
              items: const [
                DropdownMenuItem<String>(value: 'New', child: Text('New')),
                DropdownMenuItem<String>(value: 'Used - Like New', child: Text('Used - Like New')),
                DropdownMenuItem<String>(value: 'Used - Standard', child: Text('Used - Standard')),
                DropdownMenuItem<String>(value: 'Used - Not Great', child: Text('Used - Not Great')),
                DropdownMenuItem<String>(value: 'Used - Shit', child: Text('Used - Shit')),
              ],
              decoration: const InputDecoration(
                labelText: 'Condition',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _condition = value ?? 'New';
                  // Auto-set clean status when any used condition selected
                  if (_condition != 'New' && _cleanBatteriesStatus.isEmpty) {
                    _cleanBatteriesStatus = 'Needs Cleaning';
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _status,
              items: const [
                DropdownMenuItem<String>(
                  value: 'New',
                  child: Text('New'),
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
                  _status = value ?? 'New';
                  if (_status == 'New') {
                    _condition = 'New';
                  }
                  // Clear bin # when marking as Installed
                  if (_status == 'Installed') {
                    _binNumberController.clear();
                  }
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
                  value: 'Needs repair',
                  child: Text('Needs repair'),
                ),
                DropdownMenuItem<String>(
                  value: 'Prepped',
                  child: Text('Prepped'),
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
                    binNumber: widget.existing?.binNumber ?? '',
                    cleanBatteriesStatus: _cleanBatteriesStatus,
                    railType: _railType,
                    acquisitionSource: _acquisitionSource ?? '',
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
                      _lastPrepDateController.text = formatDate(DateTime.now());
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
            DropdownButtonFormField<String>(
              value: _cleanBatteriesStatus.isEmpty ? null : _cleanBatteriesStatus,
              items: const [
                DropdownMenuItem<String>(value: 'Needs Cleaning', child: Text('Needs Cleaning')),
                DropdownMenuItem<String>(value: 'Clean', child: Text('Clean')),
              ],
              decoration: const InputDecoration(
                labelText: 'Clean/Batteries',
                border: OutlineInputBorder(),
                hintText: 'Optional',
              ),
              onChanged: (value) async {
                final prev = _cleanBatteriesStatus;
                setState(() {
                  _cleanBatteriesStatus = value ?? '';
                });
                // Log a service record when marked Clean
                if (value == 'Clean' && prev != 'Clean') {
                  final user = await _loadUser();
                  final serial = _serialController.text.trim();
                  if (serial.isNotEmpty && user['name']!.isNotEmpty) {
                    try {
                      await sbAddLiftService(
                        userEmail: user['email'] ?? '',
                        userName: user['name'] ?? '',
                        serialNumber: serial,
                        serviceDate: formatDate(DateTime.now()),
                        serviceType: 'Clean',
                        description: 'Cleaning completed',
                        invoiceNumber: '',
                        jobRef: '',
                        customerName: '',
                      );
                    } catch (_) {
                      // Non-blocking — don't fail the form save over this
                    }
                  }
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
                labelText: 'Date acquired (MM/DD/YYYY)',
                hintText: 'MM/DD/YYYY',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.datetime,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _installDateController,
              decoration: const InputDecoration(
                labelText: 'Install date (MM/DD/YYYY)',
                hintText: 'MM/DD/YYYY',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.datetime,
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
                labelText: 'Last prep date (MM/DD/YYYY)',
                hintText: 'MM/DD/YYYY',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.datetime,
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

/// =======================
/// SCHEDULE SCREEN
/// =======================

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  List<QbtScheduleEvent> _events = [];
  Map<String, QbtUser> _users = {};
  Set<String> _completedIds = {};
  bool _loading = true;
  String? _error;

  // Search state
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  bool _searchActive = false;
  List<QbtScheduleEvent> _searchResults = [];
  bool _isSearchMode = false;
  bool _isSearchLoading = false;
  String _sortBy = 'newest'; // 'newest' | 'oldest'
  Timer? _searchDebounce;
  static const _kSearchDebounce = Duration(milliseconds: 400);

  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _dayKeys = {};

  // Live TSheets window: last 7 days through 60 days ahead
  static const int _liveWindowDays = 7;
  static const int _daysAhead = 60;
  // Active view shows history up to 30 days back
  static const int _activeHistoryDays = 30;

  DateTime get _liveRangeStart {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).subtract(Duration(days: _liveWindowDays));
  }

  DateTime get _liveRangeEnd {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).add(const Duration(days: _daysAhead));
  }

  DateTime get _archiveCutoff => _liveRangeStart;

  DateTime get _activeHistoryStart {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).subtract(const Duration(days: _activeHistoryDays));
  }

  // Month name → number map used for date parsing
  static const Map<String, int> _monthMap = {
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        qbtFetchScheduleEvents(start: _liveRangeStart, end: _liveRangeEnd),
        sbFetchScheduleHistory(before: _archiveCutoff, after: _activeHistoryStart),
        qbtFetchUsers(),
        sbFetchCompletedEventIds(),
      ]);
      if (!mounted) return;
      final liveEvents = results[0] as List<QbtScheduleEvent>;
      final archivedEvents = results[1] as List<QbtScheduleEvent>;
      final merged = [...archivedEvents, ...liveEvents]
        ..sort((a, b) => a.start.compareTo(b.start));
      setState(() {
        _events = merged;
        _users = results[2] as Map<String, QbtUser>;
        _completedIds = results[3] as Set<String>;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToToday(animate: false));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  String _dayKey(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  /// Scroll to today. Uses a two-pass approach:
  /// 1. Estimate offset from item counts to get roughly the right position.
  /// 2. After the frame renders, use the GlobalKey to fine-tune with ensureVisible.
  void _scrollToToday({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final items = _listItems;
    final todayKey = _dayKey(DateTime.now());

    // Count items before today for the initial estimate
    double offset = 0;
    for (final item in items) {
      if (item is String) {
        if (item == todayKey) break;
        offset += 46.0;
      } else {
        offset += 70.0;
      }
    }

    final maxExtent = _scrollController.position.maxScrollExtent;
    final target = offset.clamp(0.0, maxExtent);

    if (animate) {
      _scrollController.animateTo(target,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    } else {
      _scrollController.jumpTo(target);
    }

    // Second pass: once the target area is rendered, ensureVisible fine-tunes it
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final gk = _dayKeys[todayKey];
      if (gk?.currentContext != null) {
        Scrollable.ensureVisible(
          gk!.currentContext!,
          alignment: 0.0,
          duration: animate
              ? const Duration(milliseconds: 200)
              : Duration.zero,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void _onSearchChanged(String v) {
    setState(() => _searchQuery = v);
    _searchDebounce?.cancel();
    if (v.trim().isEmpty) {
      setState(() {
        _isSearchMode = false;
        _isSearchLoading = false;
        _searchResults = [];
      });
      return;
    }
    setState(() => _isSearchLoading = true);
    _searchDebounce = Timer(_kSearchDebounce, _performSearch);
  }

  Future<void> _performSearch() async {
    final query = _searchQuery.trim();
    if (query.isEmpty) return;

    final parsed = _parseDateRange(query);
    final dateRange = parsed.$1; // (DateTime start, DateTime end)?
    final textQuery = parsed.$2;

    try {
      final historyResults = await sbSearchScheduleHistory(
        query: textQuery,
        startDate: dateRange?.$1,
        endDate: dateRange?.$2,
        newestFirst: _sortBy == 'newest',
      );

      final liveFiltered = _filterLiveForSearch(textQuery, dateRange);

      // Merge: live events first (prefer fresh data), then history — dedup by ID
      final seen = <String>{};
      final merged = <QbtScheduleEvent>[];
      for (final e in [...liveFiltered, ...historyResults]) {
        if (seen.add(e.id)) merged.add(e);
      }

      merged.sort((a, b) => _sortBy == 'newest'
          ? b.start.compareTo(a.start)
          : a.start.compareTo(b.start));

      if (!mounted) return;
      setState(() {
        _searchResults = merged;
        _isSearchMode = true;
        _isSearchLoading = false;
      });
      // Scroll to bottom so newest results are visible
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSearchLoading = false);
    }
  }

  /// Filter the in-memory live events using the same AND-across-terms logic
  /// as the Supabase query, plus optional date range bounds.
  List<QbtScheduleEvent> _filterLiveForSearch(
    String textQuery,
    (DateTime, DateTime)? dateRange,
  ) {
    return _events.where((e) {
      if (dateRange != null) {
        final local = e.start.toLocal();
        if (local.isBefore(dateRange.$1) || local.isAfter(dateRange.$2)) return false;
      }
      if (textQuery.isEmpty) return true;
      final terms = textQuery.toLowerCase()
          .split(RegExp(r'\s+'))
          .where((t) => t.length >= 2);
      for (final term in terms) {
        final inTitle    = e.title.toLowerCase().contains(term);
        final inNotes    = e.notes.toLowerCase().contains(term);
        final inLocation = e.location.toLowerCase().contains(term);
        final inNames    = e.assignedUserIds.any(
          (id) => (_users[id]?.displayName ?? '').toLowerCase().contains(term),
        );
        if (!inTitle && !inNotes && !inLocation && !inNames) return false;
      }
      return true;
    }).toList();
  }

  /// Parse a date range out of [query].
  /// Returns `((startDate, endDate)?, remainingText)`.
  /// If no date is detected, the first element is null and the full query is returned as text.
  ///
  /// Handles: "april 21 2025", "oct 30 2019", "4/21/25", "4/21/2025",
  ///          "april 2025" (whole month), "2024" (whole year).
  ((DateTime, DateTime)?, String) _parseDateRange(String query) {
    var q = query.toLowerCase().trim();

    String strip(String src, Pattern pat) =>
        src.replaceAll(pat, ' ').replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    (DateTime, DateTime) dayRange(int y, int mo, int d) =>
        (DateTime(y, mo, d), DateTime(y, mo, d, 23, 59, 59));

    // MM/DD/YY or MM/DD/YYYY
    final slash = RegExp(r'\b(\d{1,2})/(\d{1,2})/(\d{2,4})\b');
    var m = slash.firstMatch(q);
    if (m != null) {
      var y = int.parse(m.group(3)!);
      if (y < 100) y += 2000;
      return (dayRange(y, int.parse(m.group(1)!), int.parse(m.group(2)!)), strip(q, slash));
    }

    // Month name patterns
    for (final entry in _monthMap.entries) {
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

    // "2024" → whole year
    final yearPat = RegExp(r'\b(20\d{2})\b');
    m = yearPat.firstMatch(q);
    if (m != null) {
      final y = int.parse(m.group(1)!);
      return ((DateTime(y, 1, 1), DateTime(y, 12, 31, 23, 59, 59)), strip(q, yearPat));
    }

    // No date found — full query is text
    return (null, q);
  }

  // ---------------------------------------------------------------------------
  // List building
  // ---------------------------------------------------------------------------

  /// Flat list of [String dayKey, QbtScheduleEvent, ...] for ListView.
  /// Search mode: uses _searchResults, newest day at top.
  /// Active view: uses _events, chronological, today auto-scrolled into view.
  List<dynamic> get _listItems {
    final events = _isSearchMode ? _searchResults : _events;
    final grouped = <String, List<QbtScheduleEvent>>{};
    for (final e in events) {
      grouped.putIfAbsent(_dayKey(e.start), () => []).add(e);
    }
    var sortedDays = grouped.keys.toList()..sort();
    if (_isSearchMode && _sortBy == 'newest') {
      sortedDays = sortedDays.reversed.toList();
    }
    final items = <dynamic>[];
    for (final day in sortedDays) {
      items.add(day);
      grouped[day]!.sort((a, b) => a.start.compareTo(b.start));
      items.addAll(grouped[day]!);
    }
    return items;
  }

  String _formatDayHeader(String dayKey) {
    final parts = dayKey.split('-');
    final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
    const dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'];
    return '${dayNames[dt.weekday - 1]}, ${monthNames[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  bool _isToday(String dayKey) => dayKey == _dayKey(DateTime.now());

  Color _parseColor(String hex) {
    try {
      final h = hex.replaceAll('#', '');
      return Color(int.parse('FF$h', radix: 16));
    } catch (_) {
      return kBrandGreen;
    }
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final m = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  String _assignedNames(QbtScheduleEvent event) {
    if (event.assignedUserIds.isEmpty) return '';
    return event.assignedUserIds
        .map((id) => _users[id]?.displayName ?? 'Unknown')
        .join(', ');
  }

  Future<void> _onToggleComplete(QbtScheduleEvent event) async {
    final next = !_completedIds.contains(event.id);
    setState(() {
      if (next) {
        _completedIds.add(event.id);
      } else {
        _completedIds.remove(event.id);
      }
    });
    await sbSetEventCompleted(eventId: event.id, completed: next);
    if (next && mounted) {
      final meta = await sbGetEventMeta(event.id);
      final jobType = meta['job_type'] as String?;
      final liftIds = (meta['lift_ids'] as List<String>?) ?? [];

      if ((jobType == 'Ramp Install' || jobType == 'Ramp Removal') && liftIds.isEmpty && mounted) {
        final isInstall = jobType == 'Ramp Install';
        final fundingSource = (meta['funding_source'] as String?) ?? 'Private';
        final isCcals = fundingSource == 'CCALS';
        final confirm = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(isInstall ? 'Record ramp install?' : 'Record ramp removal?'),
            content: Text(
              isInstall
                  ? 'Select the ramps and quantities used on this job to deduct them from ${isCcals ? 'CCALS' : 'Able Home'} inventory.'
                  : 'Select the ramps and quantities recovered on this job to add them back to ${isCcals ? 'CCALS' : 'Able Home'} inventory.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                child: const Text('Open Form'),
              ),
            ],
          ),
        );
        if (confirm == true && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => JobAdjustmentScreen(
                initialJobRef: event.title,
                initialTabIndex: isInstall ? 0 : 1,
                isCcals: isCcals,
              ),
            ),
          );
        }
      }

      if (jobType != null && liftIds.isNotEmpty && mounted) {
        final prefs = await SharedPreferences.getInstance();
        final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';
        final userEmail = AuthService.instance.profile?.email ?? '';
        for (final liftId in liftIds) {
          final lift = await sbFetchLiftById(liftId);
          if (lift == null || !mounted) continue;
          String? newStatus;
          String dialogTitle = '';
          String dialogBody = '';
          String confirmLabel = '';
          if (jobType == 'Stairlift Install') {
            newStatus = 'Installed';
            dialogTitle = 'Mark lift as Installed?';
            dialogBody = 'Update ${lift.brand} ${lift.series} (SN: ${lift.serialNumber}) to Installed?';
            confirmLabel = 'Mark Installed';
          } else if (jobType == 'Stairlift Removal') {
            newStatus = 'Removed';
            dialogTitle = 'Mark lift as Removed?';
            dialogBody = 'Update ${lift.brand} ${lift.series} (SN: ${lift.serialNumber}) to Removed?';
            confirmLabel = 'Mark Removed';
          }
          if (newStatus != null && mounted) {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(dialogTitle),
                content: Text(dialogBody),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                    child: Text(confirmLabel),
                  ),
                ],
              ),
            );
            if (confirm == true && mounted) {
              await sbMarkLiftStatus(
                liftId: lift.liftId,
                newStatus: newStatus,
                userEmail: userEmail,
                userName: userName,
                note: 'Marked $newStatus via schedule event: ${event.title}',
                eventDate: newStatus == 'Installed' ? event.start : null,
              );
              if (newStatus == 'Installed' && lift.customerId.isEmpty && mounted) {
                await _offerCreateCustomerForLift(context, lift, event);
              }
            }
          } else if ((jobType == 'Stairlift Service' || jobType == 'Stairlift Annual Service') && mounted) {
            final serviceType = jobType == 'Stairlift Annual Service' ? 'Annual Service' : 'Service Call';
            final confirm = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Log service record?'),
                content: Text('Create a $serviceType record for ${lift.brand} ${lift.series}?'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                    child: const Text('Log Service'),
                  ),
                ],
              ),
            );
            if (confirm == true && mounted) {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LiftServiceFormScreen(
                    lift: lift,
                    prefillServiceType: serviceType,
                    prefillCustomerName: event.title,
                    prefillDate: formatDate(DateTime.now()),
                    offerInvoicePhoto: true,
                  ),
                ),
              );
            }
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Desktop layout for wide screens (laptops, etc.)
        if (constraints.maxWidth >= 800) {
          return Scaffold(
            backgroundColor: const Color(0xFFF2F4F2),
            body: ScheduleDesktopView(
              events: _events,
              users: _users,
              completedIds: _completedIds,
              isLoading: _loading,
              error: _error,
              onToggleComplete: _onToggleComplete,
              onRefresh: _load,
              onTapEvent: (event) async {
                final color = _parseColor(event.color);
                final changed = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ScheduleEventDetailScreen(
                      event: event,
                      users: _users,
                      assignedNames: _assignedNames(event),
                      color: color,
                      formatTime: _formatTime,
                    ),
                  ),
                );
                if (changed == true) _load();
                return changed;
              },
              onAddEvent: () async {
                final created = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ScheduleEventFormScreen(
                      users: _users,
                      initialDate: DateTime.now(),
                    ),
                  ),
                );
                if (created == true) _load();
              },
              activeStart: _activeHistoryStart,
              activeEnd: _liveRangeEnd,
            ),
          );
        }

        // Mobile layout (unchanged)
        return Scaffold(
          backgroundColor: const Color(0xFFF0F0F0),
          appBar: AppBar(
            backgroundColor: kBrandGreenDark,
            foregroundColor: Colors.white,
            title: _searchActive
                ? Theme(
                    data: ThemeData.dark(),
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      cursorColor: Colors.white,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 16),
                      decoration: const InputDecoration(
                        hintText:
                            'Search by name, date, address, assignee...',
                        hintStyle: TextStyle(color: Colors.white60),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                      onChanged: _onSearchChanged,
                    ),
                  )
                : const Text('Schedule',
                    style: TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              if (_searchActive)
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel',
                  onPressed: () {
                    _searchDebounce?.cancel();
                    setState(() {
                      _searchActive = false;
                      _searchQuery = '';
                      _searchController.clear();
                      _isSearchMode = false;
                      _isSearchLoading = false;
                      _searchResults = [];
                    });
                    WidgetsBinding.instance.addPostFrameCallback(
                        (_) => _scrollToToday(animate: false));
                  },
                )
              else ...[
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Search',
                  onPressed: () => setState(() => _searchActive = true),
                ),
                TextButton(
                  onPressed: _scrollToToday,
                  child:
                      const Text('Today', style: TextStyle(color: Colors.white)),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: _load,
                ),
              ],
            ],
          ),
          body: _buildBody(),
          floatingActionButton: FloatingActionButton(
            backgroundColor: kBrandGreen,
            foregroundColor: Colors.white,
            onPressed: () async {
              final created = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => ScheduleEventFormScreen(
                    users: _users,
                    initialDate: DateTime.now(),
                  ),
                ),
              );
              if (created == true) _load();
            },
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Text(
            '${_searchResults.length} result${_searchResults.length == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const Spacer(),
          DropdownButton<String>(
            value: _sortBy,
            underline: const SizedBox(),
            style: TextStyle(fontSize: 13, color: Colors.grey[800]),
            items: const [
              DropdownMenuItem(value: 'newest', child: Text('Newest first')),
              DropdownMenuItem(value: 'oldest', child: Text('Oldest first')),
            ],
            onChanged: (v) {
              if (v != null && v != _sortBy) {
                setState(() => _sortBy = v);
                _performSearch();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        if (_isSearchLoading) const LinearProgressIndicator(color: kBrandGreen),
        if (_isSearchMode) _buildSearchBar(),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    final items = _listItems;

    if (items.isEmpty) {
      return Center(
        child: Text(
          _isSearchMode
              ? (_isSearchLoading ? 'Searching...' : 'No results found')
              : 'No events scheduled',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];

          if (item is String) {
            // Date header row
            final isToday = _isToday(item);
            _dayKeys.putIfAbsent(item, () => GlobalKey());
            return Container(
              key: _dayKeys[item],
              padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
              child: Text(
                isToday ? 'Today — ${_formatDayHeader(item)}' : _formatDayHeader(item),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isToday ? kBrandGreen : Colors.grey[700],
                  letterSpacing: 0.1,
                ),
              ),
            );
          }

          final event = item as QbtScheduleEvent;
          final color = _parseColor(event.color);
          return _ScheduleEventCard(
            event: event,
            users: _users,
            color: color,
            formatTime: _formatTime,
            completed: _completedIds.contains(event.id),
            onToggleComplete: () => _onToggleComplete(event),
            onTap: () async {
              final changed = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => ScheduleEventDetailScreen(
                    event: event,
                    users: _users,
                    assignedNames: _assignedNames(event),
                    color: color,
                    formatTime: _formatTime,
                  ),
                ),
              );
              if (changed == true) _load();
            },
          );
        },
      ),
    );
  }
}

// InitialsAvatar is now in initials_avatar.dart (imported at top of file).

class _ScheduleEventCard extends StatelessWidget {
  final QbtScheduleEvent event;
  final Map<String, QbtUser> users;
  final Color color;
  final String Function(DateTime) formatTime;
  final bool completed;
  final VoidCallback onToggleComplete;
  final VoidCallback onTap;

  const _ScheduleEventCard({
    required this.event,
    required this.users,
    required this.color,
    required this.formatTime,
    required this.completed,
    required this.onToggleComplete,
    required this.onTap,
  });

  Widget _buildAvatarStack(Color eventColor) {
    final ids = event.assignedUserIds;
    if (ids.isEmpty) return const SizedBox.shrink();

    const double size = 30;
    const double overlap = 9;

    final names = ids.map((id) => users[id]?.displayName ?? '?').toList();
    final maxShow = names.length > 3 ? 2 : names.length;
    final extra = names.length - maxShow;
    final slotCount = maxShow + (extra > 0 ? 1 : 0);
    final totalWidth = size + (slotCount - 1) * (size - overlap);

    // Add 4px padding so border rings aren't clipped at the edges
    return SizedBox(
      width: totalWidth + 4,
      height: size + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = 0; i < maxShow; i++)
            Positioned(
              left: i * (size - overlap).toDouble(),
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: eventColor, width: 1.5),
                ),
                child: InitialsAvatar(
                  name: names[i],
                  size: size,
                  backgroundColor: const Color(0xFF2E2E2E),
                  textColor: Colors.white,
                ),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: maxShow * (size - overlap).toDouble(),
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E2E2E),
                  shape: BoxShape.circle,
                  border: Border.all(color: eventColor, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  '+$extra',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final startLocal = event.start.toLocal();
    final endLocal = event.end.toLocal();
    final sameTime = startLocal == endLocal;

    final timeLabel = event.allDay
        ? 'All day'
        : sameTime
            ? formatTime(startLocal)
            : '${formatTime(startLocal)} – ${formatTime(endLocal)}';

    final cardColor = completed ? Color.lerp(color, Colors.white, 0.45)! : color;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 1),
      child: Material(
        color: cardColor,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Left: title + time
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        event.title.isNotEmpty ? event.title : '(No title)',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          decoration: completed ? TextDecoration.lineThrough : null,
                          decorationColor: Colors.white70,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        timeLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withAlpha(200),
                          decoration: completed ? TextDecoration.lineThrough : null,
                          decorationColor: Colors.white60,
                        ),
                      ),
                      if (event.location.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.location_on_outlined,
                                size: 11, color: Colors.white.withAlpha(160)),
                            const SizedBox(width: 2),
                            Expanded(
                              child: Text(
                                event.location,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withAlpha(160)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Right: avatar stack
                _buildAvatarStack(cardColor),
                const SizedBox(width: 8),
                // Complete toggle
                GestureDetector(
                  onTap: onToggleComplete,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
                    child: Icon(
                      completed ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 26,
                      color: completed
                          ? Colors.white
                          : Colors.white.withAlpha(140),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Schedule event detail screen
// ---------------------------------------------------------------------------

class ScheduleEventDetailScreen extends StatefulWidget {
  final QbtScheduleEvent event;
  final Map<String, QbtUser> users;
  final String assignedNames;
  final Color color;
  final String Function(DateTime) formatTime;

  const ScheduleEventDetailScreen({
    super.key,
    required this.event,
    required this.users,
    required this.assignedNames,
    required this.color,
    required this.formatTime,
  });

  @override
  State<ScheduleEventDetailScreen> createState() =>
      _ScheduleEventDetailScreenState();
}

class _ScheduleEventDetailScreenState extends State<ScheduleEventDetailScreen> {
  bool _completed = false;
  bool _loadingComplete = true;
  bool _savingComplete = false;

  String? _jobType;
  bool _savingJobType = false;
  String? _eventSource;
  bool _savingSource = false;
  String _eventFundingSource = 'Private';
  List<LiftRecord> _linkedLifts = [];
  bool _loadingMeta = true;
  bool _savingLift = false;
  String? _linkedCustomerName;
  String? _linkedCustomerQbId;
  bool _savingCustomer = false;

  List<String> _eventPhotoUrls = [];
  bool _uploadingPhoto = false;

  @override
  void initState() {
    super.initState();
    _loadCompleted();
    _loadMeta();
  }

  Future<void> _loadCompleted() async {
    final ids = await sbFetchCompletedEventIds();
    if (!mounted) return;
    setState(() {
      _completed = ids.contains(widget.event.id);
      _loadingComplete = false;
    });
  }

  Future<void> _loadMeta() async {
    final meta = await sbGetEventMeta(widget.event.id);
    if (!mounted) return;
    final liftIds = (meta['lift_ids'] as List<String>?) ?? [];
    final lifts = <LiftRecord>[];
    for (final id in liftIds) {
      final l = await sbFetchLiftById(id);
      if (l != null) lifts.add(l);
    }
    final photos = await sbFetchEventPhotos(widget.event.id);
    if (!mounted) return;

    String? jobType = meta['job_type'] as String?;

    // If no job type is set, try to infer it from the event title
    if ((jobType == null || jobType.isEmpty) && widget.event.title.isNotEmpty) {
      final inferred = inferJobTypeFromTitle(widget.event.title);
      if (inferred != null) {
        jobType = inferred;
        // Persist the inferred type so it shows correctly everywhere
        await sbSetEventJobType(widget.event.id, inferred);
      }
    }

    if (!mounted) return;
    setState(() {
      _jobType = jobType;
      _eventSource = meta['source'] as String?;
      _eventFundingSource = (meta['funding_source'] as String?)?.isNotEmpty == true
          ? meta['funding_source'] as String
          : 'Private';
      _linkedLifts = lifts;
      _loadingMeta = false;
      _eventPhotoUrls = photos;
      final customer = meta['customer'] as Map<String, String>?;
      _linkedCustomerName = customer?['name'];
      _linkedCustomerQbId = customer?['qb_id'];
    });
  }

  Future<void> _linkCustomer() async {
    final result = await showSearch<_QbCustomerResult?>(
      context: context,
      delegate: _CustomerSearchDelegate(),
    );
    if (result == null || !mounted) return;
    setState(() => _savingCustomer = true);
    try {
      await sbSetEventCustomer(widget.event.id, name: result.name, qbId: result.qbCustomerId);
      if (mounted) setState(() {
        _linkedCustomerName = result.name;
        _linkedCustomerQbId = result.qbCustomerId;
        _savingCustomer = false;
      });
    } catch (_) {
      if (mounted) setState(() => _savingCustomer = false);
    }
  }

  Future<void> _unlinkCustomer() async {
    setState(() => _savingCustomer = true);
    try {
      await sbSetEventCustomer(widget.event.id, name: '', qbId: '');
      if (mounted) setState(() {
        _linkedCustomerName = null;
        _linkedCustomerQbId = null;
        _savingCustomer = false;
      });
    } catch (_) {
      if (mounted) setState(() => _savingCustomer = false);
    }
  }

  void _viewPhoto(BuildContext ctx, String url) {
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => _PhotoViewScreen(url: url),
    ));
  }

  Future<void> _addEventPhoto() async {
    final ImageSource source;
    if (kIsWeb) {
      source = ImageSource.gallery;
    } else {
      final picked = await showModalBottomSheet<ImageSource>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take photo'),
                onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Choose from library'),
                onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      source = picked;
    }

    final picker = ImagePicker();
    final List<XFile> imageFiles;
    if (source == ImageSource.gallery) {
      imageFiles = await picker.pickMultiImage(imageQuality: 90);
    } else {
      final single = await picker.pickImage(source: source, imageQuality: 90);
      imageFiles = single != null ? [single] : [];
    }
    if (imageFiles.isEmpty || !mounted) return;

    setState(() => _uploadingPhoto = true);
    try {
      for (final imageFile in imageFiles) {
        await sbUploadEventPhoto(
          eventId: widget.event.id,
          imageFile: imageFile,
          linkedLiftIds: _linkedLifts.map((l) => l.liftId).toList(),
          eventTitle: widget.event.title,
          eventDate: widget.event.start,
          eventLocation: widget.event.location,
        );
      }
      final urls = await sbFetchEventPhotos(widget.event.id);
      if (mounted) {
        setState(() {
          _eventPhotoUrls = urls;
          _uploadingPhoto = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(imageFiles.length == 1 ? 'Photo added' : '${imageFiles.length} photos added')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _uploadingPhoto = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  Future<void> _deleteEventPhoto(String url) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete photo?',
      content: 'This cannot be undone.',
    );
    if (!confirmed || !mounted) return;

    try {
      await sbDeleteEventPhoto(
        eventId: widget.event.id,
        fileUrl: url,
        linkedLiftIds: _linkedLifts.map((l) => l.liftId).toList(),
      );
      final urls = await sbFetchEventPhotos(widget.event.id);
      if (mounted) setState(() => _eventPhotoUrls = urls);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  Future<void> _linkLift(LiftRecord lift) async {
    if (_linkedLifts.any((l) => l.liftId == lift.liftId)) return;
    setState(() => _savingLift = true);
    final newIds = [..._linkedLifts.map((l) => l.liftId), lift.liftId];
    await sbSetEventLiftIds(widget.event.id, newIds);
    // Only set status to Assigned for stairlift install jobs; Service/Removal leave status unchanged
    if (_jobType == 'Stairlift Install') {
      final prefs = await SharedPreferences.getInstance();
      await sbMarkLiftStatus(
        liftId: lift.liftId,
        newStatus: 'Assigned',
        userEmail: AuthService.instance.profile?.email ?? '',
        userName: prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
        note: 'Assigned to schedule event: ${widget.event.title}',
      );
    }
    if (!mounted) return;
    // Reload meta to get updated lift data, then reset savingLift
    final meta = await sbGetEventMeta(widget.event.id);
    if (!mounted) return;
    final liftIds = (meta['lift_ids'] as List<String>?) ?? [];
    final lifts = <LiftRecord>[];
    for (final id in liftIds) {
      final l = await sbFetchLiftById(id);
      if (l != null) lifts.add(l);
    }
    if (!mounted) return;
    setState(() {
      _linkedLifts = lifts;
      _savingLift = false;
    });
  }

  Future<void> _unlinkLift(LiftRecord lift) async {
    setState(() => _savingLift = true);
    final newIds = _linkedLifts.where((l) => l.liftId != lift.liftId).map((l) => l.liftId).toList();
    await sbSetEventLiftIds(widget.event.id, newIds);
    // Only revert to New when unlinking from a stairlift install job
    if (_jobType == 'Stairlift Install') {
      final prefs = await SharedPreferences.getInstance();
      await sbMarkLiftStatus(
        liftId: lift.liftId,
        newStatus: 'New',
        userEmail: AuthService.instance.profile?.email ?? '',
        userName: prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '',
        note: 'Unlinked from schedule event: ${widget.event.title}',
      );
    }
    if (!mounted) return;
    setState(() {
      _linkedLifts = _linkedLifts.where((l) => l.liftId != lift.liftId).toList();
      _savingLift = false;
    });
  }

  Future<void> _openLiftPicker() async {
    final result = await showDialog(
      context: context,
      builder: (_) => const _LiftPickerDialog(),
    );
    if (!mounted) return;
    if (result is LiftRecord) {
      await _linkLift(result);
    } else if (result is _AddNewLiftSentinel) {
      // Open the lift form; only link if the user actually saved
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const LiftFormScreen()),
      );
      if (!mounted) return;
      if (saved == true) {
        final newest = await sbFetchNewestLift();
        if (!mounted) return;
        if (newest != null) await _linkLift(newest);
      }
    }
  }

  Future<void> _toggleCompleted() async {
    final next = !_completed;
    setState(() {
      _completed = next;
      _savingComplete = true;
    });
    try {
      await sbSetEventCompleted(eventId: widget.event.id, completed: next);
      debugPrint('[Complete] marked=$next linkedLifts=${_linkedLifts.length} jobType=$_jobType');
      // Smart completion: trigger downstream actions when marking complete.
      // Fires when lifts are linked, OR when it's an explicit ramp job type.
      final isRampJob = next && (_jobType == 'Ramp Install' || _jobType == 'Ramp Removal') && _linkedLifts.isEmpty;
      if (next && (_linkedLifts.isNotEmpty || isRampJob) && mounted) {
        await _handleSmartCompletion();
      }
      // Warn if completing a service job with no lift linked
      final isServiceType = _jobType == 'Stairlift Service' || _jobType == 'Stairlift Annual Service';
      if (next && isServiceType && _linkedLifts.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No lift linked — use the Link Lift button to attach one so a service record can be logged.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Complete] ERROR: $e');
      if (mounted) setState(() => _completed = !next);
    } finally {
      if (mounted) setState(() => _savingComplete = false);
    }
  }

  Future<void> _handleSmartCompletion() async {
    debugPrint('[SmartComplete] jobType=$_jobType lifts=${_linkedLifts.map((l) => l.liftId).toList()}');
    final prefs = await SharedPreferences.getInstance();
    final userName = prefs.getString('user_name') ?? AuthService.instance.profile?.name ?? '';
    final userEmail = AuthService.instance.profile?.email ?? '';

    // Ramp job: explicit Ramp Install or Ramp Removal type
    if (_jobType == 'Ramp Install' || _jobType == 'Ramp Removal') {
      if (!mounted) return;
      final isInstall = _jobType == 'Ramp Install';
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(isInstall ? 'Record ramp install?' : 'Record ramp removal?'),
          content: Text(
            isInstall
                ? 'Select the ramps and quantities used on this job to deduct them from inventory.'
                : 'Select the ramps and quantities recovered on this job to add them back to inventory.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
              child: const Text('Open Form'),
            ),
          ],
        ),
      );
      if (confirm == true && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => JobAdjustmentScreen(
              initialJobRef: widget.event.title,
              initialTabIndex: isInstall ? 0 : 1,
              isCcals: _eventFundingSource == 'CCALS',
            ),
          ),
        );
      }
      return;
    }

    for (final lift in List<LiftRecord>.from(_linkedLifts)) {
      debugPrint('[SmartComplete] processing lift=${lift.liftId} status=${lift.status}');
      if (!mounted) return;
      switch (_jobType) {
        case 'Stairlift Install':
          if (mounted) {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Mark lift as Installed?'),
                content: Text(
                  'Update ${lift.brand} ${lift.series} (SN: ${lift.serialNumber}) to Installed?',
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                    child: const Text('Mark Installed'),
                  ),
                ],
              ),
            );
            debugPrint('[SmartComplete] Install confirm=$confirm');
            if (confirm == true && mounted) {
              debugPrint('[SmartComplete] calling sbMarkLiftStatus Installed for ${lift.liftId}');
              await sbMarkLiftStatus(
                liftId: lift.liftId,
                newStatus: 'Installed',
                userEmail: userEmail,
                userName: userName,
                note: 'Marked installed via schedule event: ${widget.event.title}',
                eventDate: widget.event.start,
              );
              debugPrint('[SmartComplete] sbMarkLiftStatus done');
            }
          }
          break;

        case 'Stairlift Removal':
          if (mounted) {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Mark lift as Removed?'),
                content: Text(
                  'Update ${lift.brand} ${lift.series} (SN: ${lift.serialNumber}) to Removed?',
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                    child: const Text('Mark Removed'),
                  ),
                ],
              ),
            );
            if (confirm == true && mounted) {
              await sbMarkLiftStatus(
                liftId: lift.liftId,
                newStatus: 'Removed',
                userEmail: userEmail,
                userName: userName,
                note: 'Marked removed via schedule event: ${widget.event.title}',
              );
            }
          }
          break;

        case 'Stairlift Service':
        case 'Stairlift Annual Service':
          if (!mounted) return;
          final serviceType = _jobType == 'Stairlift Annual Service' ? 'Annual Service' : 'Service Call';
          final confirm = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Log service record?'),
              content: Text('Create a $serviceType record for ${lift.brand} ${lift.series}?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip')),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen, foregroundColor: Colors.white),
                  child: const Text('Log Service'),
                ),
              ],
            ),
          );
          if (confirm == true && mounted) {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LiftServiceFormScreen(
                  lift: lift,
                  prefillServiceType: serviceType,
                  prefillCustomerName: widget.event.title,
                  prefillDate: formatDate(DateTime.now()),
                  offerInvoicePhoto: true,
                ),
              ),
            );
          }
          break;
      }
    }
    if (mounted) await _loadMeta(); // refresh all lift statuses
  }

  Future<void> _openMaps(String location) async {
    final encoded = Uri.encodeComponent(location);
    // Try Apple Maps first on iOS, fall back to Google Maps URL
    final appleUri = Uri.parse('maps://?q=$encoded');
    final googleUri =
        Uri.parse('https://www.google.com/maps/search/?api=1&query=$encoded');
    if (await canLaunchUrl(appleUri)) {
      await launchUrl(appleUri);
    } else {
      await launchUrl(googleUri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final startLocal = widget.event.start.toLocal();
    final endLocal = widget.event.end.toLocal();
    final sameTime = startLocal == endLocal;

    final timeLabel = widget.event.allDay
        ? 'All day'
        : sameTime
            ? widget.formatTime(startLocal)
            : '${widget.formatTime(startLocal)} – ${widget.formatTime(endLocal)}';

    final color = widget.color;
    final luminance = color.computeLuminance();
    final headerText = luminance > 0.35 ? Colors.black87 : Colors.white;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: color,
        foregroundColor: headerText,
        title: Text(
          widget.event.title.isNotEmpty ? widget.event.title : '(No title)',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.edit, color: headerText),
            tooltip: 'Edit',
            onPressed: () async {
              final changed = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => ScheduleEventFormScreen(
                    users: widget.users,
                    existingEvent: widget.event,
                    initialDate: startLocal,
                  ),
                ),
              );
              if (changed == true && context.mounted) {
                Navigator.pop(context, true);
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Color accent bar at top
          Container(
            height: 5,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 20),

          // Complete toggle
          Container(
            decoration: BoxDecoration(
              color: _completed
                  ? Colors.green.withAlpha(20)
                  : Colors.grey.withAlpha(15),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: _completed
                    ? Colors.green.withAlpha(80)
                    : Colors.grey.withAlpha(60),
              ),
            ),
            child: SwitchListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              title: Text(
                _completed ? 'Job Complete' : 'Mark as Complete',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: _completed ? Colors.green[700] : Colors.black87,
                ),
              ),
              secondary: _loadingComplete
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _completed
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color:
                          _completed ? Colors.green[700] : Colors.grey,
                    ),
              value: _completed,
              activeThumbColor: Colors.green[700],
              onChanged: _loadingComplete || _savingComplete
                  ? null
                  : (_) => _toggleCompleted(),
            ),
          ),

          const SizedBox(height: 20),

          // Job type row — always shown, tappable to set/change
          Row(
            children: [
              Icon(Icons.work_outline, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                'Job Type',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey[600]),
              ),
              const SizedBox(width: 8),
              if (_loadingMeta)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                DropdownButton<String>(
                  value: (_jobType != null && const [
                    'Stairlift Install', 'Stairlift Removal', 'Stairlift Service', 'Stairlift Annual Service',
                    'Ramp Install', 'Ramp Removal', 'Reminder', 'Other',
                  ].contains(_jobType))
                      ? _jobType
                      : null,
                  hint: Text('Set type', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                  underline: const SizedBox(),
                  isDense: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('— None —', style: TextStyle(color: Colors.grey))),
                    ...[
                      'Stairlift Install', 'Stairlift Removal', 'Stairlift Service', 'Stairlift Annual Service',
                      'Ramp Install', 'Ramp Removal', 'Reminder', 'Other',
                    ].map((t) => DropdownMenuItem(value: t, child: Text(t))),
                  ],
                  onChanged: _savingJobType ? null : (val) async {
                    setState(() {
                      _jobType = val;
                      _savingJobType = true;
                    });
                    await sbSetEventJobType(widget.event.id, val);
                    if (mounted) setState(() => _savingJobType = false);
                  },
                  selectedItemBuilder: (_) => [
                    const SizedBox.shrink(),
                    ...[
                      'Stairlift Install', 'Stairlift Removal', 'Stairlift Service', 'Stairlift Annual Service',
                      'Ramp Install', 'Ramp Removal', 'Reminder', 'Other',
                    ].map((t) =>
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: color.withAlpha(30),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: color.withAlpha(80)),
                        ),
                        child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
                      ),
                    ),
                  ],
                ),
              if (_savingJobType)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Lead source row
          Row(
            children: [
              Icon(Icons.source_outlined, size: 16, color: Colors.grey[500]),
              const SizedBox(width: 6),
              Text('Source:', style: TextStyle(fontSize: 13, color: Colors.grey[600])),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: const ['VA', 'Web Lead', 'Call-in', 'Navicare', 'Angi Lead', 'Home Advisor', 'Other'].contains(_eventSource)
                    ? _eventSource : null,
                hint: Text('Set source', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                underline: const SizedBox(),
                isDense: true,
                items: [
                  const DropdownMenuItem(value: null, child: Text('— None —', style: TextStyle(color: Colors.grey))),
                  ...['VA', 'Web Lead', 'Call-in', 'Navicare', 'Angi Lead', 'Home Advisor', 'Other']
                      .map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 13)))),
                ],
                onChanged: _savingSource ? null : (val) async {
                  setState(() { _eventSource = val; _savingSource = true; });
                  await sbSetEventSource(widget.event.id, val);
                  if (mounted) setState(() => _savingSource = false);
                },
              ),
              if (_savingSource)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
          const SizedBox(height: 16),

          // Linked lifts section
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.withAlpha(12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.withAlpha(40)),
            ),
            child: _loadingMeta
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: Row(children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Loading...', style: TextStyle(color: Colors.black45)),
                    ]),
                  )
                : Column(
                    children: [
                      ..._linkedLifts.map((lift) => ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                            leading: Icon(Icons.stairs, color: color),
                            title: Text(
                              '${lift.brand} ${lift.series}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (lift.serialNumber.isNotEmpty) Text('SN: ${lift.serialNumber}'),
                                Text(
                                  lift.status,
                                  style: TextStyle(
                                    color: lift.status == 'Installed'
                                        ? Colors.green[700]
                                        : lift.status == 'Assigned'
                                            ? Colors.orange[700]
                                            : Colors.black54,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                  tooltip: 'View lift',
                                  onPressed: () async {
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(builder: (_) => LiftDetailScreen(lift: lift)),
                                    );
                                    if (mounted) _loadMeta();
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.link_off, size: 18, color: Colors.red),
                                  tooltip: 'Remove link',
                                  onPressed: _savingLift ? null : () => _unlinkLift(lift),
                                ),
                              ],
                            ),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => LiftDetailScreen(lift: lift)),
                              );
                              if (mounted) _loadMeta();
                            },
                          )),
                      // Add lift button
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                        leading: Icon(
                          _linkedLifts.isEmpty ? Icons.link : Icons.add_link,
                          color: _linkedLifts.isEmpty ? Colors.grey[400] : color,
                        ),
                        title: Text(
                          _linkedLifts.isEmpty ? 'Link a lift' : 'Add another lift',
                          style: TextStyle(
                            color: _linkedLifts.isEmpty ? Colors.grey[600] : color,
                            fontWeight: _linkedLifts.isEmpty ? FontWeight.normal : FontWeight.w500,
                          ),
                        ),
                        trailing: _savingLift
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(Icons.chevron_right, color: Colors.grey[400]),
                        onTap: _savingLift ? null : _openLiftPicker,
                      ),
                    ],
                  ),
          ),

          const SizedBox(height: 16),

          // Linked customer section
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.withAlpha(12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.withAlpha(40)),
            ),
            child: _loadingMeta
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: Row(children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Loading...', style: TextStyle(color: Colors.black45)),
                    ]),
                  )
                : Column(
                    children: [
                      if (_linkedCustomerName != null)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          leading: Icon(Icons.person_outline, color: color),
                          title: Text(
                            _linkedCustomerName!,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: const Text('Linked customer'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_linkedCustomerQbId != null && _linkedCustomerQbId!.isNotEmpty)
                                IconButton(
                                  icon: const Icon(Icons.open_in_new, size: 18),
                                  tooltip: 'View in QuickBooks',
                                  onPressed: () => launchUrl(
                                    Uri.parse('https://app.qbo.intuit.com/app/customerdetail?nameId=$_linkedCustomerQbId'),
                                    mode: LaunchMode.externalApplication,
                                  ),
                                ),
                              IconButton(
                                icon: const Icon(Icons.link_off, size: 18, color: Colors.red),
                                tooltip: 'Remove customer',
                                onPressed: _savingCustomer ? null : _unlinkCustomer,
                              ),
                            ],
                          ),
                        ),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                        leading: Icon(
                          _linkedCustomerName == null ? Icons.person_search_outlined : Icons.person_add_alt_outlined,
                          color: _linkedCustomerName == null ? Colors.grey[400] : color,
                        ),
                        title: Text(
                          _linkedCustomerName == null ? 'Link a customer' : 'Change customer',
                          style: TextStyle(
                            color: _linkedCustomerName == null ? Colors.grey[600] : color,
                            fontWeight: _linkedCustomerName == null ? FontWeight.normal : FontWeight.w500,
                          ),
                        ),
                        trailing: _savingCustomer
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(Icons.chevron_right, color: Colors.grey[400]),
                        onTap: _savingCustomer ? null : _linkCustomer,
                      ),
                    ],
                  ),
          ),

          const SizedBox(height: 20),

          // Time
          _DetailRow(
            icon: Icons.access_time,
            label: 'Time',
            value: timeLabel,
            color: color,
          ),

          // Assigned to
          if (widget.assignedNames.isNotEmpty) ...[
            const SizedBox(height: 16),
            _DetailRow(
              icon: Icons.person_outline,
              label: 'Assigned to',
              value: widget.assignedNames,
              color: color,
            ),
          ],

          // Location — tappable to open maps
          if (widget.event.location.isNotEmpty) ...[
            const SizedBox(height: 16),
            InkWell(
              onTap: () => _openMaps(widget.event.location),
              borderRadius: BorderRadius.circular(8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.location_on, color: color, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Location',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.event.location,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: color,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                            Icon(Icons.open_in_new,
                                size: 14, color: color),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Notes
          if (widget.event.notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.notes, color: color, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Notes',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: color.withAlpha(18),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: color.withAlpha(50)),
                        ),
                        child: Text(
                          widget.event.notes,
                          style: const TextStyle(fontSize: 15, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 20),

          // Photos section
          Row(
            children: [
              Icon(Icons.photo_library_outlined, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                'Photos',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _uploadingPhoto ? null : _addEventPhoto,
                icon: _uploadingPhoto
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.add_a_photo, size: 16, color: color),
                label: Text('Add photo', style: TextStyle(color: color, fontSize: 13)),
              ),
            ],
          ),
          if (_eventPhotoUrls.isEmpty && !_uploadingPhoto)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No photos yet',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            )
          else
            SizedBox(
              height: 100,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _eventPhotoUrls.length + (_uploadingPhoto ? 1 : 0),
                itemBuilder: (context, index) {
                  if (_uploadingPhoto && index == _eventPhotoUrls.length) {
                    return Container(
                      width: 100,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Center(child: CircularProgressIndicator()),
                    );
                  }
                  final url = _eventPhotoUrls[index];
                  return GestureDetector(
                    onTap: () => _viewPhoto(context, url),
                    onLongPress: () => _deleteEventPhoto(url),
                    child: Stack(
                      children: [
                        Container(
                          width: 100,
                          margin: const EdgeInsets.only(right: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              url,
                              fit: BoxFit.cover,
                              loadingBuilder: (_, child, progress) => progress == null
                                  ? child
                                  : Container(
                                      color: Colors.grey.shade200,
                                      child: const Center(child: CircularProgressIndicator()),
                                    ),
                              errorBuilder: (_, __, e) => Container(
                                color: Colors.grey.shade200,
                                child: const Icon(Icons.broken_image, color: Colors.grey),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 12,
                          child: GestureDetector(
                            onTap: () => _deleteEventPhoto(url),
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(3),
                              child: const Icon(Icons.close, color: Colors.white, size: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

          const SizedBox(height: 32),

          // Edit button
          ElevatedButton.icon(
            onPressed: () async {
              final changed = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => ScheduleEventFormScreen(
                    users: widget.users,
                    existingEvent: widget.event,
                    initialDate: startLocal,
                  ),
                ),
              );
              if (changed == true && context.mounted) {
                Navigator.pop(context, true);
              }
            },
            icon: const Icon(Icons.edit),
            label: const Text('Edit Event'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: color,
              foregroundColor: headerText,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 15)),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Link lift to a schedule job (shown after marking a lift as Assigned)
// ---------------------------------------------------------------------------

class _LinkLiftToJobScreen extends StatefulWidget {
  /// The ID of the lift to link.
  final String liftId;

  const _LinkLiftToJobScreen({required this.liftId});

  @override
  State<_LinkLiftToJobScreen> createState() => _LinkLiftToJobScreenState();
}

class _LinkLiftToJobScreenState extends State<_LinkLiftToJobScreen> {
  bool _loading = true;
  String? _error;
  List<QbtScheduleEvent> _installEvents = [];
  Map<String, QbtUser> _users = {};
  String? _linkingEventId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final now = DateTime.now();
      final results = await Future.wait([
        qbtFetchScheduleEvents(
          start: now.subtract(const Duration(days: 7)),
          end: now.add(const Duration(days: 30)),
        ),
        qbtFetchUsers(),
      ]);
      final events = results[0] as List<QbtScheduleEvent>;
      final users = results[1] as Map<String, QbtUser>;

      // Only show Install-type events (by title inference)
      final installEvents = events.where((e) {
        final t = e.title.toLowerCase();
        return t.contains('install') && !t.contains('removal') && !t.contains('remove');
      }).toList();

      if (!mounted) return;
      setState(() {
        _installEvents = installEvents;
        _users = users;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String _formatEventDate(QbtScheduleEvent event) {
    final local = event.start.toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final m = local.minute.toString().padLeft(2, '0');
    final ampm = local.hour < 12 ? 'AM' : 'PM';
    return '${local.month}/${local.day}/${local.year}  $h:$m $ampm';
  }

  String _assignedNames(QbtScheduleEvent event) {
    if (event.assignedUserIds.isEmpty) return '';
    return event.assignedUserIds
        .map((id) => _users[id]?.displayName ?? 'Unknown')
        .join(', ');
  }

  Future<void> _linkToEvent(QbtScheduleEvent event) async {
    setState(() => _linkingEventId = event.id);
    try {
      // Fetch current lift IDs linked to this event
      final meta = await sbGetEventMeta(event.id);
      final currentIds = (meta['lift_ids'] as List<String>?) ?? [];
      if (!currentIds.contains(widget.liftId)) {
        await sbSetEventLiftIds(event.id, [...currentIds, widget.liftId]);
      }
      // Ensure job type is set to Stairlift Install
      final jobType = meta['job_type'] as String?;
      if (jobType == null || jobType.isEmpty) {
        await sbSetEventJobType(event.id, 'Stairlift Install');
      }
      if (!mounted) return;
      // Navigate to the event detail so user can see the link
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ScheduleEventDetailScreen(
            event: event,
            users: _users,
            assignedNames: _assignedNames(event),
            color: _parseEventColor(event),
            formatTime: (dt) {
              final local = dt.toLocal();
              final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
              final m = local.minute.toString().padLeft(2, '0');
              final ampm = local.hour < 12 ? 'AM' : 'PM';
              return '$h:$m $ampm';
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to link lift: $e')),
      );
      setState(() => _linkingEventId = null);
    }
  }

  Color _parseEventColor(QbtScheduleEvent event) {
    try {
      final h = event.color.replaceAll('#', '');
      return Color(int.parse('FF$h', radix: 16));
    } catch (_) {
      return kBrandGreen;
    }
  }

  @override
  Widget build(BuildContext context) {
    Future<void> openCreateJob() async {
      final created = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ScheduleEventFormScreen(
            users: _users,
            initialDate: DateTime.now(),
          ),
        ),
      );
      if (created == true) _load();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Link to Schedule Job'),
      ),
      floatingActionButton: _loading || _error != null
          ? null
          : FloatingActionButton.extended(
              onPressed: openCreateJob,
              backgroundColor: kBrandGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Create New Job'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Error: $_error', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Instruction
                    Container(
                      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: kBrandGreen.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kBrandGreen.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 18, color: kBrandGreen),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Tap an upcoming install job below to attach this lift to it. '
                              'You can also create a new job with this lift already linked.',
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _installEvents.isEmpty
                          ? Center(
                              child: Text(
                                'No upcoming install jobs found.',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView.builder(
                                padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
                                itemCount: _installEvents.length,
                                itemBuilder: (context, i) {
                                  final event = _installEvents[i];
                                  final names = _assignedNames(event);
                                  final isLinking = _linkingEventId == event.id;
                                  return Card(
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    child: ListTile(
                                      leading: Container(
                                        width: 4,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: _parseEventColor(event),
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      title: Text(
                                        event.title.isNotEmpty ? event.title : '(No title)',
                                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _formatEventDate(event),
                                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                          ),
                                          if (names.isNotEmpty)
                                            Wrap(
                                              spacing: 4,
                                              children: names
                                                  .split(', ')
                                                  .map((n) => Tooltip(
                                                        message: n,
                                                        child: InitialsAvatar(name: n, size: 22),
                                                      ))
                                                  .toList(),
                                            ),
                                        ],
                                      ),
                                      trailing: isLinking
                                          ? const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(strokeWidth: 2),
                                            )
                                          : const Icon(Icons.link, color: kBrandGreen),
                                      onTap: isLinking ? null : () => _linkToEvent(event),
                                    ),
                                  );
                                },
                              ),
                            ),
                    ),
                  ],
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scheduling Queue — pending service calls and removals
// ---------------------------------------------------------------------------

class SchedulingQueueScreen extends StatefulWidget {
  const SchedulingQueueScreen({super.key});

  @override
  State<SchedulingQueueScreen> createState() => _SchedulingQueueScreenState();
}

class _SchedulingQueueScreenState extends State<SchedulingQueueScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  List<ServiceJobRecord> _serviceJobs = [];
  List<RemovalJobRecord> _removalJobs = [];
  List<WebLeadRecord> _webLeads = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        sbFetchServiceJobs(),
        sbFetchRemovalJobs(),
        sbFetchWebLeads(),
      ]);
      if (!mounted) return;
      final serviceJobs = (results[0] as List<ServiceJobRecord>)
          .where((j) => j.status == 'Needs Scheduling')
          .toList();
      final removalJobs = (results[1] as List<RemovalJobRecord>)
          .where((j) => j.status == 'Needs Scheduling')
          .toList();
      setState(() {
        _serviceJobs = serviceJobs;
        _removalJobs = removalJobs;
        _webLeads = results[2] as List<WebLeadRecord>;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _openAddSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.build_outlined),
              title: const Text('Service Call'),
              onTap: () => Navigator.pop(ctx, 'service'),
            ),
            ListTile(
              leading: const Icon(Icons.move_to_inbox_outlined),
              title: const Text('Removal'),
              onTap: () => Navigator.pop(ctx, 'removal'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'service') {
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const ServiceJobFormScreen()),
      );
      if (saved == true && mounted) _load();
    } else {
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const RemovalJobFormScreen()),
      );
      if (saved == true && mounted) _load();
    }
  }

  Future<void> _scheduleServiceJob(ServiceJobRecord job) async {
    Map<String, QbtUser> users;
    try {
      users = await qbtFetchUsers();
    } catch (_) {
      users = {};
    }
    if (!mounted) return;
    final prefillTitle = job.title.isNotEmpty ? job.title : '${job.jobType} — ${job.customerName}';
    final liftIds = job.liftId.isNotEmpty ? [job.liftId] : <String>[];
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ScheduleEventFormScreen(
          users: users,
          initialDate: DateTime.now(),
          prefillTitle: prefillTitle,
          prefillLocation: job.address,
          prefillNotes: job.notes,
          prefillJobType: job.jobType,
          prefillLiftIds: liftIds,
          sourceJobId: job.jobId,
          sourceJobTable: 'service_jobs',
          prefillFundingSource: job.fundingSource,
        ),
      ),
    );
    if (saved == true && mounted) _load();
  }

  Future<void> _scheduleRemovalJob(RemovalJobRecord job) async {
    Map<String, QbtUser> users;
    try {
      users = await qbtFetchUsers();
    } catch (_) {
      users = {};
    }
    if (!mounted) return;
    final prefillTitle = job.title.isNotEmpty ? job.title : 'Removal — ${job.customerName}';
    final liftIds = job.liftId.isNotEmpty ? [job.liftId] : <String>[];
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ScheduleEventFormScreen(
          users: users,
          initialDate: DateTime.now(),
          prefillTitle: prefillTitle,
          prefillLocation: job.address,
          prefillNotes: job.notes,
          prefillJobType: 'Removal',
          prefillLiftIds: liftIds,
          sourceJobId: job.jobId,
          sourceJobTable: 'removal_jobs',
          prefillFundingSource: job.fundingSource,
        ),
      ),
    );
    if (saved == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final svcCount = _serviceJobs.length;
    final remCount = _removalJobs.length;
    final newLeadCount = _webLeads.where((l) => l.status == 'New').length;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: const Text('Queue'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: GoogleFonts.nunito(fontWeight: FontWeight.w700),
          unselectedLabelStyle: GoogleFonts.nunito(),
          tabs: [
            Tab(text: svcCount > 0 ? 'Service ($svcCount)' : 'Service'),
            Tab(text: remCount > 0 ? 'Removals ($remCount)' : 'Removals'),
            Tab(text: newLeadCount > 0 ? 'Leads ($newLeadCount new)' : 'Leads'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: kBrandGreen,
        foregroundColor: Colors.white,
        onPressed: _openAddSheet,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Error: $_error'),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _QueueServiceTab(
                      jobs: _serviceJobs,
                      onRefresh: _load,
                      onSchedule: _scheduleServiceJob,
                      onTap: (job) async {
                        final saved = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(builder: (_) => ServiceJobFormScreen(existing: job)),
                        );
                        if (saved == true && mounted) _load();
                      },
                      onDelete: (job) async {
                        await sbDeleteServiceJob(jobId: job.jobId);
                        _load();
                      },
                    ),
                    _QueueRemovalTab(
                      jobs: _removalJobs,
                      onRefresh: _load,
                      onSchedule: _scheduleRemovalJob,
                      onTap: (job) async {
                        final saved = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(builder: (_) => RemovalJobFormScreen(existing: job)),
                        );
                        if (saved == true && mounted) _load();
                      },
                      onDelete: (job) async {
                        await sbDeleteRemovalJob(jobId: job.jobId);
                        _load();
                      },
                    ),
                    _WebLeadsTab(leads: _webLeads, onRefresh: _load),
                  ],
                ),
    );
  }
}

class _QueueServiceTab extends StatelessWidget {
  final List<ServiceJobRecord> jobs;
  final Future<void> Function() onRefresh;
  final Future<void> Function(ServiceJobRecord) onSchedule;
  final Future<void> Function(ServiceJobRecord) onTap;
  final Future<void> Function(ServiceJobRecord) onDelete;

  const _QueueServiceTab({
    required this.jobs,
    required this.onRefresh,
    required this.onSchedule,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (jobs.isEmpty) {
      return const Center(
        child: Text(
          'No service calls waiting to be scheduled.',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
        itemCount: jobs.length,
        itemBuilder: (ctx, i) => _QueueCard.service(
          job: jobs[i],
          onSchedule: () => onSchedule(jobs[i]),
          onTap: () => onTap(jobs[i]),
          onDelete: () => onDelete(jobs[i]),
        ),
      ),
    );
  }
}

class _QueueRemovalTab extends StatelessWidget {
  final List<RemovalJobRecord> jobs;
  final Future<void> Function() onRefresh;
  final Future<void> Function(RemovalJobRecord) onSchedule;
  final Future<void> Function(RemovalJobRecord) onTap;
  final Future<void> Function(RemovalJobRecord) onDelete;

  const _QueueRemovalTab({
    required this.jobs,
    required this.onRefresh,
    required this.onSchedule,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    if (jobs.isEmpty) {
      return const Center(
        child: Text(
          'No removals waiting to be scheduled.',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
        itemCount: jobs.length,
        itemBuilder: (ctx, i) => _QueueCard.removal(
          job: jobs[i],
          onSchedule: () => onSchedule(jobs[i]),
          onTap: () => onTap(jobs[i]),
          onDelete: () => onDelete(jobs[i]),
        ),
      ),
    );
  }
}

class _JobTypeChip extends StatelessWidget {
  final String jobType;
  const _JobTypeChip({required this.jobType});

  @override
  Widget build(BuildContext context) {
    final isAnnual = jobType == 'Stairlift Annual Service';
    final bg = isAnnual
        ? const Color(0xFFEF6C00).withValues(alpha: 0.12)
        : kBrandGreen.withValues(alpha: 0.12);
    final fg = isAnnual ? const Color(0xFFBF360C) : kBrandGreenDark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        jobType,
        style: GoogleFonts.nunito(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

class _QueueCard extends StatefulWidget {
  final String jobType;
  final String title;
  final String customerName;
  final String address;
  final String phone;
  final String liftLabel;
  final String notes;
  final String dateRequested; // empty for removals
  final VoidCallback onTap;
  final Future<void> Function() onSchedule;
  final Future<void> Function() onDelete;

  const _QueueCard({
    required this.jobType,
    required this.title,
    required this.customerName,
    required this.address,
    required this.phone,
    required this.liftLabel,
    required this.notes,
    required this.dateRequested,
    required this.onTap,
    required this.onSchedule,
    required this.onDelete,
  });

  factory _QueueCard.service({
    required ServiceJobRecord job,
    required VoidCallback onTap,
    required Future<void> Function() onSchedule,
    required Future<void> Function() onDelete,
  }) {
    return _QueueCard(
      jobType: job.jobType.isEmpty ? 'Service' : job.jobType,
      title: job.title,
      customerName: job.customerName,
      address: job.address,
      phone: job.phone,
      liftLabel: job.liftType,
      notes: job.notes,
      dateRequested: job.dateRequested.isNotEmpty
          ? normalizeDateDisplay(job.dateRequested)
          : '',
      onTap: onTap,
      onSchedule: onSchedule,
      onDelete: onDelete,
    );
  }

  factory _QueueCard.removal({
    required RemovalJobRecord job,
    required VoidCallback onTap,
    required Future<void> Function() onSchedule,
    required Future<void> Function() onDelete,
  }) {
    return _QueueCard(
      jobType: 'Removal',
      title: job.title,
      customerName: job.customerName,
      address: job.address,
      phone: job.phone,
      liftLabel: job.liftType,
      notes: job.notes,
      dateRequested: '',
      onTap: onTap,
      onSchedule: onSchedule,
      onDelete: onDelete,
    );
  }

  @override
  State<_QueueCard> createState() => _QueueCardState();
}

class _QueueCardState extends State<_QueueCard> {
  bool _scheduling = false;

  Future<void> _handleSchedule() async {
    setState(() => _scheduling = true);
    try {
      await widget.onSchedule();
    } finally {
      if (mounted) setState(() => _scheduling = false);
    }
  }

  Future<void> _handleDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete entry?'),
        content: Text('Remove "${widget.title.isNotEmpty ? widget.title : widget.customerName}" from the queue? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600, foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onDelete();
  }

  Future<void> _launchPhone() async {
    if (widget.phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: widget.phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final headline = widget.title.isNotEmpty ? widget.title : widget.customerName;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            // Colored left accent bar
            Container(
              width: 5,
              decoration: BoxDecoration(
                color: kBrandGreen,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10),
                  bottomLeft: Radius.circular(10),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Job type chip + title headline
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _JobTypeChip(jobType: widget.jobType),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            headline,
                            style: GoogleFonts.nunito(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (widget.customerName.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.person_outline, size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Text(
                            widget.customerName,
                            style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[700]),
                          ),
                        ],
                      ),
                    ],
                    if (widget.address.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.location_on_outlined, size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              widget.address,
                              style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[700]),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (widget.phone.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      GestureDetector(
                        onTap: _launchPhone,
                        child: Row(
                          children: [
                            Icon(Icons.phone_outlined, size: 14, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Text(
                              widget.phone,
                              style: GoogleFonts.nunito(
                                fontSize: 13,
                                color: kBrandGreen,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (widget.liftLabel.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.stairs_rounded, size: 13, color: Colors.grey[600]),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                widget.liftLabel,
                                style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[700]),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (widget.dateRequested.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.calendar_today_outlined, size: 13, color: Colors.grey[500]),
                          const SizedBox(width: 4),
                          Text(
                            'Requested: ${widget.dateRequested}',
                            style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[600]),
                          ),
                        ],
                      ),
                    ],
                    if (widget.notes.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        widget.notes,
                        style: GoogleFonts.nunito(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    // Action buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          onPressed: _handleDelete,
                          icon: const Icon(Icons.delete_outline, size: 20),
                          color: Colors.red.shade400,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Delete',
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _scheduling ? null : _handleSchedule,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kBrandGreen,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: _scheduling
                              ? const SizedBox(
                                  width: 14, height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.calendar_month_rounded, size: 16),
                          label: Text('Schedule', style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Customer search delegate — used by LiftFormScreen to link a lift to a customer
// ---------------------------------------------------------------------------

// QB-backed customer search — searches QuickBooks live.
// Returns a (name, qbCustomerId) pair — no local Supabase customer record needed.
typedef _QbCustomerResult = ({String name, String qbCustomerId});

class _CustomerSearchDelegate extends SearchDelegate<_QbCustomerResult?> {
  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
  ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, null),
  );

  @override
  Widget buildResults(BuildContext context) => _QbCustomerSearchResults(
    query: query,
    onSelected: (r) => close(context, r),
  );

  @override
  Widget buildSuggestions(BuildContext context) => _QbCustomerSearchResults(
    query: query,
    onSelected: (r) => close(context, r),
  );
}

class _QbCustomerSearchResults extends StatefulWidget {
  final String query;
  final void Function(_QbCustomerResult) onSelected;
  const _QbCustomerSearchResults({required this.query, required this.onSelected});

  @override
  State<_QbCustomerSearchResults> createState() => _QbCustomerSearchResultsState();
}

class _QbCustomerSearchResultsState extends State<_QbCustomerSearchResults> {
  List<QbCustomer> _results = [];
  bool _loading = false;
  bool _notConnected = false;
  String _lastQuery = '';

  @override
  void didUpdateWidget(_QbCustomerSearchResults old) {
    super.didUpdateWidget(old);
    if (widget.query != _lastQuery) _search();
  }

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    final q = widget.query.trim();
    _lastQuery = q;
    if (q.length < 2) {
      setState(() { _results = []; _loading = false; });
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await QuickBooksService.searchCustomers(q);
      if (mounted && widget.query.trim() == _lastQuery) {
        setState(() { _results = results; _loading = false; });
      }
    } on QbNotConnectedException {
      if (mounted) setState(() { _loading = false; _notConnected = true; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_notConnected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'QuickBooks not connected.\nConnect QB in the Account menu to search customers.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (widget.query.trim().length < 2) {
      return Center(
        child: Text('Type at least 2 characters to search',
            style: TextStyle(color: Colors.grey[600])),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text('No QB customers found for "${widget.query}"',
            style: TextStyle(color: Colors.grey[600])),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (ctx, i) {
        final c = _results[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: kBrandGreen.withValues(alpha: 0.12),
            child: Text(
              c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
              style: const TextStyle(color: kBrandGreen, fontWeight: FontWeight.w700),
            ),
          ),
          title: Text(c.name),
          subtitle: Text(c.address.isNotEmpty ? c.address : c.phone,
              style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          onTap: () => widget.onSelected((name: c.name, qbCustomerId: c.id)),
        );
      },
    );
  }
}

