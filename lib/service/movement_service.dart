// ---------------------------------------------------
// service/movement_service.dart
// ---------------------------------------------------
// 이 서비스는 Barometer, Gyroscope, GPS 등을 사용하여
//  - 폴리라인(이동경로) 저장
//  - 스톱워치(운동시간) 관리
//  - 고도 계산(Barometer+GPS) 보정
//  - Outlier(이상치) 검사
// 등의 기능을 담당한다.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:latlong2/latlong.dart';
import 'package:sensors_plus/sensors_plus.dart'; // Barometer, Gyro
import '../models/sensor_fusion.dart'; // SensorFusion 객체 (Dead Reckoning, Baro/GPS 혼합)
// (A) EKF 임포트
import 'extended_kalman_filter.dart';
import 'location_service.dart'; // ← Hive 쓰려면 필요


// MovementService 클래스
class MovementService {
  // [1] EKF 인스턴스 추가
  // EKF를 '외부'에서 주입받아 사용
  final ExtendedKalmanFilter ekf;
  final LocationService _locationService;

  MovementService({
    required this.ekf,
    required LocationService locationService,
  }) : _locationService = locationService;

  // ---------------------------------------------------
  // (A) 폴리라인, 스톱워치, 누적고도 등 '운동' 관련 필드
  // ---------------------------------------------------

  /// 사용자가 이동한 좌표들을 담고 있는 리스트.
  /// 지도에 경로를 폴리라인으로 그릴 때 사용한다.
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
  // (B) Hive 기반 거리·고도 누적을 위한 필드 (신규 추가)
  // ---------------------------------------------------
  double _distanceFromHiveKm = 0.0; // 누적 거리 (Hive)
  double get distanceKm => _distanceFromHiveKm;

  double _cumulativeElevationHive = 0.0; // 누적 상승고도 (Hive)
  double get cumulativeElevation => _cumulativeElevationHive;

  double _cumulativeDescentHive = 0.0;   // 누적 하강고도 (Hive)
  double get cumulativeDescent => _cumulativeDescentHive;

  /// 누적 고도를 계산할 때 기준점이 될 고도
  double? _baseAltitude;

  // ---------------------------------------------------
  // (B) 바로미터(Barometer) 관련
  // ---------------------------------------------------

  /// 바로미터 이벤트 구독(subscribe) 관리
  StreamSubscription<BarometerEvent>? _barometerSub;

  /// 현재 기압(hPa)을 임시 저장
  double? _currentPressureHpa;

  // ---------------------------------------------------
  // (B') 자이로스코프(Gyroscope) 관련
  // ---------------------------------------------------

  /// 자이로 이벤트 구독(subscribe) 관리
  StreamSubscription<GyroscopeEvent>? _gyroscopeSub;

  /// 이전 자이로 시간(timestamp) (dt 계산용)
  int? _lastGyroTimestamp;

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

  // =========================================================================
  // 1) Barometer 제어 (start/stop)
  // =========================================================================

  /// 바로미터 구독 시작
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

  /// 바로미터 구독 해제
  void stopBarometer() {
    _barometerSub?.cancel();
    _barometerSub = null;
  }

  /// 기압(hPa) → 고도(m) 변환
  double _baroPressureToAltitude(double pressureHpa) {
    const seaLevel = 1013.25; // 해수면 표준 기압
    return 44330.0 * (1.0 - math.pow(pressureHpa / seaLevel, 1.0 / 5.255));
  }

  // =========================================================================
  // 2) 자이로스코프 제어 (start/stop)
  // =========================================================================

  /// 자이로스코프 구독 시작
  void startGyroscope() {
    if (_gyroscopeSub != null) return;

    _lastGyroTimestamp = DateTime.now().microsecondsSinceEpoch;

    _gyroscopeSub = gyroscopeEventStream().listen(
          (GyroscopeEvent event) {
        if (_lastGyroTimestamp == null) {
          _lastGyroTimestamp = DateTime.now().microsecondsSinceEpoch;
          return;
        }
        final nowUs = DateTime.now().microsecondsSinceEpoch;
        // dt(초 단위)
        final dt = (nowUs - _lastGyroTimestamp!) / 1_000_000.0;
        _lastGyroTimestamp = nowUs;

        // SensorFusion에 자이로(Z축 회전) 전달
        _fusion.onGyroscope(event.z, dt);
      },
      onError: (err) {
        // 필요시 에러 처리
      },
    );
  }

  /// 자이로스코프 구독 해제
  void stopGyroscope() {
    _gyroscopeSub?.cancel();
    _gyroscopeSub = null;
    _lastGyroTimestamp = null;
  }

  // Hive에 저장된 “이전 점”을 추적하기 위해...
  LatLng? _prevHiveLatLng;
  double? _prevHiveAltitude;

  /// 평균 속도(km/h)
  ///  - 거리(km) / 시간(시간단위)
  double get averageSpeedKmh {
    if (_exerciseStopwatch.elapsed.inSeconds == 0) return 0.0;
    final km = distanceKm; // <-- 여기서 distanceKm는 _distanceFromHiveKm
    final hours = _exerciseStopwatch.elapsed.inSeconds / 3600.0;
    return km / hours;
  }

  // =========================================================================
  // 4) 스톱워치 제어
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

  // =========================================================================
  // 5) onNewLocation → Outlier → EKF → 폴리라인/고도
  // =========================================================================

