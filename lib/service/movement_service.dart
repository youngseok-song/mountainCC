import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:latlong2/latlong.dart';
import 'package:sensors_plus/sensors_plus.dart'; // <-- barometer, gyroscope 사용

import '../models/sensor_fusion.dart'; // [추가] sensor_fusion import

class MovementService {
  // -------------------------
  // (A) 폴리라인, 스톱워치, 누적고도 등 기존 필드

  /// 사용자가 이동한 경로(좌표)를 저장할 리스트
  /// → 지도상에 경로 폴리라인을 표시하거나 거리 계산 등에 사용
  final List<LatLng> _polylinePoints = [];
  List<LatLng> get polylinePoints => _polylinePoints;

  /// 운동 시간(스톱워치) 측정용
  final Stopwatch _stopwatch = Stopwatch();

  /// 스톱워치 경과시간을 "HH:MM:SS" 형태로 리턴
  String get elapsedTimeString {
    final d = _stopwatch.elapsed;
    final hh = d.inHours.toString().padLeft(2, '0');
    final mm = (d.inMinutes % 60).toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return "$hh:$mm:$ss";
  }

  /// 누적 고도 합산 (상승 고도)
  double _cumulativeElevation = 0.0;
  double get cumulativeElevation => _cumulativeElevation;

  /// 누적 고도를 계산하기 위한 기준 고도
  double? _baseAltitude;

  // -------------------------
  // (B) Barometer
  // sensors_plus 6.1.1 에서 barometerEventStream(...) 사용

  /// 바로미터 스트림 구독을 위한 subscription
  StreamSubscription<BarometerEvent>? _barometerSub;

  /// 실시간 기압(hPa)
  double? _currentPressureHpa;

  // -------------------------
  // [NEW] (B') Gyroscope (자이로스코프) 추가
  /// 자이로(gyroscope) 스트림 구독을 위한 subscription
  StreamSubscription<GyroscopeEvent>? _gyroscopeSub;
  /// 자이로 timestamp 기록 (dt 계산용)
  int? _lastGyroTimestamp;

  // -------------------------
  // [추가] SensorFusion 객체 (Dead Reckoning + Baro/GPS 혼합)
  /// Dead Reckoning(가속도/자이로) + Baro + GPS 데이터를 종합해 최종 위치/고도를 추정
  final SensorFusion _fusion = SensorFusion();

  // [추가] 장기 offset 보정 주기 (ms)
  /// 예시로 3분(180000ms)마다 Baro vs GPS 오차를 조금씩 조정
  int _lastOffsetUpdateTime = 0;
  final int _offsetUpdateInterval = 3 * 60 * 1000; // 3분(예시)

  // [추가] Outlier 판단을 위해 "이전 고도" 및 "이전 위치 시각"
  /// - 이전 위치 콜백에서 저장해 둔 고도, 시각(ms)
  /// - 다음 콜백과 비교해 "1초 안에 10m 이상 튀면 Outlier" 등 판단
  double? _lastAltitude;
  int? _lastTimestampMs;

  // -------------------------
  // 바로미터 시작
  void startBarometer() {
    // 이미 구독중이라면 중복 방지
    if (_barometerSub != null) return;

    _barometerSub = barometerEventStream().listen(
          (BarometerEvent event) {
        // 새 기압값을 저장
        _currentPressureHpa = event.pressure;
        // 기압 → 고도 변환
        final baroAlt = _baroPressureToAltitude(_currentPressureHpa!);
        // SensorFusion에 전달 (Dead Reckoning 보정)
        _fusion.onBarometer(baroAlt);
      },
      onError: (err) {
        // Barometer 지원 안 할 경우 에러 발생 가능
        // print("Barometer error: $err");
      },
    );
  }

  /// 바로미터 구독 해제
  void stopBarometer() {
    _barometerSub?.cancel();
    _barometerSub = null;
  }

  /// 기압(hPa)을 고도(m)로 변환하는 공식 (표준대기 기반)
  double _baroPressureToAltitude(double pressureHpa) {
    const seaLevel = 1013.25; // 해수면 표준 기압
    return 44330.0 * (1.0 - math.pow(pressureHpa / seaLevel, 1.0 / 5.255));
  }

  // -------------------------
  // [NEW] 자이로스코프 시작
  void startGyroscope() {
    // 이미 구독 중이면 중복 방지
    if (_gyroscopeSub != null) return;

    _lastGyroTimestamp = DateTime.now().microsecondsSinceEpoch;

    _gyroscopeSub = gyroscopeEvents.listen((GyroscopeEvent event) {
      if (_lastGyroTimestamp == null) {
        _lastGyroTimestamp = DateTime.now().microsecondsSinceEpoch;
        return;
      }
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      final dt = (nowUs - _lastGyroTimestamp!) / 1_000_000.0; // 초 단위
      _lastGyroTimestamp = nowUs;

      // z축 회전을 사용 (상황에 따라 x,y,z 축 보정 필요)
      _fusion.onGyroscope(event.z, dt);
    }, onError: (err) {
      // 에러 처리 필요 시
    });
  }

  /// 자이로스코프 구독 해제
  void stopGyroscope() {
    _gyroscopeSub?.cancel();
    _gyroscopeSub = null;
    _lastGyroTimestamp = null;
  }

