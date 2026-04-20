import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:charset_converter/charset_converter.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import '../providers/stock_provider.dart';
import '../models/stock.dart';

class StockListScreen extends StatelessWidget {
  const StockListScreen({super.key});

  @override
  Widget build(BuildContext ctx) {
    final sp = Provider.of<StockProvider>(ctx);
    final stocks = sp.stockList;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Color(0xFF1A1A2E)),
          onPressed: () => Navigator.pop(ctx),
        ),
        title: const Text('自选股管理', style: TextStyle(color:Color(0xFF1A1A2E), fontWeight:FontWeight.w600)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color:Color(0xFFE84057)),
            onPressed: () => _showAddStock(ctx),
          ),
        ],
      ),
      body: stocks.isEmpty
          ? const Center(child: Column(mainAxisSize:MainAxisSize.min, children: [
              Icon(Icons.show_chart, size:48, color:Color(0xFFDDDDDD)),
              SizedBox(height:12),
              Text('暂无自选股', style:TextStyle(color:Color(0xFF9999AA))),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: stocks.length,
              itemBuilder: (ctx, i) => _StockListItem(stock: stocks[i]),
            ),
    );
  }

  void _showAddStock(BuildContext ctx) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddStockSheet(),
    );
  }
}

class _StockListItem extends StatelessWidget {
  final Stock stock;
  const _StockListItem({required this.stock});

  @override
  Widget build(BuildContext ctx) {
    final sp = Provider.of<StockProvider>(ctx, listen: false);
    final isUp = stock.changePct >= 0;
    final color = isUp ? const Color(0xFFE84057) : const Color(0xFF34C759);

    return Dismissible(
      key: Key(stock.code),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right:20),
        decoration: BoxDecoration(color:const Color(0xFFE84057), borderRadius:BorderRadius.circular(12)),
        child: const Icon(Icons.delete_outline, color:Colors.white),
      ),
      onDismissed: (_) => sp.removeStock(stock.code),
      child: Container(
        margin: const EdgeInsets.only(bottom:10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color:Colors.white, borderRadius:BorderRadius.circular(12)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment:CrossAxisAlignment.start, children: [
              Text(stock.name, style:const TextStyle(fontSize:15, fontWeight:FontWeight.w600)),
              const SizedBox(height:2),
              Text(stock.code, style:const TextStyle(fontSize:12, color:Color(0xFF9999AA))),
            ]),
          ),
          Column(crossAxisAlignment:CrossAxisAlignment.end, children: [
            Text('¥${stock.price.toStringAsFixed(2)}',
                style: TextStyle(fontSize:16, fontWeight:FontWeight.bold, color:color)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal:6, vertical:2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(stock.changePctDisplay,
                  style: TextStyle(fontSize:12, fontWeight:FontWeight.w600, color:color)),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _AddStockSheet extends StatefulWidget {
  const _AddStockSheet();
  @override
  State<_AddStockSheet> createState() => _AddStockSheetState();
}

class _AddStockSheetState extends State<_AddStockSheet> {
  final _ctrl = TextEditingController();
  final _suggestions = <_StockSuggestion>[];
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onSearchChanged);
    // 默认展示热词
    WidgetsBinding.instance.addPostFrameCallback((_) => _showHotList());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _search(_ctrl.text);
    });
  }

