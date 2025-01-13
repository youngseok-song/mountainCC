// service/extended_kalman_filter.dart

/// 간단 예시: 2D EKF (x, y, vx, vy)
class ExtendedKalmanFilter {
  // ----------------------------
  // 상태 벡터: [ x, y, vx, vy ]
  // ----------------------------
  List<double> X = [0.0, 0.0, 0.0, 0.0];

  // ----------------------------------------------------
  // 공분산 행렬 P (4x4) : 초기 오차를 크게 잡아둠
  // ----------------------------------------------------
  List<double> P = [
    1000.0, 0.0,    0.0,    0.0,
    0.0,    1000.0, 0.0,    0.0,
    0.0,    0.0,    1000.0, 0.0,
    0.0,    0.0,    0.0,    1000.0,
  ];

  // ----------------------------------------------------
  // 프로세스 잡음 공분산 (Q) : 실제 상황에 맞춰 튜닝
  // ----------------------------------------------------
  List<double> Q = [
    0.1, 0.0, 0.0,  0.0,
    0.0, 0.1, 0.0,  0.0,
    0.0, 0.0, 0.1,  0.0,
    0.0, 0.0, 0.0,  0.1,
  ];

  // ----------------------------------------------------
  // GPS 관측 잡음 공분산(R) : 2x2 행렬
  // ----------------------------------------------------
  List<double> Rgps = [
    5.0,  0.0,
    0.0,  5.0,
  ];

  // -----------------------------------------------------------------------
  // (1) 예측단계(Predict): 일정 dt 후 상태 & 공분산 예측
  // -----------------------------------------------------------------------
  void predict(double dt) {
    // 상태 벡터
    double x  = X[0];
    double y  = X[1];
    double vx = X[2];
    double vy = X[3];

    // 단순 선형 모델
    // x_k = x_{k-1} + vx * dt
    // y_k = y_{k-1} + vy * dt
    // vx_k = vx (등속 가정)
    // vy_k = vy
    double x_new  = x  + vx * dt;
    double y_new  = y  + vy * dt;
    double vx_new = vx;
    double vy_new = vy;

    X[0] = x_new;
    X[1] = y_new;
    X[2] = vx_new;
    X[3] = vy_new;

    // P^- = F * P * F^T + Q
    // F (4x4):
    //  [1, 0, dt, 0 ]
    //  [0, 1, 0,  dt]
    //  [0, 0, 1,  0 ]
    //  [0, 0, 0,  1 ]
    List<double> F = [
      1.0, 0.0, dt,  0.0,
      0.0, 1.0, 0.0, dt,
      0.0, 0.0, 1.0, 0.0,
      0.0, 0.0, 0.0, 1.0
    ];

    final P_old = matrixCopy(P);
    final Ftrans = matrixTranspose(F, 4,4);
    var FP    = matrixMultiply(F, P_old, 4,4,4);    // (4x4)*(4x4) -> 4x4
    var FPFt  = matrixMultiply(FP, Ftrans, 4,4,4);  // 4x4
    var P_pred= matrixAdd(FPFt, Q, 16);             // 4x4

    P = P_pred;
  }

  // -----------------------------------------------------------------------
  // (2) GPS 관측 업데이트(updateGPS)
  // -----------------------------------------------------------------------
  void updateGPS(double gpsX, double gpsY) {
    // 관측 z = [gpsX, gpsY]
    // h(X) = [x, y]

    double hx = X[0]; // 예측된 x
    double hy = X[1]; // 예측된 y

    // 잔차 y = z - h(x^-)
    double y1 = gpsX - hx;
    double y2 = gpsY - hy;

    // H (2x4):
    //  [1, 0, 0, 0]
    //  [0, 1, 0, 0]
    List<double> H = [
      1.0, 0.0, 0.0, 0.0,
      0.0, 1.0, 0.0, 0.0
    ];
    var Ht   = matrixTranspose(H, 2,4);       // -> (4x2)
    var PHt  = matrixMultiply(P, Ht, 4,4,2);  // (4x4)*(4x2)->(4x2)
    var HP   = matrixMultiply(H, P, 2,4,4);   // (2x4)*(4x4)->(2x4)
    var HPHt = matrixMultiply(HP, Ht, 2,4,2); // (2x2)

    // S = HPHt + R (2x2)
    var S = matrixAdd(HPHt, Rgps, 4);
    var S_inv = invert2x2(S);

    // K= P^- H^T S^-1 -> (4x2)
    var K = matrixMultiply(PHt, S_inv, 4,2,2);

    // x^+ = x^- + K*y
    // K*y => (4x2)*(2x1) -> (4x1)
    // y1,y2
    X[0] = X[0] + (K[0]*y1 + K[1]*y2);
    X[1] = X[1] + (K[2]*y1 + K[3]*y2);
    X[2] = X[2] + (K[4]*y1 + K[5]*y2);
    X[3] = X[3] + (K[6]*y1 + K[7]*y2);

    // P^+ = (I-KH)P^-
    var KH   = matrixMultiply(K, H, 4,2,4);   // (4x2)*(2x4)->(4x4)
    var I4   = [1.0,0.0,0.0,0.0,
      0.0,1.0,0.0,0.0,
      0.0,0.0,1.0,0.0,
      0.0,0.0,0.0,1.0];
    var ImKH = matrixSubtract(I4, KH, 16);
    var newP = matrixMultiply(ImKH, P, 4,4,4);

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
}
