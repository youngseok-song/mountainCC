import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_svg/flutter_svg.dart';

// Hive, GPX 관련 임포트
import 'package:hive/hive.dart';
import 'package:gpx/gpx.dart';
import '../models/location_data.dart';

// fl_chart 임포트
import 'package:fl_chart/fl_chart.dart';
import '../service/location_service.dart';
import '../service/movement_service.dart';

/// SummaryScreen: 운동 종료 후, 요약(지도 + 그래프 + 기록정보) 화면
class SummaryScreen extends StatefulWidget {
  // (A) MapScreen 등에서 전달받은 운동 결과들
  final LocationService locationService;
  final MovementService movementService;
  final String totalDistance;         // 총 이동거리 (ex: "5.20")
  final String totalTime;            // 총 운동시간 (ex: "00:30:12")
  final String restTime;             // 휴식시간 (ex: "00:05:10")
  final String avgSpeed;             // 평균 속도 (ex: "7.5")
  final String cumulativeElevation;  // 누적 상승고도 (ex: "120.0")
  final String cumulativeDescent; // 누적 하강고도 (ex: "120.0")

  const SummaryScreen({
    Key? key,
    required this.locationService,
    required this.movementService,
    required this.totalDistance,
    required this.totalTime,
    required this.restTime,
    required this.avgSpeed,
    required this.cumulativeElevation,
    required this.cumulativeDescent,
  }) : super(key: key);

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  // (1) flutter_map 컨트롤러
  final MapController _mapController = MapController();

  // [추가] Hive에서 불러올 LocationData (시간순)
  List<LocationData> _locs = [];

  // [추가] "구간별 속도"에 따라 색이 달라지는 폴리라인들
  List<Polyline> _coloredPolylines = [];

  // 기존: 지도에 표시할 경로 점들 (시작점·끝점 표시에 사용)
  List<LatLng> _trackPoints = [];

  // (3) 로딩 여부
  bool _isLoading = true;

  // (4) 차트용 데이터 (x=거리, y=고도)
  List<FlSpot> _altitudeSpots = [];

  // [중요] 지도 준비 상태 플래그
  bool _mapReady = false;
  bool _forceUpdate = false;
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

      // [중요] _locs 보관 (구간별 속도 계산에 사용)
      _locs = locs;

      // 2) locs -> GPX 문자열
      final gpxStr = _buildGpxString(locs);

      // 3) GPX -> latlng
      final parsedPoints = _parseGpxToLatLng(gpxStr);
      // 지도에 마커(시작점·끝점) 표시를 위해 보관
      _trackPoints = parsedPoints;

      // 4) locs -> (distance, altitude) -> fl_chart용 FlSpot 리스트
      final altSpots = _makeAltitudeDistanceSpots(locs);
      _altitudeSpots = altSpots;

      // (5) "평균 속도" 문자열 -> double 변환 (km/h)
      final avgSpeedDouble = double.tryParse(widget.avgSpeed) ?? 5.0;

      // (6) locs에서 인접 지점 간 속도를 계산 → 여러 색상 폴리라인 생성
      _coloredPolylines = _buildColoredSpeedPolylines(_locs, avgSpeedDouble);

      // 로딩 상태 해제
      setState(() {
        _isLoading = false;
      });

