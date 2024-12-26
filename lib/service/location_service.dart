// service/location_service.dart
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:latlong2/latlong.dart'; // 거리 계산이나 LatLng 사용
import 'package:hive/hive.dart';
import '../models/location_data.dart';

class LocationService {
  final Box<LocationData> locationBox;
  LatLng? lastSavedPosition;

  // 리스너 해제 등을 위해 상태를 기억
  bool _isTracking = false;

  LocationService(this.locationBox);

  /// 백그라운드 위치 추적을 설정하고 시작하는 메서드
  /// [onPositionUpdate]는 위치가 업데이트될 때마다 UI에서 사용할 콜백
  Future<void> startBackgroundGeolocation(
      Function(bg.Location) onPositionUpdate) async {
    if (_isTracking) return; // 이미 시작했다면 중복 방지

    // 1) 설정
    bg.BackgroundGeolocation.onLocation((bg.Location location) {
      // location 객체에는 위도, 경도, 고도, 배터리 상태, 정확도 등 다양한 정보가 들어있음
      onPositionUpdate(location);
      _maybeSavePosition(location);
    });

    // motionChange: 정지/이동 상태 변경 감지
    bg.BackgroundGeolocation.onMotionChange((bg.Location location) {
      // 필요시 활용 (앱이 정지 상태→이동 상태로 바뀔 때 등)
    });

    bg.BackgroundGeolocation.onProviderChange((bg.ProviderChangeEvent event) {
      // GPS 켜짐/꺼짐, 권한 거부 등
    });

    // 2) ready
    await bg.BackgroundGeolocation.ready(
      bg.Config(
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        distanceFilter: 10.0,   // 10m 간격으로 onLocation 콜백
        stopOnTerminate: false, // 앱 종료시 추적 중단 여부
        startOnBoot: true,      // 부팅 후 자동 시작
        debug: false,           // 디버그 모드 (콘솔에 로그)
        logLevel: bg.Config.LOG_LEVEL_OFF, // 로그 레벨
        // 기타 필요한 설정들...
      ),
    );

    // 3) 위치 업데이트 시작
    await bg.BackgroundGeolocation.start();
    _isTracking = true;
  }

  /// 위치 추적 중지
  Future<void> stopBackgroundGeolocation() async {
    if (!_isTracking) return;
    await bg.BackgroundGeolocation.stop();
    _isTracking = false;
  }

  /// 10미터 이상 이동 시 위치 정보를 Hive에 저장
  void _maybeSavePosition(bg.Location location) {
    if (location.coords == null) return;

    final LatLng currentLatLng =
    LatLng(location.coords!.latitude, location.coords!.longitude);

    if (lastSavedPosition == null) {
      _saveToHive(currentLatLng, location.coords!.altitude ?? 0.0);
      lastSavedPosition = currentLatLng;
      return;
    }

    // distance 계산
    final distanceMeter = Distance().distance(
      lastSavedPosition!,
      currentLatLng,
    );

    // 10m 이상 이동했으면 저장
    if (distanceMeter >= 10.0) {
      _saveToHive(currentLatLng, location.coords!.altitude ?? 0.0);
      lastSavedPosition = currentLatLng;
    }
  }

  /// Hive에 위치 정보 저장
  void _saveToHive(LatLng position, double altitude) {
    locationBox.add(
      LocationData(
        latitude: position.latitude,
        longitude: position.longitude,
        altitude: altitude,
        timestamp: DateTime.now(),
      ),
    );
  }
}
