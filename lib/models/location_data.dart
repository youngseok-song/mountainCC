// models/location_data.dart

import 'package:hive/hive.dart';

// 아래 part 선언은 build_runner를 통해 자동 생성될 Adapter 파일을 지정하는 것입니다.
// 터미널에서 flutter packages pub run build_runner build 명령을 실행하면
// location_data.g.dart 파일이 생성되며, 그 안에 Adapter 코드가 들어가게 됩니다.
part 'location_data.g.dart';

@HiveType(typeId: 0) // Hive에 저장할 때 이 클래스에 할당할 고유 typeId. 0부터 시작
class LocationData extends HiveObject {
  @HiveField(0)
  double latitude; // 위도

  @HiveField(1)
  double longitude; // 경도

  @HiveField(2)
  double altitude; // 고도

  @HiveField(3)
  DateTime timestamp; // 기록 시간 정보

  LocationData({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.timestamp,
  });
}