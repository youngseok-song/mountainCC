//screens/exercise_record.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:latlong2/latlong.dart' as latlng;  // Distance 계산용

// Hive, GPX 관련 임포트
import 'package:hive/hive.dart';
import 'package:gpx/gpx.dart';
import '../models/location_data.dart';

// fl_chart 임포트
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import '../service/location_service.dart';
import '../service/movement_service.dart';

/// SummaryScreen: 탭 2개 ("운동 기록 요약", "운동 기록 상세")
///  - [기록요약]: 지도 + 제목/날짜 입력 + 범례 + 운동정보 + 버튼
///  - [기록상세]: 고도그래프 등 fl_chart
class SummaryScreen extends StatefulWidget {
  final LocationService locationService;
  final MovementService movementService;

  final String totalDistance;
  final String totalTime;
  final String restTime;
  final String avgSpeed;
  final String cumulativeElevation;
  final String cumulativeDescent;

  const SummaryScreen({
    super.key,
    required this.locationService,
    required this.movementService,
    required this.totalDistance,
    required this.totalTime,
    required this.restTime,
    required this.avgSpeed,
    required this.cumulativeElevation,
    required this.cumulativeDescent,
  });

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class LapData {
  final double distanceKm;       // 이 랩이 몇 km 지점
  final Duration lapDuration;    // 그 지점까지 걸린 총 시간
  final double avgSpeedKmh;
  final String paceString;
  final double cumulativeAscent;

  LapData({
    required this.distanceKm,
    required this.lapDuration,
    required this.avgSpeedKmh,
    required this.paceString,
    required this.cumulativeAscent,
  });
}

class _SummaryScreenState extends State<SummaryScreen>
    with SingleTickerProviderStateMixin {

  // (A) 탭 컨트롤러: 탭 2개
  late TabController _tabController;

  // (B) 지도 컨트롤러
  final MapController _mapController = MapController();

  // (C) 제목 입력 TextField 컨트롤러
  final TextEditingController titleController = TextEditingController();


  // (D) 위치 데이터, 폴리라인, 차트 스팟
  List<Polyline> _coloredPolylines = [];
  List<LatLng> _trackPoints = [];
  final List<FlSpot> _paceSpots = [];
  final List<FlSpot> _altSpots = [];    // 고도 그래프용 (기존 _altitudeSpots를 대체 or 병행)
  final List<FlSpot> _speedSpots = [];

  // 통계 변수 (페이스)
  double _avgPace = 0;
  double _minPace = 0;  // “최고 페이스” (가장 빠른, 즉 분/킬로 최솟값)
  double _maxPace = 0;  // “가장 느린 페이스”

// 고도
  double _minAltitudeVal = 0;
  double _maxAltitudeVal = 0;

// 속도
  double _avgSpeedVal = 0;
  double _maxSpeedVal = 0;

  bool _isLoading = true;   // 로딩 상태
  bool _mapReady = false;   // 지도 준비 여부
  bool _forceUpdate = false;// 타일 리로드용



  @override
  void initState() {
    super.initState();
    // 탭 컨트롤러 초기화
    _tabController = TabController(length: 3, vsync: this);

    // 위치데이터 로딩, 폴리라인/차트 준비
    _loadDataAndBuildMap();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// ---------------------------------------
  /// 1) 위치데이터 로드 -> 지도/차트 정보 준비
  /// ---------------------------------------
  Future<void> _loadDataAndBuildMap() async {
    try {
      final box = Hive.box<LocationData>('locationBox');
      final locs = box.values.toList();
      if (locs.isEmpty) {
        setState(() => _isLoading = false);
        return;
      }

      // (1) timestamp 순 정렬
      locs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // (2) 차트 데이터 생성
      _generateChartData(locs);


      // gpx 변환
      final gpxStr = _buildGpxString(locs);

      // latlng 리스트 준비 -> 지도 마커/폴리라인 범위
      final parsedPoints = _parseGpxToLatLng(gpxStr);
      _trackPoints = parsedPoints;

      // 차트(고도 vs 거리)

      // 지도 폴리라인(속도)
      final avgSpeedDouble = double.tryParse(widget.avgSpeed) ?? 5.0;
      _coloredPolylines = buildInterpolatedPolylines(locs, avgSpeedDouble);

      setState(() => _isLoading = false);

      // 지도 범위 맞추기
      _fitMapToBounds();
    } catch (e) {
      debugPrint("오류: $e");
      setState(() => _isLoading = false);
    }
  }

  void _generateChartData(List<LocationData> locs) {
    // 1) 초기화
    _paceSpots.clear();
    _altSpots.clear();
    _speedSpots.clear();

    _avgPace = 0;
    _minPace = double.infinity;
    _maxPace = 0;

    _minAltitudeVal = double.infinity;
    _maxAltitudeVal = 0;

    _avgSpeedVal = 0;
    _maxSpeedVal = 0;

    double sumPace = 0;
    int paceCount = 0;

    double sumSpeed = 0;
    int speedCount = 0;

    final distanceCalc = Distance();
    double cumulativeDist = 0.0; // km

    // === 기존 prevLatLng, prevTime ===
    LatLng? prevLatLng;
    DateTime? prevTime;

    // === NEW: tempDist, tempTime ===
    // 보간 시 "이전 유효점과의 누적거리/시간"을 저장해둠
    double tempDistKm = 0.0;
    DateTime? tempTime;

    for (int i = 0; i < locs.length; i++) {
      final loc = locs[i];
      final currentLatLng = LatLng(loc.latitude, loc.longitude);

      if (i == 0) {
        // (A) 첫 점: 초기화
        prevLatLng = currentLatLng;
        prevTime = loc.timestamp;

        // 보간에 사용할 tempDist, tempTime도 초기화
        tempDistKm = 0.0;
        tempTime = prevTime;
        continue;
      }

      // (B) 현재 점과 이전 점 사이 거리, 시간차
      final distMeter = distanceCalc(prevLatLng!, currentLatLng);
      final dtSec = loc.timestamp.difference(prevTime!).inSeconds;

      if (dtSec <= 0) {
        // (C) 타임스탬프가 역순 or 같은 시각 => 보간 처리
        //   1) 보간하지 않고 그냥 skip할 수도 있지만, 여기서는
        //   2) time-based interpolation을 간단히 예시로 보여드립니다.

        // (C-1) "다음 유효 지점"을 찾는다
        //       i+1, i+2 ... 에서 dtSec > 0이 되는 첫 지점을 찾아서 연결
        int j = i+1;
        bool foundNext = false;
        for (; j < locs.length; j++) {
          final dtSec2 = locs[j].timestamp.difference(prevTime).inSeconds;
          if (dtSec2 > 0) {
            foundNext = true;
            break;
          }
        }
        if (!foundNext) {
          // 끝까지 못 찾았으면 더 이상 보간 불가 => break
          break;
        }
        // j 지점과 선형보간으로 연결
        final nextLoc = locs[j];
        final distMeter2 = distanceCalc(prevLatLng, LatLng(nextLoc.latitude, nextLoc.longitude));
        final dtSec2 = locs[j].timestamp.difference(prevTime).inSeconds;

        // (C-2) 누적거리, 누적시간 반영
        cumulativeDist += distMeter2 / 1000.0;
        // 보간된 속도, 페이스 등 계산
        final instantSpeed = (distMeter2 / dtSec2) * 3.6;
        double paceMinPerKm = 0;
        if (distMeter2 > 0) {
          paceMinPerKm = (dtSec2 / 60.0) / (distMeter2 / 1000.0);
        }

        // (C-3) Altitude
        final fusedAlt = nextLoc.altitude;
        // 원한다면 c ~ nextLoc 사이 altitude도 선형보간 가능

        // === spot 삽입 (cumulativeDist, paceMinPerKm, fusedAlt, speed 등)
        _paceSpots.add(FlSpot(cumulativeDist, paceMinPerKm));
        _altSpots.add(FlSpot(cumulativeDist, fusedAlt));
        _speedSpots.add(FlSpot(cumulativeDist, instantSpeed));

        // 통계 (pace, speed) 갱신
        if (paceMinPerKm > 0) {
          sumPace += paceMinPerKm;
          paceCount++;
          if (paceMinPerKm < _minPace) _minPace = paceMinPerKm;
          if (paceMinPerKm > _maxPace) _maxPace = paceMinPerKm;
        }
        if (fusedAlt < _minAltitudeVal) _minAltitudeVal = fusedAlt;
        if (fusedAlt > _maxAltitudeVal) _maxAltitudeVal = fusedAlt;
        if (instantSpeed > _maxSpeedVal) _maxSpeedVal = instantSpeed;
        sumSpeed += instantSpeed;
        speedCount++;

        // (C-4) prevLatLng, prevTime = j 지점으로 이동
        prevLatLng = LatLng(nextLoc.latitude, nextLoc.longitude);
        prevTime = nextLoc.timestamp;
        // for 루프 i를 j로 건너뛰기
        i = j;
        continue;
      }

      // (D) dtSec >= 0 => 정상
      cumulativeDist += distMeter / 1000.0;

      final instantSpeed = (distMeter / dtSec) * 3.6;
      double paceMinPerKm = 0;
      if (distMeter > 0) {
        paceMinPerKm = (dtSec / 60.0) / (distMeter / 1000.0);
      }

      // Altitude
      final alt = loc.altitude;

      // === Spots
      _paceSpots.add(FlSpot(cumulativeDist, paceMinPerKm));
      _altSpots.add(FlSpot(cumulativeDist, alt));
      _speedSpots.add(FlSpot(cumulativeDist, instantSpeed));

      // === 통계 ===
      if (paceMinPerKm > 0) {
        sumPace += paceMinPerKm;
        paceCount++;
        if (paceMinPerKm < _minPace) _minPace = paceMinPerKm;
        if (paceMinPerKm > _maxPace) _maxPace = paceMinPerKm;
      }
      if (alt < _minAltitudeVal) _minAltitudeVal = alt;
      if (alt > _maxAltitudeVal) _maxAltitudeVal = alt;

      sumSpeed += instantSpeed;
      speedCount++;
      if (instantSpeed > _maxSpeedVal) _maxSpeedVal = instantSpeed;

      // 갱신
      prevLatLng = currentLatLng;
      prevTime = loc.timestamp;
    }

    // 평균 pace, speed 계산
    _avgPace = (paceCount > 0) ? sumPace / paceCount : 0.0;
    if (_minPace == double.infinity) _minPace = 0.0;
    _avgSpeedVal = (speedCount > 0) ? sumSpeed / speedCount : 0.0;
  }

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


  // 지도 폴리라인(속도)
  /// 폴리라인에 보간 로직을 적용한 예시 함수
  List<Polyline> buildInterpolatedPolylines(List<LocationData> locs, double avgSpeedKmh) {
    final polylines = <Polyline>[];
    if (locs.length < 2) return polylines;

    final distanceCalc = Distance();
    int i = 0;
    while (i < locs.length - 1) {
      final A = locs[i];
      final B = locs[i + 1];

      final dtSec = B.timestamp.difference(A.timestamp).inSeconds;
      if (dtSec <= 0) {
        // (A) 역순/동일 timestamp → 보간
        //     1) i+2..i+N 중 유효한 j 찾기
        int j = i + 2;
        bool foundNext = false;
        for (; j < locs.length; j++) {
          final dtSec2 = locs[j].timestamp.difference(A.timestamp).inSeconds;
          if (dtSec2 > 0) {
            foundNext = true;
            break;
          }
        }
        if (!foundNext) {
          // 못 찾으면 여기서 종료
          break;
        }
        // j 지점을 C로 잡아서, A→C를 한 번에 연결
        final C = locs[j];

        final distMeterAC = distanceCalc(
          LatLng(A.latitude, A.longitude),
          LatLng(C.latitude, C.longitude),
        );
        final dtSecAC = C.timestamp.difference(A.timestamp).inSeconds;
        final speedKmhAC = (distMeterAC / dtSecAC) * 3.6;
        final colorAC = _getSpeedColor(speedKmhAC, avgSpeedKmh);

        polylines.add(
          Polyline(
            points: [
              LatLng(A.latitude, A.longitude),
              LatLng(C.latitude, C.longitude),
            ],
            color: colorAC,
            strokeWidth: 4.0,
          ),
        );

        // (A-2) i를 j로 점프
        i = j;
      } else {
        // (B) 정상 → A→B
        final distMeterAB = distanceCalc(
          LatLng(A.latitude, A.longitude),
          LatLng(B.latitude, B.longitude),
        );
        final speedKmhAB = (distMeterAB / dtSec) * 3.6;
        final colorAB = _getSpeedColor(speedKmhAB, avgSpeedKmh);

        polylines.add(
          Polyline(
            points: [
              LatLng(A.latitude, A.longitude),
              LatLng(B.latitude, B.longitude),
            ],
            color: colorAB,
            strokeWidth: 4.0,
          ),
        );
        // i++
        i++;
      }
    }

    return polylines;
  }

  Color _getSpeedColor(double speedKmh, double avgSpeedKmh) {
    // 1) 속도 비율 ratio = (speed / avgSpeed)
    double ratio = speedKmh / avgSpeedKmh;

    // 2) 우리가 원하는 범위 [0.3 ~ 2.6] 으로 clamp
    //    => 0.3 이하는 0.3, 2.6 이상은 2.6
    const double minRatio = 0.3;
    const double maxRatio = 2.6;
    if (ratio < minRatio) ratio = minRatio;
    if (ratio > maxRatio) ratio = maxRatio;

    // 3) 0.3 ~ 2.6 (폭 2.3) 구간을 0..1 로 환산
    double t = (ratio - minRatio) / (maxRatio - minRatio); // => [0..1]

    // 4) 24단계 => 인덱스 0..23
    const int stepCount = 24;
    int index = (t * (stepCount - 1)).round();
    // clamp
    if (index < 0) index = 0;
    if (index >= stepCount) index = stepCount - 1;

    // 5) "직접 매핑"할 24가지 색상 배열
    //    아래는 예시로 빨강→주황→노랑→연두→초록→파랑→보라 까지
    //    단계적으로 분포한 24개 RGBA 값입니다.
    //    (원하시는 색상으로 자유롭게 조정 가능)
    const List<Color> rainbow24 = [
      Color(0xFFFF0000), // Red
      Color(0xFFFF2100),
      Color(0xFFFF4200),
      Color(0xFFFF6300),
      Color(0xFFFF8400),
      Color(0xFFFFA500), // Orange
      Color(0xFFFFA500),
      Color(0xFFFFB700),
      Color(0xFFFFC900),
      Color(0xFFFFDB00),
      Color(0xFFFFED00),
      Color(0xFFFFFF00), // Yellow
      Color(0xFFFFFF00),
      Color(0xFFCCE500),
      Color(0xFF7cfc00),
      Color(0xFF00ff00),
      Color(0xFF32cd00),
      Color(0xFF339900),
      Color(0xFF228b22), // Green
      Color(0xFF008000),
      Color(0xFF006400),
      Color(0xFF0A506B),
      Color(0xFF003399),
      Color(0xFF0019CC),
      Color(0xFF0000FF), // Blue// Blue
    ];

    // 6) 최종 인덱스에 해당하는 색 리턴
    return rainbow24[index];
  }



  void _fitMapToBounds() {
    if (!_mapReady) return;
    if (_trackPoints.isEmpty) return;

    final bounds = LatLngBounds.fromPoints(_trackPoints);
    bool isLatLngBoundsValid(LatLngBounds b) {
      return (b.southWest.latitude != b.northEast.latitude ||
          b.southWest.longitude != b.northEast.longitude);
    }
    if (!isLatLngBoundsValid(bounds)) return;

    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(50),
        maxZoom: 18,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      // 로딩 중 화면
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text("운동 기록 요약"),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // *** AppBar 제거 + body에서 탭 구성 ***
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        body: Column(
          children: [
            // 상단 탭 영역
            Container(
              color: Colors.white,
              child: TabBar(
                controller: _tabController,
                labelColor: Colors.black,
                unselectedLabelColor: Colors.grey,
                tabs: const [
                  Tab(text: "운동 기록 요약"),
                  Tab(text: "운동 기록 상세"),
                  Tab(text: "랩 통계"),
                ],
              ),
            ),

            // 탭 내용
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildRecordSummaryTab(),
                  _buildRecordDetailTab(),
                  _buildLapStatsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  /// (새로 정의) HIVE 기록 탭 UI
  Widget _buildHiveListTab() {
    final box = Hive.box<LocationData>('locationBox');
    final locs = box.values.toList();

    if (locs.isEmpty) {
      return const Center(child: Text("저장된 위치데이터가 없습니다."));
    }

    // (1) Distance 계산 객체 (latlong2) 준비
    final distanceCalc = latlng.Distance();

    // (2) 새 리스트를 만들어, 각 index별로 [위도/경도/고도/시간/이동거리/시간차/속도] 등 보관
    //     예) List<RichLocation> 처럼 커스텀 클래스나, Map<String, dynamic> 사용 가능
    final List<Map<String, dynamic>> displayItems = [];

    // (3) locs를 순회하며, 이전 지점과 비교
    //     첫 번째 지점(i=0)은 "이전 위치 없음"으로 보고 거리/속도 0 처리
    LocationData? prev;
    for (int i = 0; i < locs.length; i++) {
      final current = locs[i];

      double distMeter = 0.0;
      double speedKmh = 0.0;
      int dtSec = 0;

      if (prev != null) {
        // (a) 수평 거리 계산
        distMeter = distanceCalc(
          latlng.LatLng(prev.latitude, prev.longitude),
          latlng.LatLng(current.latitude, current.longitude),
        );
        // (b) 시간차(초)
        dtSec = current.timestamp.difference(prev.timestamp).inSeconds;

        // (c) 속도(km/h) = (distMeter/1000) / (dtSec / 3600)
        //                = distMeter * 3.6 / dtSec
        if (dtSec > 0) {
          speedKmh = (distMeter * 3.6) / dtSec;
        }
      }

      // Map 등으로 담아두고, 나중에 ListView에서 사용
      displayItems.add({
        'lat': current.latitude,
        'lon': current.longitude,
        'alt': current.altitude,
        'time': current.timestamp,
        'distMeter': distMeter,
        'dtSec': dtSec,
        'speedKmh': speedKmh,
        'accuracy': current.accuracy,
      });

      prev = current; // 다음 루프에서 비교할 "이전 위치"가 됨
    }

    // (4) 이제 displayItems를 ListView.builder로 표시
    return ListView.builder(
      itemCount: displayItems.length,
      itemBuilder: (context, index) {
        final item = displayItems[index];
        final lat = item['lat'] as double;
        final lon = item['lon'] as double;
        final alt = item['alt'] as double;
        final time = item['time'] as DateTime;
        final distMeter = item['distMeter'] as double;
        final dtSec = item['dtSec'] as int;
        final speedKmh = item['speedKmh'] as double;

        return ListTile(
          leading: const Icon(Icons.location_on),
          title: Text(
            "Lat: ${lat.toStringAsFixed(6)}, "
                "Lon: ${lon.toStringAsFixed(6)}",
          ),
          subtitle: Text(
            "고도: ${alt.toStringAsFixed(1)} m\n"
                "시간: $time\n"
                "거리(이전점→현재점): ${distMeter.toStringAsFixed(1)} m\n"
                "정확도: ±${(item['accuracy'] as double).toStringAsFixed(1)} m\n"
                "시간차: ${dtSec}s\n"
                "속도: ${speedKmh.toStringAsFixed(2)} km/h",
          ),
        );
      },
    );
  }


  Widget _buildLapStatsTab() {
    final box = Hive.box<LocationData>('locationBox');
    final locs = box.values.toList();

    if (locs.isEmpty) {
      return const Center(child: Text("저장된 위치데이터가 없습니다."));
    }

    // 1) 시간 순 정렬
    locs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // 2) 랩 리스트 생성
    final laps = _makeLapList(locs);

    return ListView.separated(
      itemCount: laps.length,
      // (A) 각 랩 표시
      itemBuilder: (context, index) {
        final lap = laps[index];

        final distStr = "${lap.distanceKm.toStringAsFixed(2)} km";
        final durStr  = _formatDuration(lap.lapDuration);
        final speedStr= "${lap.avgSpeedKmh.toStringAsFixed(2)} km/h";
        final paceStr = lap.paceString;
        final ascentStr = "${lap.cumulativeAscent.toStringAsFixed(2)} m";

        return ListTile(
          leading: Text("${index + 1} 랩"),
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Expanded(child: Text(distStr)),
              Expanded(child: Text(durStr)),
              Expanded(child: Text(speedStr)),
              Expanded(child: Text(paceStr)),
              Expanded(child: Text(ascentStr)),
            ],
          ),
        );
      },
      // (B) 랩과 랩 사이 구분자(Separator) 위젯
      separatorBuilder: (context, index) {
        return Column(
          children: const [
            SizedBox(height: 5),
            // 얇은 가로선
            Divider(
              thickness: 1,       // 선 두께
              color: Color(0xFFDADADA), // 선 색상(원하는 컬러)
            ),
            SizedBox(height: 5),
          ],
        );
      },
    );
  }


  List<LapData> _makeLapList(List<LocationData> locs) {
    // (A) 준비
    final distanceCalc = Distance();
    List<LapData> result = [];

    // 누적거리, 누적상승고도, etc.
    double cumulativeDist = 0.0;
    double cumulativeAscent = 0.0;

    // (B) 시작 시점(= 첫 위치)
    final startTime = locs.first.timestamp;
    DateTime prevTime = startTime;
    LatLng prevLatLng = LatLng(locs.first.latitude, locs.first.longitude);
    double prevAlt = locs.first.altitude;

    // “다음 랩 km” (1.0, 2.0, 3.0…)
    double nextLapTarget = 1.0;

    // (C) 첫 Lap: 0km
    result.add(
      LapData(
        distanceKm: 0.0,
        lapDuration: Duration.zero,
        avgSpeedKmh: 0.0,
        paceString: "--'--\"",
        cumulativeAscent: 0.0,
      ),
    );

    for (int i = 1; i < locs.length; i++) {
      final current = locs[i];
      final curLatLng = LatLng(current.latitude, current.longitude);

      final distMeter = distanceCalc(prevLatLng, curLatLng);
      final distKm = distMeter / 1000.0;

      cumulativeDist += distKm;

      // 상승고도 계산
      final altDiff = current.altitude - prevAlt;
      if (altDiff > 0) {
        cumulativeAscent += altDiff;
      }

      final nowTime = current.timestamp;

      // 만약 cumulativeDist >= nextLapTarget => 랩 생성
      while (cumulativeDist >= nextLapTarget) {
        // 랩 지점 = nextLapTarget
        final lapDist = nextLapTarget;
        // 경과시간 = nowTime - startTime
        final dur = nowTime.difference(startTime);

        // 평균속도 = lapDist / (dur.inSeconds/3600)
        final hours = dur.inSeconds / 3600.0;
        double speedKmh = 0.0;
        if (hours > 0 && lapDist>0) {
          speedKmh = lapDist / hours;
        }

        // 페이스
        final paceStr = _formatPace( (dur.inSeconds/60.0) / lapDist );

        result.add(
          LapData(
            distanceKm: lapDist,
            lapDuration: dur,
            avgSpeedKmh: speedKmh,
            paceString: paceStr,
            cumulativeAscent: cumulativeAscent,
          ),
        );

        nextLapTarget += 1.0; // 다음 랩(1km씩 증가)
      }

      // 갱신
      prevLatLng = curLatLng;
      prevAlt = current.altitude;
      prevTime = nowTime;
    }

    // (D) 마지막 leftover
    if (cumulativeDist % 1.0 != 0.0) {
      // 예: 5.35 → leftover=5.35
      final leftover = cumulativeDist;
      final endTime = locs.last.timestamp;
      final dur = endTime.difference(startTime);

      double speedKmh = 0.0;
      final hours = dur.inSeconds / 3600.0;
      if (hours>0 && leftover>0) {
        speedKmh = leftover / hours;
      }
      final paceStr = _formatPace( (dur.inSeconds/60.0)/ leftover );

      result.add(
        LapData(
          distanceKm: leftover,
          lapDuration: dur,
          avgSpeedKmh: speedKmh,
          paceString: paceStr,
          cumulativeAscent: cumulativeAscent,
        ),
      );
    }

    return result;
  }

  String _formatDuration(Duration d) {
    final hh = d.inHours.toString().padLeft(2, '0');
    final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return "$hh:$mm:$ss";
  }

  // -----------------------------------------------
  // (1) 기록요약 탭: 지도 + 제목영역 + 범례 + 운동정보 + 버튼
  // -----------------------------------------------
  Widget _buildRecordSummaryTab() {
    final screenHeight = MediaQuery.of(context).size.height;

    return Column(
      children: [
        const SizedBox(height: 15),
        // 제목 + 날짜
        _buildTitleSection(),

        const SizedBox(height: 30),

        // 지도 (화면높이의 30%)
        SizedBox(
          height: screenHeight * 0.3,
          child: _buildMap(),
        ),

        const SizedBox(height: 5),

        // “느림~빠름” 색 범례
        Padding(
          padding: const EdgeInsets.symmetric(horizontal:16, vertical: 8),
          child: _buildSpeedLegendBar(),
        ),

        const SizedBox(height: 15),

        // 운동정보 + 버튼 : 남은 공간 사용
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                children: [
                  const SizedBox(height: 15),

                  // 운동시간 / 휴식시간
                  Center(
                    child: RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: "운동시간 : ${widget.totalTime} ",
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          TextSpan(
                            text: "(휴식시간 : ${widget.restTime})",
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // 운동 정보 테이블
                  _buildDataMatrix(),
                ],
              ),

              // 버튼
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        // 저장 안 함
                        await widget.locationService.stopBackgroundGeolocation();
                        widget.movementService.resetAll();
                        await Hive.box<LocationData>('locationBox').clear();
                        if (!mounted) return;
                        Navigator.pop(context);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey[300],
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: const Text(
                        "저장하지 않고 종료",
                        style: TextStyle(color: Colors.black),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        // 저장 후 종료
                        Navigator.pop(context);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
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
        ),
      ],
    );
  }

  // -----------------------------------------------
  // (2) 기록상세 탭: 고도그래프 (fl_chart 예시)
  // -----------------------------------------------
  Widget _buildRecordDetailTab() {
    // 데이터가 전혀 없을 때 예외처리
    if (_paceSpots.isEmpty && _altSpots.isEmpty && _speedSpots.isEmpty) {
      return const Center(child: Text("기록된 데이터가 없어 그래프를 표시할 수 없습니다."));
    }

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // 1) 페이스
            SizedBox(height:20),
            const Text("페이스", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height:10),
            _buildStackedPaceChart(),
            SizedBox(height:10),
            _buildPaceSummary(),


            // (A) 가로선 추가
            SizedBox(height: 20),  // 그래프-선 사이 여백
            Container(
              width: double.infinity,
              height: 1,
              color: Colors.grey[300],
            ),
            SizedBox(height: 20),  // 선-다음 그래프 사이 여백

            // 2) 고도
            const Text("고도", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height:10),
            _buildStackedAltitudeChart(),
            SizedBox(height:10),
            _buildAltitudeSummary(),
            const SizedBox(height: 30),


            // (A) 가로선 추가
            SizedBox(height: 20),  // 그래프-선 사이 여백
            Container(
              width: double.infinity,
              height: 1,
              color: Colors.grey[300],
            ),
            SizedBox(height: 20),  // 선-다음 그래프 사이 여백


            // 3) 속도
            const Text("속도", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            SizedBox(height:10),
            _buildStackedSpeedChart(),
            SizedBox(height:10),
            _buildSpeedSummary(),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------
  // 지도
  // -----------------------------------------------
  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        onMapReady: () {
          _mapReady = true;
          _fitMapToBounds();
          setState(() => _forceUpdate = true);
        },
        initialCenter: _trackPoints.isNotEmpty
            ? _trackPoints.first
            : LatLng(37.5665, 126.9780),
        initialZoom: 16.0,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
        ),
      ),
      children: [
        TileLayer(
          key: ValueKey(_forceUpdate),
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          maxZoom: 19,
        ),
        if (_coloredPolylines.isNotEmpty)
          PolylineLayer(polylines: _coloredPolylines),
        if (_trackPoints.isNotEmpty)
          MarkerLayer(
            markers: [
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

  // -----------------------------------------------
  // (A) “느림~빠름” 색상 범례
  // -----------------------------------------------
  Widget _buildSpeedLegendBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 느림
        const Text(
          "느림",
          style: TextStyle(fontSize: 14, color: Colors.black),
        ),

        // 그라데이션 Bar
        Container(
          width: 300,
          height: 10,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            gradient: const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                // 빨강→주황→노랑→연두→초록→하늘→파랑
                Color(0xFFFF0000),
                Color(0xFFFF8000),
                Color(0xFFFFFF00),
                Color(0xFF80FF00),
                Color(0xFF00FF00),
                Color(0xFF00FFFF),
                Color(0xFF0000FF),
              ],
              stops: [0.0, 0.17, 0.34, 0.51, 0.68, 0.85, 1.0], // 균등 분배 예시
            ),
          ),
        ),

        // 빠름
        const Text(
          "빠름",
          style: TextStyle(fontSize: 14, color: Colors.black),
        ),
      ],
    );
  }

  // -----------------------------------------------
  // (B) “제목 + 날짜”
  // -----------------------------------------------
  Widget _buildTitleSection() {
    // 현재 시각
    final now = DateTime.now();
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(now);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, //왼쪽정렬
        children: [
          Row(
            children: [
              const Icon(Icons.directions_walk, color: Colors.grey),
              const SizedBox(width: 8),

              // 제목 (TextField)
              Expanded(
                child: TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: "운동 제목을 입력해주세요.",
                  ),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          //const SizedBox(height: 6),
          // 날짜 텍스트
          Text(
            dateStr,
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------
  // (C) 운동 정보 테이블
  // -----------------------------------------------
  Widget _buildDataMatrix() {
    return Container(
      padding: const EdgeInsets.all(12),
      child: Table(
        children: [
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
          TableRow(
            children: [
              _buildValueCell("${widget.totalDistance} km"),
              _buildValueCell("${widget.avgSpeed} km/h"),
            ],
          ),
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
            SvgPicture.asset(
              iconPath,
              width: 18,
              height: 18,
            ),
            const SizedBox(width: 6),
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

// 페이스 차트
  Widget _buildStackedPaceChart() {
    // (1) reversedSpots 계산
    final offset = _maxPace;
    final reversedSpots = _paceSpots.map((spot) {
      final reversedY = offset - spot.y;
      return FlSpot(spot.x, reversedY);
    }).toList();

    return SizedBox(
      height: 200,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // (2) 차트 채우기
          Positioned.fill(
            child: Padding(
              // 그래프 자체에 여백을 주고 싶다면 Padding으로 감싸기
              padding: const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 20),
              child: _buildLineChart(
                spots: reversedSpots,
                color: Colors.purple,
                noDataText: "페이스 데이터가 없습니다.",
                isReversed: true,
                offsetValue: offset,
                // ↑ 축을 전부 숨겼으므로, yLabelFormatter도 실제 표시엔 안 쓰이지만
                //   내부 계산이 필요하시다면 남겨두셔도 됩니다
                yLabelFormatter: (double val) => _formatPace(val),
              ),
            ),
          ),


          // (3) 그래프 바깥 왼쪽 상단에 "min/km" 표시
          Positioned(
            top: 0,
            left: 0,
            child: Text(
              "min/km",
              style: TextStyle(fontSize: 12, color: Colors.black),
            ),
          ),

          // (4) 그래프 바깥 오른쪽 하단에 "km" 표시
          Positioned(
            right: 0,
            bottom: 0,
            child: Text(
              "km",
              style: TextStyle(fontSize: 12, color: Colors.black),
            ),
          ),
        ],
      ),
    );
  }

// 고도 차트
  Widget _buildStackedAltitudeChart() {

    // 2) 실제 차트는 _buildLineChart로
    //    unitY, leftAxisName 이런건 안 써도 됨(축 이름은 Stack으로 배치)
    return SizedBox(
      height: 200,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // (A) 차트 자체를 전체에 fill
          Positioned.fill(
            child: _buildLineChart(
              spots: _altSpots,
              color: Colors.orange,
              noDataText: "고도 데이터가 없습니다.",
              isReversed: false,
              yLabelFormatter: (double val) => val.toStringAsFixed(1),
              // isReversed: false,
            ),
          ),

          // (B) 왼쪽 위 => "m" (수직 회전)
          // (B) 왼쪽 축 라벨: "m"
          Positioned(
            top: 0,
            left: 0,
            child: Text("m"),      // y축 라벨
          ),

          // (C) 아래 축 라벨: "km"
          Positioned(
            right: 0,
            bottom: 0,
            child: Text("km"),     // x축 라벨
          ),
        ],
      ),
    );
  }

// 속도 차트
  Widget _buildStackedSpeedChart() {
    return SizedBox(
      height: 200,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // (A) 차트
          Positioned.fill(
            child: _buildLineChart(
              spots: _speedSpots,
              color: Colors.redAccent,
              noDataText: "속도 데이터가 없습니다.",
              isReversed: false,
              yLabelFormatter: (double val) => val.toStringAsFixed(1),
            ),
          ),

          // (B) 왼쪽 위 => "km/h" (수직 회전)
          Positioned(
            top: 0,
            left: 0,
            child: Text("km/h"),      // y축 라벨
          ),

          // (C) 아래 축 라벨: "km"
          Positioned(
            right: 0,
            bottom: 0,
            child: Text("km"),     // x축 라벨
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow({
    required String leftTitle,
    required String leftValue,
    required String rightTitle,
    required String rightValue,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center, // 전체 Row를 수평 중앙 정렬
      children: [
        // 왼쪽 영역
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center, // 세로축에서도 중앙
            children: [
              Text(leftTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(leftValue, style: const TextStyle(fontSize: 16)),
            ],
          ),
        ),

        // 가운데 세로선 (얇은 라인)
        Container(
          width: 1,
          height: 40,
          color: Colors.grey[300],
        ),

        // 오른쪽 영역
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(rightTitle, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(rightValue, style: const TextStyle(fontSize: 16)),
            ],
          ),
        ),
      ],
    );
  }


  Widget _buildPaceSummary() {
    final avg = _formatPace(_avgPace);
    final best = _formatPace(_minPace); // minPace = 가장 빠른

    return _buildSummaryRow(
      leftTitle: "평균 페이스",
      leftValue: avg,
      rightTitle: "최고 페이스",
      rightValue: best,
    );
  }

// 고도
  Widget _buildAltitudeSummary() {
    return _buildSummaryRow(
      leftTitle: "최저 고도",
      leftValue: "${_minAltitudeVal.toStringAsFixed(2)} m",
      rightTitle: "최고 고도",
      rightValue: "${_maxAltitudeVal.toStringAsFixed(2)} m",
    );
  }

// 속도
  Widget _buildSpeedSummary() {
    return _buildSummaryRow(
      leftTitle: "평균 속도",
      leftValue: "${_avgSpeedVal.toStringAsFixed(2)} km/h",
      rightTitle: "최대 속도",
      rightValue: "${_maxSpeedVal.toStringAsFixed(2)} km/h",
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

// pace를 "분'초\"" 형태로
String _formatPace(double pace) {
  if (pace <= 0) return "--'--\"";
  final minPart = pace.floor();
  final secPart = ((pace - minPart) * 60).round();
  return "$minPart'${secPart.toString().padLeft(2, '0')}\"";
}


/// 동적으로 X/Y 범위와 간격을 설정하는 LineChart
// 어떤 double 값을 받아서, 라벨 문자열을 리턴하는 함수 시그니처
typedef YLabelFormatter = String Function(double value);
Widget _buildLineChart({
  required List<FlSpot> spots,
  required Color color,
  String? noDataText,
  bool isReversed = false,  // <<--- 새로 추가
  double? offsetValue,      // <<--- 새로 추가 (역순 변환 시 사용)
  required YLabelFormatter yLabelFormatter,
}) {
  // (A) 스팟이 비어있으면 "데이터 없음" 표시
  if (spots.isEmpty) {
    return Center(child: Text(noDataText ?? "데이터가 없습니다."));
  }


  // (B) X축 범위: [0, maxX]
  final double maxX = spots.map((e) => e.x).reduce((a, b) => a > b ? a : b);
  final double minX = 0.0;

  // X축 간격
  double xRange = maxX - minX;
  double xInterval = xRange > 0 ? xRange / 10 : 1.0;

  // (C) Y축 범위
  // - isReversed=false → 0..maxY
  // - isReversed=true  → 0..(offsetValue - minPace), etc (이미 변환된 spots를 쓴다면 단순 계산)
  final double maxY = spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
  final double minY = spots.map((e) => e.y).reduce((a, b) => a < b ? a : b);

  double yRange = (maxY - minY).abs();
  double yInterval = yRange > 0 ? yRange / 5 : 1.0;

  // (D) 차트에 표시할 라인
  final lineBarData = LineChartBarData(
    spots: spots,
    isCurved: true,
    color: color,
    barWidth: 2,
    dotData: FlDotData(show: false),
    belowBarData: BarAreaData(
      show: true,
      color: color.withAlpha(75),
    ),
  );

  return SizedBox(
    height: 200,
    child: LineChart(
      LineChartData(
        // (1) minX/maxX: 그대로
        minX: minX,
        maxX: maxX,

        // (2) minY, maxY: 이미 spots가 변환되어 왔으므로, 그대로 사용
        minY: minY,
        maxY: maxY * 1.2,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          drawHorizontalLine: true,

          // X축 점선 간격
          verticalInterval: xInterval,
          // Y축 점선 간격
          horizontalInterval: yInterval,

          // (B) 점선 스타일
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.grey,
            strokeWidth: 0.5,
            dashArray: [4,4],  // 4픽셀 점선, 4픽셀 공백
          ),
          getDrawingVerticalLine: (value) => FlLine(
            color: Colors.grey,
            strokeWidth: 0.5,
            dashArray: [4,4],
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: const Border(
            left: BorderSide(color: Colors.grey),
            bottom: BorderSide(color: Colors.grey),
            right: BorderSide(color: Colors.transparent),
            top: BorderSide(color: Colors.transparent),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            /// (축 이름)
            axisNameWidget: null,
            sideTitles: SideTitles(
              showTitles: true,
              interval: yInterval,
              reservedSize: 40.0,
              getTitlesWidget: (value, meta) {
                // 최댓값 라벨은 숨김
                if (meta.max == value) {
                  return const SizedBox.shrink();
                }

                // 2) 역변환 (isReversed)
                double realVal = value;
                if (isReversed && offsetValue != null) {
                  realVal = offsetValue - value;
                }

                final label = yLabelFormatter(realVal);
                return Text(label, style: const TextStyle(fontSize: 12));
              },
            ),
          ),
          bottomTitles: AxisTitles(
            axisNameWidget: null,
            sideTitles: SideTitles(
              showTitles: true,
              interval: xInterval,
              getTitlesWidget: (value, meta) {
                // X축 라벨
                if (value == meta.max) {
                  return const SizedBox.shrink();
                }
                return Text(value.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 12));
              },
            ),
          ),
          rightTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        lineBarsData: [lineBarData],
      ),
    ),
  );
}

