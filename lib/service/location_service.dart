// service/location_service.dart

import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;
import 'package:latlong2/latlong.dart';
import 'package:hive/hive.dart';
import '../models/location_data.dart';

// 위치 추적을 관리하는 서비스 클래스
class LocationService {
  final Box<LocationData> locationBox; // Hive Box를 통해 위치 데이터를 저장
  LatLng? lastSavedPosition; // 마지막으로 저장된 위치 (LatLng)

  bool _isTracking = false; // 현재 위치 추적 상태

  // 생성자: Hive Box를 인자로 받아 초기화
  LocationService(this.locationBox);

  // ------------------------------------------------------------
  // 백그라운드 위치 추적 시작
  Future<void> startBackgroundGeolocation(
      Function(bg.Location) onPositionUpdate) async {
    // 이미 위치 추적 중이라면 무시
    if (_isTracking) return;

    // 위치 정보가 업데이트될 때 호출되는 콜백 등록
    bg.BackgroundGeolocation.onLocation((bg.Location location) {
      onPositionUpdate(location); // 외부에서 정의한 위치 업데이트 함수 호출
      _maybeSavePosition(location); // 필요 시 위치를 저장
    });

    // 모션 상태가 변경될 때 호출되는 콜백 등록 (움직임 감지)
    bg.BackgroundGeolocation.onMotionChange((bg.Location location) {
      // 추가 동작이 필요한 경우 여기에 작성
    });

    // 위치 제공자(Provider)가 변경될 때 호출되는 콜백 등록
    bg.BackgroundGeolocation.onProviderChange((bg.ProviderChangeEvent event) {
      // 추가 동작이 필요한 경우 여기에 작성
    });

    // 백그라운드 지오로케이션 초기화
    await bg.BackgroundGeolocation.ready(
      bg.Config(
        disableLocationAuthorizationAlert: true, // 위치 권한 팝업 비활성화
        desiredAccuracy: bg.Config.DESIRED_ACCURACY_HIGH, // 위치 정확도 설정
        distanceFilter: 1.5, // 위치 변경 감지 기준 거리 (미터 단위)
        stopOnTerminate: false, // 앱 종료 시 추적 지속 여부
        startOnBoot: true, // 부팅 시 추적 시작 여부
        debug: false, // 디버그 모드 비활성화
        logLevel: bg.Config.LOG_LEVEL_OFF, // 로그 레벨 설정
      ),
    );

    // 위치 추적 시작
    await bg.BackgroundGeolocation.start();
    _isTracking = true; // 위치 추적 상태를 true로 변경
  }

  // ------------------------------------------------------------
  // 백그라운드 위치 추적 중지
  Future<void> stopBackgroundGeolocation() async {
    // 위치 추적 중이 아니라면 무시
    if (!_isTracking) return;

    // 위치 추적 중지
    await bg.BackgroundGeolocation.stop();
    _isTracking = false; // 위치 추적 상태를 false로 변경
  }

  // ------------------------------------------------------------
  // 조건에 따라 위치를 저장
  void _maybeSavePosition(bg.Location location) {
    final currentLatLng = LatLng(location.coords.latitude, location.coords.longitude); // 현재 위치

    // 처음 위치가 저장되지 않았을 경우 바로 저장
    if (lastSavedPosition == null) {
      _saveToHive(currentLatLng, location.coords.altitude); // Hive에 저장
      lastSavedPosition = currentLatLng; // 마지막 위치 갱신
      return;
    }

    // 마지막 저장된 위치와 현재 위치 사이의 거리 계산
    final distanceMeter = Distance().distance(
      lastSavedPosition!,
      currentLatLng,
    );

    // 거리 차이가 5m 이상인 경우 위치 저장
    if (distanceMeter >= 5.0) {
      _saveToHive(currentLatLng, location.coords.altitude); // Hive에 저장
      lastSavedPosition = currentLatLng; // 마지막 위치 갱신
    }
  }

  // ------------------------------------------------------------
  // Hive에 위치 데이터 저장
  void _saveToHive(LatLng position, double altitude) {
    // Hive Box에 위치 데이터를 추가
    locationBox.add(
      LocationData(
        latitude: position.latitude, // 위도
        longitude: position.longitude, // 경도
        altitude: altitude, // 고도
        timestamp: DateTime.now(), // 저장 시간
      ),
    );
  }
}
