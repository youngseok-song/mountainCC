import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'models/location_data.dart';
import 'screens/webview_and_map_screen.dart'; // 새로 만든 화면 import

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) Hive 초기화
  await Hive.initFlutter();

  // 2) LocationData 타입 어댑터 등록
  Hive.registerAdapter(LocationDataAdapter());

  // 3) locationBox 오픈 (타입 명시: LocationData)
  await Hive.openBox<LocationData>('locationBox');

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
