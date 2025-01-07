import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// (예시) Hive, GPX 관련 임포트
import 'package:hive/hive.dart';
import 'package:gpx/gpx.dart';
import '../models/location_data.dart';

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({Key? key}) : super(key: key);

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final MapController _mapController = MapController();

  // 지도에 표시할 최종 (lat,lng) 목록
  List<LatLng> _trackPoints = [];
  bool _isLoading = true; // 로딩 표시

  // 운동 기록 정보 예시 (실제로는 인자로 넘기거나 Hive에서 불러오기)
  double totalDistance = 0.0;
  String totalTime = "00:00:00";
  String restTime = "00:00:00";
  double avgSpeed = 0.0;
  double cumulativeElevation = 0.0;

  @override
  void initState() {
    super.initState();
    // 1) Hive에서 위치 데이터 불러와 GPX 지도 표시 준비
    _loadDataAndBuildMap();
  }

  /// Hive -> (lat,lon) -> gpx -> parse -> flutter_map 폴리라인
  Future<void> _loadDataAndBuildMap() async {
    try {
      // (A) 예시: Hive box
      final box = Hive.box<LocationData>('locationBox');
      final locs = box.values.toList();
      if (locs.isEmpty) {
        // 기록이 없다면
        setState(() => _isLoading = false);
        return;
      }

      // (B) GPX XML 문자열 생성
      final gpxStr = _buildGpxString(locs);

      // (C) GPX 파싱 -> List<LatLng>
      final parsedPoints = _parseGpxToLatLng(gpxStr);

      // (D) 운동 정보 (예시)
      totalDistance = 5.2;
      totalTime = "00:30:12";
      restTime = "00:05:10";
      avgSpeed = 7.5;
      cumulativeElevation = 120.0;

      // UI 갱신
      setState(() {
        _trackPoints = parsedPoints;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("오류: $e");
      setState(() => _isLoading = false);
    }
  }

  /// locs -> GPX XML 문자열
  String _buildGpxString(List<LocationData> locs) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<gpx creator="MyApp" version="1.1" xmlns="http://www.topografix.com/GPX/1/1">');
    buffer.writeln('  <trk>');
    buffer.writeln('    <name>My workout track</name>');
    buffer.writeln('    <trkseg>');

    for (final loc in locs) {
      buffer.writeln('      <trkpt lat="${loc.latitude}" lon="${loc.longitude}">');
      buffer.writeln('        <ele>${loc.altitude.toStringAsFixed(1)}</ele>');
      final utcTime = loc.timestamp.toUtc().toIso8601String();
      buffer.writeln('        <time>$utcTime</time>');
      buffer.writeln('      </trkpt>');
    }

    buffer.writeln('    </trkseg>');
    buffer.writeln('  </trk>');
    buffer.writeln('</gpx>');
    return buffer.toString();
  }

  /// GPX 파싱 -> LatLng 리스트
  List<LatLng> _parseGpxToLatLng(String gpxXml) {
    final gpxData = GpxReader().fromString(gpxXml);
    final result = <LatLng>[];

    if (gpxData.trks != null) {
      for (final trk in gpxData.trks!) {
        if (trk.trksegs != null) {
          for (final seg in trk.trksegs!) {
            if (seg.trkpts != null) {
              for (final pt in seg.trkpts!) {
                if (pt.lat != null && pt.lon != null) {
                  result.add(LatLng(pt.lat!, pt.lon!));
                }
              }
            }
          }
        }
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 뒤로가기 버튼 제거
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text("운동 기록 요약"),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
        children: [
          // (A) 지도 영역
          Expanded(
            flex: 2,
            child: _buildMap(),
          ),

          // (B) (옵션) 그래프 영역
          Expanded(
            flex: 1,
            child: Container(
              color: Colors.lightGreen[100],
              child: const Center(
                child: Text("고도/속도 그래프 표시 영역(예시)"),
              ),
            ),
          ),

          // (C) 운동 정보
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            color: Colors.white,
            child: Column(
              children: [
                Text("운동시간: $totalTime / 휴식시간: $restTime"),
                Text("누적 거리: ${totalDistance.toStringAsFixed(2)} km"),
                Text("평균 속도: ${avgSpeed.toStringAsFixed(2)} km/h"),
                Text("누적 상승고도: ${cumulativeElevation.toStringAsFixed(1)} m"),
              ],
            ),
          ),

          // (D) 하단 버튼들
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: () {
                    // 저장 안함
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[300],
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    "저장하지 않고 종료",
                    style: TextStyle(color: Colors.black),
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    // 기록 저장 -> gpx서버 업로드 등
                    // 이후 pop
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    "기록 저장 후 종료",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 실제 flutter_map 빌드
  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _trackPoints.isNotEmpty ? _trackPoints.first : LatLng(37.5665, 126.9780),
        initialZoom: 16.0,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          maxZoom: 19,
        ),
        if (_trackPoints.isNotEmpty)
          PolylineLayer(
            polylines: [
              Polyline(
                points: _trackPoints,
                strokeWidth: 4.0,
                color: Colors.blue,
              ),
            ],
          ),
      ],
    );
  }
}
