// screens/webview_and_map_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'; // flutter_inappwebview 패키지 임포트
import 'map_screen.dart'; // 지도/운동 화면

class WebViewAndMapScreen extends StatefulWidget {
  const WebViewAndMapScreen({super.key});

  @override
  State<WebViewAndMapScreen> createState() => _WebViewAndMapScreenState();
}

class _WebViewAndMapScreenState extends State<WebViewAndMapScreen> {
  // true 면 웹뷰 화면을 표시하고, false 면 지도 화면(MapScreen) 표시
  bool _showWebView = true;

  // InAppWebViewController: 웹뷰를 제어할 수 있는 컨트롤러 (JS 실행 등)
  InAppWebViewController? _webViewController;

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
                url: WebUri('https://mountaincc.co.kr/version-test'),
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
              // MapScreen에서 "종료" 버튼 등을 누르면 다시 웹뷰로 돌아가기
              onStopWorkout: () {
                setState(() {
                  _showWebView = true;
                });
              },
            ),
        ],
      ),
    );
  }
}