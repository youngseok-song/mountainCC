import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart'; // 권한 체크를 위해 추가
import 'package:hive/hive.dart';

// (중요) flutter_background_geolocation 관련 import
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;

import '../models/location_data.dart';
import '../service/location_service.dart';

// ------------------ Clip용 폴리곤 (한국)
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
  final MapController _mapController = MapController();

  late LocationService _locationService;
  // flutter_background_geolocation으로 동작하는 LocationService

  // flutter_background_geolocation.Location 기반의 현재 위치
  bg.Location? _currentBgLocation;
  final List<LatLng> _polylinePoints = [];

  bool _isWorkoutStarted = false;
  bool _isPaused = false;

  final Stopwatch _stopwatch = Stopwatch();
  String _elapsedTime = "00:00:00";

  double _cumulativeElevation = 0.0;
  double? _baseAltitude;

  // (map이 준비된 후에 move하려면 필요)
  bool _mapIsReady = false;

  @override
  void initState() {
    super.initState();

    // Hive 박스 열어서 LocationService 초기화
    final locationBox = Hive.box<LocationData>('locationBox');
    _locationService = LocationService(locationBox);
  }

  /// (1) 백그라운드 위치 권한(항상 허용) 체크/요청
  Future<bool> _checkAndRequestAlwaysPermission() async {
    // permission_handler 패키지를 통해 '항상 허용' 상태인지 확인
    if (await Permission.locationAlways.isGranted) {
      // 이미 항상 허용 상태라면 바로 true
      return true;
    }

    // 아직 권한 없으면 요청
    final status = await Permission.locationAlways.request();

    if (status == PermissionStatus.granted) {
      // 허용됨
      return true;
    } else if (status == PermissionStatus.permanentlyDenied) {
      // 사용자가 '다시 묻지 않기' 등을 눌러 완전히 거부한 상태
      // → 앱 설정 화면으로 안내
      _showNeedPermissionDialog();
      return false;
    }
    // 그 외(denied, restricted)도 false 반환
    return false;
  }

  /// 권한이 거부되었을 때, 설정 화면으로 이동할지 물어보는 다이얼로그
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
      // 사용자가 '설정으로 이동' 선택 시
      await openAppSettings();
    }
  }

  /// (2) 운동 시작 로직
  Future<void> _startWorkout() async {
    // 1) 먼저 백그라운드 위치(항상 허용) 권한 체크
    final hasAlways = await _checkAndRequestAlwaysPermission();
    if (!hasAlways) {
      return;
    }
    // 이후 백그라운드 지오로케이션 시작, setState() 등
    // 2) 운동 시작 상태/UI 세팅
    setState(() {
      _isWorkoutStarted = true;
      _stopwatch.start();
    });
    _updateElapsedTime();

    // 3) flutter_background_geolocation 시작
    await _locationService.startBackgroundGeolocation(
          (bg.Location loc) {
        // 위치가 업데이트될 때마다 실행되는 콜백
        if (!mounted) return;
        setState(() {
          _currentBgLocation = loc;
          _polylinePoints.add(
            LatLng(loc.coords.latitude, loc.coords.longitude),
          );
          _updateCumulativeElevation(loc);
        });

        // 맵이 준비된 상태면 카메라 이동
        if (_mapIsReady) {
          _mapController.move(
            LatLng(loc.coords.latitude, loc.coords.longitude),
            15.0,
          );
        }
      },
    );

    // 4) 현재 위치를 즉시 받아서 맵 이동 (바로 callback 이전에)
    //    - flutter_background_geolocation에는 getCurrentPosition() 등이 있음
    final currentLoc = await bg.BackgroundGeolocation.getCurrentPosition(
      desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
      // ↓ 'timeout'은 초 단위, 예: 30
      timeout: 30,
    );
    if (!mounted) return;
    setState(() {
      _currentBgLocation = currentLoc;
      _polylinePoints.add(
        LatLng(currentLoc.coords.latitude, currentLoc.coords.longitude),
      );
    });
    // 맵 이동
    if (_mapIsReady) {
      _mapController.move(
        LatLng(currentLoc.coords.latitude, currentLoc.coords.longitude),
        15.0,
      );
    }
  }

  /// (3) 운동 일시중지/종료
  void _pauseWorkout() {
    setState(() {
      _stopwatch.stop();
      _isPaused = true;
    });
  }

  Future<void> _stopWorkout() async {
    setState(() {
      _isWorkoutStarted = false;
      _stopwatch.stop();
      _stopwatch.reset();
      _elapsedTime = "00:00:00";
      _polylinePoints.clear();
      _cumulativeElevation = 0.0;
      _baseAltitude = null;
      _isPaused = false;
      _currentBgLocation = null;
    });

    // 백그라운드 위치 추적 중지
    await _locationService.stopBackgroundGeolocation();

    // onStopWorkout 콜백 호출(웹뷰 화면으로 복귀 등)
    widget.onStopWorkout?.call();
  }

  /// (4) 스톱워치
  void _updateElapsedTime() {
    Future.delayed(const Duration(seconds: 1), () {
      if (_stopwatch.isRunning) {
        if (!mounted) return;
        setState(() {
          _elapsedTime = _formatTime(_stopwatch.elapsed);
        });
        _updateElapsedTime();
      }
    });
  }

  String _formatTime(Duration duration) {
    String hours = duration.inHours.toString().padLeft(2, '0');
    String minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    String seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return "$hours:$minutes:$seconds";
  }

  /// (5) 거리/고도/속도 계산
  double _calculateDistance() {
    double totalDistance = 0.0;
    for (int i = 1; i < _polylinePoints.length; i++) {
      totalDistance += Distance().distance(
        _polylinePoints[i - 1],
        _polylinePoints[i],
      );
    }
    return totalDistance / 1000; // m -> km
  }

  double _calculateAverageSpeed() {
    if (_stopwatch.elapsed.inSeconds == 0) return 0.0;
    double distanceInKm = _calculateDistance();
    double timeInHours = _stopwatch.elapsed.inSeconds / 3600.0;
    return distanceInKm / timeInHours;
  }

  void _updateCumulativeElevation(bg.Location location) {
    final double currentAltitude = location.coords.altitude;
    if (_baseAltitude == null) {
      _baseAltitude = currentAltitude;
    } else {
      double elevationDifference = currentAltitude - _baseAltitude!;
      if (elevationDifference > 3.0) {
        // 3m 이상 상승 시 누적 상승고도에 추가
        _cumulativeElevation += elevationDifference;
        _baseAltitude = currentAltitude;
      } else if (elevationDifference < 0) {
        // 고도가 하강하면 base 갱신
        _baseAltitude = currentAltitude;
      }
    }
  }

  /// (6) UI
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
      // (A) 일시중지 버튼
      return SizedBox(
        width: MediaQuery.of(context).size.width * 0.4,
        height: 40,
        child: ElevatedButton(
          onPressed: _pauseWorkout,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orangeAccent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text("중지 ⏸️", style: TextStyle(color: Colors.white, fontSize: 15)),
        ),
      );
    } else {
      // (B) 재시작 & 종료 버튼
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("운동 기록 + Clip OSM (BackgroundGeo)"),
      ),
      body: Stack(
        children: [
          // FlutterMap
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              // 맵 준비 완료 시점 체크
              onMapReady: () {
                setState(() {
                  _mapIsReady = true;
                });
              },
              initialCenter: const LatLng(37.5665, 126.9780),
              initialZoom: 15.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
              ),
            ),
            children: [
              // 기본 OSM 타일
              TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: ['a','b','c'],
              ),
              // 한국 영역만 Clip
              KoreaClipLayer(
                polygon: mainKoreaPolygon,
                child: TileLayer(
                  urlTemplate: 'https://tiles.osm.kr/hot/{z}/{x}/{y}.png',
                  maxZoom: 19,
                ),
              ),
              // 정확도 범위 Circle
              if (_currentBgLocation?.coords != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: LatLng(
                        _currentBgLocation!.coords.latitude,
                        _currentBgLocation!.coords.longitude,
                      ),
                      // flutter_background_geolocation.Location 에서 accuracy가 null일 수 있으므로 ?? 5.0
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
              // 경로 폴리라인
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

          // (A) 운동 시작 전 → "운동 시작" 버튼
          if (!_isWorkoutStarted)
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  height: 50.0,
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
            ),

          // (B) 운동 중 → 하단 패널 표시
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
                          // coords.altitude가 null일 수 있어 0처리
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
        ],
      ),
    );
  }
}

// ------------------ ClipPath classes ------------------
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
    if (polygon.isNotEmpty) {
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
