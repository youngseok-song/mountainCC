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
    // (1) MovementService 호출 → (ekfLatLng, fusedAlt, acc) 반환
    final (ekfLatLng, fusedAlt, acc) = movementService.onNewLocation(loc, ignoreData: ignoreData);

    // (2) 만약 null이면 (Outlier, ignoreData) → 그냥 return
    if (ekfLatLng == null) {
      return;
    }

    // (3) Hive 저장 → EKF 값 사용
    locationService.maybeSavePosition(
      ekfLatLng,
      fusedAlt!,  // non-null 단언
      acc!,       // non-null 단언
    );
  }
}


