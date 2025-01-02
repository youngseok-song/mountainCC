// movement_service.dart
//
// 이 파일에서는 운동 측정에 필요한 계산 및 상태를 집중 관리합니다.
// - 스톱워치(운동시간)
// - 폴리라인(위치 목록) 기반 거리 계산
// - 평균 속도
// - 누적 고도
//
// 실제 UI(map_screen.dart)에서는 MovementService 객체를 생성하여
// 거리/속도/고도/시간 등 값을 가져오거나 업데이트합니다.
//

import 'package:latlong2/latlong.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;

class MovementService {
  // (1) 위치 기록: 지도에 표시할 polylinePoints
  //    - 새 위치가 들어오면 이 리스트에 추가
  final List<LatLng> polylinePoints = [];

  // (2) 운동 시간 관리 (Stopwatch)
  //    - 운동 시작 시 start(), 일시중지 시 stop(), 재시작 시 다시 start()
  //    - UI에서 1초마다 elapsedTime을 setState로 갱신
  final Stopwatch _stopwatch = Stopwatch();

  // (3) 누적 고도 관리
  double _cumulativeElevation = 0.0;
  double? _baseAltitude; // 이전 고도 기준

  // (4) 1초마다 UI에서 읽을 문자열 (시:분:초)
  String get elapsedTimeString {
    final duration = _stopwatch.elapsed;
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return "$hours:$minutes:$seconds";
  }

  // (5) 총 거리 (km) 계산
  //    - polylinePoints를 순회하며 누적
  double calculateDistanceKm() {
    double totalDistance = 0.0;
    for (int i = 1; i < polylinePoints.length; i++) {
      totalDistance += Distance().distance(
        polylinePoints[i - 1],
        polylinePoints[i],
      );
    }
    return totalDistance / 1000.0; // m -> km
  }

  // (6) 평균 속도 (km/h)
  //    - 거리(km) / (경과시간(hr))
  double calculateAverageSpeedKmh() {
    if (_stopwatch.elapsed.inSeconds == 0) return 0.0;
    final distanceInKm = calculateDistanceKm();
    final timeInHours = _stopwatch.elapsed.inSeconds / 3600.0;
    return distanceInKm / timeInHours;
  }

  // (7) 누적 고도 계산
  //    - 새 위치(Altitude) 들어올 때마다 업데이트
  void updateCumulativeElevation(bg.Location location) {
    final double currentAltitude = location.coords.altitude;
    if (_baseAltitude == null) {
      _baseAltitude = currentAltitude;
      return;
    }

    final elevationDifference = currentAltitude - _baseAltitude!;
    if (elevationDifference > 3.0) {
      // 3m 이상 상승 시 누적
      _cumulativeElevation += elevationDifference;
      _baseAltitude = currentAltitude;
    } else if (elevationDifference < 3.0) {
      // 고도 하강 시 기준 고도 갱신
      _baseAltitude = currentAltitude;
    }
  }

  double get cumulativeElevation => _cumulativeElevation;

  // (8) 스톱워치 제어
  void startStopwatch() => _stopwatch.start();
  void stopStopwatch() => _stopwatch.stop();
  void resetStopwatch() => _stopwatch.reset();

  // (9) 누적값들 초기화
  //    - 운동 종료 시점에 모두 리셋
  void resetAll() {
    polylinePoints.clear();
    _cumulativeElevation = 0.0;
    _baseAltitude = null;
    stopStopwatch();
    resetStopwatch();
  }
}
