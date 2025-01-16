/// extended_kalman_filter_3d.dart
///
/// 3D 확장 버전 예시:
///  - 상태벡터: [x, y, z, vx, vy, vz, heading]
///  - predict()시 ax, ay, az, gz 활용
///  - updateGPS()시 x_gps, y_gps, z_gps 활용
///  - updateHeading()은 기존과 유사 (나침반으로 yaw 보정)

import 'dart:math' as math;

class ExtendedKalmanFilter3D {
  // ---------------------------------------------
  // 상태 벡터: [ x, y, z, vx, vy, vz, heading ]
  // ---------------------------------------------
  List<double> X = List.filled(7, 0.0);

  /// X[0] = x     (동서방향)
  /// X[1] = y     (남북방향)
  /// X[2] = z     (고도)
  /// X[3] = vx
  /// X[4] = vy
  /// X[5] = vz
  /// X[6] = heading (yaw, 라디안)

  // ----------------------------------------------------
  // 공분산 행렬 P (7x7)
  // ----------------------------------------------------
  List<double> P = List.filled(49, 0.0);

  // ----------------------------------------------------
  // 프로세스 잡음 공분산 (Q) (7x7)
  //   - 실제 상황에 맞게 튜닝 필요
  // ----------------------------------------------------
  List<double> Q = List.filled(49, 0.0);

  // ----------------------------------------------------
  // GPS 관측 잡음 공분산(Rgps) : 3x3
  //   - (x_gps, y_gps, z_gps)
  // ----------------------------------------------------
  List<double> Rgps = [
    13.0, 0.0,  0.0,     // 예시로 x,y,z 쪽 잡음을 13m^2 가정 (상황에 따라 조정)
    0.0,  13.0, 0.0,
    0.0,  0.0,  20.0,    // 고도(z)는 오차 더 크다고 가정 (ex: 20m^2)
  ];

  // ----------------------------------------------------
  // Heading 관측 잡음 공분산(Rheading): 1x1
  // ----------------------------------------------------
  List<double> Rheading = [ 0.5 ]; // 라디안^2 정도로 예시

  ExtendedKalmanFilter3D() {
    _initDefaultMatrices();
  }

  // ----------------------------------------------------
  // 초기화 메서드
  // ----------------------------------------------------
  void _initDefaultMatrices() {
    // P: 초기에 큰 값으로 (위치 1000, 속도 1000, heading 1000 등)
    //    7x7
    for (int i = 0; i < 49; i++) {
      P[i] = 0.0;
    }
    // 대각원소만 크게
    P[0] = 1000;  // x
    P[8] = 1000;  // y
    P[16] = 1000; // z
    P[24] = 1000; // vx
    P[32] = 1000; // vy
    P[40] = 1000; // vz
    P[48] = 1000; // heading (7x7 중 마지막 대각원소 index= 6*7 + 6 = 48)

    // Q: 프로세스 잡음 (예시로 대각 몇 개만 채움)
    for (int i = 0; i < 49; i++) {
      Q[i] = 0.0;
    }
    // 대각선 예시값 (실제 상황에 맞춰 튜닝 필요)
    Q[0] = 0.1;   // x
    Q[8] = 0.1;   // y
    Q[16] = 0.2;  // z
    Q[24] = 0.5;  // vx
    Q[32] = 0.5;  // vy
    Q[40] = 0.8;  // vz
    Q[48] = 0.3;  // heading
  }

  // ---------------------------------------------
  // GETTER 편의
  // ---------------------------------------------
  double get x => X[0];
  double get y => X[1];
  double get z => X[2];
  double get vx => X[3];
  double get vy => X[4];
  double get vz => X[5];
  double get heading => X[6];

