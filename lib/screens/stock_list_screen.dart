import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  void _onSearchChanged() {
    _search(_ctrl.text);
  }

  Future<void> _search(String q) async {
    if (q.length < 2) { setState(() => _suggestions.clear()); return; }
    setState(() { _loading = true; _suggestions.clear(); });

    final common = _commonStocks();
    final q2 = q.toLowerCase();
    // 宽松匹配：代码包含 / 名称包含 / 拼音前缀匹配 / 拼音含子串匹配
    final filtered = common.where((s) =>
      s.code.toLowerCase().contains(q2) ||
      s.name.contains(q) ||                                    // 中文名称含子串
      s.pinyin.startsWith(q2) ||                               // 拼音前缀
      s.pinyin.replaceAll(' ', '').contains(q2) ||            // 去空格拼音含子串
      s.pinyin.contains(q2)                                    // 拼音含子串
    ).toList();

    setState(() {
      _suggestions.addAll(filtered.take(10));
      _loading = false;
    });
  }

  /// 热词股票池（约50只，覆盖沪深主要板块）
  static final List<_StockSuggestion> _hotList = [
    _StockSuggestion(code:'sh600519', name:'贵州茅台',   pinyin:'gui zhou mao tai gzmt'),
    _StockSuggestion(code:'sh601318', name:'中国平安',   pinyin:'zhong guo ping an zgpa'),
    _StockSuggestion(code:'sh600036', name:'招商银行',   pinyin:'zhao shang yin hang zsyh'),
    _StockSuggestion(code:'sh600028', name:'中国石化',   pinyin:'zhong guo shi hua zgfh'),
    _StockSuggestion(code:'sh600050', name:'中国联通',   pinyin:'zhong guo lian tong zglt'),
    _StockSuggestion(code:'sh601166', name:'兴业银行',   pinyin:'xing ye yin hang xyyh'),
    _StockSuggestion(code:'sh600000', name:'浦发银行',   pinyin:'pu fa yin hang pfyh'),
    _StockSuggestion(code:'sh601398', name:'工商银行',   pinyin:'gong shang yin hang gsyh'),
    _StockSuggestion(code:'sh601288', name:'农业银行',   pinyin:'nong ye yin hang nyyh'),
    _StockSuggestion(code:'sh601988', name:'中国银行',   pinyin:'zhong guo yin hang zgyh'),
    _StockSuggestion(code:'sh601857', name:'中国石油',   pinyin:'zhong guo shi you zgsy'),
    _StockSuggestion(code:'sz000858', name:'五粮液',     pinyin:'wu liang ye wly'),
    _StockSuggestion(code:'sz000001', name:'平安银行',   pinyin:'ping an yin hang payh'),
    _StockSuggestion(code:'sz000002', name:'万科A',       pinyin:'wan ke wk'),
    _StockSuggestion(code:'sz000333', name:'美的集团',   pinyin:'mei di ji tuan mdjt'),
    _StockSuggestion(code:'sz000651', name:'格力电器',   pinyin:'ge li dian qi gldq'),
    _StockSuggestion(code:'sz300750', name:'宁德时代',   pinyin:'ning de shi dai ndsd'),
    _StockSuggestion(code:'sh688981', name:'中芯国际',   pinyin:'zhong xin guo ji zxgj'),
    _StockSuggestion(code:'sh600276', name:'恒瑞医药',   pinyin:'heng rui yi yao hryy'),
    _StockSuggestion(code:'sh601012', name:'隆基绿能',   pinyin:'long ji lv neng ljln'),
    _StockSuggestion(code:'sh600900', name:'长江电力',   pinyin:'chang jiang dian li cjdl'),
    _StockSuggestion(code:'sh600031', name:'三一重工',   pinyin:'san yi zhong gong syzg'),
    _StockSuggestion(code:'sz300059', name:'东方财富',   pinyin:'dong fang cai fu dftc dfcf'),
    _StockSuggestion(code:'sh600887', name:'伊利股份',   pinyin:'yi li gu fen ylgf'),
    _StockSuggestion(code:'sz002475', name:'立讯精密',   pinyin:'li xun jing mi lxjm'),
    _StockSuggestion(code:'sh603259', name:'药明康德',   pinyin:'yao ming kang de ymkd'),
    _StockSuggestion(code:'sz000725', name:'京东方A',     pinyin:'jing dong fang jdf'),
    _StockSuggestion(code:'sh601888', name:'中国中免',   pinyin:'zhong guo zhong mian zgfm'),
    _StockSuggestion(code:'sh600009', name:'上海机场',   pinyin:'shang hai ji chang shjjc'),
    _StockSuggestion(code:'sh600104', name:'上汽集团',   pinyin:'shang qi ji tuan sqjt'),
    _StockSuggestion(code:'sh600585', name:'海螺水泥',   pinyin:'hai luo shui ni hlsn'),
    _StockSuggestion(code:'sh600150', name:'中国船舶',   pinyin:'zhong guo chuan bo zgcb'),
    _StockSuggestion(code:'sh600346', name:'恒力石化',   pinyin:'heng li shi hua hlfh'),
    _StockSuggestion(code:'sh600309', name:'万华化学',   pinyin:'wan hua hua xue whhx'),
    _StockSuggestion(code:'sh601669', name:'中国电建',   pinyin:'zhong guo dian jian zgdj'),
    _StockSuggestion(code:'sh601186', name:'中国铁建',   pinyin:'zhong guo tie jian zgtj'),
    _StockSuggestion(code:'sh601728', name:'中国电信',   pinyin:'zhong guo dian xin zgdx'),
    _StockSuggestion(code:'sh601728', name:'中国移动',   pinyin:'zhong guo yi dongzgyd'),
    _StockSuggestion(code:'sh600036', name:'招商银行',   pinyin:'zhao shang yin hang zsyh'),
    _StockSuggestion(code:'sz300015', name:'爱尔眼科',   pinyin:'ai er yan ke aeyk'),
    _StockSuggestion(code:'sz300760', name:'迈瑞医疗',   pinyin:'mai rui yi liao mryl'),
    _StockSuggestion(code:'sh688041', name:'海光信息',   pinyin:'hai guang xin xi hxxx'),
    _StockSuggestion(code:'sz000063', name:'中兴通讯',   pinyin:'zhong xing tong xun zxtx'),
    _StockSuggestion(code:'sh600089', name:'特变电工',   pinyin:'te bian dian gong tbdy'),
    _StockSuggestion(code:'sz300122', name:'智飞生物',   pinyin:'zhi fei sheng wu zfsw'),
    _StockSuggestion(code:'sh600703', name:'三安光电',   pinyin:'san an guang dian sagd'),
    _StockSuggestion(code:'sh603288', name:'海天味业',   pinyin:'hai tian wei ye htwy'),
    _StockSuggestion(code:'sh600690', name:'海尔智家',   pinyin:'hai er zhi jia hezj'),
    _StockSuggestion(code:'sh600690', name:'海信视像',   pinyin:'hai xin shi xiang hxsx'),
  ];

  List<_StockSuggestion> _commonStocks() => _hotList;

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
            onChanged: (v) {}, // 保留但用 listener 处理
          ),
        ),
        const SizedBox(height:12),
        if (_loading)
          const Center(child:CircularProgressIndicator(strokeWidth:2))
        else if (_suggestions.isEmpty && _ctrl.text.length >= 2)
          const Expanded(child: Center(child:Text('未找到相关股票', style:TextStyle(color:Color(0xFFBBBBCC)))))
        else if (_suggestions.isEmpty)
          const Expanded(child: Center(child:Text('输入股票代码或名称搜索', style:TextStyle(color:Color(0xFFBBBBCC)))))
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
