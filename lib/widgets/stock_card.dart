import 'package:flutter/material.dart';
import '../models/stock.dart';

class StockCard extends StatelessWidget {
  final Stock stock;
  const StockCard({super.key, required this.stock});

  @override
  Widget build(BuildContext ctx) {
    final isUp = stock.changePct >= 0;
    final color = isUp ? const Color(0xFFE84057) : const Color(0xFF34C759);
    final arrow = isUp ? '↑' : '↓';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color:Colors.black.withOpacity(0.04), blurRadius:8, offset:const Offset(0,2))],
      ),
      child: Row(children: [
        // 左：股票信息
        Expanded(
          child: Column(crossAxisAlignment:CrossAxisAlignment.start, children: [
            Text(stock.name, style:const TextStyle(fontSize:15, fontWeight:FontWeight.w600)),
            const SizedBox(height:3),
            Text(stock.code, style:const TextStyle(fontSize:12, color:Color(0xFF9999AA))),
          ]),
        ),
        // 中：走势图占位
        Container(
          width: 60, height: 32,
          decoration: BoxDecoration(
            color: color.withOpacity(0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          child: CustomPaint(
            painter: _MiniChartPainter(isUp: isUp, color: color),
          ),
        ),
        const SizedBox(width:12),
        // 右：价格和涨跌幅
        Column(crossAxisAlignment:CrossAxisAlignment.end, children: [
          Text('¥${stock.price.toStringAsFixed(2)}',
              style: TextStyle(fontSize:16, fontWeight:FontWeight.bold, color:color)),
          if (stock.isClosed)
            Container(
              padding: const EdgeInsets.symmetric(horizontal:5, vertical:2),
              decoration: BoxDecoration(
                color: const Color(0xFFE8E8F0),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('收盘', style: TextStyle(fontSize:10, fontWeight:FontWeight.w600, color:Color(0xFF9999AA))),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal:6, vertical:2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('$arrow ${stock.changePct.abs().toStringAsFixed(2)}%',
                  style: TextStyle(fontSize:12, fontWeight:FontWeight.w600, color:color)),
            ),
        ]),
      ]),
    );
  }
}

class _MiniChartPainter extends CustomPainter {
  final bool isUp;
  final Color color;
  _MiniChartPainter({required this.isUp, required this.color});

  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path();
    final pts = isUp
        ? [0.2,0.5,0.3,0.7,0.5,0.4,0.8,0.1,1.0,0.2]
        : [0.1,0.3,0.4,0.2,0.5,0.6,0.7,0.5,0.9,0.8,1.0,0.9];

    for (int i=0; i<pts.length; i++) {
      final x = (i/(pts.length-1)) * s.width;
      final y = (1 - pts[i]) * s.height;
      if (i==0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    c.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter _) => false;
}