  // ---------------------------------------------------------
  // (1) 예측단계(Predict): (ax, ay, az, gz, dt)
  // ---------------------------------------------------------
  void predict(double dt, double gz, double ax, double ay, double az) {
    // 1) 상태 꺼내기
    double x_ = X[0];
    double y_ = X[1];
    double z_ = X[2];
    double vx_ = X[3];
    double vy_ = X[4];
    double vz_ = X[5];
    double hdg = X[6];

    // (A) heading 적분 (자이로 z축)
    double heading_new = hdg + gz * dt;

    // (B) 속도 갱신 (등가속도 가정)
    double vx_new = vx_ + ax * dt;
    double vy_new = vy_ + ay * dt;
    double vz_new = vz_ + az * dt;

    // (C) 위치 갱신
    double x_new = x_ + vx_ * dt + 0.5 * ax * dt * dt;
    double y_new = y_ + vy_ * dt + 0.5 * ay * dt * dt;
    double z_new = z_ + vz_ * dt + 0.5 * az * dt * dt;

    // 2) 상태벡터 갱신
    X[0] = x_new;
    X[1] = y_new;
    X[2] = z_new;
    X[3] = vx_new;
    X[4] = vy_new;
    X[5] = vz_new;
    X[6] = heading_new;

    // ---------------------------------------------------
    // (A) 선형화된 F(7x7) 행렬 구성
    //   x_new = x + vx*dt + 0.5*ax*dt^2 → ∂x_new/∂x=1, ∂x_new/∂vx=dt
    //   y_new = y + vy*dt + 0.5*ay*dt^2 ...
    //   z_new = z + vz*dt + 0.5*az*dt^2 ...
    //   vx_new = vx + ax*dt → ∂vx_new/∂vx=1
    //   ...
    //   heading_new = heading + gz*dt → ∂heading_new/∂heading=1
    // ---------------------------------------------------
    List<double> F = [
      1, 0, 0, dt, 0,  0,  0,  // x depends on vx
      0, 1, 0, 0,  dt, 0,  0,  // y depends on vy
      0, 0, 1, 0,  0,  dt, 0,  // z depends on vz
      0, 0, 0, 1,  0,  0,  0,  // vx
      0, 0, 0, 0,  1,  0,  0,  // vy
      0, 0, 0, 0,  0,  1,  0,  // vz
      0, 0, 0, 0,  0,  0,  1,  // heading
    ];

    // 3) P^- = F * P * F^T + Q
    var P_old = matrixCopy(P);
    var Ftrans = matrixTranspose(F, 7, 7);
    var FP = matrixMultiply(F, P_old, 7, 7, 7);   // (7x7)*(7x7)->(7x7)
    var FPFt = matrixMultiply(FP, Ftrans, 7, 7, 7);
    var P_pred = matrixAdd(FPFt, Q, 49);

    P = P_pred;
  }

  // -----------------------------------------------------------------------
  // (2) GPS 관측 업데이트: (x_gps, y_gps, z_gps)
  // -----------------------------------------------------------------------
  void updateGPS(double gpsX, double gpsY, double gpsZ) {
    // 관측 z = [gpsX, gpsY, gpsZ]
    // 예측 h(X) = [ x, y, z ]
    // residual = z - h(X)
    double hx = X[0]; // x
    double hy = X[1]; // y
    double hz = X[2]; // z

    double r1 = gpsX - hx;
    double r2 = gpsY - hy;
    double r3 = gpsZ - hz;

    // H: (3x7) - 상태에서 x,y,z만 뽑는 행렬
    // [1,0,0,0,0,0,0
    //  0,1,0,0,0,0,0
    //  0,0,1,0,0,0,0]
    List<double> H = [
      1,0,0,0,0,0,0,
      0,1,0,0,0,0,0,
      0,0,1,0,0,0,0,
    ];

    // H^T: (7x3)
    var Ht = matrixTranspose(H, 3, 7);

    // PHt: (7x3) = (7x7)*(7x3)
    var PHt = matrixMultiply(P, Ht, 7, 7, 3);

    // HP: (3x7)*(7x7)->(3x7)
    var HP = matrixMultiply(H, P, 3, 7, 7);

    // HPHt: (3x3)
    var HPHt = matrixMultiply(HP, Ht, 3, 7, 3);

    // S = HPHt + Rgps (3x3)
    var S = matrixAdd(HPHt, Rgps, 9);

    // S_inv: (3x3)
    var S_inv = invert3x3(S);

    // K= P^- * H^T * S^-1 => (7x3)
    var K = matrixMultiply(PHt, S_inv, 7, 3, 3);

    // x^+ = x^- + K* residual
    // residual = [r1, r2, r3]
    // K는 7x3
    // => X[0..6] += sum_i( K[row, i]*residual[i] )
    List<double> dX = [0,0,0,0,0,0,0];
    for(int row=0; row<7; row++){
      double temp = K[row*3 + 0]*r1 +
          K[row*3 + 1]*r2 +
          K[row*3 + 2]*r3;
      dX[row] = temp;
    }
    for(int i=0; i<7; i++){
      X[i] += dX[i];
    }

    // P^+ = (I - K H) P
    var KH = matrixMultiply(K, H, 7, 3, 7); // (7x3)*(3x7)->(7x7)
    // I(7x7)
    List<double> I7 = identity7();
    var ImKH = matrixSubtract(I7, KH, 49);
    var newP = matrixMultiply(ImKH, P, 7, 7, 7);

    P = newP;
  }

