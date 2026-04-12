import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/config_provider.dart';
import '../providers/stock_provider.dart';
import '../models/alert_type.dart';
import '../widgets/alert_switch_card.dart';

class MonitorSettingsScreen extends StatefulWidget {
  const MonitorSettingsScreen({super.key});
  @override
  State<MonitorSettingsScreen> createState() => _MonitorSettingsScreenState();
}

class _MonitorSettingsScreenState extends State<MonitorSettingsScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length:2, vsync:this);
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

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
        title: const Text('监控设置', style: TextStyle(color:Color(0xFF1A1A2E), fontWeight:FontWeight.w600)),
        bottom: TabBar(
          controller: _tab,
          labelColor: const Color(0xFFE84057),
          unselectedLabelColor: const Color(0xFF9999AA),
          indicatorColor: const Color(0xFFE84057),
          indicatorWeight: 2,
          tabs: const [
            Tab(text:'播报开关'),
            Tab(text:'参数配置'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildSwitchTab(),
          _buildThresholdTab(),
        ],
      ),
    );
  }

  Widget _buildSwitchTab() {
    final cp = context.watch<ConfigProvider>();
    final types = AlertType.values;
    // 按优先级分组
    final p0 = types.where((t) => t.priority == AlertPriority.p0).toList();
    final p1 = types.where((t) => t.priority == AlertPriority.p1).toList();
    final p2 = types.where((t) => t.priority == AlertPriority.p2).toList();
    final p3 = types.where((t) => t.priority == AlertPriority.p3).toList();
    final p4 = types.where((t) => t.priority == AlertPriority.p4).toList();

    return ListView(padding: const EdgeInsets.all(16), children: [
      _buildPriorityHint('🔴 P0 最高优先级 — 可打断一切播报'),
      ...p0.map((t) => AlertSwitchCard(type:t, enabled:cp.isEnabled(t), onChanged:(v) => cp.setEnabled(t, v))),
      const SizedBox(height:8),
      _buildPriorityHint('🟠 P1 紧急 — 可打断P2/P3/P4'),
      ...p1.map((t) => AlertSwitchCard(type:t, enabled:cp.isEnabled(t), onChanged:(v) => cp.setEnabled(t, v))),
      const SizedBox(height:8),
      _buildPriorityHint('🟡 P2 中等 — 正常排队'),
      ...p2.map((t) => AlertSwitchCard(type:t, enabled:cp.isEnabled(t), onChanged:(v) => cp.setEnabled(t, v))),
      const SizedBox(height:8),
      _buildPriorityHint('🟢 P3 例行 — 最低优先级'),
      ...p3.map((t) => AlertSwitchCard(type:t, enabled:cp.isEnabled(t), onChanged:(v) => cp.setEnabled(t, v))),
      const SizedBox(height:8),
      _buildPriorityHint('⚪ P4 基础 — 不打断任何播报'),
      ...p4.map((t) => AlertSwitchCard(type:t, enabled:cp.isEnabled(t), onChanged:(v) => cp.setEnabled(t, v))),
    ]);
  }

  Widget _buildPriorityHint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom:8, top:4),
      child: Text(text, style: const TextStyle(fontSize:12, color:Color(0xFF9999AA), fontWeight:FontWeight.w500)),
    );
  }

  Widget _buildThresholdTab() {
    final cp = context.watch<ConfigProvider>();
    final sp = context.read<StockProvider>();
    final items = [
      _ThresholdItem(
        label:'快速拉升阈值',
        desc:'5分钟内涨幅超过此值则触发预警',
        value: cp.threshold(AlertType.rapidRise).toDouble(),
        min:3, max:10, suffix:'%',
        onChanged:(v) {
          cp.setThreshold(AlertType.rapidRise, v.round());
          sp.updateThreshold(rise: v.round());
        },
      ),
      _ThresholdItem(
        label:'快速下跌阈值',
        desc:'5分钟内跌幅超过此值则触发预警',
        value: cp.threshold(AlertType.rapidFall).toDouble(),
        min:3, max:10, suffix:'%',
        onChanged:(v) {
          cp.setThreshold(AlertType.rapidFall, v.round());
          sp.updateThreshold(fall: v.round());
        },
      ),
      _ThresholdItem(
        label:'大盘异动阈值',
        desc:'上证/深证/创业板指涨跌幅超此值时提醒',
        value: cp.threshold(AlertType.indexMove).toDouble(),
        min:0.5, max:3, suffix:'%',
        onChanged:(v) {
          cp.setThreshold(AlertType.indexMove, v.round());
          sp.updateThreshold(idx: (v*10).round());
        },
      ),
      _ThresholdItem(
        label:'成交量异常倍数',
        desc:'5分钟成交量超过昨日均量的此倍数时提醒',
        value: cp.threshold(AlertType.volumeAbnormal).toDouble(),
        min:2, max:10, suffix:'倍',
        onChanged:(v) {
          cp.setThreshold(AlertType.volumeAbnormal, v.round());
          sp.updateThreshold(vol: v.round());
        },
      ),
      _ThresholdItem(
        label:'集合竞价阈值',
        desc:'竞价阶段（9:15-9:25）涨跌幅超此值时提醒',
        value: cp.threshold(AlertType.auctionMove).toDouble(),
        min:3, max:10, suffix:'%',
        onChanged:(v) {
          cp.setThreshold(AlertType.auctionMove, v.round());
          sp.updateThreshold(auction: v.round());
        },
      ),
    ];

    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('调节各项阈值，实时生效', style:TextStyle(fontSize:13, color:Color(0xFF9999AA))),
      const SizedBox(height:16),
      ...items.map((i) => _ThresholdSlider(item:i)),
    ]);
  }
}

class _ThresholdItem {
  final String label, desc;
  final double value, min, max;
  final String suffix;
  final ValueChanged<double> onChanged;
  _ThresholdItem({required this.label, required this.desc, required this.value, required this.min, required this.max, required this.suffix, required this.onChanged});
}

class _ThresholdSlider extends StatelessWidget {
  final _ThresholdItem item;
  const _ThresholdSlider({required this.item});

  @override
  Widget build(BuildContext ctx) {
    return Container(
      margin: const EdgeInsets.only(bottom:16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color:Colors.white, borderRadius:BorderRadius.circular(14)),
      child: Column(crossAxisAlignment:CrossAxisAlignment.start, children: [
        Row(children: [
          Text(item.label, style:const TextStyle(fontSize:15, fontWeight:FontWeight.w600)),
          const Spacer(),
          Text('${item.value.toStringAsFixed(1)}${item.suffix}',
              style: const TextStyle(fontSize:16, fontWeight:FontWeight.bold, color:Color(0xFFE84057))),
        ]),
        const SizedBox(height:4),
        Text(item.desc, style:const TextStyle(fontSize:11, color:Color(0xFFBBBBCC))),
        const SizedBox(height:10),
        SliderTheme(
          data: SliderTheme.of(ctx).copyWith(
            activeTrackColor: const Color(0xFFE84057),
            inactiveTrackColor: const Color(0xFFF0F0F5),
            thumbColor: const Color(0xFFE84057),
            overlayColor: const Color(0xFFE84057).withOpacity(0.12),
          ),
          child: Slider(
            value: item.value,
            min: item.min,
            max: item.max,
            divisions: ((item.max - item.min) * 2).round(),
            onChanged: item.onChanged,
          ),
        ),
      ]),
    );
  }
}