  /// BG plugin의 onLocation()에서 호출
  ///  - ignoreData: 특정 상황(카운트다운) 등에서 데이터를 무시할 때
  (LatLng?, double?, double?) onNewLocation(bg.Location loc, {bool ignoreData = false}) {
    if (ignoreData) return (null, null, null);

    // (A) Outlier 검사
    // (A) Outlier 검사
    if (isOutlier(loc)) {
      return (null, null, null); // 이상치면 저장 안 함
    }

    // (B) EKF Predict (dt 계산)
    double dt = _computeDeltaTime(loc);
    ekf.predict(dt);

    // scale 변환 후 ekf.updateGPS(gpsX, gpsY);
    final double scale = 111000.0;
    double gpsX = loc.coords.longitude * scale;
    double gpsY = loc.coords.latitude * scale;
    ekf.updateGPS(gpsX, gpsY);

    // (4) 결과(ekf.x, ekf.y)를 사용해 폴리라인 추가, 고도 계산 등
    double ekfLat = ekf.y / scale;
    double ekfLon = ekf.x / scale;
    _polylinePoints.add(LatLng(ekfLat, ekfLon));

    // (E) 고도 계산 (기존 SensorFusion + Baro)
    final gpsAlt = loc.coords.altitude;
    final fusedAlt = _fusion.getFusedAltitude() ?? gpsAlt;
    _updateCumulativeElevation(fusedAlt);

    // Baro offset 주기적 보정
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastOffsetUpdateTime > _offsetUpdateInterval) {
      _updateBaroOffsetIfNeeded(gpsAlt);
      _lastOffsetUpdateTime = nowMs;
    }

    // (F) Outlier 판단용 기록(고도 기준)
    _lastAltitude = gpsAlt;
    _lastTimestampMs = _parseTimestamp(loc.timestamp)
        ?? DateTime.now().millisecondsSinceEpoch;

    // (D) Hive에 6m마다 저장
    final acc = loc.coords.accuracy ?? 999.0;
    _locationService.maybeSavePosition(LatLng(ekfLat, ekfLon), fusedAlt, acc);

    // (E) [추가] "혹시 새로 Hive에 저장됐으면, 거리/고도 누적 업데이트"
    _updateStatsFromHive();

    // 반환 (ekf lat/lon, fused altitude, accuracy)
    return (LatLng(ekfLat, ekfLon), fusedAlt, acc);
  }


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

    // == (A) 누적 거리 ==
    if (_prevHiveLatLng != null) {
      final distMeter = Distance().distance(_prevHiveLatLng!, newHiveLatLng);
      _distanceFromHiveKm += (distMeter / 1000.0);
    }

    // == (B) 누적 고도 ==
    // 기존 _updateCumulativeElevation와 유사하나,
    //   "Hive로 저장된 점들" 사이의 diff만 반영
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

    // 4) 마지막 좌표/고도 갱신
    _prevHiveLatLng   = newHiveLatLng;
    _prevHiveAltitude = newAlt;
  }

  // -------------------------------------------------------------------
  // dt(초) 계산 → EKF predict에 사용
  // -------------------------------------------------------------------
  int? _lastEkfTimestampMs;
  double _computeDeltaTime(bg.Location loc) {
    int nowMs = _parseTimestamp(loc.timestamp)
        ?? DateTime.now().millisecondsSinceEpoch;
    if (_lastEkfTimestampMs == null) {
      _lastEkfTimestampMs = nowMs;
      return 1.0; // 첫 dt=1초 가정
    }
    double dtSec = (nowMs - _lastEkfTimestampMs!) / 1000.0;
    _lastEkfTimestampMs = nowMs;
    // 방어코드
    if (dtSec < 0) dtSec = 0.01;
    return dtSec;
  }

  // =========================================================================
  // 6) Outlier(이상치) 검사 예시 (고도 기준)
  // =========================================================================

  /// 간단한 Outlier 검사 (고도 갑작스런 튐)
  bool isOutlier (bg.Location loc) {
    // 이전 값이 없으면 검사 불가
    if (_lastAltitude == null || _lastTimestampMs == null) {
      return false;
    }

    final nowMs = _parseTimestamp(loc.timestamp)
        ?? DateTime.now().millisecondsSinceEpoch;
    final dtMs = nowMs - _lastTimestampMs!;
    if (dtMs <= 0) {
      // 시간이 역행하거나 같은 Timestamp
      return false;
    }

    final dtSec = dtMs / 1000.0;
    final altDiff = (loc.coords.altitude - _lastAltitude!).abs();

    // 1초 이하에 altDiff >= 10m면 Outlier로 본다 (예시)
    return (dtSec <= 1.0 && altDiff >= 10.0);
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
  // 8) 누적 고도 계산
  // =========================================================================
  /// 현재 고도(currentAlt) - baseAltitude > 3.0m 이면 누적고도에 추가
  void _updateCumulativeElevation(double currentAlt) {
    if (_baseAltitude == null) {
      _baseAltitude = currentAlt;
      return;
    }
    final diff = currentAlt - _baseAltitude!;
    if (diff > 5.0) {
      _cumulativeElevationHive += diff;
      _baseAltitude = currentAlt;
    } else if (diff < -5.0) {
      _baseAltitude = currentAlt;
      _cumulativeDescentHive += (-diff);    // 또는 diff.abs()
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
  // 10) 운동 종료 시: resetAll()
  // =========================================================================
  /// 운동 관련 상태 초기화
  void resetAll() {
    // Barometer, Gyro 구독 해제
    stopBarometer();
    stopGyroscope();

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
  // 11) heading (방향) 값 Getter
  // =========================================================================
  /// 라디안 단위 (0 ~ 2π)
  double get headingRad => _fusion.heading;

  /// 도(deg) 단위 (0 ~ 360)
  double get headingDeg => (_fusion.heading * 180.0 / math.pi) % 360.0;
}
