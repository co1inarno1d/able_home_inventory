// lib/auth/auth.dart
//
// Role-based authentication for Able Home Accessibility.
// Uses Supabase Auth (email + password) with a user_profiles table
// that stores each user's role.
//
// Roles:
//   admin      — full access to everything (Colin)
//   owner      — full access minus settings; can approve buybacks
//   assessor   — schedule, customers, ops hub (view), web leads
//   service    — schedule, lifts (view + service log), customers (view), prep
//   installer  — schedule, lifts (view + prep), prep screen

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/utils.dart';

// ---------------------------------------------------------------------------
// ROLE ENUM
// ---------------------------------------------------------------------------

enum UserRole { admin, installer }

extension UserRoleX on UserRole {
  String get label {
    switch (this) {
      case UserRole.admin: return 'Admin';
      case UserRole.installer: return 'Installer';
    }
  }

  static UserRole fromString(String s) {
    switch (s.toLowerCase()) {
      case 'admin': return UserRole.admin;
      default: return UserRole.installer; // safest default
    }
  }
}

// ---------------------------------------------------------------------------
// USER PROFILE
// ---------------------------------------------------------------------------

class UserProfile {
  final String userId;
  final String email;
  final String name;
  final UserRole role;

  const UserProfile({
    required this.userId,
    required this.email,
    required this.name,
    required this.role,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      userId: json['user_id']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      role: UserRoleX.fromString(json['role']?.toString() ?? 'installer'),
    );
  }

  bool get isAdmin => role == UserRole.admin;

  // Installers: everything except Dashboard, Customers, Settings
  bool get canSeeLifts => true;
  bool get canEditLifts => true;
  bool get canSeeRamps => true;
  bool get canEditRamps => true;
  bool get canSeeSchedule => true;
  bool get canSeeOpsHub => true;
  bool get canEditOpsHub => true;
  bool get canSeeDashboard => false; // temporarily hidden until team accounts are set up
  bool get canSeeCustomers => true;
  bool get canEditCustomers => true;
  bool get canSeePrepScreen => true;
  bool get canSeeSettings => isAdmin;
  bool get canApproveBuybacks => isAdmin;
  bool get canAdjustInventory => isAdmin;
}

// ---------------------------------------------------------------------------
// AUTH SERVICE (singleton)
// ---------------------------------------------------------------------------

class AuthService extends ChangeNotifier {
  static final AuthService instance = AuthService._();
  AuthService._();

  UserProfile? _profile;
  bool _loading = false;

  UserProfile? get profile => _profile;
  bool get isLoggedIn => _profile != null;
  bool get loading => _loading;

  SupabaseClient get _sb => Supabase.instance.client;

  /// Called on app start — restores session if Supabase has one cached.
  Future<void> restoreSession() async {
    // Auth temporarily bypassed — auto sign in as installer for team testing.
    _profile = const UserProfile(
      userId: 'temp',
      email: 'team@ableha.com',
      name: 'Able Home',
      role: UserRole.installer,
    );
    _loading = false;
    notifyListeners();
  }

  Future<String?> signIn(String email, String password) async {
    _loading = true;
    notifyListeners();
    try {
      final res = await _sb.auth.signInWithPassword(
        email: email.trim(),
        password: password.trim(),
      );
      if (res.user == null) return 'Sign in failed — no user returned';
      await _loadProfile(res.user!.id);
      return null; // success — AuthGate rebuilds via notifyListeners in _loadProfile
    } on AuthException catch (e) {
      _loading = false;
      notifyListeners();
      return e.message;
    } catch (e) {
      _loading = false;
      notifyListeners();
      return e.toString();
    }
  }

  Future<void> signOut() async {
    await _sb.auth.signOut();
    _profile = null;
    notifyListeners();
  }

