// screens/webview_and_map_screen.dart

import 'dart:async'; // <-- (중요) StreamSubscription 등 사용을 위해
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'; // flutter_inappwebview 패키지 임포트
import 'package:connectivity_plus/connectivity_plus.dart'; // 연결 상태 감지
import 'map_screen.dart'; // 지도/운동 화면
import '../service/movement_service.dart'; // MovementService
import '../service/location_service.dart'; // LocationService
import '../service/location_manager.dart'; // LocationManager
import '../main.dart'; // 지도/운동 화면

class WebViewAndMapScreen extends StatefulWidget {
  final MovementService movementService;
  final LocationService locationService;
  final LocationManager locationManager;

  const WebViewAndMapScreen({
    super.key,
    required this.movementService,
    required this.locationService,
    required this.locationManager,
  });

  @override
  State<WebViewAndMapScreen> createState() => _WebViewAndMapScreenState();
}

class _WebViewAndMapScreenState extends State<WebViewAndMapScreen> {
  // [A] true 면 웹뷰 화면 표시, false 면 지도 화면 표시
  bool _showWebView = true;

  // [B] 웹뷰 컨트롤러
  InAppWebViewController? _webViewController;

  // [C] 지도 MapScreen에 접근하기 위한 GlobalKey
  //     - 지도 타일 재로드를 위해 MapScreenState의 메서드를 호출할 수 있음
  //final GlobalKey<MapScreenState> _mapScreenKey = GlobalKey<MapScreenState>();

  // [D] 연결 상태 감지용 Subscription
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void initState() {
    super.initState();
    // (1) 네트워크 상태 변화를 구독
    _connectivitySub = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      // results 예: [ConnectivityResult.wifi, ConnectivityResult.mobile]
      // 여러 개가 동시에 연결될 수도 있다는 개념

      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) {
        _onInternetReconnected();
      } else {
        // 오프라인 상태 처리
      }
    });
  }

  @override
  void dispose() {
    // (2) 구독 해제
    _connectivitySub?.cancel();
    super.dispose();
  }

  // (3) 재연결 시 로직
  void _onInternetReconnected() {
    if (_showWebView) {
      // 현재 웹뷰 화면이면 웹뷰 reload
      _webViewController?.reload();
    } else {
      // 지도 화면이면 지도 타일 캐시 무효화 → 재요청
      mapScreenKey.currentState?.reloadMapTiles();
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 전체 레이아웃은 Stack으로 겹쳐 놓고, 조건에 따라 위젯을 보여준다.
      body: Stack(
        children: [
          // (1) 웹뷰 표시 영역
          if (_showWebView)
            InAppWebView(
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                // 기타 cross-platform 옵션들
              ),
              // 첫 로딩할 URL
              initialUrlRequest: URLRequest(
                url: WebUri('https://outify-git-main-jeongdxxns-projects.vercel.app/'),
              ),

              // 웹뷰가 생성된 직후 호출
              onWebViewCreated: (controller) {
                // 인스턴스 보관 → 이후 JS 실행 등에 사용할 수 있음
                _webViewController = controller;

                // (2) JS → Flutter 로 메시지를 전달할 핸들러 등록
                // - JS 측에서 window.flutter_inappwebview.callHandler('StartWorkout', 'start') 호출 시
                //   여기 callback 이 실행된다.
                controller.addJavaScriptHandler(
                  handlerName: 'StartWorkout',
                  callback: (args) {
                    // args는 JS에서 넘긴 인자 리스트, 예) ['start']
                    if (args.isNotEmpty && args[0] == 'start') {
                      // 웹에서 "start" 라는 메시지를 넘기면 → 지도화면으로 전환
                      setState(() {
                        _showWebView = false;
                      });
                    }
                    // 필요한 경우, Flutter가 JS 쪽에 응답(리턴값)을 줄 수 있음
                    return "OK from Flutter";
                  },
                );
              },
            ),

          // (3) 지도(운동) 화면
          // - _showWebView = false 일 때만 표시
          if (!_showWebView)
            MapScreen(
              key: mapScreenKey, // <-- 반드시 추가(웹/앱 리로드)
              // MapScreen에서 "종료" 버튼 등을 누르면 다시 웹뷰로 돌아가기
              onStopWorkout: () {
                setState(() => _showWebView = true);
              },
              //MovementService, LocationService 주입
              movementService: widget.movementService,
              locationService: widget.locationService,

            ),
        ],
      ),
    );
  }
}