import 'dart:async';                        // Timer, Future.delayed 등을 위해
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive/hive.dart';

// flutter_background_geolocation
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;

import '../models/location_data.dart';
import '../service/location_service.dart';

// ------------------------------
// 한국 지도 범위 Clip을 위한 폴리곤 좌표
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
  // (A) FlutterMap 제어용 컨트롤러 & 맵 초기상태
  final MapController _mapController = MapController();
  bool _mapIsReady = false;

  // (B) LocationService : flutter_background_geolocation 시작/중지 + Hive 저장 담당
  late LocationService _locationService;

  // (C) 현재 위치(마커 표시 목적)
  bg.Location? _currentBgLocation;

  // (D) 운동(스톱워치) 상태
  bool _isWorkoutStarted = false; // "운동 시작" 버튼 누르면 true
  bool _isPaused = false;         // 일시중지 상태
  final Stopwatch _stopwatch = Stopwatch();  // 운동 시간 측정
  String _elapsedTime = "00:00:00";          // UI에 표시할 스톱워치 문자열

  // (E) 폴리라인/거리/고도 계산용
  final List<LatLng> _polylinePoints = [];
  double _cumulativeElevation = 0.0;
  double? _baseAltitude;

  // -----------------------------
  // 첫 GPS 위치(Fix) 대기 관련
  bool _isFirstFixFound = false; // 첫 위치를 잡았는지 여부

  // -----------------------------
  // 3초 카운트다운 관련
  bool _inCountdown = false;    // 카운트다운 오버레이 표시 여부
  int _countdownValue = 10;      // 3→2→1
  bool _ignoreInitialData = true;
  // → 3초 카운트다운이 끝날 때까지 폴리라인/거리/고도 측정을 무시

  @override
  void initState() {
    super.initState();

    // Hive box 열기 → LocationService 초기화
    final locationBox = Hive.box<LocationData>('locationBox');
    _locationService = LocationService(locationBox);
  }

  // =========================================================
  // (1) Always 위치 권한 체크/요청
  Future<bool> _checkAndRequestAlwaysPermission() async {
    // 이미 권한 있으면 통과
    if (await Permission.locationAlways.isGranted) {
      return true;
    }
    // 없으면 요청
    final status = await Permission.locationAlways.request();
    if (status.isGranted) {
      return true;
    } else {
      // 완전 거부 => 설정 이동 안내
      _showNeedPermissionDialog();
      return false;
    }
  }

  // 권한 거부 → 설정화면 안내 다이얼로그
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

  // =========================================================
  // (2) 운동 시작 버튼 로직
  Future<void> _startWorkout() async {
    // 1) 위치 권한 체크
    final hasAlways = await _checkAndRequestAlwaysPermission();
    if (!hasAlways) return;

    // 2) 운동 시작 UI 상태 표시 (아직 스톱워치는 start 안 함)
    setState(() {
      _isWorkoutStarted = true;
      _elapsedTime = "00:00:00";
      _stopwatch.reset();
      _isFirstFixFound = false;       // 첫 GPS 위치 찾기 전
      _ignoreInitialData = true;      // 폴리라인,거리 무시
    });

    // 3) background_geolocation 바로 start
    //    첫 위치(Fix)를 찾으면 onLocation 콜백 → _isFirstFixFound = true
    await _locationService.startBackgroundGeolocation((bg.Location loc) {
      if (!mounted) return;

      // (A) 마커 업데이트 (바로 표시)
      setState(() {
        _currentBgLocation = loc;
      });

      // (B) 첫 위치(Fix) 확인
      if (!_isFirstFixFound) {
        // -> 아직 첫 위치가 안 잡힌 상태였다면, 이제 잡힘
        _isFirstFixFound = true;

        // 첫 위치는 마커만 보여주고,
        // 폴리라인/거리 계산은 안 함
        // => 이제부터 3초 카운트다운을 시작
        _startCountdown();
        return;
      }

      // (C) 첫 위치는 이미 찾은 상태
      // -> 카운트다운이 진행중 or 끝난 상태
      if (_ignoreInitialData) {
        // => 아직 3초 안 지났다면 데이터 무시
        return;
      }

      // (D) 실제 폴리라인, 고도 반영
      setState(() {
        _polylinePoints.add(
          LatLng(loc.coords.latitude, loc.coords.longitude),
        );
        _updateCumulativeElevation(loc);
      });

      // 지도 이동 (현재 줌 유지)
      if (_mapIsReady) {
        final currentZoom = _mapController.camera.zoom;
        _mapController.move(
          LatLng(loc.coords.latitude, loc.coords.longitude),
          currentZoom,
        );
      }
    });

    // 4) getCurrentPosition()으로 초기 위치 한 번 가져오기
    final currentLoc = await bg.BackgroundGeolocation.getCurrentPosition(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      timeout: 30,
    );
    if (!mounted) return;

    // 마커 표시
    setState(() {
      _currentBgLocation = currentLoc;
    });

    // 첫 위치가 이미 없었던 상태라면
    if (!_isFirstFixFound) {
      // => now it is the first fix
      _isFirstFixFound = true;
      _startCountdown();
    } else if (!_ignoreInitialData) {
      // 첫 위치는 잡혔고, 카운트다운 끝났다면
      setState(() {
        _polylinePoints.add(
          LatLng(currentLoc.coords.latitude, currentLoc.coords.longitude),
        );
        _updateCumulativeElevation(currentLoc);
      });
    }

    // 지도 이동
    if (_mapIsReady) {
      _mapController.move(
        LatLng(currentLoc.coords.latitude, currentLoc.coords.longitude),
        15.0,
      );
    }
  }

  // =========================================================
  // (3) 3초 카운트다운 : 첫 위치(Fix)된 순간부터
  void _startCountdown() {
    setState(() {
      _inCountdown = true;     // 카운트다운 오버레이 표시
      _countdownValue = 10;
      _ignoreInitialData = true; // 3초 동안 위치 데이터 반영X
    });

    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_countdownValue <= 1) {
        timer.cancel();
        setState(() {
          _inCountdown = false;
          _ignoreInitialData = false;
        });

        // 스톱워치 시작
        _stopwatch.reset();
        _stopwatch.start();
        _updateElapsedTime();

        // (추가) 카운트다운 끝난 시점에 "현재 위치" 다시 한번 갱신
        final loc = await bg.BackgroundGeolocation.getCurrentPosition(
          desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
          timeout: 30,
        );
        if (!mounted) return;

        setState(() {
          _currentBgLocation = loc;
          // 폴리라인 반영
          _polylinePoints.add(
            LatLng(loc.coords.latitude, loc.coords.longitude),
          );
          _updateCumulativeElevation(loc);
        });

        // 여기서 바로 mapController.move(...)
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

  // =========================================================
  // (4) 일시중지
  void _pauseWorkout() {
    setState(() {
      _stopwatch.stop();
      _isPaused = true;
    });
  }

  // =========================================================
  // (5) 운동 종료
  Future<void> _stopWorkout() async {
    setState(() {
      _isWorkoutStarted = false;
      _isPaused = false;

      // 스톱워치 초기화
      _stopwatch.stop();
      _stopwatch.reset();
      _elapsedTime = "00:00:00";

      // 폴리라인, 고도
      _polylinePoints.clear();
      _cumulativeElevation = 0.0;
      _baseAltitude = null;

      // 첫 위치, 카운트다운
      _isFirstFixFound = false;
      _inCountdown = false;
      _ignoreInitialData = true;
      _countdownValue = 3;

      // 위치 초기화
      _currentBgLocation = null;
    });

    await _locationService.stopBackgroundGeolocation();
    widget.onStopWorkout?.call();
  }

  // =========================================================
  // (6) 스톱워치 UI 갱신 (1초 마다)
  void _updateElapsedTime() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      // 스톱워치가 동작 중이면 => 계속 경과시간 세팅
      if (_stopwatch.isRunning) {
        setState(() {
          _elapsedTime = _formatTime(_stopwatch.elapsed);
        });
        _updateElapsedTime(); // 재귀
      }
    });
  }

  String _formatTime(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return "$hours:$minutes:$seconds";
  }

  // =========================================================
  // (7) 거리/속도/고도 계산
  double _calculateDistance() {
    double totalDistance = 0.0;
    for (int i = 1; i < _polylinePoints.length; i++) {
      totalDistance += Distance().distance(
        _polylinePoints[i - 1],
        _polylinePoints[i],
      );
    }
    return totalDistance / 1000.0; // m->km
  }

  double _calculateAverageSpeed() {
    if (_stopwatch.elapsed.inSeconds == 0) return 0.0;
    final distKm = _calculateDistance();
    final timeH = _stopwatch.elapsed.inSeconds / 3600.0;
    return distKm / timeH;
  }

  void _updateCumulativeElevation(bg.Location location) {
    final currentAltitude = location.coords.altitude;
    if (_baseAltitude == null) {
      _baseAltitude = currentAltitude;
      return;
    }

    final diff = currentAltitude - _baseAltitude!;
    if (diff > 3.0) {
      _cumulativeElevation += diff;
      _baseAltitude = currentAltitude;
    } else if (diff < 0) {
      _baseAltitude = currentAltitude;
    }
  }

  // =========================================================
  // (8) UI 헬퍼
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
              setState(() {
                _stopwatch.start();
                _isPaused = false;
              });
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

  // -------------------------------
  // (추가) 카운트다운 오버레이 (검정 배경 + 숫자)
  Widget _buildCountdownOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black87,
        child: Center(
          child: Text(
            _countdownValue.toString(), // 3->2->1
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

  // =========================================================
  // (9) build()
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("운동 기록 + 첫 위치 후 3초 Delay"),
      ),
      body: Stack(
        children: [
          // A) FlutterMap
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
              TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: ['a','b','c'],
              ),
              KoreaClipLayer(
                polygon: mainKoreaPolygon,
                child: TileLayer(
                  urlTemplate: 'https://tiles.osm.kr/hot/{z}/{x}/{y}.png',
                  maxZoom: 19,
                ),
              ),
              // 정확도 원 (마커 근처)
              if (_currentBgLocation?.coords != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: LatLng(
                        _currentBgLocation!.coords.latitude,
                        _currentBgLocation!.coords.longitude,
                      ),
                      radius: _currentBgLocation?.coords.accuracy ?? 5.0,
                      useRadiusInMeter: true,
                      color: Colors.blue.withAlpha(25),
                      borderStrokeWidth: 2.0,
                      borderColor: Colors.blue,
                    ),
                  ],
                ),
              // 현재 위치 마커
              if (_currentBgLocation?.coords != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(
                        _currentBgLocation!.coords.latitude,
                        _currentBgLocation!.coords.longitude,
                      ),
                      width: 12.0,
                      height: 12.0,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2.0),
                        ),
                      ),
                    ),
                  ],
                ),
              // 폴리라인 (ignoreInitialData = false 상태일 때만 쌓임)
              if (_polylinePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _polylinePoints,
                      strokeWidth: 4.0,
                      color: Colors.blue,
                    ),
                  ],
                ),
            ],
          ),

          // B) 운동 시작 전 => "운동 시작" 버튼
          if (!_isWorkoutStarted)
            Positioned(
              bottom: 20, left: 0, right: 0,
              child: Center(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  height: 50.0,
                  child: ElevatedButton(
                    onPressed: _startWorkout,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      elevation: 5.0,
                    ),
                    child: const Text(
                      "운동 시작",
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),

          // C) 운동 중 → 하단 패널
          if (_isWorkoutStarted)
            Positioned(
              bottom: 0, left: 0, right: 0,
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

                    GridView.count(
                      shrinkWrap: true,
                      crossAxisCount: 2,
                      mainAxisSpacing: 18.5,
                      crossAxisSpacing: 12,
                      childAspectRatio: 3.5,
                      children: [
                        _buildInfoTile(
                          "📍 거리",
                          "${_calculateDistance().toStringAsFixed(1)} km",
                        ),
                        _buildInfoTile(
                          "⚡ 속도",
                          "${_calculateAverageSpeed().toStringAsFixed(2)} km/h",
                        ),
                        _buildInfoTile(
                          "🏠 현재고도",
                          "${(_currentBgLocation?.coords.altitude ?? 0).toInt()} m",
                        ),
                        _buildInfoTile(
                          "📈 누적상승고도",
                          "${_cumulativeElevation.toStringAsFixed(1)} m",
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildPauseResumeButtons(),
                  ],
                ),
              ),
            ),

          // (추가) D) 카운트다운 오버레이 (검정 배경 + 숫자)
          if (_inCountdown) _buildCountdownOverlay(),
        ],
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
