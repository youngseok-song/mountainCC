import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive/hive.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;

import '../models/location_data.dart'; // 위치 데이터 저장로직
import '../service/location_service.dart'; // 위치 로직
import '../service/movement_service.dart'; // 운동 로직

import 'dart:math' as math;

/*
 * MapScreen
 *  - flutter_map 으로 지도 표시
 *  - 운동 시작/일시중지/종료
 *  - BackgroundGeolocation 권한 체크 + 시작/중지
 *  - 카운트다운 후에 MovementService에 위치 전달
 *  - [NEW] Marker를 회전시켜 방향 표시(삼각형 아이콘)
 */

// 예시: 한반도 근사 폴리곤 (clip)
final List<LatLng> mainKoreaPolygon = [
  LatLng(33.0, 124.0),
  LatLng(38.5, 124.0),
  LatLng(38.5, 131.0),
  LatLng(37.2, 131.8),
  LatLng(34.0, 127.2),
  LatLng(32.0, 127.0),
];

class MapScreen extends StatefulWidget {
  final VoidCallback? onStopWorkout;
  const MapScreen({super.key, this.onStopWorkout});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // (1) 지도 컨트롤러
  final MapController _mapController = MapController();
  bool _mapIsReady = false;

  // (2) Service
  late LocationService _locationService;
  late MovementService _movementService; // 새로 추가

  // (3) 현재 위치
  bg.Location? _currentBgLocation;

  // (4) 운동 상태
  bool _isWorkoutStarted = false;
  bool _isPaused = false;
  String _elapsedTime = "00:00:00";

  // 첫 위치 & 카운트다운
  bool _isFirstFixFound = false;
  bool _inCountdown = false;
  int _countdownValue = 10;
  bool _ignoreInitialData = true;

  @override
  void initState() {
    super.initState();
    // Hive box -> locationService
    final locationBox = Hive.box<LocationData>('locationBox');
    _locationService = LocationService(locationBox);

    // movementService 초기화
    _movementService = MovementService();
  }

  // ------------------------------------------------------------
  // (A) 위치 권한 체크
  Future<bool> _checkAndRequestAlwaysPermission() async {
    if (await Permission.locationAlways.isGranted) {
      return true;
    }
    final status = await Permission.locationAlways.request();
    if (status.isGranted) {
      return true;
    } else {
      _showNeedPermissionDialog();
      return false;
    }
  }

