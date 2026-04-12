import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'providers/stock_provider.dart';
import 'providers/config_provider.dart';
import 'screens/home_screen.dart';
import 'screens/stock_list_screen.dart';
import 'screens/monitor_settings_screen.dart';

class TingutongApp extends StatelessWidget {
  const TingutongApp({super.key});
  @override
  Widget build(BuildContext ctx) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => StockProvider()..init()),
        ChangeNotifierProvider(create: (_) => ConfigProvider()),
      ],
      child: MaterialApp(
        title: '听股通',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'PingFang',
          colorScheme: ColorScheme.fromSeed(
            seed: const Color(0xFFE84057),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF5F6FA),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            elevation: 0,
            iconTheme: IconThemeData(color: Color(0xFF1A1A2E)),
            titleTextStyle: TextStyle(color:Color(0xFF1A1A2E), fontSize:17, fontWeight:FontWeight.w600),
          ),
        ),
        home: const _MainNavigator(),
      ),
    );
  }
}

class _MainNavigator extends StatefulWidget {
  const _MainNavigator();
  @override
  State<_MainNavigator> createState() => _MainNavigatorState();
}

class _MainNavigatorState extends State<_MainNavigator> {
  int _currentIndex = 0;

  void _navigateToStocks() => setState(() => _currentIndex = 1);
  void _navigateToSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder:(_)=> const MonitorSettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          HomeScreen(
            onNavigateStocks: _navigateToStocks,
            onNavigateSettings: _navigateToSettings,
          ),
          const StockListScreen(),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color:Colors.black.withOpacity(0.06), blurRadius:12, offset:const Offset(0,-2))],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical:6),
          child: Row(mainAxisAlignment:MainAxisAlignment.spaceAround, children: [
            _NavItem(icon:Icons.home_rounded, label:'首页', selected:_currentIndex==0,
                onTap:()=>setState(()=>_currentIndex=0)),
            _NavItem(icon:Icons.star_rounded, label:'自选股', selected:_currentIndex==1,
                onTap:()=>setState(()=>_currentIndex=1)),
          ]),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext ctx) {
    final color = selected ? const Color(0xFFE84057) : const Color(0xFFBBBBCC);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal:20, vertical:4),
        child: Column(mainAxisSize:MainAxisSize.min, children: [
          Icon(icon, color:color, size:26),
          const SizedBox(height:2),
          Text(label, style:TextStyle(fontSize:11, color:color, fontWeight: selected?FontWeight.w600:FontWeight.normal)),
        ]),
      ),
    );
  }
}
