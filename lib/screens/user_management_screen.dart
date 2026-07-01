// lib/screens/user_management_screen.dart
//
// Admin-only screen for managing team members and their roles.
// Users must sign up themselves via the login screen first; admin
// then assigns the correct role here. Row deletions remove the
// user_profiles row (auth account remains — user can re-register).

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth/auth.dart';
import '../supabase_api.dart';
import '../utils/utils.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  List<UserProfile> _users = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final users = await sbFetchUserProfiles();
      if (!mounted) return;
      setState(() { _users = users; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _editUser(UserProfile user) async {
    final result = await showDialog<_EditResult>(
      context: context,
      builder: (_) => _EditUserDialog(user: user),
    );
    if (result == null || !mounted) return;
    try {
      await sbUpdateUserProfile(user.userId, name: result.name, role: result.role);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
      }
    }
  }

  Future<void> _deleteUser(UserProfile user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove ${user.name}?',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        content: Text(
          'This removes their role from the app. Their login account is unaffected — they can re-register and be assigned a new role.',
          style: GoogleFonts.nunito(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await sbDeleteUserProfile(user.userId);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to remove: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Team Members',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Error: $_error',
                          style: GoogleFonts.nunito(color: Colors.red)),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : Column(
                  children: [
                    _InviteHint(),
                    Expanded(
                      child: _users.isEmpty
                          ? Center(
                              child: Text('No team members yet.',
                                  style: GoogleFonts.nunito(
                                      color: Colors.grey[600], fontSize: 15)),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 40),
                              itemCount: _users.length,
                              itemBuilder: (_, i) => _UserTile(
                                user: _users[i],
                                onEdit: () => _editUser(_users[i]),
                                onDelete: () => _deleteUser(_users[i]),
                              ),
                            ),
                    ),
                  ],
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// Invite hint banner
// ---------------------------------------------------------------------------

class _InviteHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: kBrandGreen.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBrandGreen.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: kBrandGreen.withValues(alpha: 0.7)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'New team members sign up at the app login screen using their work email. '
              'They\'ll appear here as "Installer" — update their role once they\'ve signed in.',
              style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[700]),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// User tile
// ---------------------------------------------------------------------------

class _UserTile extends StatelessWidget {
  final UserProfile user;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _UserTile({
    required this.user,
    required this.onEdit,
    required this.onDelete,
  });

  Color _roleColor(UserRole role) {
    switch (role) {
      case UserRole.admin:     return Colors.deepPurple;
      case UserRole.installer: return Colors.grey[600]!;
    }
  }

  @override
  Widget build(BuildContext context) {
    final initials = user.name.trim().isEmpty
        ? user.email.substring(0, 1).toUpperCase()
        : user.name.trim().split(' ').map((w) => w[0]).take(2).join().toUpperCase();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: kBrandGreen.withValues(alpha: 0.15),
          child: Text(initials,
              style: GoogleFonts.nunito(
                  fontWeight: FontWeight.w700,
                  color: kBrandGreenDark,
                  fontSize: 14)),
        ),
        title: Text(
          user.name.isNotEmpty ? user.name : user.email,
          style: GoogleFonts.nunito(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (user.name.isNotEmpty)
              Text(user.email,
                  style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[500])),
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _roleColor(user.role).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                user.role.label,
                style: GoogleFonts.nunito(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _roleColor(user.role),
                ),
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 19),
              color: Colors.grey[600],
              tooltip: 'Edit',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.person_remove_outlined, size: 19),
              color: Colors.red[400],
              tooltip: 'Remove',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit dialog
// ---------------------------------------------------------------------------

class _EditResult {
  final String name;
  final UserRole role;
  const _EditResult({required this.name, required this.role});
}

class _EditUserDialog extends StatefulWidget {
  final UserProfile user;
  const _EditUserDialog({required this.user});

  @override
  State<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<_EditUserDialog> {
  late final TextEditingController _nameCtrl;
  late UserRole _role;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.user.name);
    _role = widget.user.role;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit Team Member',
          style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.user.email,
              style: GoogleFonts.nunito(fontSize: 12, color: Colors.grey[500])),
          const SizedBox(height: 14),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: 'Display Name',
              labelStyle: GoogleFonts.nunito(),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            style: GoogleFonts.nunito(),
          ),
          const SizedBox(height: 14),
          Text('Role', style: GoogleFonts.nunito(fontSize: 13, color: Colors.grey[700])),
          const SizedBox(height: 6),
          ...UserRole.values.map((r) => RadioListTile<UserRole>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: r,
                groupValue: _role,
                onChanged: (v) { if (v != null) setState(() => _role = v); },
                title: Text(r.label,
                    style: GoogleFonts.nunito(fontSize: 13)),
                activeColor: kBrandGreen,
              )),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: GoogleFonts.nunito()),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kBrandGreen),
          onPressed: () => Navigator.pop(
            context,
            _EditResult(name: _nameCtrl.text.trim(), role: _role),
          ),
          child: Text('Save', style: GoogleFonts.nunito(color: Colors.white)),
        ),
      ],
    );
  }
}
