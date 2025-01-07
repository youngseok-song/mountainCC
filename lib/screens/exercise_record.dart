import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// Hive, GPX 관련 임포트
import 'package:hive/hive.dart';
import 'package:gpx/gpx.dart';
import '../models/location_data.dart';

// fl_chart 임포트
import 'package:fl_chart/fl_chart.dart';

/// SummaryScreen: 운동 종료 후, 요약(지도 + 그래프 + 기록정보) 화면
class SummaryScreen extends StatefulWidget {
  // (A) MapScreen 등에서 전달받은 운동 결과들
  final String totalDistance;         // 총 이동거리 (ex: "5.20")
  final String totalTime;            // 총 운동시간 (ex: "00:30:12")
  final String restTime;             // 휴식시간 (ex: "00:05:10")
  final String avgSpeed;             // 평균 속도 (ex: "7.5")
  final String cumulativeElevation;  // 누적 상승고도 (ex: "120.0")

  const SummaryScreen({
    Key? key,
    required this.totalDistance,
    required this.totalTime,
    required this.restTime,
    required this.avgSpeed,
    required this.cumulativeElevation,
  }) : super(key: key);

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  // (1) flutter_map 컨트롤러
  final MapController _mapController = MapController();

  // (2) 지도에 표시할 경로 점들
  List<LatLng> _trackPoints = [];

  // (3) 로딩 여부
  bool _isLoading = true;

  // (4) 차트용 데이터 (x=거리, y=고도)
  List<FlSpot> _altitudeSpots = [];

  @override
  void initState() {
    super.initState();
    // (A) 화면 초기화 시, Hive 데이터 로드 -> 지도 & 그래프 데이터 구성
    _loadDataAndBuildMap();
  }

