import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:hive/hive.dart';

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;

import '../models/location_data.dart';
import '../service/location_service.dart';
import '../service/barometer_service.dart';

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
  late BarometerService _barometerService;

  // flutter_background_geolocation.Location 기반의 현재 위치
  bg.Location? _currentBgLocation;
  final List<LatLng> _polylinePoints = [];

  bool _isWorkoutStarted = false;
  bool _isPaused = false;

  final Stopwatch _stopwatch = Stopwatch();
  String _elapsedTime = "00:00:00";

  double _cumulativeElevation = 0.0;
  double? _baseAltitude;

  // (중요) flutter_map 5.x 이상에서 onMapReady를 활용하기 위한 변수
  bool _mapIsReady = false;

  @override
  void initState() {
    super.initState();
    final locationBox = Hive.box<LocationData>('locationBox');
    _locationService = LocationService(locationBox);
    _barometerService = BarometerService();
  }

  // ------------------ (1) 운동 시작 ------------------
  void _startWorkout() async {
    setState(() {
      _isWorkoutStarted = true;
      _stopwatch.start();
    });
    _updateElapsedTime();

    // 위치추적 시작 (백그라운드)
    await _locationService.startBackgroundGeolocation((bg.Location loc) {
      if (!mounted) return;
      setState(() {
        _currentBgLocation = loc;
        _polylinePoints.add(LatLng(loc.coords!.latitude, loc.coords!.longitude));
        _updateCumulativeElevation(loc);
      });

      // 지도 이동 (맵이 준비된 상태인지 확인)
      if (_mapIsReady) {
        _mapController.move(
          LatLng(loc.coords!.latitude, loc.coords!.longitude),
          15.0,
        );
      }
    });
  }

  // ------------------ (2) 일시중지 / 종료 ------------------
  void _pauseWorkout() {
    setState(() {
      _stopwatch.stop();
      _isPaused = true;
    });
  }

  void _stopWorkout() async {
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

    // 백그라운드 위치추적 중지
    await _locationService.stopBackgroundGeolocation();

    widget.onStopWorkout?.call();
  }

  // ------------------ (3) 스톱워치 ------------------
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

  // ------------------ (4) 거리/고도/속도 계산 ------------------
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
    double currentAltitude = _calculateCurrentAltitude(location);
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

  double _calculateCurrentAltitude(bg.Location location) {
    double gpsAltitude = location.coords?.altitude ?? 0.0;
    if (_barometerService.isBarometerAvailable &&
        _barometerService.currentPressure != null) {
      const double seaLevelPressure = 1013.25;
      double altitudeFromBarometer = 44330 *
          (1.0 -
              math.pow(
                  (_barometerService.currentPressure! / seaLevelPressure),
                  0.1903) as double);
      return (gpsAltitude + altitudeFromBarometer) / 2;
    } else {
      return gpsAltitude;
    }
  }

  // ------------------ (5) UI 빌드 ------------------
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
          onPressed: _pauseWorkout,
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
        title: const Text("운동 기록 + Clip OSM (onMapReady)"),
      ),
      body: Stack(
        children: [
          // FlutterMap
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              // 여기가 핵심: onMapReady
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
              // OSM 기본 타일
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
                      point: LatLng(_currentBgLocation!.coords!.latitude,
                          _currentBgLocation!.coords!.longitude),
                      radius: _currentBgLocation?.coords?.accuracy ?? 5.0,
                      useRadiusInMeter: true,
                      color: Colors.blue.withOpacity(0.1),
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
                      point: LatLng(_currentBgLocation!.coords!.latitude,
                          _currentBgLocation!.coords!.longitude),
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

          // 운동 시작 전
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

          // 운동 중 하단 패널
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
                        _buildInfoTile("🏠 현재고도", "${_currentBgLocation?.coords?.altitude?.toInt() ?? 0} m"),
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

// ------------------ ClipPath ------------------
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
      return child;
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
