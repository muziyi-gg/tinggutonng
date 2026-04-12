import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stock_provider.dart';
import '../widgets/stock_card.dart';
import '../widgets/live_status_indicator.dart';

class HomeScreen extends StatelessWidget {
  final VoidCallback onNavigateStocks;
  final VoidCallback onNavigateSettings;
  const HomeScreen({super.key, required this.onNavigateStocks, required this.onNavigateSettings});

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      body: SafeArea(child: Column(children: [
        _buildHeader(ctx),
        Expanded(child: _buildBody(ctx)),
      ])),
    );
  }

  Widget _buildHeader(BuildContext ctx) {
    final sp = context.watch<StockProvider>();
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: const BoxDecoration(color: Colors.white),
      child: Row(children: [
        const Text('听股通', style: TextStyle(fontSize:22, fontWeight:FontWeight.bold, color:Color(0xFF1A1A2E))),
        const SizedBox(width:8),
        LiveStatusIndicator(polling: sp.isPolling),
        const Spacer(),
        IconButton(
          onPressed: () => sp.reportAllStocks(),
          icon: const Icon(Icons.play_circle_fill, color: Color(0xFFE84057), size:28),
          tooltip: '手动播报自选股',
        ),
      ]),
    );
  }

  Widget _buildBody(BuildContext ctx) {
    final sp = context.watch<StockProvider>();
    final stocks = sp.stockList;
    final alerts = sp.recentAlerts;

    return CustomScrollView(slivers: [
      if (alerts.isNotEmpty)
        SliverToBoxAdapter(child: _AlertBanner(alert: alerts.first)),
      SliverToBoxAdapter(child: _sectionTitle('我的自选', onSeeAll: onNavigateStocks)),
      if (stocks.isEmpty)
        const SliverToBoxAdapter(child: _EmptyState())
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal:16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => Padding(
                padding: const EdgeInsets.only(bottom:10),
                child: StockCard(stock: stocks[i]),
              ),
              childCount: stocks.length > 5 ? 5 : stocks.length,
            ),
          ),
        ),
      SliverToBoxAdapter(child: _buildMonitorEntry(ctx)),
      if (alerts.isNotEmpty) ...[
        SliverToBoxAdapter(child: _sectionTitle('最近播报', null)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _AlertListItem(alert: alerts[i]),
              childCount: alerts.length > 10 ? 10 : alerts.length,
            ),
          ),
        ),
      ],
    ]);
  }

  Widget _buildMonitorEntry(BuildContext ctx) {
    return GestureDetector(
      onTap: onNavigateSettings,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE8E8F0)),
        ),
        child: const Row(children: [
          Icon(Icons.settings_input_antenna, color: Color(0xFF6C63FF), size:24),
          SizedBox(width:12),
          Expanded(child: Column(crossAxisAlignment:CrossAxisAlignment.start, children: [
            Text('监控设置', style:TextStyle(fontSize:15, fontWeight:FontWeight.w600)),
            Text('自定义播报类型与阈值', style:TextStyle(fontSize:12, color:Color(0xFF9999AA))),
          ])),
          Icon(Icons.chevron_right, color:Color(0xFFBBBBCC)),
        ]),
      ),
    );
  }

  Widget _sectionTitle(String title, {VoidCallback? onSeeAll}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(children: [
        Text(title, style: const TextStyle(fontSize:16, fontWeight:FontWeight.w600, color:Color(0xFF1A1A2E))),
        const Spacer(),
        if (onSeeAll != null) GestureDetector(
          onTap: onSeeAll,
          child: const Text('查看全部 ›', style: TextStyle(fontSize:13, color:Color(0xFF666687))),
        ),
      ]),
    );
  }
}

class _AlertBanner extends StatelessWidget {
  final dynamic alert;
  const _AlertBanner({required this.alert});

  @override
  Widget build(BuildContext ctx) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_bannerColor(alert.type.id).withOpacity(0.9), _bannerColor(alert.type.id).withOpacity(0.7)],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Text(alert.type.icon, style: const TextStyle(fontSize:22)),
        const SizedBox(width:10),
        Expanded(child: Text(alert.text, style: const TextStyle(color:Colors.white, fontSize:15, fontWeight:FontWeight.w500))),
        Text(_timeAgo(alert.ts), style: const TextStyle(color:Colors.white70, fontSize:12)),
      ]),
    );
  }

  Color _bannerColor(String id) {
    switch(id) {
      case 'A4': case 'A5': return const Color(0xFFE84057);
      case 'A6': return const Color(0xFFFF7F50);
      case 'A2': return const Color(0xFF4CAF50);
      case 'A3': return const Color(0xFFFF5722);
      default: return const Color(0xFF6C63FF);
    }
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '${d.inSeconds}秒前';
    if (d.inHours < 1) return '${d.inMinutes}分钟前';
    return '${d.inHours}小时前';
  }
}

class _AlertListItem extends StatelessWidget {
  final dynamic alert;
  const _AlertListItem({required this.alert});

  @override
  Widget build(BuildContext ctx) {
    final color = _bannerColor(alert.type.id);
    return Container(
      margin: const EdgeInsets.only(bottom:8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color:Colors.white, borderRadius:BorderRadius.circular(10)),
      child: Row(children: [
        Container(
          width:32, height:32,
          decoration: BoxDecoration(color:color.withOpacity(0.12), borderRadius:BorderRadius.circular(8)),
          child: Center(child: Text(alert.type.icon, style:const TextStyle(fontSize:16))),
        ),
        const SizedBox(width:10),
        Expanded(child: Text(alert.text, style:const TextStyle(fontSize:13))),
        Text(_timeAgo(alert.ts), style:const TextStyle(fontSize:11, color:Color(0xFFBBBBCC))),
      ]),
    );
  }

  Color _bannerColor(String id) {
    switch(id) {
      case 'A4': case 'A5': return const Color(0xFFE84057);
      case 'A6': return const Color(0xFFFF7F50);
      case 'A2': return const Color(0xFF4CAF50);
      case 'A3': return const Color(0xFFFF5722);
      default: return const Color(0xFF6C63FF);
    }
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '${d.inSeconds}秒前';
    if (d.inHours < 1) return '${d.inMinutes}分钟前';
    return '${d.inHours}小时前';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext ctx) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(color:Colors.white, borderRadius:BorderRadius.circular(14)),
      child: const Column(children: [
        Icon(Icons.add_chart, size:48, color:Color(0xFFDDDDDD)),
        SizedBox(height:12),
        Text('暂无自选股', style:TextStyle(fontSize:15, color:Color(0xFF9999AA))),
        SizedBox(height:4),
        Text('点击上方"+"添加您的第一只股票', style:TextStyle(fontSize:12, color:Color(0xFFBBBBCC))),
      ]),
    );
  }
}
