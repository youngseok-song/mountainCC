// ---------------------------------------------------
// service/movement_service.dart
// ---------------------------------------------------

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:latlong2/latlong.dart';
import 'package:sensors_plus/sensors_plus.dart'; // Barometer, Gyro
import '../models/sensor_fusion.dart'; // SensorFusion 객체 (Dead Reckoning, Baro/GPS 혼합)
import 'package:flutter_compass/flutter_compass.dart';
import 'location_service.dart'; // ← Hive 쓰려면 필요


// Triple 구조체 정의
class Triple {
  final double lat;
  final double lon;
  final double alt;
  final int timestampMs; // 필요하다면, 시간도 함께 저장
  Triple(this.lat, this.lon, this.alt, this.timestampMs);
}

// MovementService 클래스
class MovementService {
  // ---------------------------------------------------
  /// (A)변수 선언부
  // ---------------------------------------------------


  // GPS 데이터(등)를 무시할지 결정하는 플래그
//  - 초기에는 true (데이터 수집 전 or 카운트다운 대기)
//  - 운동 준비가 끝나면 false로 바꿔 실제 데이터를 처리
  bool _ignoreAllData = true;  // 기본 true (초기에는 '사용 안 함')
  void setIgnoreAllData(bool ignore) {
    _ignoreAllData = ignore;
  }
  bool get ignoreAllData => _ignoreAllData;
  final LocationService _locationService;

  MovementService({
    required LocationService locationService,
  }) : _locationService = locationService;


  // ---------------------------------------------------
  /// (A) 폴리라인, 스톱워치, 누적고도 등 '운동' 관련 필드
  // ---------------------------------------------------

  // 사용자가 이동한 좌표들을 담고 있는 리스트.
  // 지도에 경로를 폴리라인으로 그릴 때 사용한다.
  final List<LatLng> _polylinePoints = [];
  // 외부에서 읽을 수 있도록 getter 제공
  List<LatLng> get polylinePoints => _polylinePoints;

  /// 스톱워치
  final Stopwatch _exerciseStopwatch = Stopwatch(); // 운동중
  final Stopwatch _restStopwatch = Stopwatch(); // 휴식중

  String get exerciseElapsedTimeString {
    final d = _exerciseStopwatch.elapsed;
    return _formatDuration(d);
  }

  String get restElapsedTimeString {
    final d = _restStopwatch.elapsed;
    return _formatDuration(d);
  }