      // [추가] 데이터 준비가 끝났으므로, 만약 지도도 준비됐다면 fitCamera
      //  (지도가 준비되지 않은 상태라면, onMapReady에서 다시 시도)
      _fitMapToBounds();

    } catch (e) {
      debugPrint("오류 발생: $e");
      setState(() => _isLoading = false);
    }
  }

  /// locs -> GPX XML 문자열 생성 (기존 코드)
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

  /// gpxXml -> List LatLng (지도 폴리라인 표시용) (기존 코드)
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

  /// locs -> (x=거리(km), y=고도(m))를 FlSpot 형태로 변환 (기존 코드)
  List<FlSpot> _makeAltitudeDistanceSpots(List<LocationData> locs) {
    final spots = <FlSpot>[];
    if (locs.isEmpty) return spots;

    double cumulativeDist = 0.0;
    final distanceCalc = Distance();

    for (int i = 0; i < locs.length; i++) {
      if (i == 0) {
        cumulativeDist = 0.0;
      } else {
        final distMeter = distanceCalc(
          LatLng(locs[i-1].latitude, locs[i-1].longitude),
          LatLng(locs[i].latitude,   locs[i].longitude),
        );
        cumulativeDist += distMeter;
      }

      // x축 = 누적 거리(km), y축 = 고도(m)
      spots.add(FlSpot(cumulativeDist / 1000.0, locs[i].altitude));
    }
    return spots;
  }

  // -------------------------------------------------------------------
  // "구간별 속도"에 따라 여러 색을 가진 폴리라인 생성
  // -------------------------------------------------------------------
  List<Polyline> _buildColoredSpeedPolylines(List<LocationData> locs, double avgSpeedKmh) {
    final polylines = <Polyline>[];
    if (locs.length < 2) return polylines;

    final distanceCalc = Distance();

    for (int i = 0; i < locs.length - 1; i++) {
      final A = locs[i];
      final B = locs[i + 1];

      // (1) 시간 차(초)
      final dtSec = B.timestamp.difference(A.timestamp).inSeconds;
      if (dtSec <= 0) continue;

      // (2) 거리(m)
      final distMeter = distanceCalc(
        LatLng(A.latitude, A.longitude),
        LatLng(B.latitude, B.longitude),
      );

      // (3) 속도(km/h)
      final speedKmh = (distMeter / dtSec) * 3.6;

      // (4) 속도 → 색상
      final color = _getSpeedColor(speedKmh, avgSpeedKmh);

      // (5) 짧은 폴리라인 1개
      polylines.add(
        Polyline(
          points: [
            LatLng(A.latitude, A.longitude),
            LatLng(B.latitude, B.longitude),
          ],
          color: color,
          strokeWidth: 4.0,
        ),
      );
    }

    return polylines;
  }

  List<LineChartBarData> buildSlopeColoredLines(List<FlSpot> spots) {
    final lines = <LineChartBarData>[];
    if (spots.length < 2) return lines;

    for (int i = 0; i < spots.length - 1; i++) {
      final curr = spots[i];
      final next = spots[i + 1];

      final dx = next.x - curr.x; // x축(거리) 차이 (km)
      final dy = next.y - curr.y; // y축(고도) 차이 (m)
      if (dx == 0) continue;

      // 경사도 계산
      final horizontalMeter = dx * 1000;
      final slope = (dy / horizontalMeter) * 100;

      // 경사도 범위 → color 결정 (이미 있는 함수)
      final color = _getSlopeColor(slope);

      // 아래처럼 "belowBarData"에 같은 color를 활용한 그라데이션 적용
      final segmentLine = LineChartBarData(
        spots: [curr, next],
        isCurved: false,
        color: color,
        barWidth: 3,
        dotData: FlDotData(show: false),

        // ▼▼ 라인 아래 영역(그라데이션) ▼▼
        belowBarData: BarAreaData(
          show: true,
          gradient: LinearGradient(
            colors: [
              // color에 약간 투명도(또는 밝기)를 부여
              color.withAlpha(100),
              Colors.transparent,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      );

      lines.add(segmentLine);
    }
    return lines;
  }

// 예: 경사도 범위별 색상 함수
  Color _getSlopeColor(double slopePercent) {
    // 단순 예시: 경사가 양수(오르막)일 때 빨간 계열, 음수(내리막)일 때 파란 계열
    if (slopePercent > 10) {
      return Colors.red; // 매우 가파른 오르막
    } else if (slopePercent > 5) {
      return Colors.orange;
    } else if (slopePercent > 1) {
      return Colors.yellow;
    } else if (slopePercent >= 0) {
      return Colors.green;
    } else {
      // 내리막인 경우
      if (slopePercent < -10) {
        return Colors.blueAccent;
      } else if (slopePercent < -5) {
        return Colors.blue;
      }
      return Colors.lightBlue;
    }
  }

  Color _getSpeedColor(double speedKmh, double avgSpeedKmh) {
    // 예) 5단계 분류
    if (speedKmh < avgSpeedKmh * 0.5) {
      return Color(0xffff0000);
    } else if (speedKmh < avgSpeedKmh * 0.8) {
      return Color(0xffffa500);
    } else if (speedKmh < avgSpeedKmh * 1.2) {
      return Color(0xff2e8b57);
    } else if (speedKmh < avgSpeedKmh * 1.5) {
      return Color(0xff4169e1);
    } else {
      return Color(0xff0000ff);
    }
  }

  // -------------------------------------------------------------------
  // (중요) 지도 범위를 "경로" 전체가 화면에 들어오도록 조정
  // -------------------------------------------------------------------
  void _fitMapToBounds() {
    // 1) 지도가 아직 준비되지 않았다면 리턴
    if (!_mapReady) return;
    // 2) 경로가 없으면 리턴
    if (_trackPoints.isEmpty) return;
    final bounds = LatLngBounds.fromPoints(_trackPoints);

    // (3) 유효성 확인
    //     southWest == northEast 면 "모든 점이 동일"하다고 볼 수 있음
    bool isLatLngBoundsValid(LatLngBounds b) {
      // southWest와 northEast가 같은 좌표인지 체크
      return (b.southWest.latitude != b.northEast.latitude ||
          b.southWest.longitude != b.northEast.longitude);
    }

    if (!isLatLngBoundsValid(bounds)) {
      // 유효하지 않으면 리턴
      return;
    }

    // 4) 지도 카메라를 bounds에 맞추기 (flutter_map 4.x)
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(50), // 테두리 여백
        maxZoom: 18,                      // 너무 크게 확대되지 않도록 제한
      ),
    );
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
          // (A) 지도 (2/4)
          Expanded(
            flex: 2,
            child: _buildMap(),
          ),

          // (B) 그래프 (1/4)
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: _buildAltitudeDistanceChart(),
            ),
          ),
          Center(
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                children: [
                  TextSpan(
                    text: "운동시간 : ${widget.totalTime} ",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black,),
                  ),
                  TextSpan(
                    text: "(휴식시간 : ${widget.restTime})",
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          // (C) 운동 정보 (테이블 형태)
          _buildDataMatrix(),

          // (D) 하단 버튼
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 저장 안 함
                ElevatedButton(
                  onPressed: () async {
                    // “저장하지 않고 종료” 로직
                    // 1) BG 추적, MovementService 정리
                    await widget.locationService.stopBackgroundGeolocation();
                    widget.movementService.resetAll();
                    // 2) Hive 기록 삭제
                    await Hive.box<LocationData>('locationBox').clear();
                    // 3) 화면 닫기
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

  /// ------------------------------------------------------
  /// (A) flutter_map 빌드 (onMapReady + fitCamera)
  /// ------------------------------------------------------
  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        // (1) onMapReady: 지도가 준비된 순간
        onMapReady: () {
          _mapReady = true;
          // 이 시점에 _fitMapToBounds() 재호출해서, 이미 _trackPoints 있으면 맞추기
          _fitMapToBounds();
          setState(() => _forceUpdate = true);
        },

        // (2) 초기 위치는 혹시 모를 상황 대비
        initialCenter: _trackPoints.isNotEmpty
            ? _trackPoints.first
            : LatLng(37.5665, 126.9780),
        initialZoom: 16.0,

        // 지도 회전 금지
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
        ),
      ),
      children: [
        // 기본 타일
        TileLayer(
          key: ValueKey(_forceUpdate),
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          maxZoom: 19,
        ),

        // 속도별 여러 색상 폴리라인
        if (_coloredPolylines.isNotEmpty)
          PolylineLayer(
            polylines: _coloredPolylines,
          ),

        // (시작점 & 끝점 마커)
        if (_trackPoints.isNotEmpty)
          MarkerLayer(
            markers: [
              // 시작점
              Marker(
                width: 15,
                height: 15,
                point: _trackPoints.first,
                child: SvgPicture.asset(
                  'assets/icons/map_start.svg',
                  width: 15,
                  height: 15,
                ),
              ),
              // 끝점
              Marker(
                width: 15,
                height: 15,
                point: _trackPoints.last,
                child: SvgPicture.asset(
                  'assets/icons/map_end.svg',
                  width: 15,
                  height: 15,
                ),
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
      isCurved: true,           // 곡선
      color: Colors.blue,       // 선 색
      barWidth: 3,              // 선 두께
      dotData: FlDotData(show: false),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          colors: [
            Colors.blue.withAlpha(100),
            Colors.transparent,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
    );

    final lineChartData = LineChartData(
      minY: 0,
      gridData: FlGridData(show: true),
      titlesData: FlTitlesData(
        show: true,
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 100,  // y축 고도 50m 간격(필요에 따라 조정)
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
            interval: 2, // x축 1km 간격(예시)
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
      lineBarsData: buildSlopeColoredLines(_altitudeSpots),
    );

    return LineChart(lineChartData);
  }

  /// ------------------------------------------
  /// (C) 운동 정보 (5줄×2칸 Table)
  /// ------------------------------------------
  Widget _buildDataMatrix() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Table(
        children: [
          // 2) "누적거리" / "평균속도"
          TableRow(
            children: [
              _buildTitleCellWithIcon(
                iconPath: 'assets/icons/distance.svg',
                title: "누적거리",
              ),
              _buildTitleCellWithIcon(
                iconPath: 'assets/icons/speed.svg',
                title: "평균속도",
              ),
            ],
          ),
          // 3) 실제 값
          TableRow(
            children: [
              _buildValueCell("${widget.totalDistance} km"),
              _buildValueCell("${widget.avgSpeed} km/h"),
            ],
          ),
          // 4) "누적상승고도" / "누적하강고도"
          TableRow(
            children: [
              _buildTitleCellWithIcon(
                iconPath: 'assets/icons/elevation.svg',
                title: "누적상승고도",
              ),
              _buildTitleCellWithIcon(
                iconPath: 'assets/icons/descent.svg',
                title: "누적하강고도",
              ),
            ],
          ),
          // 5) 실제 값
          TableRow(
            children: [
              _buildValueCell("${widget.cumulativeElevation} m"),
              _buildValueCell("${widget.cumulativeDescent} m"),
            ],
          ),
        ],
      ),
    );
  }

  /// 아이콘 + 텍스트를 함께 표시하는 Title 셀
  Widget _buildTitleCellWithIcon({
    required String iconPath,
    required String title,
  }) {
    return TableCell(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 1) SVG 아이콘
            SvgPicture.asset(
              iconPath,
              width: 18,
              height: 18,
            ),
            const SizedBox(width: 6),
            // 2) 텍스트
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.grey,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildValueCell(String text) {
    return TableCell(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }
}
