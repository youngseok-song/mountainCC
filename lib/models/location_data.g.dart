// models/location_data.g.dart

// GENERATED CODE - DO NOT MODIFY BY HAND

// 이 파일은 `hive_generator` 패키지에 의해 자동 생성되었습니다.
// 수동으로 수정할 경우, 재생성 시 변경 사항이 덮어쓰여질 수 있습니다.

part of 'location_data.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

// 이 클래스는 `LocationData` 모델과 Hive 간의 브릿지 역할을 합니다.
// Hive가 `LocationData` 객체를 직렬화(저장) 및 역직렬화(불러오기)할 수 있도록 합니다.
class LocationDataAdapter extends TypeAdapter<LocationData> {
  @override
  final int typeId = 0; // 이 어댑터의 고유 식별자. 애플리케이션 내에서 고유해야 합니다.

  // `LocationData` 객체를 읽어서 복원하는 메서드입니다.
  @override
  LocationData read(BinaryReader reader) {
    // 필드 개수를 읽습니다.
    final numOfFields = reader.readByte();

    // 각 필드를 읽어서 맵에 저장합니다.
    // 예: 필드 번호를 키로, 해당 값을 값으로 저장.
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };

    // 읽은 데이터를 기반으로 `LocationData` 객체를 생성하여 반환합니다.
    return LocationData(
      latitude: fields[0] as double, // 위도
      longitude: fields[1] as double, // 경도
      altitude: fields[2] as double, // 고도
      timestamp: fields[3] as DateTime, // 타임스탬프
    );
  }

  // `LocationData` 객체를 쓰기 위해 직렬화하는 메서드입니다.
  @override
  void write(BinaryWriter writer, LocationData obj) {
    writer
      ..writeByte(4) // 필드 개수 작성
      ..writeByte(0) // 필드 번호 0
      ..write(obj.latitude) // 위도 값 작성
      ..writeByte(1) // 필드 번호 1
      ..write(obj.longitude) // 경도 값 작성
      ..writeByte(2) // 필드 번호 2
      ..write(obj.altitude) // 고도 값 작성
      ..writeByte(3) // 필드 번호 3
      ..write(obj.timestamp); // 타임스탬프 값 작성
  }

  // 해시코드를 생성하여 어댑터를 고유하게 식별합니다.
  @override
  int get hashCode => typeId.hashCode;

  // 동일성을 비교하기 위한 메서드입니다.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || // 객체가 동일한지 확인
          other is LocationDataAdapter && // `LocationDataAdapter`인지 확인
              runtimeType == other.runtimeType && // 런타임 타입이 같은지 확인
              typeId == other.typeId; // `typeId`가 같은지 확인
}
