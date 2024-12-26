import 'package:flutter_barometer_plugin/flutter_barometer.dart';

class BarometerService {
  bool isBarometerAvailable = false;
  double? currentPressure;

  BarometerService() {
    FlutterBarometer.currentPressureEvent.listen((pressure) {
      if (!isBarometerAvailable && pressure.hectpascal != null) {
        isBarometerAvailable = true;
      }
      currentPressure = pressure.hectpascal;
    }, onError: (error) {
      isBarometerAvailable = false;
    });
  }
}
