//sensor_fusion.dart

import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

class SensorFusion {
  // --------------------------------------------
  // 상태값: 위치, 속도, heading, 고도 등
  double posX = 0.0;
  double posY = 0.0;
  double velX = 0.0;
  double velY = 0.0;
  double heading = 0.0;

  double? baroAltitude;
  double? gpsAltitude;

  // [추가] Barometer - GPS 간 오프셋 (장기 보정용)
  double baroOffset = 0.0;
  // barometer 고도에 이 offset을 더해 최종 baroAltWithOffset으로 사용할 수 있음

  void init() {
    posX = 0.0;
    posY = 0.0;
    velX = 0.0;
    velY = 0.0;
    heading = 0.0;
    baroAltitude = null;
    gpsAltitude = null;

    // [추가]
    baroOffset = 0.0; // 오프셋 초기화
  }

  // --------------------------------------------
  // (A) 가속도 이벤트 (Dead Reckoning)
  void onAccelerometer(double ax, double ay, double dt) {
    final cosH = math.cos(heading);
    final sinH = math.sin(heading);

    double axLocal = ax * cosH - ay * sinH;
    double ayLocal = ax * sinH + ay * cosH;

    velX += axLocal * dt;
    velY += ayLocal * dt;

    posX += velX * dt;
    posY += velY * dt;
  }

  // --------------------------------------------
  // (B) 자이로 이벤트
  void onGyroscope(double gz, double dt) {
    heading += gz * dt;
  }

  // --------------------------------------------
  // (C) Barometer -> 고도
  void onBarometer(double baroAlt) {
    baroAltitude = baroAlt;
  }

  // --------------------------------------------
  // (D) GPS 보정 (Complementary Filter)
  void onGps(double gpsX, double gpsY, double? gpsAlt) {
    // 예: DR vs GPS 혼합
    const alpha = 0.8;
    posX = alpha * posX + (1 - alpha) * gpsX;
    posY = alpha * posY + (1 - alpha) * gpsY;

    gpsAltitude = gpsAlt;
  }

  // [추가] baroOffset 보정 주입
  //  - barometer altitude에 offset을 더해 "baroAltWithOffset" 개념으로 사용
  //  - 아래 getFusedAltitude()에서 활용할 수 있음
  double get baroAltWithOffset {
    if (baroAltitude == null) return double.nan;
    return baroAltitude! + baroOffset;
  }

  // --------------------------------------------
  // get fused altitude
  double? getFusedAltitude() {
    final ba = baroAltitude == null ? null : baroAltWithOffset;
    final ga = gpsAltitude;

    if (ba == null && ga == null) return null;
    if (ba != null && ga != null) {
      // 예: 70% baro + 30% gps
      return 0.7 * ba + 0.3 * ga;
    }
    return ba ?? ga;
  }

  // --------------------------------------------
  // [예시] posX, posY -> LatLng 변환 (간단 스케일)
  LatLng getCurrentLatLng() {
    return LatLng(posY * 1e-5, posX * 1e-5);
  }
}
