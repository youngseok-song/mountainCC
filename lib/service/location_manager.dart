// location_manager.dart (새 파일로 가정)

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'movement_service.dart';
import 'location_service.dart';

/// 중간 관리자: 한 번의 위치가 들어오면,
///  1) Outlier 검사(1회),
///  2) MovementService (폴리라인 etc.),
///  3) LocationService (Hive 저장)
class LocationManager {
  final MovementService movementService;
  final LocationService locationService;

  // 두 서비스를 생성자에서 받아온다.
  LocationManager({
    required this.movementService,
    required this.locationService,
  });

  /// BG plugin이 location을 콜백으로 받을 때 호출할 메서드
  void onNewLocation(bg.Location loc, {bool ignoreData = false}) {
    // (A) MovementService에 그대로 넘김 (Outlier/EKF 등은 MovementService가 담당)
    movementService.onNewLocation(loc, ignoreData: ignoreData);

    // (4) Hive 저장
    locationService.maybeSavePosition(loc);
  }
}