  /// 搜索策略：所有输入（中文/拼音/代码）统一走新浪搜索 API
  /// 新浪 suggest3.sinajs.cn 支持全市场 A 股搜索，完美支持中文
  /// 同时在本地热词池做拼音模糊匹配兜底
  Future<void> _search(String q) async {
    if (!mounted) return;
    setState(() { _loading = true; _suggestions.clear(); });

    final q2 = q.trim();
    if (q2.isEmpty) {
      _showHotList();
      return;
    }

    if (q2.length < 1) {
      setState(() { _loading = false; });
      return;
    }

    // 优先调新浪 API（全市场，支持中文/拼音/代码）
    final apiResults = await _searchSina(q2);
    if (apiResults.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _suggestions.addAll(apiResults.take(12));
        _loading = false;
      });
      return;
    }

    // 新浪无结果时，搜本地热词池兜底（处理冷门股/拼音）
    await _searchLocal(q2);
  }

  /// 新浪全市场股票搜索 API
  /// 支持：中文名称、拼音（首字母/全拼）、股票代码（6位或带前缀）
  /// type=11,12,13,14,15 覆盖 A 股（沪深京）
  /// 响应格式：var suggestvalue="名称,类型,代码,完整代码,名称2...;..."
  Future<List<_StockSuggestion>> _searchSina(String q) async {
    try {
      final encoded = Uri.encodeComponent(q);
      final url = 'https://suggest3.sinajs.cn/suggest/type=11,12,13,14,15&key=$encoded';
      final r = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://finance.sina.com.cn/',
        },
      ).timeout(const Duration(seconds: 5));

      if (r.statusCode != 200) return [];

      // 响应是 GBK 编码，使用 charset_converter 解码
      String body;
      try {
        body = await CharsetConverter.decode('gbk', r.bodyBytes);
      } catch (_) {
        // 兜底：把非 Latin-1 字节替换为 ? 再解码
        final safe = r.bodyBytes.map((b) => b < 256 ? b : 63).toList();
        body = latin1.decode(safe);
      }

      // 解析 var suggestvalue="..."
      final match = RegExp(r'var suggestvalue="([^"]+)"').firstMatch(body);
      if (match == null) return [];

      final items = match[1]!.split(';');
      final result = <_StockSuggestion>[];

      for (final item in items) {
        if (item.trim().isEmpty) continue;
        final parts = item.split(',');
        // parts[2] = 6位代码, parts[3] = 完整前缀代码 (sh600519 / sz000858 / bj920175)
        if (parts.length < 4) continue;
        final code = parts[3].trim();        // 完整代码，如 sh600519
        final name = parts[0].trim();
        if (code.isEmpty || name.isEmpty) continue;

        // 只取 A 股（完整代码以 sh/sz/bj 开头，且代码为6位数字）
        if (!RegExp(r'^(sh|sz|bj)\d{6}$').hasMatch(code)) continue;

        result.add(_StockSuggestion(
          code: code,
          name: name,
          pinyin: '',
        ));
      }
      return result;
    } catch (e) {
      debugPrint('Sina search error: $e');
    }
    return [];
  }

  /// 本地热词池搜索（拼音模糊兜底）
  Future<void> _searchLocal(String q) async {
    if (!mounted) return;
    final q2 = q.toLowerCase().trim();
    final filtered = _hotList.where((s) {
      if (s.code.toLowerCase().contains(q2)) return true;
      if (s.name.contains(q2)) return true;
      final py = s.pinyin.replaceAll(' ', '');
      if (py == q2) return true;
      if (py.contains(q2)) return true;
      final firstLetters = s.pinyin.split(' ').where((w) => w.isNotEmpty).map((w) => w[0]).join();
      if (firstLetters == q2) return true;
      if (firstLetters.contains(q2)) return true;
      return false;
    }).toList();

    if (!mounted) return;
    setState(() {
      _suggestions.addAll(filtered.take(15));
      _loading = false;
    });
  }

  void _showHotList() {
    if (!mounted) return;
    setState(() {
      _suggestions.clear();
      _suggestions.addAll(_hotList.take(30));
      _loading = false;
    });
  }

  /// 本地热词池（覆盖沪深京主要板块，80只A股核心股票）
  static final List<_StockSuggestion> _hotList = [
    _StockSuggestion(code:'sh600519', name:'贵州茅台',   pinyin:'gui zhou mao tai gzmt'),
    _StockSuggestion(code:'sh601318', name:'中国平安',   pinyin:'zhong guo ping an zgpa'),
    _StockSuggestion(code:'sh600036', name:'招商银行',   pinyin:'zhao shang yin hang zsyh'),
    _StockSuggestion(code:'sh601398', name:'工商银行',   pinyin:'gong shang yin hang gsyh'),
    _StockSuggestion(code:'sh601857', name:'中国石油',   pinyin:'zhong guo shi you zgsy'),
    _StockSuggestion(code:'sh601166', name:'兴业银行',   pinyin:'xing ye yin hang xyyh'),
    _StockSuggestion(code:'sh601288', name:'农业银行',   pinyin:'nong ye yin hang nyyh'),
    _StockSuggestion(code:'sh601988', name:'中国银行',   pinyin:'zhong guo yin hang zgyh'),
    _StockSuggestion(code:'sh600028', name:'中国石化',   pinyin:'zhong guo shi hua zgfh'),
    _StockSuggestion(code:'sh600050', name:'中国联通',   pinyin:'zhong guo lian tong zglt'),
    _StockSuggestion(code:'sh600000', name:'浦发银行',   pinyin:'pu fa yin hang pfyh'),
    _StockSuggestion(code:'sh600886', name:'国投电力',   pinyin:'guo tou dian li gtdl'),
    _StockSuggestion(code:'sh600900', name:'长江电力',   pinyin:'chang jiang dian li cjdl'),
    _StockSuggestion(code:'sz000858', name:'五粮液',     pinyin:'wu liang ye wly'),
    _StockSuggestion(code:'sz000001', name:'平安银行',   pinyin:'ping an yin hang payh'),
    _StockSuggestion(code:'sz000002', name:'万科A',       pinyin:'wan ke wk'),
    _StockSuggestion(code:'sz000333', name:'美的集团',   pinyin:'mei di ji tuan mdjt'),
    _StockSuggestion(code:'sz000651', name:'格力电器',   pinyin:'ge li dian qi gldq'),
    _StockSuggestion(code:'sz000725', name:'京东方A',     pinyin:'jing dong fang jdf'),
    _StockSuggestion(code:'sz000063', name:'中兴通讯',   pinyin:'zhong xing tong xun zxtx'),
    _StockSuggestion(code:'sz000661', name:'长春高新',   pinyin:'chang chun gao xin ccgx'),
    _StockSuggestion(code:'sz000876', name:'新希望',     pinyin:'xin xi wang xqw'),
    _StockSuggestion(code:'sz300059', name:'东方财富',   pinyin:'dong fang cai fu dftc'),
    _StockSuggestion(code:'sz300750', name:'宁德时代',   pinyin:'ning de shi dai ndsd'),
    _StockSuggestion(code:'sh688981', name:'中芯国际',   pinyin:'zhong xin guo ji zxgj'),
    _StockSuggestion(code:'sh688599', name:'南山铝业',   pinyin:'nan shan lv ye nsly'),
    _StockSuggestion(code:'sh688111', name:'金山办公',   pinyin:'jin shan ban gong jsbg'),
    _StockSuggestion(code:'sh688036', name:'传音控股',   pinyin:'chuan yin kong gu cykg'),
    _StockSuggestion(code:'sh688041', name:'海光信息',   pinyin:'hai guang xin xi hxxx'),
    _StockSuggestion(code:'sh688012', name:'中微公司',   pinyin:'zhong wei gong si zwgs'),
    _StockSuggestion(code:'sh600276', name:'恒瑞医药',   pinyin:'heng rui yi yao hryy'),
    _StockSuggestion(code:'sh603259', name:'药明康德',   pinyin:'yao ming kang de ymkd'),
    _StockSuggestion(code:'sh600031', name:'三一重工',   pinyin:'san yi zhong gong syzg'),
    _StockSuggestion(code:'sh600585', name:'海螺水泥',   pinyin:'hai luo shui ni hlsn'),
    _StockSuggestion(code:'sh600309', name:'万华化学',   pinyin:'wan hua hua xue whhx'),
    _StockSuggestion(code:'sh600887', name:'伊利股份',   pinyin:'yi li gu fen ylgf'),
    _StockSuggestion(code:'sh603288', name:'海天味业',   pinyin:'hai tian wei ye htwy'),
    _StockSuggestion(code:'sh600690', name:'海尔智家',   pinyin:'hai er zhi jia hezj'),
    _StockSuggestion(code:'sh600703', name:'三安光电',   pinyin:'san an guang dian sagd'),
    _StockSuggestion(code:'sh600089', name:'特变电工',   pinyin:'te bian dian gong tbdy'),
    _StockSuggestion(code:'sh600104', name:'上汽集团',   pinyin:'shang qi ji tuan sqjt'),
    _StockSuggestion(code:'sh600150', name:'中国船舶',   pinyin:'zhong guo chuan bo zgcb'),
    _StockSuggestion(code:'sh600346', name:'恒力石化',   pinyin:'heng li shi hua hlfh'),
    _StockSuggestion(code:'sh600009', name:'上海机场',   pinyin:'shang hai ji chang shjjc'),
    _StockSuggestion(code:'sh601888', name:'中国中免',   pinyin:'zhong guo zhong mian zgzm'),
    _StockSuggestion(code:'sh601186', name:'中国铁建',   pinyin:'zhong guo tie jian zgtj'),
    _StockSuggestion(code:'sh601669', name:'中国电建',   pinyin:'zhong guo dian jian zgdj'),
    _StockSuggestion(code:'sh601728', name:'中国电信',   pinyin:'zhong guo dian xin zgdx'),
    _StockSuggestion(code:'sh600941', name:'中国移动',   pinyin:'zhong guo yi dong zgyd'),
    _StockSuggestion(code:'sh601012', name:'隆基绿能',   pinyin:'long ji lv neng ljln'),
    _StockSuggestion(code:'sh600522', name:'中天科技',   pinyin:'zhong tian ke ji ztkj'),
    _StockSuggestion(code:'sh601658', name:'邮储银行',   pinyin:'you chu yin hang ycyh'),
    _StockSuggestion(code:'sh600837', name:'海通证券',   pinyin:'hai tong zheng quan htzq'),
    _StockSuggestion(code:'sh601688', name:'华泰证券',   pinyin:'hua tai zheng quan htzq'),
    _StockSuggestion(code:'sh600999', name:'招商证券',   pinyin:'zhao shang zheng quan zszq'),
    _StockSuggestion(code:'sh601377', name:'兴业证券',   pinyin:'xing ye zheng quan xyzq'),
    _StockSuggestion(code:'sz002475', name:'立讯精密',   pinyin:'li xun jing mi lxjm'),
    _StockSuggestion(code:'sz300015', name:'爱尔眼科',   pinyin:'ai er yan ke aeyk'),
    _StockSuggestion(code:'sz300760', name:'迈瑞医疗',   pinyin:'mai rui yi liao mryl'),
    _StockSuggestion(code:'sz300122', name:'智飞生物',   pinyin:'zhi fei sheng wu zfsw'),
    _StockSuggestion(code:'sz300274', name:'阳光电源',   pinyin:'yang guang dian yuan ygdy'),
    _StockSuggestion(code:'sz300124', name:'汇川技术',   pinyin:'hui chuan ji shu hcjs'),
    _StockSuggestion(code:'sz300223', name:'北京君正',   pinyin:'bei jing jun zheng bjjz'),
    _StockSuggestion(code:'sz300496', name:'中科创达',   pinyin:'zhong ke chuang da zkcd'),
    _StockSuggestion(code:'sz002594', name:'比亚迪',     pinyin:'bi ya di byd'),
    _StockSuggestion(code:'sz002371', name:'北方华创',   pinyin:'bei fang hua chuang bfhc'),
    _StockSuggestion(code:'sz002456', name:'欧菲光',    pinyin:'ou fei guang ofg'),
    _StockSuggestion(code:'sz002230', name:'科大讯飞',   pinyin:'ke da xun fei kdxf'),
    _StockSuggestion(code:'sz002049', name:'紫光国微',   pinyin:'zi guang guo wei zggw'),
    _StockSuggestion(code:'sz002415', name:'海康威视',   pinyin:'hai kang wei shi hkws'),
    _StockSuggestion(code:'sz002027', name:'分众传媒',   pinyin:'fen zhong chuan mei fzcm'),
    _StockSuggestion(code:'sz002236', name:'大华股份',   pinyin:'da hua gu fen dhgf'),
    _StockSuggestion(code:'sz002241', name:'歌尔股份',   pinyin:'ge er gu fen gegf'),
    _StockSuggestion(code:'sz002714', name:'牧原股份',   pinyin:'mu yuan gu fen mygf'),
    _StockSuggestion(code:'sz002601', name:'龙佰集团',   pinyin:'long bai ji tuan lbjt'),
    _StockSuggestion(code:'sh601127', name:'赛力斯',    pinyin:'sai li si sls'),
  ];

  @override
  Widget build(BuildContext ctx) {
    return Container(
      height: MediaQuery.of(ctx).size.height * 0.8,
      decoration: const BoxDecoration(
        color:Colors.white,
        borderRadius: BorderRadius.vertical(top:Radius.circular(20)),
      ),
      child: Column(children: [
        const SizedBox(height:8),
        Container(width:40, height:4, decoration:BoxDecoration(
          color:const Color(0xFFDDDDDD), borderRadius:BorderRadius.circular(2))),
        const SizedBox(height:16),
        const Text('添加股票', style:TextStyle(fontSize:17, fontWeight:FontWeight.w600)),
        const SizedBox(height:16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal:16),
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '输入股票代码、名称或拼音首字母',
              prefixIcon: const Icon(Icons.search, color:Color(0xFF9999AA)),
              filled: true,
              fillColor: const Color(0xFFF5F5F7),
              border: OutlineInputBorder(borderRadius:BorderRadius.circular(12), borderSide:BorderSide.none),
            ),
          ),
        ),
        const SizedBox(height:12),
        if (_loading)
          const Expanded(child: Center(child:CircularProgressIndicator(strokeWidth:2)))
        else if (_suggestions.isEmpty && _ctrl.text.isNotEmpty)
          Expanded(child: Center(
            child: Column(mainAxisSize:MainAxisSize.min, children: [
              const Icon(Icons.search_off, color:Color(0xFFDDDDDD), size:40),
              const SizedBox(height:8),
              Text('未找到 "${_ctrl.text}"，尝试其他关键词', style:const TextStyle(color:Color(0xFFBBBBCC), fontSize:13)),
            ]),
          ))
        else if (_suggestions.isEmpty)
          Expanded(child: Center(child:Text('输入股票代码或名称搜索', style:TextStyle(color:Color(0xFFBBBBCC)))))
        else
          Expanded(
            child: ListView.builder(
              itemCount: _suggestions.length,
              itemBuilder: (ctx, i) {
                final s = _suggestions[i];
                return ListTile(
                  leading: Container(
                    width:36, height:36,
                    decoration: BoxDecoration(color:const Color(0xFFF0F0F5), borderRadius:BorderRadius.circular(8)),
                    child: const Center(child: Icon(Icons.show_chart, size:18, color:Color(0xFF6C63FF))),
                  ),
                  title: Text(s.name, style:const TextStyle(fontWeight:FontWeight.w600)),
                  subtitle: Text(s.code, style:const TextStyle(fontSize:12, color:Color(0xFF9999AA))),
                  trailing: const Icon(Icons.add, color:Color(0xFFE84057), size:20),
                  onTap: () {
                    Provider.of<StockProvider>(ctx, listen: false).addStock(s.code, s.name);
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          ),
      ]),
    );
  }
}

class _StockSuggestion {
  final String code;
  final String name;
  final String pinyin;
  _StockSuggestion({required this.code, required this.name, required this.pinyin});
}