  // -------------------------
  // (C) 거리/속도 계산

  /// 누적 이동 거리(km)
  /// - _polylinePoints 순회하며 두 점 사이의 거리를 합산
  double get distanceKm {
    double total = 0.0;
    for (int i = 1; i < _polylinePoints.length; i++) {
      total += Distance().distance(
        _polylinePoints[i - 1],
        _polylinePoints[i],
      );
    }
    return total / 1000.0;
  }

  /// 평균 속도(km/h)
  /// - 총거리 / (시간[시]) = (km) / (시간[hr])
  double get averageSpeedKmh {
    if (_stopwatch.elapsed.inSeconds == 0) return 0.0;
    final km = distanceKm;
    final hours = _stopwatch.elapsed.inSeconds / 3600.0;
    return km / hours;
  }

  // -------------------------
  // (D) 스톱워치 관련 메서드
  void startStopwatch() => _stopwatch.start();
  void pauseStopwatch() => _stopwatch.stop();
  void resetStopwatch() => _stopwatch.reset();

  // -------------------------
  // (E) 새 위치 -> 폴리라인 + 고도 계산
  /// 위치 콜백(onLocation)에서 호출
  /// - Outlier 검사, 폴리라인 추가, Baro/GPS 혼합, 누적고도, offset 보정 등
  void onNewLocation(bg.Location loc, {bool ignoreData = false}) {
    if (ignoreData) return; // 카운트다운 중이라면 스킵 등

    // [추가] Outlier 제거 로직
    if (_isOutlier(loc)) {
      // print("Skip location as Outlier");
      return;
    }

    // 1) 폴리라인에 새 점 추가
    _polylinePoints.add(LatLng(loc.coords.latitude, loc.coords.longitude));

    // 2) GPS 고도
    final gpsAlt = loc.coords.altitude;

    // 3) SensorFusion에 GPS 보정
    final double scale = 1e5;
    final double gpsX = loc.coords.longitude * scale;
    final double gpsY = loc.coords.latitude * scale;
    _fusion.onGps(gpsX, gpsY, gpsAlt);

    // 4) Baro+GPS 혼합 alt
    final fusedAlt = _fusion.getFusedAltitude() ?? gpsAlt;

    // 5) 누적 고도(_cumulativeElevation) 반영
    _updateCumulativeElevation(fusedAlt);

    // 6) 장기 offset 보정 (3분마다)
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastOffsetUpdateTime > _offsetUpdateInterval) {
      _updateBaroOffsetIfNeeded(gpsAlt);
      _lastOffsetUpdateTime = nowMs;
    }

    // 7) 마지막 위치정보 갱신 (Outlier 판단용)
    _lastAltitude = gpsAlt;
    _lastTimestampMs = _parseTimestamp(loc.timestamp)
        ?? DateTime.now().millisecondsSinceEpoch;
  }

  // [추가] Outlier 검사 함수
  bool _isOutlier(bg.Location loc) {
    if (_lastAltitude == null || _lastTimestampMs == null) {
      return false;
    }

    final nowMs = _parseTimestamp(loc.timestamp)
        ?? DateTime.now().millisecondsSinceEpoch;
    final dtMs = nowMs - _lastTimestampMs!;
    if (dtMs <= 0) {
      return false;
    }

    final dtSec = dtMs / 1000.0;
    final altDiff = (loc.coords.altitude - _lastAltitude!).abs();

    // 조건: 1초 이하 & altDiff >= 10m
    return (dtSec <= 1.0 && altDiff >= 10.0);
  }

  // [추가] Timestamp 변환 함수
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

  // [추가] 장기 offset 보정
  void _updateBaroOffsetIfNeeded(double? gpsAlt) {
    if (gpsAlt == null || _fusion.baroAltitude == null) return;

    final baroAltWithOffset = _fusion.baroAltWithOffset;
    final diff = gpsAlt - baroAltWithOffset;

    if (diff.abs() < 10.0) {
      _fusion.baroOffset += 0.2 * diff;
    }
  }

  /// 누적 고도 업데이트
  void _updateCumulativeElevation(double currentAlt) {
    if (_baseAltitude == null) {
      _baseAltitude = currentAlt;
      return;
    }
    final diff = currentAlt - _baseAltitude!;
    if (diff > 3.0) {
      _cumulativeElevation += diff;
      _baseAltitude = currentAlt;
    } else if (diff < 3.0) {
      _baseAltitude = currentAlt;
    }
  }

  // -------------------------
  // (F) 운동 종료
  void resetAll() {
    stopBarometer();
    stopGyroscope(); // [NEW] 자이로도 정지

    _polylinePoints.clear();
    _cumulativeElevation = 0.0;
    _baseAltitude = null;
    pauseStopwatch();
    resetStopwatch();
    _currentPressureHpa = null;

    // sensor_fusion init
    _fusion.init();

    _lastOffsetUpdateTime = 0;
    _lastAltitude = null;
    _lastTimestampMs = null;
  }

  // -------------------------
  // [NEW] heading getter
  /// SensorFusion.heading 라디안
  double get headingRad => _fusion.heading;
  /// 편의용: degree (0~360)
  double get headingDeg => (_fusion.heading * 180.0 / math.pi) % 360.0;
}
