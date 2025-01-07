// service/movement_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'movement_service.dart';

final movementServiceProvider = ChangeNotifierProvider<MovementService>((ref) {
  // MovementService 생성
  return MovementService();
});