  Future<void> _showNeedPermissionDialog() async {
    final goSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text("위치 권한 필요"),
          content: const Text(
            "항상 허용 권한이 필요합니다.\n"
                "앱 설정 화면에서 '항상 허용'으로 변경해주세요.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text("취소"),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text("설정으로 이동"),
            ),
          ],
        );
      },
    );
    if (goSettings == true) {
      await openAppSettings();
    }
  }

  // ------------------------------------------------------------
  // (B) 운동 시작
  Future<void> _startWorkout() async {
    final hasAlways = await _checkAndRequestAlwaysPermission();
    if (!hasAlways) return;

    setState(() {
      _isWorkoutStarted = true;
      _isPaused = false;
      _elapsedTime = "00:00:00";

      _isFirstFixFound = false;
      _inCountdown = false;
      _ignoreInitialData = true;

      // movementService 초기화
      _movementService.resetAll();
    });

    // (1) Barometer + Gyroscope start
    _movementService.startBarometer();
    _movementService.startGyroscope(); // [NEW] 자이로 추가

    // BackgroundGeolocation 시작
    await _locationService.startBackgroundGeolocation((bg.Location loc) {
      if (!mounted) return;

      setState(() {
        _currentBgLocation = loc;
      });

      if (!_isFirstFixFound) {
        // 첫 위치
        _isFirstFixFound = true;
        _startCountdown();
        return;
      }

      if (_ignoreInitialData) {
        // 카운트다운 중 => 데이터 무시
        return;
      }

      // (중요) movementService에 전달
      _movementService.onNewLocation(loc, ignoreData: false);

      // 지도 이동
      if (_mapIsReady) {
        final currentZoom = _mapController.camera.zoom;
        _mapController.move(
          LatLng(loc.coords.latitude, loc.coords.longitude),
          currentZoom,
        );
      }
    });

    // 첫 위치 getCurrentPosition
    final currentLoc = await bg.BackgroundGeolocation.getCurrentPosition(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      timeout: 30,
    );
    if (!mounted) return;

    setState(() {
      _currentBgLocation = currentLoc;
    });

    if (!_isFirstFixFound) {
      _isFirstFixFound = true;
      _startCountdown();
    } else if (!_ignoreInitialData) {
      _movementService.onNewLocation(currentLoc, ignoreData: false);
    }

    if (_mapIsReady) {
      _mapController.move(
        LatLng(currentLoc.coords.latitude, currentLoc.coords.longitude),
        15.0,
      );
    }
  }

  // ------------------------------------------------------------
  // (C) 카운트다운
  void _startCountdown() {
    setState(() {
      _inCountdown = true;
      _countdownValue = 10; // 10초
      _ignoreInitialData = true;
    });

    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_countdownValue <= 1) {
        timer.cancel();

        setState(() {
          _inCountdown = false;
          _ignoreInitialData = false;
        });

        // 스톱워치 start
        _movementService.resetStopwatch();
        _movementService.startStopwatch();
        _updateElapsedTime();

        // 현재 위치 한번 더
        final loc = await bg.BackgroundGeolocation.getCurrentPosition(
          desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
          timeout: 30,
        );
        if (!mounted) return;

        setState(() {
          _currentBgLocation = loc;
          // movementService에 전달
          _movementService.onNewLocation(loc);
        });

        if (_mapIsReady) {
          final currentZoom = _mapController.camera.zoom;
          _mapController.move(
            LatLng(loc.coords.latitude, loc.coords.longitude),
            currentZoom,
          );
        }
      } else {
        setState(() {
          _countdownValue--;
        });
      }
    });
  }

  // ------------------------------------------------------------
  // (D) 일시중지
  void _pauseWorkout() {
    setState(() {
      _isPaused = true;
    });
    // movementService 스톱워치 stop
    _movementService.pauseStopwatch();
  }

  // ------------------------------------------------------------
  // (E) 운동 종료
  Future<void> _stopWorkout() async {
    setState(() {
      _isWorkoutStarted = false;
      _isPaused = false;

      // movementService 리셋
      _movementService.resetAll();

      _elapsedTime = "00:00:00";
      _isFirstFixFound = false;
      _inCountdown = false;
      _ignoreInitialData = true;
      _countdownValue = 10;
      _currentBgLocation = null;
    });

    await _locationService.stopBackgroundGeolocation();
    widget.onStopWorkout?.call();
  }

  // ------------------------------------------------------------
  // (F) 1초마다 스톱워치 갱신
  void _updateElapsedTime() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;

      // 운동중이고, 일시중지 상태가 아니면 계속 갱신
      if (_isWorkoutStarted && !_isPaused) {
        setState(() {
          _elapsedTime = _movementService.elapsedTimeString;
        });
        _updateElapsedTime();
      }
    });
  }

  // ------------------------------------------------------------
  // (G) UI 빌드
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("운동 기록 + 첫 위치 후 카운트다운"),
      ),
      body: Stack(
        children: [
          // 1) FlutterMap
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              onMapReady: () => setState(() => _mapIsReady = true),
              initialCenter: const LatLng(37.5665, 126.9780),
              initialZoom: 15.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
              ),
            ),
            children: [
              // 기본 OSM
              TileLayer(
                urlTemplate: 'https://tiles.osm.kr/hot/{z}/{x}/{y}.png',
                maxZoom: 19,
              ),
              // 한국 지도의 클리핑 레이어
              KoreaClipLayer(
                polygon: mainKoreaPolygon,
                child: TileLayer(
                  urlTemplate: 'https://tiles.osm.kr/hot/{z}/{x}/{y}.png',
                  maxZoom: 19,
                ),
              ),

              // 정확도 원
              if (_currentBgLocation != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: LatLng(
                        _currentBgLocation!.coords.latitude,
                        _currentBgLocation!.coords.longitude,
                      ),
                      radius: _currentBgLocation?.coords.accuracy ?? 5.0,
                      useRadiusInMeter: true,
                      color: Colors.blue.withAlpha(50),
                      borderColor: Colors.blue,
                      borderStrokeWidth: 2.0,
                    ),
                  ],
                ),

              // [NEW] 현재 위치 + 방향 삼각형
              if (_currentBgLocation?.coords != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(
                        _currentBgLocation!.coords.latitude,
                        _currentBgLocation!.coords.longitude,
                      ),
                      width: 40.0,
                      height: 40.0,
                      child: Transform.rotate(
                        angle: _movementService.headingRad - math.pi / 2, // inline 사용
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.navigation,
                          color: Colors.blue,
                          size: 30.0,
                        ),
                      ),
                    ),
                  ],
                ),

              // 폴리라인(이동경로)
              if (_movementService.polylinePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _movementService.polylinePoints,
                      strokeWidth: 4.0,
                      color: Colors.blue,
                    ),
                  ],
                ),
            ],
          ),

          // 2) 운동 시작 전 => "운동 시작" 버튼
          if (!_isWorkoutStarted)
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Center(
                child: ElevatedButton(
                  onPressed: _startWorkout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 5.0,
                  ),
                  child: const Text(
                    "운동 시작",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
              ),
            ),

          // 3) 운동 중 => 하단 패널
          if (_isWorkoutStarted)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey,
                      blurRadius: 10,
                      spreadRadius: 2,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("운동시간", style: TextStyle(fontSize: 16, color: Colors.grey)),
                    Text(
                      _elapsedTime,
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black),
                    ),
                    const SizedBox(height: 16),

                    // 거리, 속도, 고도
                    GridView.count(
                      shrinkWrap: true,
                      crossAxisCount: 2,
                      mainAxisSpacing: 18.5,
                      crossAxisSpacing: 12,
                      childAspectRatio: 3.5,
                      children: [
                        _buildInfoTile("📍 거리", "${_movementService.distanceKm.toStringAsFixed(1)} km"),
                        _buildInfoTile("⚡ 속도", "${_movementService.averageSpeedKmh.toStringAsFixed(2)} km/h"),
                        _buildInfoTile(
                          "🏠 현재고도",
                          "${(_currentBgLocation?.coords.altitude ?? 0).toInt()} m",
                        ),
                        _buildInfoTile(
                          "📈 누적상승고도",
                          "${_movementService.cumulativeElevation.toStringAsFixed(1)} m",
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildPauseResumeButtons(),
                  ],
                ),
              ),
            ),

          // 4) 카운트다운 오버레이
          if (_inCountdown) _buildCountdownOverlay(),
        ],
      ),
    );
  }

  Widget _buildInfoTile(String title, String value) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(title, style: const TextStyle(fontSize: 14, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildPauseResumeButtons() {
    if (!_isPaused) {
      // "중지" 버튼
      return SizedBox(
        width: MediaQuery.of(context).size.width * 0.4,
        height: 40,
        child: ElevatedButton(
          onPressed: _pauseWorkout,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orangeAccent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text("중지 ⏸️", style: TextStyle(color: Colors.white, fontSize: 15)),
        ),
      );
    } else {
      // "재시작" + "종료"
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ElevatedButton(
            onPressed: () {
              // 재시작
              setState(() {
                _isPaused = false;
              });
              _movementService.startStopwatch();
              _updateElapsedTime();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blueAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(120, 48),
            ),
            child: const Text("재시작 ▶", style: TextStyle(color: Colors.white, fontSize: 15)),
          ),
          ElevatedButton(
            onPressed: _stopWorkout,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(120, 48),
            ),
            child: const Text("종료 ■", style: TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ],
      );
    }
  }

  Widget _buildCountdownOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black87,
        child: Center(
          child: Text(
            _countdownValue.toString(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 72,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------
//  ClipPath classes : 한국 영역
class KoreaClipLayer extends StatelessWidget {
  final Widget child;
  final List<LatLng> polygon;
  const KoreaClipLayer({
    super.key,
    required this.polygon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final mapCamera = MapCamera.of(context);
    final ui.Path path = ui.Path();

    if (polygon.isNotEmpty && mapCamera != null) {
      final firstPt = mapCamera.latLngToScreenPoint(polygon[0]);
      path.moveTo(firstPt.x, firstPt.y);
      for (int i = 1; i < polygon.length; i++) {
        final pt = mapCamera.latLngToScreenPoint(polygon[i]);
        path.lineTo(pt.x, pt.y);
      }
      path.close();
    }

    return ClipPath(
      clipper: _KoreaClipper(path),
      child: child,
    );
  }
}

class _KoreaClipper extends CustomClipper<ui.Path> {
  final ui.Path path;
  const _KoreaClipper(this.path);

  @override
  ui.Path getClip(Size size) => path;
  @override
  bool shouldReclip(_KoreaClipper oldClipper) => true;
}

