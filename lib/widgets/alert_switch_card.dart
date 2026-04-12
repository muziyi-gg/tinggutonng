import 'package:flutter/material.dart';
import '../models/alert_type.dart';

class AlertSwitchCard extends StatelessWidget {
  final AlertType type;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  const AlertSwitchCard({super.key, required this.type, required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext ctx) {
    return Container(
      margin: const EdgeInsets.only(bottom:8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: enabled ? const Color(0xFFE8E8F0) : const Color(0xFFF5F5F7)),
      ),
      child: Row(children: [
        Container(
          width:36, height:36,
          decoration: BoxDecoration(
            color: (enabled ? _typeColor(type) : const Color(0xFFEEEEF5)).withOpacity(0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Center(child: Text(enabled ? type.icon : '◯', style:const TextStyle(fontSize:18))),
        ),
        const SizedBox(width:12),
        Expanded(
          child: Column(crossAxisAlignment:CrossAxisAlignment.start, children: [
            Text(type.name, style: TextStyle(
              fontSize:14, fontWeight:FontWeight.w600,
              color: enabled ? const Color(0xFF1A1A2E) : const Color(0xFFBBBBCC),
            )),
            const SizedBox(height:2),
            Text(type.desc, style:const TextStyle(fontSize:11, color:Color(0xFFBBBBCC))),
          ]),
        ),
        Switch.adaptive(
          value: enabled,
          onChanged: onChanged,
          activeColor: const Color(0xFFE84057),
        ),
      ]),
    );
  }

  Color _typeColor(AlertType t) {
    switch(t.id) {
      case 'A4': case 'A5': case 'A6': return const Color(0xFFE84057);
      case 'A2': return const Color(0xFF4CAF50);
      case 'A3': return const Color(0xFFFF5722);
      default: return const Color(0xFF6C63FF);
    }
  }
}
