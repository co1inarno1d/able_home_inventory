// lib/integrations/quickbooks_service.dart
//
// QuickBooks Online integration — OAuth2 connect + customer search.
// All API calls are proxied through the qb-proxy Supabase edge function
// so credentials never live in the Flutter app.

import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

const String _proxyBase =
    'https://kaujczbhtajqfrjgbxft.supabase.co/functions/v1/qb-proxy';

const String _anonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImthdWpjemJodGFqcWZyamdieGZ0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0NDI3NjYsImV4cCI6MjA4NzAxODc2Nn0.WbxeNDGKlOVEy7_2F_VBoa0oRv0JHqK1NdpP1G6LDbk';

// Always use the production redirect URI — Intuit production apps require HTTPS
// and don't accept localhost. Connect QB from the deployed app at inventory.ableha.com.
const String _redirectUri = 'https://inventory.ableha.com/qb-callback';

Map<String, String> get _headers => {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $_anonKey',
    };

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------

/// Thrown when QB tokens are missing, expired, or revoked.
/// The caller should show "reconnect" UI rather than a generic error.
class QbNotConnectedException implements Exception {
  final String message;
  const QbNotConnectedException(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// QB financials summary returned from /financials
// ---------------------------------------------------------------------------

class QbFinancials {
  final double billed;
  final double collected;
  final double totalOwed;
  final int overdueCount;
  final int invoiceCount;

  const QbFinancials({
    required this.billed,
    required this.collected,
    required this.totalOwed,
    required this.overdueCount,
    required this.invoiceCount,
  });
}

// ---------------------------------------------------------------------------
// QB customer summary (for service call context)
// ---------------------------------------------------------------------------

class QbInvoiceSummary {
  final String date;
  final double amount;
  final double balance;
  final String note;
  const QbInvoiceSummary({
    required this.date,
    required this.amount,
    required this.balance,
    required this.note,
  });
}

class QbCustomerSummary {
  final String customerName;
  final double balance;
  final String notes;
  final List<QbInvoiceSummary> invoices;
  const QbCustomerSummary({
    required this.customerName,
    required this.balance,
    required this.notes,
    required this.invoices,
  });
}

// ---------------------------------------------------------------------------
// QB customer record returned from search
// ---------------------------------------------------------------------------

class QbCustomer {
  final String id;
  final String name;
  final String phone;
  final String email;
  final String address;

  const QbCustomer({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.address,
  });

  factory QbCustomer.fromJson(Map<String, dynamic> j) => QbCustomer(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        phone: j['phone']?.toString() ?? '',
        email: j['email']?.toString() ?? '',
        address: j['address']?.toString() ?? '',
      );
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

class QuickBooksService {
  QuickBooksService._();

  // ---- Deep link (works once QB customer ID is linked) --------------------

  static String customerUrl(String qbCustomerId) =>
      'https://app.qbo.intuit.com/app/customerdetail?nameId=$qbCustomerId';

  static Future<bool> openCustomer(String qbCustomerId) async {
    if (qbCustomerId.isEmpty) return false;
    return launchUrl(Uri.parse(customerUrl(qbCustomerId)),
        mode: LaunchMode.externalApplication);
  }

  // ---- Connection status --------------------------------------------------

  static Future<({bool connected, String? realmId})> getStatus() async {
    final res = await http.get(
      Uri.parse('$_proxyBase/status'),
      headers: _headers,
    );
    if (res.statusCode != 200) return (connected: false, realmId: null);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      connected: body['connected'] == true,
      realmId: body['realm_id']?.toString(),
    );
  }

  // ---- OAuth connect flow -------------------------------------------------

  static const _stateKey = 'qb_oauth_state';

  /// Step 1: Get the authorization URL from the edge function and open it.
  /// The server issues a state token for CSRF protection; we store it in
  /// localStorage so we can read it back after the QB redirect.
  static Future<String?> startOAuthFlow() async {
    try {
      final res = await http.post(
        Uri.parse('$_proxyBase/auth-url'),
        headers: _headers,
        body: jsonEncode({'redirect_uri': _redirectUri}),
      );
      if (res.statusCode != 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        return body['error']?.toString() ?? 'Failed to get auth URL';
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final url = body['url']?.toString() ?? '';
      final state = body['state']?.toString() ?? '';
      if (url.isEmpty) return 'No auth URL returned';
      // Persist state across the redirect so we can verify it on callback.
      if (kIsWeb && state.isNotEmpty) {
        html.window.localStorage[_stateKey] = state;
      }
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      return null; // success — browser opened
    } catch (e) {
      return e.toString();
    }
  }

  /// Step 2: After QB redirects back with ?code=...&realmId=...&state=...,
  /// call this to complete the token exchange. Passes state back to the server
  /// for CSRF verification, then clears it from localStorage.
  static Future<String?> completeOAuthFlow({
    required String code,
    required String realmId,
  }) async {
    String? state;
    if (kIsWeb) {
      state = html.window.localStorage[_stateKey];
      html.window.localStorage.remove(_stateKey);
    }
    // Also read state from the redirect URL itself as a fallback.
    final urlState = Uri.base.queryParameters['state'];
    final resolvedState = state ?? urlState ?? '';

    try {
      final res = await http.post(
        Uri.parse('$_proxyBase/callback'),
        headers: _headers,
        body: jsonEncode({
          'code': code,
          'realm_id': realmId,
          'redirect_uri': _redirectUri,
          'state': resolvedState,
        }),
      );
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        return body['error']?.toString() ?? 'Token exchange failed';
      }
      return null; // success
    } catch (e) {
      return e.toString();
    }
  }

  /// Removes stored tokens (disconnect QB).
  static Future<void> disconnect() async {
    await http.post(
      Uri.parse('$_proxyBase/disconnect'),
      headers: _headers,
    );
  }

  // ---- Customer search ----------------------------------------------------

  /// Fetches revenue, payments, and outstanding invoices for a date range.
  /// Returns null if QB is not connected (caller shows "--" placeholders).
  static Future<QbFinancials?> fetchFinancials({
    required DateTime start,
    required DateTime end,
  }) async {
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    try {
      final res = await http.post(
        Uri.parse('$_proxyBase/financials'),
        headers: _headers,
        body: jsonEncode({'start_date': fmt(start), 'end_date': fmt(end)}),
      );
      if (res.statusCode == 401) return null; // not connected
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return QbFinancials(
        billed: (body['billed'] as num?)?.toDouble() ?? 0,
        collected: (body['collected'] as num?)?.toDouble() ?? 0,
        totalOwed: (body['total_owed'] as num?)?.toDouble() ?? 0,
        overdueCount: (body['overdue_count'] as num?)?.toInt() ?? 0,
        invoiceCount: (body['invoice_count'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetches customer name, balance, notes, and last 5 invoices from QB.
  /// Returns null if QB is not connected or customer not found.
  static Future<QbCustomerSummary?> fetchCustomerSummary(String qbCustomerId) async {
    if (qbCustomerId.isEmpty) return null;
    try {
      final res = await http.post(
        Uri.parse('$_proxyBase/customer-summary'),
        headers: _headers,
        body: jsonEncode({'qb_customer_id': qbCustomerId}),
      );
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final invoices = (body['invoices'] as List? ?? []).map((i) {
        final m = i as Map<String, dynamic>;
        return QbInvoiceSummary(
          date: m['date']?.toString() ?? '',
          amount: (m['amount'] as num?)?.toDouble() ?? 0,
          balance: (m['balance'] as num?)?.toDouble() ?? 0,
          note: m['note']?.toString() ?? '',
        );
      }).toList();
      return QbCustomerSummary(
        customerName: body['customer_name']?.toString() ?? '',
        balance: (body['balance'] as num?)?.toDouble() ?? 0,
        notes: body['notes']?.toString() ?? '',
        invoices: invoices,
      );
    } catch (_) {
      return null;
    }
  }

  /// Appends [note] to the Notes field of a QB customer record.
  /// Silent on failure — never blocks the user flow.
  static Future<void> appendNoteToCustomer({
    required String qbCustomerId,
    required String note,
  }) async {
    if (qbCustomerId.isEmpty) return;
    try {
      await http.post(
        Uri.parse('$_proxyBase/append-note'),
        headers: _headers,
        body: jsonEncode({'qb_customer_id': qbCustomerId, 'note': note}),
      );
    } catch (_) {}
  }

  /// Returns QB customers matching [query].
  /// Throws [QbNotConnectedException] when tokens are missing or expired
  /// (caller should show reconnect UI). Throws [Exception] for other errors.
  static Future<List<QbCustomer>> searchCustomers(String query) async {
    final res = await http.post(
      Uri.parse('$_proxyBase/search'),
      headers: _headers,
      body: jsonEncode({'query': query}),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode == 401) {
      throw QbNotConnectedException(body['error']?.toString() ?? 'QB not connected');
    }
    if (res.statusCode != 200) {
      throw Exception(body['error']?.toString() ?? 'QB search failed');
    }
    final list = (body['customers'] as List? ?? []);
    return list
        .map((e) => QbCustomer.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
