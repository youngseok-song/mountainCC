import 'package:geolocator/geolocator.dart';
import 'package:hive/hive.dart';
import 'package:latlong2/latlong.dart';
import '../models/location_data.dart';

class LocationService {
  final Box<LocationData> locationBox; // Hive Box: LocationData를 저장하는 박스
  LatLng? lastSavedPosition; // 마지막으로 저장한 위치

  LocationService(this.locationBox);

  // 현재 위치를 가져오는 메서드
  Future<Position> getCurrentPosition() async {
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
  }

  // 위치 스트림을 추적하는 메서드
  // onPositionUpdate 콜백을 받아 위치가 변할 때마다 UI 업데이트 용도로 호출해줍니다.
  void trackLocation(void Function(Position) onPositionUpdate) {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 1, // 1m 이동 시마다 위치 업데이트
      ),
    ).listen((position) {
      // UI 업데이트를 위한 콜백 호출
      onPositionUpdate(position);
      // 일정 거리(여기서는 10m) 이상 이동 시 Hive에 저장
      _maybeSavePosition(position);
    });
  }

  // 10미터 이상 이동 시 위치 정보를 Hive에 저장하는 메서드
  void _maybeSavePosition(Position position) {
    if (lastSavedPosition == null ||
        Geolocator.distanceBetween(
          lastSavedPosition!.latitude,
          lastSavedPosition!.longitude,
          position.latitude,
          position.longitude,
        ) >= 10) {
      // 10m 이상 이동했으므로 저장
      saveLocation(position);
      lastSavedPosition = LatLng(position.latitude, position.longitude);
    }
  }

  // 위치를 Hive에 저장하는 메서드
  void saveLocation(Position position) {
    locationBox.add(LocationData(
      latitude: position.latitude,
      longitude: position.longitude,
      altitude: position.altitude,
      timestamp: DateTime.now(),
    ));
  }
}