  /// 스톱워치 경과시간을 "HH:MM:SS" 형태로 리턴
  String _formatDuration(Duration dur) {
    final hh = dur.inHours.toString().padLeft(2, '0');
    final mm = (dur.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (dur.inSeconds % 60).toString().padLeft(2, '0');
    return "$hh:$mm:$ss";
  }

  // ---------------------------------------------------
  /// (B) Hive 기반 거리·고도 누적을 위한 필드
  // ---------------------------------------------------
  double _distanceFromHiveKm = 0.0; // 누적 거리 (Hive)
  double get distanceKm => _distanceFromHiveKm;

  double _cumulativeElevationHive = 0.0; // 누적 상승고도 (Hive)
  double get cumulativeElevation => _cumulativeElevationHive;

  double _cumulativeDescentHive = 0.0;   // 누적 하강고도 (Hive)
  double get cumulativeDescent => _cumulativeDescentHive;

  bool _baroOffsetInitialized = false; // 칼만필터 사용 안할때 변수

  /// 누적 고도를 계산할 때 기준점이 될 고도
  double? _baseAltitude;
  LatLng? _lastLatLng;  // "이전 위치"를 저장할 필드


  // ---------------------------------------------------
  /// 센서 관련 구독
  // ---------------------------------------------------

  // 바로미터 이벤트 구독(subscribe) 관리
  StreamSubscription<BarometerEvent>? _barometerSub;
  // 현재 기압(hPa)을 임시 저장
  double? _currentPressureHpa;
  // 자이로 이벤트 구독(subscribe) 관리
  StreamSubscription<GyroscopeEvent>? _gyroscopeSub;
  // 가속도 이벤트 구독(subscribe) 관리
  StreamSubscription<AccelerometerEvent>? _accelSub;
  // Compass 구독을 위한 subscription
  StreamSubscription<CompassEvent>? _compassSub;
  /// heading 값 (UI에서 읽을 수 있도록 getter 제공)
  double _currentHeadingRad = 0.0; // 라디안



  // ---------------------------------------------------
  // (C) SensorFusion: Dead Reckoning + Baro/GPS 혼합
  // ---------------------------------------------------
  //  - baroAltitude, gpsAltitude, heading, baroOffset 등 관리

  final SensorFusion _fusion = SensorFusion();

  // 외부에서 Barometer 고도, 융합 고도 등을 읽을 수 있는 getter
  double? get baroAltitude => _fusion.baroAltitude;
  double? get fusedAltitude => _fusion.getFusedAltitude();

  // ---------------------------------------------------
  // (C') BaroOffset 보정 타이머(주기적 보정)
  // ---------------------------------------------------
  int _lastOffsetUpdateTime = 0;          // 마지막 offset 보정 시점(ms)
  final int _offsetUpdateInterval = 3 * 60 * 1000; // 3분

  // ---------------------------------------------------
  // Outlier 판단을 위해 이전 고도/시간 저장
  // ---------------------------------------------------
  double? _lastAltitude;
  int? _lastTimestampMs;

  // Hive에 저장된 “이전 점”을 추적하기 위해...
  LatLng? _prevHiveLatLng;
  double? _prevHiveAltitude;

  // ---------------------------------------------------
  /// 센서 선언 함수
  // ---------------------------------------------------

  // 가속도 센서 구독 시작
  void startAccelerometer() {
    if (_accelSub != null) return;

    _accelSub = accelerometerEventStream().listen((event){
      if (_ignoreAllData) return;
    });
  }

  // 가속도 센서 구독 종료
  void stopAccelerometer() {
    _accelSub?.cancel();
    _accelSub = null;
  }

  // 나침반 센서 구독 시작
  void startCompass() {
    if (_compassSub != null) return;

    _compassSub = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading == null) return;
      if (_ignoreAllData) return;
      final headingDeg = event.heading!;
      final headingRad = headingDeg * math.pi / 180.0;
      // MovementService 내부 저장 (UI 표시)
      _currentHeadingRad = headingRad;
    });
  }

  // 나침판 센서 구독 종료
  void stopCompass() {
    _compassSub?.cancel();
    _compassSub = null;
  }

  // 바로미터 구독 시작
  void startBarometer() {
    // 이미 구독 중이면 중복 방지
    if (_barometerSub != null) return;

    // barometerEventStream은 sensors_plus 패키지 제공
    _barometerSub = barometerEventStream().listen(
          (BarometerEvent event) {
        // 현재 기압(hPa)을 갱신
        _currentPressureHpa = event.pressure;

        // 기압 → 고도 변환
        final baroAlt = _baroPressureToAltitude(_currentPressureHpa!);

        // SensorFusion에 baroAlt 전달
        _fusion.onBarometer(baroAlt);
      },
      onError: (err) {
        // ex) 바로메터 지원 안 하는 기기에서 에러 가능
        // print("Barometer error: $err");
      },
    );
  }

  // 바로미터 구독 해제
  void stopBarometer() {
    _barometerSub?.cancel();
    _barometerSub = null;
  }

  // 자이로스코프 구독 시작
  void startGyroscope() {
    if (_gyroscopeSub != null) return;

    _gyroscopeSub = gyroscopeEventStream().listen((GyroscopeEvent event) {
      if (_ignoreAllData) return;
    });
  }

  // 자이로스코프 구독 해제
  void stopGyroscope() {
    _gyroscopeSub?.cancel();
    _gyroscopeSub = null;
  }

  // 기압(hPa) → 고도(m) 변환
  double _baroPressureToAltitude(double pressureHpa) {
    const seaLevel = 1013.25; // 해수면 표준 기압
    return 44330.0 * (1.0 - math.pow(pressureHpa / seaLevel, 1.0 / 5.255));
  }

  // 평균 속도(km/h)
  //  - 거리(km) / 시간(시간단위)
  double get averageSpeedKmh {
    if (_exerciseStopwatch.elapsed.inSeconds == 0) return 0.0;
    final km = distanceKm; // <-- 여기서 distanceKm는 _distanceFromHiveKm
    final hours = _exerciseStopwatch.elapsed.inSeconds / 3600.0;
    return km / hours;
  }

  //고도계산 및 바로미터 계산
  double  _handleAltitudeAndBaro(bg.Location loc) {
    // (1) 고도 계산 (SensorFusion + Baro)
    final gpsAlt = loc.coords.altitude;
    final fusedAlt = _fusion.getFusedAltitude() ?? gpsAlt;

    // (2) Baro offset 주기적 보정
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastOffsetUpdateTime > _offsetUpdateInterval) {
      _updateBaroOffsetIfNeeded(gpsAlt);
      _lastOffsetUpdateTime = nowMs;
    }

    // (3) Outlier 판단용 기록(고도 기준)
    _lastAltitude = gpsAlt;
    _lastTimestampMs = _parseTimestamp(loc.timestamp)
        ?? DateTime.now().millisecondsSinceEpoch;

    // (4) 원한다면 fusedAlt를 반환하거나,
    //     onNewLocation에서 필요하면, MovementService 내부 필드로 보관하는 것도 가능.
    return fusedAlt;
  }

  // 운동중 하단 패널 반영(거리/고도 누적 업데이트)
  void _updateStatsFromHive() {
    // 1) LocationService에서 현재 "마지막으로 저장된" 위치를 가져옴.
    final newHiveLatLng = _locationService.lastSavedPosition;
    if (newHiveLatLng == null) return; // 아직 저장된게 없다면 pass

    // 2) 만약 이전 _prevHiveLatLng와 동일하면, "새로 추가된"게 아님 → pass
    if (_prevHiveLatLng == newHiveLatLng) {
      return;
    }

    // 3) LocationService.locationBox.values.last => 새로 추가된 Hive 레코드
    final box = _locationService.locationBox;
    if (box.isEmpty) return;
    final lastData = box.values.last; // 방금 추가된 data

    final newAlt = lastData.altitude;

    // 누적 거리
    if (_prevHiveLatLng != null) {
      final distMeter = Distance().distance(_prevHiveLatLng!, newHiveLatLng);
      _distanceFromHiveKm += (distMeter / 1000.0);
    }

    // 누적 고도
    if (_prevHiveAltitude == null) {
      _prevHiveAltitude = newAlt;
    } else {
      final diff = newAlt - _prevHiveAltitude!;
      if (diff > 5.0) {
        _cumulativeElevationHive += diff;
        _prevHiveAltitude = newAlt;
      } else if (diff < -5.0) {
        _cumulativeDescentHive += (-diff);
        _prevHiveAltitude = newAlt;
      }
    }

    // 좌표/고도 갱신
    _prevHiveLatLng   = newHiveLatLng;
  }


  // =========================================================================
  // 4) 운동 시작/중지/종료/초기화 관련 함수
  // =========================================================================

  /// 운동(메인) 스톱워치 시작
  void startStopwatch() {
    _exerciseStopwatch.start();
  }

  /// 운동(메인) 스톱워치 일시중지 → 휴식 스톱워치 시작
  void pauseStopwatch() {
    _exerciseStopwatch.stop();
    _restStopwatch.start();
  }

  /// 재시작: 휴식 스톱워치 중단 → 운동 스톱워치 다시 시작
  void resumeStopwatch() {
    _restStopwatch.stop();
    _exerciseStopwatch.start();
  }

  /// 완전 리셋(운동 종료 시)
  void resetStopwatch() {
    _exerciseStopwatch.stop();
    _exerciseStopwatch.reset();
    _restStopwatch.stop();
    _restStopwatch.reset();
  }

  /// 운동 관련 상태 초기화
  void resetAll() {
    // Barometer, Gyro 구독 해제
    stopBarometer();
    stopGyroscope();
    stopCompass();
    _baroOffsetInitialized = false; // BaroOffset 보정 전 상태
    _currentHeadingRad = 0.0;
    // 폴리라인, 누적고도, 스톱워치 등 초기화
    _polylinePoints.clear();
    _distanceFromHiveKm = 0.0;
    _cumulativeElevationHive = 0.0;
    _cumulativeDescentHive = 0.0;
    _baseAltitude = null;
    pauseStopwatch();
    resetStopwatch();
    _currentPressureHpa = null;
    // SensorFusion 초기화
    _fusion.init();
    // Offset 업데이트 시점, Altitude 기록도 초기화
    _lastOffsetUpdateTime = 0;
    _lastAltitude = null;
    _lastTimestampMs = null;
  }

  // =========================================================================
  // 5) onNewLocation → Outlier → RawGPS → 폴리라인/고도
  // =========================================================================
  /// BG plugin의 onLocation()에서 호출
  (LatLng?, double?, double?) onNewLocation(bg.Location loc, {bool ignoreData = false}) {

    // (A) 카운트 다운 중
    if (_ignoreAllData || ignoreData) {
      return (null,null,null);
    }

    if (isOutlier(loc)) {
      return (null, null, null); // 이상치면 저장 안 함
    }


     final result = _applyRawGPS(loc);


    if (result == null) {
      return (null, null, null);
    }

    // result가 (ekfLat, ekfLon, acc) 형태이므로, 구조분해 할당
    final (rowLat, rowLon, acc) = result;

    final fusedAlt = _handleAltitudeAndBaro(loc);

    // (4) 결과(ekf.x, ekf.y)를 사용해 폴리라인 추가, 고도 계산 등
    _polylinePoints.add(LatLng(rowLat, rowLon));

    //"혹시 새로 Hive에 저장됐으면, 거리/고도 누적 업데이트"
    _updateStatsFromHive();

    // 4) "이전 위치" 저장
    _lastLatLng = LatLng(loc.coords.latitude, loc.coords.longitude);
    _lastAltitude = loc.coords.altitude;
    _lastTimestampMs = _parseTimestamp(loc.timestamp);

    // 반환 (ekf lat/lon, fused altitude, accuracy)
    return (LatLng(rowLat, rowLon), fusedAlt, acc);
  }

  // 원본 gps 로직
  ( double, double, double )? _applyRawGPS(bg.Location loc) {
    if (!_baroOffsetInitialized) {
      setInitialBaroOffsetIfPossible(loc.coords.altitude);
      _baroOffsetInitialized = true;
    }

    // 1) lat/lon 그대로 사용
    final lat = loc.coords.latitude;
    final lon = loc.coords.longitude;
    final acc = loc.coords.accuracy;

    return (lat, lon, acc);
  }

  // =========================================================================
  // 6) Outlier(이상치) 검사 예시 (고도 기준)
  // =========================================================================

  /// Outlier 검사
  bool isOutlier(bg.Location loc) {
    // (A) 먼저 legacyOutlierCheck()
    if (legacyOutlierCheck(loc)) {
      return true;
    }
    // 두 함수 모두 false면 → Outlier 아님
    return false;
  }

  /// 단발성 이상치 검사
  bool legacyOutlierCheck(bg.Location loc) {
    if (_lastAltitude == null || _lastTimestampMs == null || _lastLatLng == null) {
      return false;
    }

    /*final nowMs = _parseTimestamp(loc.timestamp) ?? DateTime.now().millisecondsSinceEpoch;
    final dtMs = nowMs - _lastTimestampMs!;
    if (dtMs <= 0) {
      return false;
    }
    final dtSec = dtMs / 1000.0;

    // (A) 고도 차
    final altDiff = (loc.coords.altitude - _lastAltitude!).abs();

    final altChangePerSec = altDiff / dtSec;
    if (altChangePerSec > 10.0) {
      return true;
    }

    // (B) 속도
    final currentLatLng = LatLng(loc.coords.latitude, loc.coords.longitude);
    final distMeter = Distance().distance(_lastLatLng!, currentLatLng);
    final speedKmh = (distMeter / dtSec) * 3.6;

    // 예: 시속 50km/h 초과
    if (speedKmh > 130.0) {
      return true;
    }*/

    return false;
  }

  /// Location timestamp 파싱 (int or String)
  int? _parseTimestamp(dynamic timestamp) {
    if (timestamp is int) {
      return timestamp;
    } else if (timestamp is String) {
      try {
        return DateTime.parse(timestamp).millisecondsSinceEpoch;
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  // =========================================================================
  // 7) 장기 offset 보정 (3분마다)
  // =========================================================================

  /// GPS 고도 vs Barometer 고도가 크게 차이 나지 않을 때(diff < 10)
  /// → baroOffset를 0.2 * diff 만큼 누적 보정
  void _updateBaroOffsetIfNeeded(double? gpsAlt) {
    if (gpsAlt == null || _fusion.baroAltitude == null) return;

    final baroAltWithOffset = _fusion.baroAltWithOffset;
    final diff = gpsAlt - baroAltWithOffset;

    // 너무 큰 diff는 outlier일 가능성 높으니, 여기선 최대 10m 이하만 반영
    if (diff.abs() < 10.0) {
      _fusion.baroOffset += 0.2 * diff;
    }
  }


  // =========================================================================
  // 9) 초기 오프셋 보정(캘리브레이션)
  // =========================================================================
  /// 운동 시작 직후(첫 GPS 고도 획득 시점)에 한 번 호출해서,
  /// Barometer의 초기 Offset을 GPS와 맞춰준다.
  void setInitialBaroOffsetIfPossible(double? gpsAlt) {
    if (gpsAlt == null) return;
    if (_fusion.baroAltitude == null) {
      return; // 아직 Barometer 값 없음
    }
    final diff = gpsAlt - _fusion.baroAltitude!;
    _fusion.baroOffset = diff;

    // === 추가: offset을 확 바꿨으니, baseAltitude를 새 융합고도에 맞춰버림 ===
    final fusedAltNow = _fusion.getFusedAltitude();
    if (fusedAltNow != null) {
      _baseAltitude = fusedAltNow;
    }
  }


  // =========================================================================
  // 11) heading (방향) 값 Getter
  // =========================================================================
  /// 라디안 단위 (0 ~ 2π)
  double get headingRad => _currentHeadingRad;

  /// 도(deg) 단위 (0 ~ 360)
  double get headingDeg {

    return (_currentHeadingRad * 180.0 / math.pi) % 360.0;
  }
}