  /// -------------------------------------------------------------------
  /// 1) Hive 데이터 로드 -> GPX 변환 -> 지도 폴리라인 + 차트 데이터
  /// -------------------------------------------------------------------
  Future<void> _loadDataAndBuildMap() async {
    try {
      // 1) locs = Hive box의 LocationData 목록
      final box = Hive.box<LocationData>('locationBox');
      final locs = box.values.toList(); // List<LocationData>
      if (locs.isEmpty) {
        // 기록이 없다면
        setState(() => _isLoading = false);
        return;
      }

      // 2) locs -> GPX 문자열
      final gpxStr = _buildGpxString(locs);

      // 3) GPX -> latlng
      final parsedPoints = _parseGpxToLatLng(gpxStr);

      // 4) locs -> (distance, altitude) -> fl_chart용 FlSpot 리스트
      final altSpots = _makeAltitudeDistanceSpots(locs);

      // 5) UI 반영
      setState(() {
        _trackPoints = parsedPoints;
        _altitudeSpots = altSpots;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("오류 발생: $e");
      setState(() => _isLoading = false);
    }
  }

  /// locs -> GPX XML 문자열 생성
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

  /// gpxXml -> List LatLng  (지도 폴리라인 표시용)
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

  /// locs -> (x=거리(km), y=고도(m))를 FlSpot 형태로 변환
  List<FlSpot> _makeAltitudeDistanceSpots(List<LocationData> locs) {
    // locs가 순서대로(시간순) 정렬되었다고 가정
    if (locs.length < 2) {
      // 점이 1개 이하라면, 그래프 만들기 어려움
      return [];
    }

    final distanceCalc = Distance(); // latlong2 패키지 제공
    double cumulativeDist = 0.0;     // 누적거리 (meter)
    final spots = <FlSpot>[];

    for (int i = 0; i < locs.length; i++) {
      if (i == 0) {
        // 첫 점
        cumulativeDist = 0.0;
      } else {
        // 이전 점 ~ 현재 점 거리 계산
        final prev = locs[i - 1];
        final curr = locs[i];
        final distMeter = distanceCalc(
          LatLng(prev.latitude, prev.longitude),
          LatLng(curr.latitude, curr.longitude),
        );
        cumulativeDist += distMeter; // 누적
      }

      // x=거리(km), y=고도(m)
      final xVal = cumulativeDist / 1000.0; // km
      final yVal = locs[i].altitude;        // meter
      spots.add(FlSpot(xVal, yVal));
    }
    return spots;
  }

  @override
  Widget build(BuildContext context) {
    // 로딩 중이면 로딩 표시
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text("운동 기록 요약"),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 로딩 완료된 경우
    return Scaffold(
      // 뒤로가기 버튼 제거
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text("운동 기록 요약"),
      ),
      body: Column(
        children: [
          /// (A) 지도 (2/4)
          Expanded(
            flex: 2,
            child: _buildMap(),
          ),

          /// (B) 그래프 (1/4)
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: _buildAltitudeDistanceChart(),
            ),
          ),

          /// (C) 운동 정보 (테이블 형태)
          _buildDataMatrix(),

          // (D) 하단 버튼
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 저장 안 함
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[300],
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text("저장하지 않고 종료", style: TextStyle(color: Colors.black)),
                ),
                // 저장 후 종료
                ElevatedButton(
                  onPressed: () {
                    // 기록 저장 로직 (ex: 서버 업로드, etc)
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  child: const Text("기록 저장 후 종료", style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// ------------------------------------------
  /// (A) flutter_map 빌드
  /// ------------------------------------------
  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        // 지도 초기 위치: 첫 점 or (37.5665,126.9780)
        initialCenter: _trackPoints.isNotEmpty
            ? _trackPoints.first
            : LatLng(37.5665, 126.9780),
        initialZoom: 16.0,
      ),
      children: [
        // 기본 타일
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          maxZoom: 19,
        ),
        // 경로(폴리라인)
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

  /// ------------------------------------------
  /// (B) 고도-거리 라인차트 (fl_chart)
  /// ------------------------------------------
  Widget _buildAltitudeDistanceChart() {
    if (_altitudeSpots.isEmpty) {
      return const Center(child: Text("고도/거리 데이터가 없습니다."));
    }

    final lineBarData = LineChartBarData(
      spots: _altitudeSpots,
      color: Colors.blue,
      isCurved: false,
      dotData: FlDotData(show: false),
      belowBarData: BarAreaData(show: false),
    );

    final lineChartData = LineChartData(
      minY: 0,
      gridData: FlGridData(show: true),
      titlesData: FlTitlesData(
        show: true,
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 50,  // y축 고도 50m 간격(필요에 따라 조정)
            reservedSize: 40,
            getTitlesWidget: (value, meta) {
              final altitudeM = value.round();
              return Text("$altitudeM m", style: const TextStyle(fontSize: 11));
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 1, // x축 1km 간격(예시)
            reservedSize: 44,
            getTitlesWidget: (value, meta) {
              final distanceKm = value.toStringAsFixed(1);
              // -0.3 라디안(약 -17도) 기울여 표시
              return Transform.rotate(
                angle: -0.3,
                alignment: Alignment.center,
                child: Text("$distanceKm km", style: const TextStyle(fontSize: 11)),
              );
            },
          ),
        ),
        rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      borderData: FlBorderData(show: false),
      lineBarsData: [lineBarData],
    );

    return LineChart(lineChartData);
  }

  /// ------------------------------------------
  /// (C) 운동 정보 (5줄×2칸 Table)
  /// ------------------------------------------
  Widget _buildDataMatrix() {
    // 임시로 누적하강고도(cumDescent)는 "0.00"으로 표기
    const cumDescent = "0.00";

    // 첫 번째 줄: 운동시간/휴식시간을 한 칸으로 합쳐 표시.
    //   Flutter Table 은 colSpan 미지원 → 두 번째 칸을 빈칸으로 둠
    return Container(
      padding: const EdgeInsets.all(12),
      child: Table(
        columnWidths: const <int, TableColumnWidth>{
          0: FlexColumnWidth(),
          1: FlexColumnWidth(),
        },
        children: [
          // 1) 운동시간 + 휴식시간 (한 칸)
          TableRow(
            children: [
              TableCell(
                child: Center(
                  child: Text(
                    "운동시간 ${widget.totalTime} (휴식시간 ${widget.restTime})",
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              // 이 칸은 비워둠( colSpan 대용 )
              const SizedBox(),
            ],
          ),

          // 2) "누적거리" / "평균속도"
          TableRow(
            children: [
              _buildTitleCell("누적거리"),
              _buildTitleCell("평균속도"),
            ],
          ),

          // 3) 실제 값: "00.00 km" / "00.00 km/h"
          TableRow(
            children: [
              _buildValueCell("${widget.totalDistance} km"),
              _buildValueCell("${widget.avgSpeed} km/h"),
            ],
          ),

          // 4) "누적상승고도" / "누적하강고도"
          TableRow(
            children: [
              _buildTitleCell("누적상승고도"),
              _buildTitleCell("누적하강고도"),
            ],
          ),

          // 5) 실제 값: "120.0 m" / "0.00 m"
          TableRow(
            children: [
              _buildValueCell("${widget.cumulativeElevation} m"),
              _buildValueCell("$cumDescent m"),
            ],
          ),
        ],
      ),
    );
  }

  // [소제목] 셀
  Widget _buildTitleCell(String text) {
    return TableCell(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.grey,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  // [값] 셀
  Widget _buildValueCell(String text) {
    return TableCell(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
