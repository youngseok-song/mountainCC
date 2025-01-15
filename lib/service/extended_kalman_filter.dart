// service/extended_kalman_filter.dart

/// 간단 예시: 2D EKF (x, y, vx, vy)
class ExtendedKalmanFilter {
  // ----------------------------
  // 상태 벡터: [ x, y, vx, vy, heading ]
  // ----------------------------
  List<double> X = [0.0, 0.0, 0.0, 0.0, 0.0];

  // ----------------------------------------------------
  // 공분산 행렬 P (5x5) : 초기 오차를 크게 잡아둠
  // ----------------------------------------------------
  List<double> P = [
    1000.0, 0.0,    0.0,    0.0,    0.0,
    0.0,    1000.0, 0.0,    0.0,    0.0,
    0.0,    0.0,    1000.0, 0.0,    0.0,
    0.0,    0.0,    0.0,    1000.0, 0.0,
    0.0,    0.0,    0.0,    0.0,    1000.0,
  ];

  // ----------------------------------------------------
  // 프로세스 잡음 공분산 (Q) : 실제 상황에 맞춰 튜닝
  // ----------------------------------------------------
  List<double> Q = [
    // x,   y,   vx,   vy,   heading
    0.1,  0.0,  0.0,  0.0,  0.0,
    0.0,  0.1,  0.0,  0.0,  0.0,
    0.0,  0.0,  1.0,  0.0,  0.0, // vx 잡음(가속도)
    0.0,  0.0,  0.0,  1.0,  0.0, // vy 잡음(가속도)
    0.0,  0.0,  0.0,  0.0,  0.5,
  ];

  // ----------------------------------------------------
  // GPS 관측 잡음 공분산(R) : 2x2 행렬
  // ----------------------------------------------------
  List<double> Rgps = [
    5.0,  0.0,
    0.0,  5.0,
  ];

  List<double> Rheading = [ 0.5 ]; // 라디안^2 기준

  // -----------------------------------------------------------------------
  // (1) 예측단계(Predict): 일정 dt 후 상태 & 공분산 예측
  // -----------------------------------------------------------------------
  void predict(double dt, double gz, double ax, double ay) {
    // 1) 상태 꺼내기
    double x = X[0];
    double y = X[1];
    double vx = X[2];
    double vy = X[3];
    double heading = X[4];

    // 2) heading 적분 (자이로)
    double heading_new = heading + gz * dt;

    // 3) 속도 갱신 (등가속도 가정)
    double vx_new = vx + ax * dt;
    double vy_new = vy + ay * dt;

    // 4) 위치 갱신
    //   x_new = x + vx*dt + 0.5*ax*dt^2
    //   y_new = y + vy*dt + 0.5*ay*dt^2
    double x_new = x + vx*dt + 0.5 * ax * dt * dt;
    double y_new = y + vy*dt + 0.5 * ay * dt * dt;

    // 5) 대입
    X[0] = x_new;
    X[1] = y_new;
    X[2] = vx_new;
    X[3] = vy_new;
    X[4] = heading_new;

    // (A) 선형화된 F 행렬(5x5) 재구성
    //   ∂(x_new)/∂x = 1
    //   ∂(x_new)/∂vx= dt
    //   ...
    //   여기선 a가 입력이므로 F는 기존과 유사, 단지 vx, x의 관계가 바뀜
    List<double> F = [
      1.0, 0.0, dt,  0.0, 0.0,
      0.0, 1.0, 0.0, dt,  0.0,
      0.0, 0.0, 1.0, 0.0, 0.0,
      0.0, 0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 0.0, 1.0,
    ];
    // ※ a(ax,ay)는 "입력" 형태라서 F에는 직접 안 들어감(간단화)

    // 6) P^- = F P F^T + Q
    var P_old = matrixCopy(P);
    var Ftrans = matrixTranspose(F, 5, 5);
    var FP = matrixMultiply(F, P_old, 5, 5, 5);
    var FPFt = matrixMultiply(FP, Ftrans, 5, 5, 5);
    var P_pred = matrixAdd(FPFt, Q, 25);

    P = P_pred;
  }

