import 'package:flutter/material.dart';

/// Displays 1–2 initials of a name in a coloured circle.
/// Per-person colours match the TSheets calendar colour scheme.
class InitialsAvatar extends StatelessWidget {
  final String name;
  final double size;
  final Color? backgroundColor;
  final Color? textColor;

  const InitialsAvatar({
    super.key,
    required this.name,
    this.size = 28,
    this.backgroundColor,
    this.textColor,
  });

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  static const Map<String, Color> _namedColors = {
    'Matthew Walsh':        Color(0xFF9E9E9E),
    'Christopher Doherty':  Color(0xFFE65100),
    'James Doherty':        Color(0xFF00C853),
    'Ryan Clark':           Color(0xFF8B0000),
    'Connor Hibbard':       Color(0xFF6D6E00),
    'Harrington Riendeau':  Color(0xFF00AEEF),
    'Liam Arnold':          Color(0xFF6A1B9A),
    'Stephen Tremblay':     Color(0xFFD32F2F),
    'Colin Arnold':         Color(0xFFBF8040),
  };

  Color get _defaultColor {
    final trimmed = name.trim();
    if (_namedColors.containsKey(trimmed)) return _namedColors[trimmed]!;
    const fallbacks = [
      Color(0xFF1565C0), Color(0xFF2E7D32), Color(0xFF00695C),
      Color(0xFF4527A0), Color(0xFF558B2F), Color(0xFF00838F),
    ];
    final hash = name.codeUnits.fold(0, (sum, c) => sum + c);
    return fallbacks[hash % fallbacks.length];
  }

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ?? _defaultColor;
    final fg = textColor ?? Colors.white;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        _initials,
        style: TextStyle(
          color: fg,
          fontSize: size * 0.38,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
    );
  }
}
