// ---------------------------------------------------
// screens/map_screen.dart
// ---------------------------------------------------
// flutter_map + BackgroundGeolocation + MovementService 조합으로
// 실제 지도 표시, 운동 시작/중지/일시정지, 고도/거리/속도 등 UI를 표현.
//
// 이 예시에서는 "초기 오프셋"을 첫 위치를 가져온 뒤에
//   _movementService.setInitialBaroOffsetIfPossible(gpsAlt)
// 로 호출함으로써, Barometer와 GPS 차이를 크게 줄인다.

import 'dart:async';
import 'dart:ui' as ui;        // ClipPath, Path 사용 시 필요

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:hive/hive.dart';

import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;


import '../models/location_data.dart';
import '../service/location_service.dart';    // BG start/stop + Hive 저장
import '../service/movement_service.dart';    // 폴리라인, 스톱워치, 고도 계산 등
import 'dart:math' as math;


// ----------------------------------
// 예: 한반도 근사 폴리곤 (clip)
final List<LatLng> mainKoreaPolygon = [
  LatLng(33.0, 124.0),
  LatLng(38.5, 124.0),
  LatLng(38.5, 131.0),
  LatLng(37.2, 131.8),
  LatLng(34.0, 127.2),
  LatLng(32.0, 127.0),
];

// MapScreen 위젯
class MapScreen extends StatefulWidget {
  // onStopWorkout: 운동 종료 후 WebView 등 다른 화면으로 돌아갈 때 호출
  final VoidCallback? onStopWorkout;
  const MapScreen({super.key, this.onStopWorkout});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // (A) 지도 컨트롤러
  final MapController _mapController = MapController();
  bool _mapIsReady = false; // onMapReady 콜백에서 true로 바뀜

  // (B) Service 객체
  late LocationService _locationService;  // BG 위치추적, Hive 저장
  late MovementService _movementService;  // 운동(Baro/GPS 고도, 폴리라인, 스톱워치 등)

  // (C) 현재 BG plugin이 넘겨준 위치
  bg.Location? _currentBgLocation;

  // (D) 운동 상태
  bool _isWorkoutStarted = false;   // 운동 중 여부
  bool _isStartingWorkout = false;  // 운동 시작 절차 진행 중
  bool _isPaused = false;           // 일시중지 상태
  String _elapsedTime = "00:00:00"; // 스톱워치 UI용

  // -----------------------------------------
  // (추가) compass 사용
  // -----------------------------------------
  StreamSubscription<CompassEvent>? _compassSub;
  double? _compassHeading; // 도(0=북, 90=동, 180=남, 270=서)

  @override
  void initState() {
    super.initState();

    // Hive box (locationBox) 열기
    final locationBox = Hive.box<LocationData>('locationBox');
    _locationService = LocationService(locationBox);

    // MovementService 초기화
    _movementService = MovementService();

  }

  @override
  void dispose() {
    // compass 해제
    _compassSub?.cancel();
    _compassSub = null;
    super.dispose();
  }

  void _startCompass() {
    // flutter_compass의 이벤트 스트림 구독
    _compassSub = FlutterCompass.events!.listen((CompassEvent event) {
      // event.heading: 0 ~ 360 (double)
      if (event.heading != null) {
        setState(() {
          _compassHeading = event.heading; // 단위: 도
        });
      }
    });
  }

  void _stopCompass() {
    _compassSub?.cancel();
    _compassSub = null;
  }

  // ------------------------------------------------------------
  // (1) 위치 권한 체크 (항상 허용)
  // ------------------------------------------------------------
  Future<bool> _checkAndRequestAlwaysPermission() async {
    // 이미 권한 있으면 true
    if (await Permission.locationAlways.isGranted) {
      return true;
    }

    // 권한 요청
    final status = await Permission.locationAlways.request();
    if (status.isGranted) {
      return true;
    } else {
      _showNeedPermissionDialog();
      return false;
    }
  }

