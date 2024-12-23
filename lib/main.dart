import 'dart:ui' as ui;          // <-- 도형 그리기용 Path는 dart:ui로부터
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// 예시용: 간단한 한국 본토 폴리곤
final List<LatLng> mainKoreaPolygon = [
  LatLng(33.0, 124.0),  // 서쪽 경계 (제주도 서쪽)
  LatLng(38.5, 124.0),  // 북서쪽 경계 (북한 서쪽)
  LatLng(38.5, 131.0),  // 북동쪽 경계 (함경도 동쪽)
  LatLng(37.2, 131.8),  // 독도
  LatLng(34.0, 127.2),  // 동쪽 경계 (제주도 동쪽)
  LatLng(32.0, 127.0),  // 제주도 남쪽
];

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OSM Flutter Demo (Two-layer Clip + ui.Path)',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Two-layer Clip: ui.Path')),
      body: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: LatLng(37.5665, 126.9780),
          initialZoom: 6.0,
          onMapEvent: (evt) {
            // 지도 이동/확대/축소 시 setState로 Rebuild → ClipPath 갱신
            setState(() {});
          },
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
          ),
        ),
        children: [
          // 1) 아래 레이어: OSM (전 세계)
          TileLayer(
            urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
            subdomains: const ['a','b','c'],
            maxZoom: 19,
          ),

          // 2) 위 레이어: tiles.osm.kr, ClipPath로 한국 폴리곤만 남김
          KoreaClipLayer(
            polygon: mainKoreaPolygon,
            child: TileLayer(
              urlTemplate: 'https://tiles.osm.kr/hot/{z}/{x}/{y}.png',
              maxZoom: 19,
            ),
          ),
        ],
      ),
    );
  }
}

/// 한국 영역을 ClipPath로 잘라서 child를 표시
class KoreaClipLayer extends StatelessWidget {
  final Widget child;
  final List<LatLng> polygon;

  const KoreaClipLayer({
    Key? key,
    required this.polygon,
    required this.child,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final mapCamera = MapCamera.of(context);
    if (mapCamera == null) {
      // 예외 처리: mapCamera를 못 얻으면 child 그대로
      return child;
    }

    // 1) 폴리곤의 LatLng → 화면 Offset 변환
    final ui.Path path = ui.Path();
    if (polygon.isNotEmpty) {
      final firstPt = mapCamera.latLngToScreenPoint(polygon[0]);
      path.moveTo(firstPt.x, firstPt.y);

      for (int i = 1; i < polygon.length; i++) {
        final pt = mapCamera.latLngToScreenPoint(polygon[i]);
        path.lineTo(pt.x, pt.y);
      }
      path.close();
    }

    // 2) ClipPath로 child를 잘라내기
    return ClipPath(
      clipper: _KoreaClipper(path),
      child: child,
    );
  }
}

/// _KoreaClipper: 주어진 ui.Path로만 표시
class _KoreaClipper extends CustomClipper<ui.Path> {
  final ui.Path path;
  _KoreaClipper(this.path);

  @override
  ui.Path getClip(Size size) => path;

  @override
  bool shouldReclip(_KoreaClipper oldClipper) => true;
}
