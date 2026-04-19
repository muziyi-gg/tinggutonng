import 'package:flutter/material.dart';
import '../services/tts_service.dart';

/// TTS 调试页面：测试播报并显示完整诊断信息
class TtsDebugScreen extends StatefulWidget {
  const TtsDebugScreen({super.key});

  @override
  State<TtsDebugScreen> createState() => _TtsDebugScreenState();
}

class _TtsDebugScreenState extends State<TtsDebugScreen> {
  // 手动创建一个 TtsService 实例用于测试
  // 注意：如果 App 级别已经初始化过，这里会创建第二个实例
  // 但调试目的下这是 OK 的
  final TtsService _testTts = TtsService();
  bool _initDone = false;
  String _lastError = '';
  String _testResult = '';
  TtsState? _lastState;
  String? _selectedEngine;
  String _testText = '上证指数上涨，平安银行报15.60元，涨1.23%';

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    setState(() => _lastError = '初始化中...');
    await _testTts.init();
    setState(() {
      _initDone = _testTts.initDone;
      if (!_initDone) _lastError = _testTts.initError;
    });
  }

  Future<void> _testSpeak() async {
    if (!_initDone) {
      setState(() => _testResult = 'TTS 未初始化成功: ${_testTts.initError}');
      return;
    }
    setState(() {
      _testResult = '正在播报...';
      _lastState = _testTts.state;
    });
    try {
      await _testTts.speak(_testText);
      setState(() {
        _testResult = 'speak() 成功返回';
        _lastState = _testTts.state;
      });
    } on TtsException catch (e) {
      setState(() {
        _testResult = 'TtsException: $e';
        _lastError = '$e';
      });
    } catch (e) {
      setState(() {
        _testResult = 'Exception: $e';
        _lastError = '$e';
      });
    }
  }

  Future<void> _testStop() async {
    await _testTts.stop();
    setState(() => _testResult = 'stop() 成功');
  }

  @override
  void dispose() {
    _testTts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TTS 调试'),
        backgroundColor: const Color(0xFFE84057),
        foregroundColor: Colors.white,
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // 诊断信息
        _card('诊断信息', [
          _row('初始化状态', _initDone ? '✅ 成功' : '❌ 失败'),
          if (!_initDone && _testTts.initError.isNotEmpty)
            _row('初始化错误', _testTts.initError),
          _row('平台', '${_testTts.initDone ? (_testTts.langAvailable >= 0 ? 'Android' : 'iOS') : '未知'}'),
          _row('当前状态', _testTts.state.name),
          _row('TTS 语言', _testTts.currentLanguage),
          _row('语言可用', _testTts.langAvailable >= 1 ? '✅ 可用' : '❌ 不可用 (${_testTts.langAvailable})'),
          if (_testTts.availableEngines.isNotEmpty)
            _row('可用引擎', _testTts.availableEngines.join(', ')),
          if (_testTts.lastPlatformCode != null)
            _row('错误码', _testTts.lastPlatformCode!),
          if (_testTts.lastErrorMessage != null)
            _row('引擎错误信息', _testTts.lastErrorMessage!),
        ]),

        const SizedBox(height: 16),

        // 测试播报
        _card('测试播报', [
          TextField(
            decoration: const InputDecoration(
              labelText: '播报文本',
              border: OutlineInputBorder(),
              hintText: '输入要播报的文本',
            ),
            controller: TextEditingController(text: _testText),
            onChanged: (v) => _testText = v,
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _initDone ? _testSpeak : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('播放'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE84057),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testStop,
                icon: const Icon(Icons.stop),
                label: const Text('停止'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          if (_lastState != null) Text('当前 TTS 状态: ${_lastState!.name}', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          if (_testResult.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _testResult.contains('Exception') || _testResult.contains('失败')
                    ? Colors.red[50]
                    : Colors.green[50],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_testResult, style: TextStyle(
                fontSize: 13,
                color: _testResult.contains('Exception') || _testResult.contains('失败')
                    ? Colors.red[700]
                    : Colors.green[700],
              )),
            ),
        ]),

        const SizedBox(height: 16),

        // 错误日志
        if (_lastError.isNotEmpty)
          _card('最近错误', [
            Text(_lastError, style: const TextStyle(fontSize: 13, color: Colors.red)),
          ]),

        const SizedBox(height: 12),
        const Text(
          '💡 如果播放失败，请把以上诊断信息截图发给我',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ]),
    );
  }

  Widget _card(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const Divider(),
            ...children.map((c) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: c)),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 90, child: Text('$label:', style: TextStyle(fontSize: 12, color: Colors.grey[600]))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
      ]),
    );
  }
}
