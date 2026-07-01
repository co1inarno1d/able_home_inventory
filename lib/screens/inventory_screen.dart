// lib/screens/inventory_screen.dart
//
// Mobile-only hub that lets users pick Stairlifts or Ramps.
// On desktop, Lifts and Ramps appear as separate nav tabs.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../utils/utils.dart';

// LiftsScreen and RampsScreen live in main.dart — imported via the app barrel.
// We use a callback so this screen doesn't need to import main.dart directly.

class InventoryScreen extends StatelessWidget {
  /// Called when user taps Stairlifts — caller pushes LiftsScreen.
  final VoidCallback onLifts;
  /// Called when user taps Ramps — caller pushes RampsScreen.
  final VoidCallback onRamps;

  const InventoryScreen({super.key, required this.onLifts, required this.onRamps});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kSurface,
      appBar: AppBar(
        backgroundColor: kBrandGreenDark,
        foregroundColor: Colors.white,
        title: Text('Inventory',
            style: GoogleFonts.nunito(fontWeight: FontWeight.w700)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InventoryCard(
              icon: Icons.list_alt_rounded,
              label: 'Stairlifts',
              subtitle: 'Track, prep, and manage stairlift units',
              color: kBrandGreen,
              onTap: onLifts,
            ),
            const SizedBox(height: 16),
            _InventoryCard(
              icon: Icons.stairs_rounded,
              label: 'Ramps',
              subtitle: 'Manage ramp inventory and CCALS jobs',
              color: Colors.teal,
              onTap: onRamps,
            ),
          ],
        ),
      ),
    );
  }
}

class _InventoryCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _InventoryCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: kCardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: GoogleFonts.nunito(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        style: GoogleFonts.nunito(
                            fontSize: 13, color: Colors.grey[600])),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}
