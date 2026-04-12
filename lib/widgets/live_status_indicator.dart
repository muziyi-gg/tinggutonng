import 'package:flutter/material.dart';

class LiveStatusIndicator extends StatefulWidget {
  final bool connected;
  const LiveStatusIndicator({super.key, required this.connected});
  @override
  State<LiveStatusIndicator> createState() => _LiveStatusIndicatorState();
}

class _LiveStatusIndicatorState extends State<LiveStatusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration:const Duration(milliseconds:1800), vsync:this);
    _anim = Tween<double>(begin:0.4, end:1.0).animate(
      CurvedAnimation(parent:_ctrl, curve: Curves.easeInOut));
    if (widget.connected) _ctrl.repeat(reverse:true);
  }

  @override
  void didUpdateWidget(LiveStatusIndicator old) {
    super.didUpdateWidget(old);
    if (widget.connected && !_ctrl.isAnimating) _ctrl.repeat(reverse:true);
    if (!widget.connected) _ctrl.stop();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext ctx) {
    return Row(mainAxisSize:MainAxisSize.min, children: [
      AnimatedBuilder(
        animation:_anim,
        builder:(_, __) => Container(
          width:8, height:8,
          decoration: BoxDecoration(
            shape:BoxShape.circle,
            color: widget.connected
                ? const Color(0xFF34C759).withOpacity(_anim.value)
                : const Color(0xFFDDDDDD),
          ),
        ),
      ),
      const SizedBox(width:6),
      Text(
        widget.connected ? '后台运行中' : '已断开',
        style: TextStyle(
          fontSize:12,
          color: widget.connected ? const Color(0xFF34C759) : const Color(0xFFBBBBCC),
          fontWeight: FontWeight.w500,
        ),
      ),
    ]);
  }
}