  // -------------------------------------------------------
  // (3) Heading(나침반) 1차원 업데이트 (동일)
  // -------------------------------------------------------
  void updateHeading(double measuredHeading) {
    // h_heading = X[6]
    double h_heading = X[6];
    double residual = measuredHeading - h_heading;

    // H= (1x7): [0,0,0,0,0,0,1]
    List<double> H = [0,0,0,0,0,0,1];

    // H^T= (7x1)
    var Ht = matrixTranspose(H, 1,7); // -> (7x1)

    // PHt => (7x1)
    var PHt = matrixMultiply(P, Ht, 7,7,1);
    // HP => (1x7)*(7x7)->(1x7)
    var HP = matrixMultiply(H, P, 1,7,7);

    // HPHt => (1x1)
    var HPHt = matrixMultiply(HP, Ht, 1,7,1);
    // S= HPHt + Rheading => (1x1)
    double S = HPHt[0] + Rheading[0];

    // S_inv= 1/S
    if (S.abs() < 1e-9) return; // 방어코드
    double invS = 1.0 / S;

    // K= P^- * H^T * S^-1 => (7x1)
    var K = List<double>.filled(7, 0.0);
    for(int i=0; i<7; i++){
      K[i] = PHt[i]*invS;
    }

    // x^+ = x^- + K* residual
    for(int i=0; i<7; i++){
      X[i] += K[i]*residual;
    }

    // P^+= (I-KH)P
    var KH = List<double>.filled(49, 0.0);
    for(int r=0; r<7; r++){
      for(int c=0; c<7; c++){
        KH[r*7 + c] = K[r]*H[c];
      }
    }
    List<double> I7 = identity7();
    var ImKH = List<double>.filled(49, 0.0);
    for(int i=0; i<49; i++){
      ImKH[i] = I7[i] - KH[i];
    }
    var newP = matrixMultiply(ImKH, P, 7,7,7);
    P = newP;
  }

  // -------------------------------------------------------
  // 행렬/벡터 유틸 (2D EKF 때와 동일하나 3x3, 7x7 등 확장)
  // -------------------------------------------------------
  // 깊은 복사
  List<double> matrixCopy(List<double> src) => List<double>.from(src);

  // 전치 (rows x cols -> cols x rows)
  List<double> matrixTranspose(List<double> M, int rows,int cols){
    List<double> T = List<double>.filled(rows*cols, 0.0);
    for(int r=0; r<rows; r++){
      for(int c=0; c<cols; c++){
        T[c*rows + r] = M[r*cols + c];
      }
    }
    return T;
  }

  // 행렬 곱 (A: rA x cA, B: cA x cB => R: rA x cB)
  List<double> matrixMultiply(List<double> A, List<double> B, int rA,int cA,int cB){
    List<double> R = List<double>.filled(rA*cB, 0.0);
    for(int i=0; i<rA; i++){
      for(int j=0; j<cB; j++){
        double sum=0.0;
        for(int k=0; k<cA; k++){
          sum += A[i*cA+k]*B[k*cB+j];
        }
        R[i*cB + j] = sum;
      }
    }
    return R;
  }

