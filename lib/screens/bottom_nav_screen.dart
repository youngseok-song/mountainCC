// bottom_nav_screen.dart (새 파일 가정)
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'map_screen.dart';
import '../service/movement_service.dart';
import '../service/location_service.dart';
import '../service/location_manager.dart';

class BottomNavScreen extends StatefulWidget {
  final MovementService movementService;
  final LocationService locationService;
  final LocationManager locationManager;

  const BottomNavScreen({
    Key? key,
    required this.movementService,
    required this.locationService,
    required this.locationManager,
  }) : super(key: key);

  @override
  State<BottomNavScreen> createState() => _BottomNavScreenState();
}

class _BottomNavScreenState extends State<BottomNavScreen> {
  int _selectedIndex = 0;

  // ▼ IndexedStack 안에 넣을 위젯들을 미리 생성해둠.
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();

    _screens = [
      // 0: 홈
      _buildWebViewScreen('https://outify-git-main-jeongdxxns-projects.vercel.app/'),
      // 1: 검색
      _buildWebViewScreen('https://outify-git-main-jeongdxxns-projects.vercel.app/'), // 예시
      // 2: 운동하기 (MapScreen)
      MapScreen(
        movementService: widget.movementService,
        locationService: widget.locationService,
        onStopWorkout: () {
          // 운동 종료 후 -> 홈 탭(0)으로 이동
          setState(() {
            _selectedIndex = 0;
          });
        },
      ),
      // 3: 쇼핑
      _buildWebViewScreen('https://outify-git-main-jeongdxxns-projects.vercel.app/shop'), // 예시
      // 4: 마이페이지
      _buildWebViewScreen('https://outify-git-main-jeongdxxns-projects.vercel.app/mypage'), // 예시
    ];
  }

  Widget _buildWebViewScreen(String url) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      // 기타 인앱웹뷰 설정
    );
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // (1) IndexedStack 안에 _screens를 children으로 둔다.
      // (2) index=_selectedIndex 인 것만 화면에 표시하지만, 나머지도 상태는 살아있음.
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),

      // 하단 네비게이션
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: '홈',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.search),
            label: '검색',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.directions_run),
            label: '운동하기',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.shopping_cart),
            label: '쇼핑',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: '마이페이지',
          ),
        ],
      ),
    );
  }
}
