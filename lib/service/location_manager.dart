// location_manager.dart (새 파일로 가정)

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'movement_service.dart';
import 'location_service.dart';
import 'extended_kalman_filter.dart';

/// 중간 관리자: 한 번의 위치가 들어오면,
///  1) Outlier 검사(1회),
///  2) MovementService (폴리라인 etc.),
///  3) LocationService (Hive 저장)
class LocationManager {
  final MovementService movementService;
  final LocationService locationService;
  final ExtendedKalmanFilter ekf;

  // 두 서비스를 생성자에서 받아온다.
  LocationManager({
    required this.movementService,
    required this.locationService,
    required this.ekf,
  });

  /// BG plugin이 location을 콜백으로 받을 때 호출할 메서드
  void onNewLocation(bg.Location loc, {bool ignoreData=false}) {
    // (1) Outlier 검사
    if (movementService.isOutlier(loc)) {
      return;
    }

    // (2) EKF 예측 + 업데이트
    //  2-1) 예측: dt(초) 계산 필요
    double dt = _computeDeltaTime(loc.timestamp);
    ekf.predict(dt);

    //  2-2) 관측 (gpsX, gpsY)
    // 여기서는 단순히 lat, lon -> x,y 로 변환 (간단 예)
    double lat = loc.coords.latitude;
    double lon = loc.coords.longitude;
    // 변환 방법 예: 1도 ~111km... etc. => 간단히 scale
    const scale = 111000.0; // rough meter per deg
    double gpsX = lon*scale;
    double gpsY = lat*scale;

    ekf.updateGPS(gpsX, gpsY);

    // (3) MovementService 로직 (폴리라인, 고도 계산 등)
    movementService.onNewLocation(loc);

    // (4) Hive 저장
    locationService.maybeSavePosition(loc);
  }

  // 만약 EKF에서도 시간 계산 필요 → loc.timestamp vs lastTimestamp
  int? _lastTimestampMs;
  double _computeDeltaTime(dynamic timestamp) {
    // parse timestamp
    int nowMs = _parseTimestamp(timestamp) ?? DateTime.now().millisecondsSinceEpoch;
    if(_lastTimestampMs==null){
      _lastTimestampMs = nowMs;
      return 1.0; // 첫 dt=1초 가정
    }
    double dtSec = (nowMs - _lastTimestampMs!) /1000.0;
    if(dtSec<0) dtSec=0.01; // 역행 방어
    _lastTimestampMs = nowMs;
    return dtSec;
  }

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
}
