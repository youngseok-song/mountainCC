//main.dart

import 'package:flutter/material.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:hive_flutter/hive_flutter.dart';
import 'models/location_data.dart';
import 'screens/webview_and_map_screen.dart'; // 새로 만든 화면 import

// 1) 헤드리스 함수 정의
@pragma('vm:entry-point')
void backgroundGeolocationHeadlessTask(bg.HeadlessEvent headlessEvent) async {
  print("🎯 [HeadlessTask] => $headlessEvent");

  switch (headlessEvent.name) {
    case bg.Event.TERMINATE:
    // 앱이 종료되었을 때 이벤트
    // 위치를 얻는 예시
      try {
        final location = await bg.BackgroundGeolocation.getCurrentPosition(
          persist: true,
          extras: {"via": "TERMINATE Headless"},
        );
        print("[HeadlessTask] location=$location");
      } catch (e) {
        print("[HeadlessTask] ERROR: $e");
      }
      break;

    case bg.Event.LOCATION:
      final loc = headlessEvent.event as bg.Location;
      print("[HeadlessTask] onLocation: $loc");
      // 필요 시 Hive에 저장 or 서버 전송 가능
      break;

    case bg.Event.MOTIONCHANGE:
      final loc = headlessEvent.event as bg.Location;
      print("[HeadlessTask] onMotionChange: $loc");
      break;

  // 그 외 GEOFENCE, HEARTBEAT, SCHEDULE 등등
  // ...
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) Hive 초기화
  await Hive.initFlutter();

  // 2) LocationData 타입 어댑터 등록
  Hive.registerAdapter(LocationDataAdapter());

  // 3) locationBox 오픈 (타입 명시: LocationData)
  await Hive.openBox<LocationData>('locationBox');

  // 2) 헤드리스 등록
  bg.BackgroundGeolocation.registerHeadlessTask(backgroundGeolocationHeadlessTask);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Real-time GPS on OSM + Clip (BackgroundGeo ver.)',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      home: const WebViewAndMapScreen(),
    );
  }
}
