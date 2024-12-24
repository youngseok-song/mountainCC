import 'package:flutter/material.dart';
// 1) webview_flutter 4.x 이상 패키지
import 'package:webview_flutter/webview_flutter.dart';

import 'map_screen.dart'; // 기존 map_screen.dart (운동화면) import

class WebViewAndMapScreen extends StatefulWidget {
  const WebViewAndMapScreen({Key? key}) : super(key: key);

  @override
  State<WebViewAndMapScreen> createState() => _WebViewAndMapScreenState();
}

class _WebViewAndMapScreenState extends State<WebViewAndMapScreen> {
  bool _showWebView = true;
  // ↑ 처음에는 웹뷰(WebView)를 표시.
  //   웹에서 '따라가기' 버튼을 누르면 -> _showWebView = false -> 지도(MapScreen) 화면으로 전환

  late final WebViewController _webViewController;
  // ↑ webview_flutter 4.x 버전에서 새롭게 도입된 WebViewController

  @override
  void initState() {
    super.initState();

    // 2) webview_flutter 4.x 방식:
    //    컨트롤러를 먼저 생성하고,
    //    자바스크립트 모드나 자바스크립트 채널을 설정한 후,
    //    loadRequest(...) 로 URL 로드를 요청합니다.
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted) // JS 허용
      ..addJavaScriptChannel(
        'StartWorkout',
        onMessageReceived: (JavaScriptMessage message) {
          // 웹에서 'window.StartWorkout.postMessage("start")'를 호출하면 여기로 들어옵니다.
          if (message.message == 'start') {
            setState(() {
              // “따라가기” 버튼 클릭에 해당 → 지도 화면으로 전환
              _showWebView = false;
            });
          }
        },
      )
      ..loadRequest(
        Uri.parse('https://outify-git-main-jeongdxxns-projects.vercel.app/'),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 3) _showWebView 값에 따라,
      //    - true면 WebViewWidget 보여주고
      //    - false면 MapScreen(운동화면) 보여줌
      body: Stack(
        children: [
          // (1) _showWebView = true => WebView 표시
          if (_showWebView)
          // WebView(...) 대신 WebViewWidget(controller: ...) 사용
            WebViewWidget(controller: _webViewController),

          // (2) _showWebView = false => MapScreen 표시
          if (!_showWebView)
            MapScreen(
              // 운동 종료 시 다시 웹뷰로 돌아가는(표시하는) 콜백
              onStopWorkout: () {
                setState(() {
                  // 운동이 끝나면 웹뷰 다시 켜기
                  _showWebView = true;
                });
              },
            ),
        ],
      ),
    );
  }
}
