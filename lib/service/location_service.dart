// service/location_service.dart

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:latlong2/latlong.dart';
import 'package:hive/hive.dart';
import '../models/location_data.dart';

class LocationService {
  // --------------------------
  // (A) distanceFilter 동적 변수
  // --------------------------
  /// BG plugin 에서 위치 콜백 발생시키는 최소 이동거리
  /// (Activity에 따라 바뀔 예정)
  double _bgDistanceFilter = 3.0;

  /// Hive 저장 간격 (기본 6m)
  double _hiveDistanceFilter = 6.0;

  /// 현재 활동 상태(on_foot, running 등) 보관 (디버깅/로그용)
  String _currentActivity = 'on_foot';

  // --------------------------
  final Box<LocationData> locationBox;
  LatLng? lastSavedPosition;


  String get currentActivity => _currentActivity;

  bool _isTracking = false;   // 실제 추적 중?
  bool _isStarting = false;   // start() 절차 진행 중?

  LocationService(this.locationBox);

  /// ===================================================
  /// 0) [NEW] ActivityChange 핸들러 초기화
  /// ===================================================
  Future<void> _initActivityChangeListener() async {
    bg.BackgroundGeolocation.onActivityChange((bg.ActivityChangeEvent event) async {
      // event.activity => on_foot, running, on_bicycle, in_vehicle, still 등
      _currentActivity = event.activity; // 보관 (로그용)

      // (1) BG distanceFilter 변경
      double newBGFilter;
      double newHiveFilter;

      switch (_currentActivity) {
        case 'on_foot':
          newBGFilter   = 3.0;   // 걸을 때
          newHiveFilter = 3.0;
          break;
        case 'running':
          newBGFilter   = 3.0;   // 뛸 때 더 자주
          newHiveFilter = 3.0;
          break;
        case 'on_bicycle':
          newBGFilter   = 15.0;  // 자전거면 좀 더 큰 필터
          newHiveFilter = 15.0;
          break;
        case 'in_vehicle':
          newBGFilter   = 20.0;  // 차량일 땐 더 크게
          newHiveFilter = 20.0;
          break;
        default:
        // still, unknown 등
          newBGFilter   = 3.0;
          newHiveFilter = 6.0;
      }

      // BG plugin에 setConfig
      if (newBGFilter != _bgDistanceFilter) {
        _bgDistanceFilter = newBGFilter;
        await bg.BackgroundGeolocation.setConfig(
          bg.Config(distanceFilter: _bgDistanceFilter),
        );
      }

      // Hive 저장 간격도 변경
      _hiveDistanceFilter = newHiveFilter;
    });
  }

  /// -------------------------------
  /// [NEW] 플러그인 현재 상태를 앱 변수와 동기화
  Future<void> syncStateFromPlugin() async {
    final state = await bg.BackgroundGeolocation.state;
    _isTracking = state.enabled;
    _isStarting = false;
  }

  /// ------------------------------------------------------------
  /// 백그라운드 위치 추적 시작
  Future<void> startBackgroundGeolocation() async {
    // [NEW] 혹시 플러그인 자체가 이미 실행 중인지 확인
    await syncStateFromPlugin();

    // (1) 만약 이미 시작 중이거나 이미 tracking 중이면 return
    if (_isStarting || _isTracking) {
      return;
    }
    _isStarting = true;

    // (2) ActivityChange 리스너 초기화
    await _initActivityChangeListener();

    // (3) ready
    await bg.BackgroundGeolocation.ready(
      bg.Config(
        disableLocationAuthorizationAlert: true,
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH,
        distanceFilter: 3.0,  // 초기값(걸음 기준)
        stopTimeout: 60,
        logLevel: bg.Config.LOG_LEVEL_VERBOSE,
        debug: true,

        stopOnTerminate: true,
        startOnBoot: false,
        disableStopDetection: true,
        stopOnStationary: false,
      ),
    );

    // (4) 실제 start
    await bg.BackgroundGeolocation.start();
    await bg.BackgroundGeolocation.changePace(true); // 이동상태 강제전환

    _isTracking = true;
    _isStarting = false;
  }

  /// ------------------------------------------------------------
  /// 백그라운드 위치 추적 중지
  Future<void> stopBackgroundGeolocation() async {
    if (!_isTracking) return;
    await bg.BackgroundGeolocation.stop();
    _isTracking = false;
  }

  /// ------------------------------------------------------------
  /// Hive 저장 로직 (EKF lat/lon, altitude, accuracy)
  /// ------------------------------------------------------------
  void maybeSavePosition(LatLng pos, double alt, double acc) {
    if (lastSavedPosition == null) {
      _saveToHive(pos, alt, acc);
      lastSavedPosition = pos;
      return;
    }

    // (A) 이전 위치와 거리 계산
    final dist = Distance().distance(lastSavedPosition!, pos); // meter

    // (B) "활동 상태별"로 동적 결정된 _hiveDistanceFilter 사용
    if (dist >= _hiveDistanceFilter) {
      _saveToHive(pos, alt, acc);
      lastSavedPosition = pos;
    }
  }

  void _saveToHive(LatLng pos, double alt, double acc) {
    locationBox.add(
      LocationData(
        latitude: pos.latitude,
        longitude: pos.longitude,
        altitude: alt,
        timestamp: DateTime.now(),
        accuracy: acc,
      ),
    );
  }
}
