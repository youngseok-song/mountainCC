// bottom_nav_screen.dart (새 파일 가정)
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'map_screen.dart';
import '../service/movement_service.dart';
import '../service/location_service.dart';
import '../service/location_manager.dart';

// 만약 '쇼핑' / '마이페이지'도 WebView로 구성한다면,
// 각각의 URL만 다를 뿐, 사실상 '공용 WebView 위젯'을 만들어도 되고,
// 또는 그냥 InAppWebView를 탭마다 각각 써도 됩니다.

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
  // (1) 현재 선택된 탭 인덱스
  int _selectedIndex = 0;

  // (2) 탭별 화면 - 5개
  //     여기서 "홈"과 "검색", "쇼핑", "마이페이지"는 각각 WebView를 보여주도록 구성
  //     "운동하기"는 MapScreen을 직접 보여준다.
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

  // (3) 탭 전환 시 setState
  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  // (4) 재사용 가능한 WebView 빌더(간단 예시)
  Widget _buildWebViewScreen(String initialUrl) {
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
      // 기타 인앱웹뷰 설정
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex], // 현재 선택된 탭 화면을 표시
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed, // 5개 탭이므로 fixed 사용
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