  Future<void> _loadProfile(String userId) async {
    try {
      final raw = await _sb
          .from('user_profiles')
          .select()
          .eq('user_id', userId)
          .maybeSingle();
      if (raw != null) {
        _profile = UserProfile.fromJson(raw);
      } else {
        // Profile row missing — fall back to a minimal installer profile
        // so the user isn't locked out. Admin can fix the role later.
        final user = _sb.auth.currentUser;
        _profile = UserProfile(
          userId: userId,
          email: user?.email ?? '',
          name: user?.email?.split('@').first ?? '',
          role: UserRole.installer,
        );
      }
    } catch (e) {
      // If profile load fails, still allow access with a fallback profile
      // so a RLS misconfiguration doesn't hard-lock everyone out.
      final user = _sb.auth.currentUser;
      if (user != null) {
        _profile = UserProfile(
          userId: userId,
          email: user.email ?? '',
          name: user.email?.split('@').first ?? '',
          role: UserRole.installer,
        );
      } else {
        _profile = null;
      }
    }
    _loading = false;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// LOGIN SCREEN
// ---------------------------------------------------------------------------

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    final err = await AuthService.instance.signIn(_emailCtrl.text, _passCtrl.text);
    if (!mounted) return;
    setState(() { _saving = false; _error = err; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBrandGreenDark,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              children: [
                const SizedBox(height: 20),
                Text(
                  'Able Home',
                  style: GoogleFonts.nunito(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                Text(
                  'Accessibility',
                  style: GoogleFonts.nunito(
                    fontSize: 16,
                    fontWeight: FontWeight.w400,
                    color: Colors.white70,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 48),
                Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Sign In',
                              style: GoogleFonts.nunito(
                                  fontSize: 20, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _emailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.email_outlined),
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) => v == null || !v.contains('@')
                                ? 'Enter a valid email'
                                : null,
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: _passCtrl,
                            obscureText: _obscure,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outlined),
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                icon: Icon(_obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                            validator: (v) => v == null || v.isEmpty
                                ? 'Required'
                                : null,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.red[50],
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.red[200]!),
                              ),
                              child: Text(_error!,
                                  style: GoogleFonts.nunito(
                                      color: Colors.red[800], fontSize: 13)),
                            ),
                          ],
                          const SizedBox(height: 20),
                          ElevatedButton(
                            onPressed: _saving ? null : _submit,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: kBrandGreen,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            child: _saving
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : Text('Sign In',
                                    style: GoogleFonts.nunito(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
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
// AUTH GATE (wraps the whole app)
// ---------------------------------------------------------------------------

class AuthGate extends StatefulWidget {
  final Widget Function(UserProfile) builder;
  final void Function(BuildContext)? onQbCallback;
  const AuthGate({super.key, required this.builder, this.onQbCallback});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _restoring = true;

  @override
  void initState() {
    super.initState();
    AuthService.instance.addListener(_onAuthChange);
    // restoreSession calls _loadProfile which calls notifyListeners when done,
    // which triggers _onAuthChange → setState. We just need to clear the
    // _restoring spinner once the async work finishes.
    AuthService.instance.restoreSession().then((_) {
      if (mounted) setState(() => _restoring = false);
    }).catchError((_) {
      if (mounted) setState(() => _restoring = false);
    });
  }

  @override
  void dispose() {
    AuthService.instance.removeListener(_onAuthChange);
    super.dispose();
  }

  void _onAuthChange() {
    if (mounted) setState(() {});
  }

  bool _qbCallbackHandled = false;

  void _maybeHandleQbCallback(BuildContext context) {
    if (_qbCallbackHandled) return;
    final uri = Uri.base;
    if (uri.queryParameters.containsKey('code') &&
        uri.queryParameters.containsKey('realmId')) {
      _qbCallbackHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onQbCallback?.call(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_restoring) {
      return const Scaffold(
        backgroundColor: kBrandGreenDark,
        body: Center(
            child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    _maybeHandleQbCallback(context);
    final profile = AuthService.instance.profile;
    if (profile == null) return const LoginScreen();
    return widget.builder(profile);
  }
}