  // 행렬 더하기 (동일 크기)
  List<double> matrixAdd(List<double> A, List<double> B, int len){
    List<double> R = List<double>.filled(len, 0.0);
    for(int i=0; i<len; i++){
      R[i] = A[i] + B[i];
    }
    return R;
  }

  // 행렬 빼기 (동일 크기)
  List<double> matrixSubtract(List<double> A, List<double> B, int len){
    List<double> R= List<double>.filled(len,0.0);
    for(int i=0; i<len; i++){
      R[i] = A[i] - B[i];
    }
    return R;
  }

  // 3x3 역행렬
  List<double> invert3x3(List<double> M) {
    // M = [a11,a12,a13, a21,a22,a23, a31,a32,a33]
    double a11=M[0], a12=M[1], a13=M[2];
    double a21=M[3], a22=M[4], a23=M[5];
    double a31=M[6], a32=M[7], a33=M[8];

    // determinant
    double det = a11*(a22*a33 - a23*a32)
        - a12*(a21*a33 - a23*a31)
        + a13*(a21*a32 - a22*a31);
    if (det.abs() < 1e-14) {
      // 역행렬 불가 -> 단위행렬 반환 or 예외
      return [1,0,0, 0,1,0, 0,0,1];
    }
    double invDet = 1.0/det;

    // 수동으로 cofactor 계산
    double b11 = (a22*a33 - a23*a32)*invDet;
    double b12 = -(a12*a33 - a13*a32)*invDet;
    double b13 = (a12*a23 - a13*a22)*invDet;

    double b21 = -(a21*a33 - a23*a31)*invDet;
    double b22 = (a11*a33 - a13*a31)*invDet;
    double b23 = -(a11*a23 - a13*a21)*invDet;

    double b31 = (a21*a32 - a22*a31)*invDet;
    double b32 = -(a11*a32 - a12*a31)*invDet;
    double b33 = (a11*a22 - a12*a21)*invDet;

    return [b11,b12,b13, b21,b22,b23, b31,b32,b33];
  }

  // 7x7 단위행렬
  List<double> identity7() {
    // 49 elements
    List<double> I = List<double>.filled(49, 0.0);
    for(int i=0; i<7; i++){
      I[i*7 + i] = 1.0;
    }
    return I;
  }

  // ---------------------------------------------
  // (A) 첫 GPS + 고도로 EKF를 초기화하는 메서드 (예시)
  // ---------------------------------------------
  void initWithGPS({
    required double gpsX,
    required double gpsY,
    required double gpsZ,
    required double gpsAccuracyM,      // 예: 10m
    required double headingAccuracyDeg // 예: 90°
  }) {
    // 상태벡터를 [gpsX, gpsY, gpsZ, 0, 0, 0, 0] 등으로 초기화
    X[0] = gpsX;
    X[1] = gpsY;
    X[2] = gpsZ;
    X[3] = 0.0;  // vx
    X[4] = 0.0;  // vy
    X[5] = 0.0;  // vz
    X[6] = 0.0;  // heading

    // gpsAccuracy^2 → 위치 분산, headingAccuracyRad^2 → heading 분산
    double posVar = gpsAccuracyM * gpsAccuracyM;
    double headingAccuracyRad = headingAccuracyDeg * math.pi / 180.0;
    double headingVar = headingAccuracyRad * headingAccuracyRad;

    // 속도쪽 초기 불확실성 등은 크게
    double velVar = 500.0;
    double zVar   = 500.0; // 고도도 초기엔 크게 잡을 수 있음

    // P 초기화 (diagonal)
    for (int i=0; i<49; i++){
      P[i] = 0.0;
    }
    P[0]  = posVar;  // x
    P[8]  = posVar;  // y
    P[16] = zVar;    // z
    P[24] = velVar;  // vx
    P[32] = velVar;  // vy
    P[40] = velVar;  // vz
    P[48] = headingVar; // heading
  }
}
