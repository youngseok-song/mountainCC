import 'package:flutter_barometer_plugin/flutter_barometer.dart';

class BarometerService {
  bool isBarometerAvailable = false; // 바로미터 지원 여부를 담을 변수
  double? currentPressure; // 현재 기압(hPa) 값

  BarometerService() {
    // 바로미터 데이터 스트림을 구독
    // - 바로미터에서 데이터가 들어오는지 확인
    // - 데이터가 들어오면 isBarometerAvailable = true 로 설정
    // - 기압값(currentPressure)을 업데이트
    FlutterBarometer.currentPressureEvent.listen((pressure) {
      // pressure.hectpascal 값이 null이 아니면 바로미터가 동작한다고 가정
      if (!isBarometerAvailable && pressure.hectpascal != null) {
        isBarometerAvailable = true;
      }
      currentPressure = pressure.hectpascal;
    }, onError: (error) {
      // 에러 발생 시 바로미터 사용 불가로 간주
      isBarometerAvailable = false;
    });
  }
}