  // -----------------------------------------------------------------------
  // (2) GPS 관측 업데이트(updateGPS)
  // -----------------------------------------------------------------------
  void updateGPS(double gpsX, double gpsY) {
    // z=[gpsX, gpsY], h(X)=[x, y] => x= X[0], y= X[1]
    double hx = X[0];
    double hy = X[1];

    double y1 = gpsX - hx;
    double y2 = gpsY - hy;

    // H = 2x5
    List<double> H = [
      1.0, 0.0, 0.0, 0.0, 0.0,  // for x
      0.0, 1.0, 0.0, 0.0, 0.0,  // for y
    ];

    // PHt => (5x5)*(5x2)??? 사실은 (5x5)*(5x2)가 안 맞음 → 먼저 transpose(H,2,5)
    // Step:
    //  - H는 (2x5)
    //  - H^T는 (5x2)
    //  - P는 (5x5)
    // => P*(H^T) => (5x5)*(5x2)->(5x2)
    var Ht = matrixTranspose(H, 2, 5); // (5x2)

    // PHt => (5x5)*(5x2)->(5x2)
    var PHt = matrixMultiply(P, Ht, 5, 5, 2);

    // HP => (2x5)*(5x5)->(2x5)
    var HP = matrixMultiply(H, P, 2, 5, 5);

    // HPHt => (2x5)*(5x2) = (2x2)
    var HPHt = matrixMultiply(HP, Ht, 2, 5, 2);

    // S = HPHt + R => (2x2)
    var S = matrixAdd(HPHt, Rgps, 4);

    var S_inv = invert2x2(S); // (2x2 -> 2x2)

    // K= P^- H^T S^-1 => (5x2)
    var K = matrixMultiply(PHt, S_inv, 5, 2, 2);

    // x^+ = x^- + K*y => (5x1)
    // y=[y1, y2]
    X[0] = X[0] + (K[0]*y1 + K[1]*y2);
    X[1] = X[1] + (K[2]*y1 + K[3]*y2);
    X[2] = X[2] + (K[4]*y1 + K[5]*y2);
    X[3] = X[3] + (K[6]*y1 + K[7]*y2);
    X[4] = X[4] + (K[8]*y1 + K[9]*y2);

    // P^+ = (I - K H) P
    // => K H => (5x2)*(2x5) = (5x5)
    var KH = matrixMultiply(K, H, 5, 2, 5);
    // I5 => 5x5 단위행렬
    List<double> I5 = [
      1,0,0,0,0,
      0,1,0,0,0,
      0,0,1,0,0,
      0,0,0,1,0,
      0,0,0,0,1,
    ];
    var ImKH = matrixSubtract(I5, KH, 25);
    var newP = matrixMultiply(ImKH, P, 5, 5, 5);

    P = newP;
  }

  // -------------------------------------------------------
  // 자기장 센서로 얻은 heading(절대 방위)을 EKF에서 보정
  // -------------------------------------------------------
  void updateHeading(double measuredHeading) {
    double h_heading = X[4]; // 예측된 heading
    double residual = measuredHeading - h_heading;
    // 만약 -π ~ π 범위 정규화 등 할 수도

    // H= (1x5)
    List<double> H = [0,0,0,0,1];
    // H^T= (5x1)
    var Ht = matrixTranspose(H, 1,5); // -> (5x1)

    // PHt => (5x5)*(5x1)->(5x1)
    var PHt = matrixMultiply(P, Ht, 5,5,1);
    // HP => (1x5)*(5x5)->(1x5)
    var HP = matrixMultiply(H, P, 1,5,5);

    // HPHt => (1x5)*(5x1)->(1x1)
    var HPHt = matrixMultiply(HP, Ht, 1,5,1);
    // S=HPHt+Rheading => (1x1)
    double S = HPHt[0] + Rheading[0];

    // S_inv= 1/S
    double invS = 1.0 / S;

    // K= P^- * H^T * S^-1 => (5x1)
    // PHt => (5x1)
    var K = List<double>.filled(5, 0.0);
    for(int i=0; i<5; i++){
      K[i] = PHt[i]*invS;
    }

    // x^+ = x^- + K * residual
    X[0] += K[0]*residual;
    X[1] += K[1]*residual;
    X[2] += K[2]*residual;
    X[3] += K[3]*residual;
    X[4] += K[4]*residual;

    // P^+= (I-KH)P
    // K(5x1)*H(1x5) -> (5x5)
    var KH = List<double>.filled(25, 0.0);
    for(int r=0; r<5; r++){
      for(int c=0; c<5; c++){
        KH[r*5 + c] = K[r]*H[c];
      }
    }
    // I5
    List<double> I5 = [
      1,0,0,0,0,
      0,1,0,0,0,
      0,0,1,0,0,
      0,0,0,1,0,
      0,0,0,0,1,
    ];
    var ImKH = List<double>.filled(25, 0.0);
    for(int i=0; i<25; i++){
      ImKH[i] = I5[i] - KH[i];
    }
    // newP= ImKH * P => (5x5)*(5x5)->(5x5)
    var newP = matrixMultiply(ImKH, P, 5,5,5);
    P = newP;
  }

  // -------------------------------------------------------
  // 행렬/벡터 유틸
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

  // 2x2 역행렬
  // S= [a,b; c,d]
  // S^-1= 1/det * [ d,-b; -c,a]
  List<double> invert2x2(List<double> M) {
    double a=M[0], b=M[1], c=M[2], d=M[3];
    double det = a*d - b*c;
    if (det.abs() < 1e-10) {
      // 역행렬 불가 -> 에러 or 단위행렬
      return [1.0,0.0,0.0,1.0];
    }
    double invDet= 1.0/det;
    return [
      d*invDet,  -b*invDet,
      -c*invDet, a*invDet
    ];
  }

  // 편의 Getter
  double get x  => X[0];
  double get y  => X[1];
  double get vx => X[2];
  double get vy => X[3];

  // ---------------------------------------------
  // (A) 첫 GPS 위치로 EKF를 초기화하는 메서드
  // ---------------------------------------------
  void initWithGPS(double gpsX, double gpsY) {
    // [x, y, vx, vy, heading]
    X[0] = gpsX;
    X[1] = gpsY;
    X[2] = 0.0;
    X[3] = 0.0;
    X[4] = 0.0;

    P = [
      800.0, 0.0,   0.0,   0.0,   0.0,
      0.0,   800.0, 0.0,   0.0,   0.0,
      0.0,   0.0,   800.0, 0.0,   0.0,
      0.0,   0.0,   0.0,   800.0, 0.0,
      0.0,   0.0,   0.0,   0.0,   800.0,
    ];
    // 필요시 5번째 항만 3~400 정도, etc. 튜닝 가능
  }
}
