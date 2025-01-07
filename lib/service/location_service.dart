// service/location_service.dart
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:latlong2/latlong.dart';
import 'package:hive/hive.dart';
import '../models/location_data.dart';

class LocationService {
  final Box<LocationData> locationBox;
  LatLng? lastSavedPosition;

  bool _isTracking = false;   // 실제 추적 중?
  bool _isStarting = false;   // start() 절차 진행 중?

  LocationService(this.locationBox);

  /// -------------------------------
  /// [NEW] 플러그인 현재 상태를 앱 변수와 동기화
  Future<void> syncStateFromPlugin() async {
    // BG plugin의 state.enabled: (true면 이미 start()된 상태)
    final state = await bg.BackgroundGeolocation.state;
    _isTracking = state.enabled;
    // _isStarting은 어차피 우리가 "start 절차" 직접 제어하므로, 여기선 특별히 false로 둬도 됨.
    _isStarting = false;
  }

  /// ------------------------------------------------------------
  /// 백그라운드 위치 추적 시작
  Future<void> startBackgroundGeolocation(Function(bg.Location) onPositionUpdate) async {

    // [NEW] 혹시 플러그인 자체가 이미 실행 중인지 확인.
    await syncStateFromPlugin();

    // (1) 만약 이미 시작 중이거나 이미 tracking 중이면 return
    if (_isStarting || _isTracking) {
      return;
    }
    _isStarting = true;

    // 위치 업데이트 콜백 등록
    bg.BackgroundGeolocation.onLocation((bg.Location location) {
      onPositionUpdate(location);
      _maybeSavePosition(location);
    });

    // (기타 onMotionChange, onProviderChange 등 생략)

    // (2) ready
    await bg.BackgroundGeolocation.ready(
      bg.Config(
        // 기존 코드
        disableLocationAuthorizationAlert: true,
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        distanceFilter: 3.0,
        stopTimeout: 60,
        logLevel: bg.Config.LOG_LEVEL_VERBOSE,
        debug: true,

        // 2) 추가 옵션
        stopOnTerminate: true,      // 앱이 Terminate되면 추적중지 (원하시는 대로)
        startOnBoot: false,         // 기기 재부팅 시 자동시작 X (원하시는 대로)
        disableStopDetection: true, // 정지 감지 비활성화 -> 움직임이 없어도 계속 추적
        stopOnStationary: false,    // stationary 상태여도 멈추지 말 것
      ),
    );

    // (3) 실제 start
    await bg.BackgroundGeolocation.start();
    await bg.BackgroundGeolocation.changePace(true); //이동상태 강제전환
    // 완료
    _isTracking = true;
    _isStarting = false;
  }

  /// ------------------------------------------------------------
  /// 백그라운드 위치 추적 중지
  Future<void> stopBackgroundGeolocation() async {
    // 혹시 아직 시작도 안 했다면 skip
    if (!_isTracking) return;

    await bg.BackgroundGeolocation.stop();
    _isTracking = false;
  }

  /// ------------------------------------------------------------
  void _maybeSavePosition(bg.Location location) {
    final currentLatLng = LatLng(location.coords.latitude, location.coords.longitude);

    if (lastSavedPosition == null) {
      _saveToHive(currentLatLng, location.coords.altitude);
      lastSavedPosition = currentLatLng;
      return;
    }
    // 6m마다 hive에 저장
    final distanceMeter = Distance().distance(lastSavedPosition!, currentLatLng);
    if (distanceMeter >= 6.0) {
      _saveToHive(currentLatLng, location.coords.altitude);
      lastSavedPosition = currentLatLng;
    }
  }

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
