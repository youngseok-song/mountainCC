// screens/map_screen.dart
import 'dart:math' as math;
import 'dart:ui' as ui; // ClipPath용
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive/hive.dart';

import '../models/location_data.dart';
import '../service/location_service.dart';
import '../service/barometer_service.dart';

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
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // flutter_map 컨트롤러
  final MapController _mapController = MapController();

  // Location / Barometer Service
  late LocationService _locationService;
  late BarometerService _barometerService;

  // 위치 & 경로 정보
  Position? _currentPosition;
  final List<LatLng> _polylinePoints = [];

  // 운동 상태
  bool _isWorkoutStarted = false;
  bool _isPaused = false;

  // 시간/스톱워치
  final Stopwatch _stopwatch = Stopwatch();
  String _elapsedTime = "00:00:00";

  // 고도 관련
  double _cumulativeElevation = 0.0;
  double? _baseAltitude;

  @override
  void initState() {
    super.initState();
    // Hive에서 locationBox 가져오기
    final locationBox = Hive.box<LocationData>('locationBox');
    _locationService = LocationService(locationBox);
    _barometerService = BarometerService();

    _requestLocationPermission();
  }

  // 위치 권한 요청
  Future<void> _requestLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("위치 서비스를 활성화해주세요."))
      );
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("위치 권한이 거부되었습니다."))
        );
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("위치 권한이 영구적으로 거부되었습니다."))
      );
      return;
    }
  }

  // 운동 시작
  void _startWorkout() async {
    setState(() {
      _isWorkoutStarted = true;
      _stopwatch.start();
    });

    // 현재 위치 가져와 지도 이동
    final position = await _locationService.getCurrentPosition();
    setState(() {
      _currentPosition = position;
    });
    _mapController.move(LatLng(position.latitude, position.longitude), 15.0);

    // 실시간 위치 추적
    _locationService.trackLocation((pos) {
      if (!mounted) return;
      setState(() {
        _currentPosition = pos;
        _polylinePoints.add(LatLng(pos.latitude, pos.longitude));
        _updateCumulativeElevation(pos);
      });
    });

    // 경과시간 업데이트
    _updateElapsedTime();
  }

  // 일시중지
  void _pauseWorkout() {
    setState(() {
      _stopwatch.stop();
      _isPaused = true;
    });
  }

  // 종료
  void _stopWorkout() {
    setState(() {
      _isWorkoutStarted = false;
      _stopwatch.stop();
      _stopwatch.reset();
      _elapsedTime = "00:00:00";
      _polylinePoints.clear();
      _cumulativeElevation = 0.0;
      _baseAltitude = null;
      _isPaused = false;
    });
  }

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

  double _calculateDistance() {
    double totalDistance = 0.0;
    for (int i = 1; i < _polylinePoints.length; i++) {
      totalDistance += Geolocator.distanceBetween(
        _polylinePoints[i - 1].latitude,
        _polylinePoints[i - 1].longitude,
        _polylinePoints[i].latitude,
        _polylinePoints[i].longitude,
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

  void _updateCumulativeElevation(Position position) {
    double currentAltitude = _calculateCurrentAltitude(position);
    if (_baseAltitude == null) {
      _baseAltitude = currentAltitude;
    } else {
      double elevationDifference = currentAltitude - _baseAltitude!;
      if (elevationDifference > 3.0) {
        _cumulativeElevation += elevationDifference;
        _baseAltitude = currentAltitude;
      } else if (elevationDifference < 0) {
        _baseAltitude = currentAltitude;
      }
    }
  }

  double _calculateCurrentAltitude(Position position) {
    // 바로미터 사용 가능 시 가정
    if (_barometerService.isBarometerAvailable && _barometerService.currentPressure != null) {
      const double seaLevelPressure = 1013.25;
      double altitudeFromBarometer = 44330 *
          (1.0 - math.pow((_barometerService.currentPressure! / seaLevelPressure), 0.1903) as double);
      return (position.altitude + altitudeFromBarometer) / 2;
    } else {
      return position.altitude;
    }
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
      return SizedBox(
        width: MediaQuery.of(context).size.width * 0.4,
        height: 40,
        child: ElevatedButton(
          onPressed: () {
            _pauseWorkout();
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.orangeAccent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text("중지 ⏸️", style: TextStyle(color: Colors.white, fontSize: 15)),
        ),
      );
    } else {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 재시작
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
          // 종료
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
        title: const Text("운동 기록 + Clip OSM"),
      ),
      body: Stack(
        children: [
          // FlutterMap (Stack 맨 아래)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(37.5665, 126.9780),
              initialZoom: 15.0,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
              ),
            ),
            children: [
              // (1) OSM 전 세계
              TileLayer(
                urlTemplate: 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                subdomains: ['a','b','c'],
              ),

              // (2) ClipPath로 한국만 tiles.osm.kr
              KoreaClipLayer(
                polygon: mainKoreaPolygon,
                child: TileLayer(
                  urlTemplate: 'https://tiles.osm.kr/hot/{z}/{x}/{y}.png',
                  maxZoom: 19,
                ),
              ),

              // (3) 정확도 범위 Circle
              if (_currentPosition != null)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                      radius: _currentPosition!.accuracy,
                      useRadiusInMeter: true,
                      color: Colors.blue.withOpacity(0.1),
                      borderStrokeWidth: 2.0,
                      borderColor: Colors.blue,
                    ),
                  ],
                ),

              // (4) 현재 위치 마커
              if (_currentPosition != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
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

              // (5) 경로 Polyline
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

          // 운동 시작 전 버튼
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

          // 운동 중: 하단 패널
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
                        _buildInfoTile("📍 거리", "${_calculateDistance().toStringAsFixed(1)} km"),
                        _buildInfoTile("⚡ 속도", "${_calculateAverageSpeed().toStringAsFixed(2)} km/h"),
                        _buildInfoTile("🏠 현재고도", "${_currentPosition?.altitude.toInt() ?? 0} m"),
                        _buildInfoTile("📈 누적상승고도", "${_cumulativeElevation.toStringAsFixed(1)} m"),
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
    if (mapCamera == null) {
      return child; // mapCamera 가져오기 불가 시, clip 없이 child 그대로
    }

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