  // 권한 필요 팝업
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
      // 앱 설정 화면 열기
      await openAppSettings();
    }
  }

  // ------------------------------------------------------------
  // (2) 운동 시작
  // ------------------------------------------------------------
  Future<void> _startWorkout() async {
    // 이미 시작 중이거나 이미 운동 중이면 return
    if (_isStartingWorkout || _isWorkoutStarted) return;

    setState(() {
      _isStartingWorkout = true;
    });

    // 위치 권한(항상 허용) 체크
    final hasAlways = await _checkAndRequestAlwaysPermission();
    if (!hasAlways) {
      setState(() {
        _isStartingWorkout = false;
      });
      return;
    }

    // UI 상태 갱신 (운동 시작)
    setState(() {
      _isWorkoutStarted = true;
      _isPaused = false;
      _elapsedTime = "00:00:00";

      // MovementService 초기화 (스톱워치, 폴리라인, 고도 등)
      _movementService.resetAll();
    });

    // (A) Barometer, Gyro 시작
    _movementService.startBarometer();
    _movementService.startGyroscope();

    // *** Compass 시작 추가 ***
    _startCompass();

    // (B) BackgroundGeolocation 시작 (콜백 등록)
    await _locationService.startBackgroundGeolocation((bg.Location loc) {
      if (!mounted) return;
      setState(() {
        _currentBgLocation = loc;
      });

      // MovementService에 위치 전달
      _movementService.onNewLocation(loc, ignoreData: false);

      // 지도 카메라 이동
      /*if (_mapIsReady) {
        final currentZoom = _mapController.camera.zoom;
        _mapController.move(
          LatLng(loc.coords.latitude, loc.coords.longitude),
          currentZoom,
        );
      }*/
    });

    // (C) 첫 위치를 즉시 가져오기 (getCurrentPosition)
    final currentLoc = await bg.BackgroundGeolocation.getCurrentPosition(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      timeout: 30,
    );

    // 만약 화면이 사라졌다면(return)
    if (!mounted) {
      setState(() {
        _isStartingWorkout = false;
      });
      return;
    }

    // 첫 위치 처리
    setState(() {
      _currentBgLocation = currentLoc;

      // MovementService에 onNewLocation
      _movementService.onNewLocation(currentLoc, ignoreData: false);

      // **중요**: 운동 시작 직후, Barometer offset 보정
      _movementService.setInitialBaroOffsetIfPossible(
        currentLoc.coords.altitude,
      );

      // 지도 카메라 첫 이동
      if (_mapIsReady) {
        _mapController.move(
          LatLng(currentLoc.coords.latitude-0.001, currentLoc.coords.longitude),
          17.0,
        );
      }
    });

    // (D) 스톱워치 시작 + 1초 간격 UI 업데이트
    _movementService.startStopwatch();
    _updateElapsedTime();

    // 시작 절차 완료
    setState(() {
      _isStartingWorkout = false;
    });
  }

  // ------------------------------------------------------------
  // (3) 일시중지
  // ------------------------------------------------------------
  void _pauseWorkout() {
    setState(() {
      _isPaused = true;
    });
    // MovementService의 스톱워치 중지
    _movementService.pauseStopwatch();
  }

  // ------------------------------------------------------------
  // (4) 운동 종료
  // ------------------------------------------------------------
  Future<void> _stopWorkout() async {
    setState(() {
      _isWorkoutStarted = false;
      _isPaused = false;

      _movementService.resetAll();  // 센서 정지, 폴리라인/스톱워치 초기화
      _elapsedTime = "00:00:00";
      _currentBgLocation = null;
    });

    // BG 위치추적 중지
    await _locationService.stopBackgroundGeolocation();

    // (B) Barometer, Gyroscope, Compass 정지
    _movementService.stopBarometer();
    _movementService.stopGyroscope();
    _stopCompass();  // <-- Compass 정지 호출

    // onStopWorkout 콜백이 있다면 호출 (WebView 복귀 등)
    widget.onStopWorkout?.call();
  }

  // ------------------------------------------------------------
  // (5) 스톱워치 UI 갱신 (1초 간격)
  // ------------------------------------------------------------
  void _updateElapsedTime() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      // 운동 중 && 일시중지가 아닌 상태에서만 계속 갱신
      if (_isWorkoutStarted && !_isPaused) {
        setState(() {
          _elapsedTime = _movementService.elapsedTimeString;
        });
        // 재귀적으로 다시 호출
        _updateElapsedTime();
      }
    });
  }

  // ------------------------------------------------------------
  // (6) UI 빌드
  // ------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      /*appBar: AppBar(
        title: const Text("운동 기록 (flutter_compass 적용)"),
      ),*/
      body: Stack(
        children: [
          // -------------------------------------------------
          // (A) FlutterMap
          // -------------------------------------------------
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
              // 1) 기본 타일 레이어 (OSM)
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                maxZoom: 19,
              ),
              // 2) 한국 지도 클리핑 레이어
              KoreaClipLayer(
                polygon: mainKoreaPolygon,
                child: TileLayer(
                  urlTemplate: 'https://tiles.osm.kr/hot/{z}/{x}/{y}.png',
                  maxZoom: 19,
                ),
              ),
              // 3) 위치 정확도 원 (Circle)
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
                      color: Colors.red.withAlpha(50),
                      borderColor: Colors.red,
                      borderStrokeWidth: 2.0,
                    ),
                  ],
                ),
              // 4) 현재 위치 + heading 방향
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
                        // 1) _compassHeading가 null일 수도 있으니 ?? 0
                        // 2) to 라디안: (deg * pi/180)
                        // 3) Icon 자체가 "위쪽=0도"라면, 북쪽(0도) 시에 위를 향하도록 -90도 보정
                        angle: ((_compassHeading ?? 0) * math.pi / 180) - math.pi / 2,
                        alignment: Alignment.center,
                        child: const Icon(
                          Icons.navigation,
                          color: Colors.red,
                          size: 30.0,
                        ),
                      ),
                    ),
                  ],
                ),
              // 5) 이동 경로(폴리라인)
              if (_movementService.polylinePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _movementService.polylinePoints,
                      strokeWidth: 5.0,
                      color: Colors.red,
                    ),
                  ],
                ),
            ],
          ),

          // -------------------------------------------------
          // (B) 운동 전 => "운동 시작" 버튼
          // -------------------------------------------------
          if (!_isWorkoutStarted)
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Center(
                child: ElevatedButton(
                  onPressed: _isStartingWorkout ? null : _startWorkout,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 5.0,
                  ),
                  child: const Text(
                    "운동 시작",
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white
                    ),
                  ),
                ),
              ),
            ),

          // -------------------------------------------------
          // (C) 운동 중 => 하단 패널 (일시중지/재시작/종료, 정보 표시)
          // -------------------------------------------------
          if (_isWorkoutStarted)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
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
                        // 거리
                        _buildInfoTile(
                            "📍 거리",
                            "${_movementService.distanceKm.toStringAsFixed(1)} km"
                        ),
                        // 속도
                        _buildInfoTile(
                            "⚡ 속도",
                            "${_movementService.averageSpeedKmh.toStringAsFixed(2)} km/h"
                        ),
                        // (변경) GPS 고도 대신 Fused Altitude(바로+GPS 융합)
                        _buildInfoTile(
                          "🏠 현재고도 (Fused)",
                          "${(_movementService.fusedAltitude ?? 0.0).toStringAsFixed(1)} m",
                        ),
                        // 누적상승고도
                        _buildInfoTile(
                          "📈 누적상승고도",
                          "${_movementService.cumulativeElevation.toStringAsFixed(1)} m",
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // "중지"/"재시작+종료" 버튼들
                    _buildPauseResumeButtons(),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // (7) UI 헬퍼 위젯들
  // ------------------------------------------------------------
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
      // "일시중지 ⏸️"
      return SizedBox(
        width: MediaQuery.of(context).size.width * 0.4,
        height: 40,
        child: ElevatedButton(
          onPressed: _pauseWorkout,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orangeAccent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text(
            "중지 ⏸️",
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      );
    } else {
      // "재시작 ▶" + "종료 ■"
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
}

// ------------------------------------------------------------
// Clip classes (한반도 지도 영역을 clipPath로 잘라내는 예시)
// ------------------------------------------------------------
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

    // polygon 리스트가 유효하면, 해당 꼭지점들을 path로 만든다
    if (polygon.isNotEmpty && mapCamera != null) {
      final firstPt = mapCamera.latLngToScreenPoint(polygon[0]);
      path.moveTo(firstPt.x, firstPt.y);
      for (int i = 1; i < polygon.length; i++) {
        final pt = mapCamera.latLngToScreenPoint(polygon[i]);
        path.lineTo(pt.x, pt.y);
      }
      path.close();
    }

    // ClipPath로 child를 잘라서 표시
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
