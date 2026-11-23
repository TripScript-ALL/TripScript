class OcrService {
  Future<double?> recognizeAmountFromImage(String imagePath) async {
    // OCR은 서버 파이프라인으로 옮길 예정이라 앱 내 ML Kit 모델을 제외합니다.
    // 이미지 업로드와 수동 입력은 그대로 동작합니다.
    return null;
  }

  void dispose() {}
}
