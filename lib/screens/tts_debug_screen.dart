import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/stock_provider.dart';

/// TTS + 生命周期调试页面：查看完整日志，测试各种场景
class TtsDebugScreen extends StatefulWidget {
  const TtsDebugScreen({super.key});

  @override
  State<TtsDebugScreen> createState() => _TtsDebugScreenState();
}

class _TtsDebugScreenState extends State<TtsDebugScreen> {
  String _testText = '上证指数上涨，平安银行报15.60元，涨1.23%';
  String _manualLog = '';

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TTS & 生命周期调试'),
        backgroundColor: const Color(0xFFE84057),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              context.read<StockProvider>().clearLog();
              setState(() {});
            },
            tooltip: '清空日志',
          ),
        ],
      ),
      body: Consumer<StockProvider>(
        builder: (ctx, sp, _) {
          final log = sp.debugLog;

          return Column(children: [
            // 顶部测试区
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                // 生命周期状态卡片
                _lifecycleCard(sp),
                const SizedBox(height: 12),
                // 测试输入
                Row(children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: '测试播报文本',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      controller: TextEditingController(text: _testText),
                      onChanged: (v) => _testText = v,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        final txt = _testText;
                        sp.startReport();
                        _addLog('用户点击：开始播报（interval=${sp.reportIntervalSec}s）');
                      },
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('开始'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE84057),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                      ),
                    ),
                    const SizedBox(height: 4),
                    OutlinedButton.icon(
                      onPressed: () {
                        sp.stopSpeaking();
                        _addLog('用户点击：停止播报');
                      },
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('停止'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                      ),
                    ),
                  ]),
                ]),
              ]),
            ),

            // 分隔线
            const Divider(height: 1),

            // 日志列表
            Expanded(child: log.isEmpty
                ? Center(child: Text('暂无日志\n请测试各种场景（熄屏/切后台）后查看', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[400], fontSize: 14)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    itemCount: log.length,
                    itemBuilder: (ctx, i) {
                      final e = log[log.length - 1 - i]; // 最新的在前
                      return _logLine(e);
                    },
                  )),
          ]);
        },
      ),
    );
  }

  Widget _lifecycleCard(StockProvider sp) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blue[100]!),
      ),
      child: Row(children: [
        Icon(Icons.phone_android, color: Colors.blue[700], size: 20),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('App 生命周期: ${_lifecycleName(sp.debugLog.isNotEmpty ? sp.debugLog.last.ts : DateTime.now())}',
              style: TextStyle(fontSize: 12, color: Colors.blue[700])),
          Text('播报状态: _speaking=${sp.isSpeaking} | TTS播放中=${sp.debugLog.any((e) => e.msg.contains('START'))}',
              style: TextStyle(fontSize: 11, color: Colors.blue[600])),
          Text('计时器活跃: ${sp.debugLog.any((e) => e.tag == 'lifecycle' && e.msg.contains('timer'))}',
              style: TextStyle(fontSize: 11, color: Colors.blue[600])),
        ]),
      ]),
    );
  }

  String _lifecycleName(DateTime ts) {
    final diff = DateTime.now().difference(ts);
    if (diff.inSeconds < 5) return 'resumed（刚刚）';
    if (diff.inSeconds < 30) return 'resumed（${diff.inSeconds}秒前）';
    return 'paused（${diff.inSeconds}秒前）';
  }

  void _addLog(String msg) {
    setState(() {
      _manualLog += '[${DateTime.now().toString().substring(11, 19)}] $msg\n';
    });
  }

  Widget _logLine(dynamic e) {
    Color tagColor;
    IconData tagIcon;
    switch (e.tag) {
      case 'lifecycle':
        tagColor = Colors.orange;
        tagIcon = Icons.phone_android;
        break;
      case 'report':
        tagColor = Colors.purple;
        tagIcon = Icons.mic;
        break;
      case 'poll':
        tagColor = Colors.green;
        tagIcon = Icons.cloud;
        break;
      case 'TTS':
        tagColor = Colors.blue;
        tagIcon = Icons.volume_up;
        break;
      default:
        tagColor = Colors.grey;
        tagIcon = Icons.info;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(tagIcon, size: 12, color: tagColor),
        const SizedBox(width: 4),
        Text(e.ts.toString().substring(11, 19),
            style: TextStyle(fontSize: 10, color: Colors.grey[400])),
        const SizedBox(width: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: tagColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text('[${e.tag}]', style: TextStyle(fontSize: 9, color: tagColor, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(e.msg,
              style: const TextStyle(fontSize: 11),
              softWrap: true),
        ),
      ]),
    );
  }
}