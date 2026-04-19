import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stock_provider.dart';
import '../models/alert_type.dart';
import '../widgets/alert_switch_card.dart';

class MonitorSettingsScreen extends StatefulWidget {
  const MonitorSettingsScreen({super.key});
  @override
  State<MonitorSettingsScreen> createState() => _MonitorSettingsScreenState();
}

class _MonitorSettingsScreenState extends State<MonitorSettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Color(0xFF1A1A2E)),
          onPressed: () => Navigator.pop(ctx),
        ),
        title: const Text('监控设置',
            style: TextStyle(color: Color(0xFF1A1A2E), fontWeight: FontWeight.w600)),
        bottom: TabBar(
          controller: _tab,
          labelColor: const Color(0xFFE84057),
          unselectedLabelColor: const Color(0xFF9999AA),
          indicatorColor: const Color(0xFFE84057),
          tabs: const [
            Tab(text: '播报开关'),
            Tab(text: '参数配置'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildSwitchTab(ctx),
          _buildThresholdTab(ctx),
        ],
      ),
    );
  }

  Widget _buildSwitchTab(BuildContext ctx) {
    final sp = context.watch<StockProvider>();
    final p0 = AlertType.values.where((t) => t.priority == AlertPriority.p0).toList();
    final p1 = AlertType.values.where((t) => t.priority == AlertPriority.p1).toList();
    final p2 = AlertType.values.where((t) => t.priority == AlertPriority.p2).toList();
    final p3 = AlertType.values.where((t) => t.priority == AlertPriority.p3).toList();
    final p4 = AlertType.values.where((t) => t.priority == AlertPriority.p4).toList();

    return ListView(padding: const EdgeInsets.all(16), children: [
      _priorityHint('🔴 P0 — 最高优先级（可打断一切播报）'),
      ...p0.map((t) => AlertSwitchCard(
          type: t, enabled: sp.isPolling, onChanged: (v) {})),
      const SizedBox(height: 8),
      _priorityHint('🟠 P1 — 紧急（可打断P2/P3/P4）'),
      ...p1.map((t) => AlertSwitchCard(
          type: t, enabled: sp.isPolling, onChanged: (v) {})),
      const SizedBox(height: 8),
      _priorityHint('🟡 P2 — 中等'),
      ...p2.map((t) => AlertSwitchCard(
          type: t, enabled: sp.isPolling, onChanged: (v) {})),
      const SizedBox(height: 8),
      _priorityHint('🟢 P3 — 例行'),
      ...p3.map((t) => AlertSwitchCard(
          type: t, enabled: sp.isPolling, onChanged: (v) {})),
      const SizedBox(height: 8),
      _priorityHint('⚪ P4 — 基础'),
      ...p4.map((t) => AlertSwitchCard(
          type: t, enabled: sp.isPolling, onChanged: (v) {})),
    ]);
  }

  Widget _priorityHint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(text,
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w500)),
    );
  }

  Widget _buildThresholdTab(BuildContext ctx) {
    final sp = context.watch<StockProvider>();
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Phase 1 播报参数设置',
          style: TextStyle(fontSize: 13, color: Color(0xFF9999AA))),
      const SizedBox(height: 16),
      _IntervalSelector(
        current: sp.reportIntervalSec,
        onChanged: (v) => sp.setReportInterval(v),
      ),
    ]);
  }
}

class _IntervalSelector extends StatelessWidget {
  final int current;
  final ValueChanged<int> onChanged;
  const _IntervalSelector({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext ctx) {
    final options = [1, 5, 10, 15, 30, 60, 300];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('播报间隔',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text('定时播报自选股行情的时间间隔',
            style: TextStyle(fontSize: 12, color: Color(0xFFBBBBCC))),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final sec in options)
              SizedBox(
                width: (MediaQuery.of(ctx).size.width - 80) / 4,
                child: _intervalButton(sec, current == sec),
              ),
          ],
        ),
      ]),
    );
  }

  Widget _intervalButton(int sec, bool selected) {
    final label = sec < 60 ? '${sec}秒' : '${sec ~/ 60}分钟';
    return GestureDetector(
      onTap: () => onChanged(sec),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE84057) : const Color(0xFFF5F5F7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : const Color(0xFF666687),
            ),
          ),
        ),
      ),
    );
  }
}
