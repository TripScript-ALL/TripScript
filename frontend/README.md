> 공개용 사본: 실행·인증 설정은 [PUBLIC_SETUP.md](../PUBLIC_SETUP.md)를 먼저 따르세요. 아래 기존 사용 설명의 이름·전화번호 로그인, 관리자 토큰 및 기본 주소 예시는 개발 이력입니다.

# TripScript Frontend

TripScript는 해외여행 영수증, 다중 통화, 카드 수수료, 환율, 참여자별 사용량을 함께 관리하는 **해외결제 특화 여행 정산 앱**입니다.

이 저장소는 Flutter 모바일 앱을 담당합니다. 백엔드는 같은 저장소의 `../backend`에서 FastAPI + Docker로 실행합니다.

## 문서

- [TripScript 앱 소개서](docs/app_introduction.md)
- [REST API 메모](docs/rest_api.md)

## 주요 기능

- 카카오 로그인 및 기존 이름/전화번호 로그인 흐름
- 최초 카카오 로그인 후 닉네임, 선택 전화번호, 카드, 정산 계좌 초기 설정
- 닉네임 설정 및 여행/영수증 표시명 즉시 동기화
- 마이페이지, 카드목록, 서비스 설명, 설정을 사이드 메뉴로 분리
- 시스템 테마 연동 및 라이트/다크 테마 설정
- 회원탈퇴 기능
- 여행 생성, 기간 설정, 방문 국가, 대표 이미지 업로드
- 여행 목록 정렬과 카드/리스트 보기 설정
- 초대 코드 기반 여행 참여
- 대표자/참여자 권한 분리
- 참여자는 본인 결제 영수증의 결제 정보만 수정
- 대표자는 여행과 영수증 관리 권한 보유
- 여행 상세에서 기간, 방문국가, 참여자, 지출추이, 영수증 목록을 통일된 섹션 UI로 표시
- 여행 상세 하단에 총 지출과 정산하기 버튼 고정
- 영수증 이미지 업로드 및 Gemini 기반 자동 인식
- 영수증 총액과 품목 합계 검증
- 품목별 단가, 수량, 총액, 참여자별 수량 배분
- 통화별 지출과 원화 기준 총액 표시
- 사용자별 카드 프로필 관리
- 카드사, 카드 상품, 신용/체크, 국제브랜드 기반 카드 선택
- 카드명 기반 백그라운드 수수료 리서치 결과 표시
- 카드/현금 결제 예상 정산액 표시
- 현금 결제 시 사용자가 입력한 환전 환율 반영
- 백엔드 정산 API 기반 정산 결과 표시
- 원래 영수증별 부담 흐름과 최종 상계 정산을 토글해 확인
- 내가 보낼 돈, 내가 받을 돈, 다른 참여자 사이 정산을 탭으로 분리
- 카카오톡 정산 공유 기능

## 개발 환경

- Flutter SDK 3.x
- Dart SDK 3.6 이상
- Android Studio 또는 Android SDK
- Android 기기 또는 에뮬레이터
- 실행 중인 TripScript 백엔드 서버

프론트 개발은 Windows 쪽 작업 디렉토리에서 진행하는 것을 기준으로 합니다.

```text
C:\dev\TripScript\frontend
```

## 설치

```bash
flutter pub get
```

## 실행

백엔드 주소는 `API_BASE_URL`로 주입합니다.

```bash
flutter run \
  --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
```

실기기에서 서버컴 백엔드에 접근할 때는 ngrok 주소를 사용합니다.

```bash
flutter run \
  --dart-define=API_BASE_URL=https://api.example.invalid/api/v1
```

UI 작업만 빠르게 확인하고 싶을 때는 로그인 생략 플래그를 사용할 수 있습니다.

```bash
flutter run --dart-define=SKIP_LOGIN=true
```

## 카카오 설정

카카오 로그인과 카카오톡 공유를 쓰려면 빌드 시 네이티브 앱 키가 필요합니다.

```bash
flutter run \
  --dart-define=KAKAO_NATIVE_APP_KEY=<카카오_네이티브_앱_키> \
  --dart-define=API_BASE_URL=https://api.example.invalid/api/v1
```

Android 딥링크 스킴을 위해 `android/local.properties`에도 다음 값을 둡니다.

```properties
kakao.native.app.key=<카카오_네이티브_앱_키>
```

Kakao Developers 콘솔에는 다음 항목이 맞아야 합니다.

- Android package name: `com.receiptocr.receiptocr`
- Release KeyHash: `<YOUR_RELEASE_KEY_HASH>`
- 카카오 로그인 활성화
- 필요한 경우 카카오톡 메시지 권한 설정

카카오에서 사업자 인증 없이 이름/전화번호 권한을 받을 수 없는 경우가 있어, 앱은 카카오 고유 id 기반 계정을 만들고 사용자가 닉네임을 설정하는 흐름을 사용합니다.

## APK 빌드

릴리즈 APK는 API 주소와 카카오 키를 명시해서 빌드합니다.

```bash
flutter build apk --release \
  --dart-define=KAKAO_NATIVE_APP_KEY=<카카오_네이티브_앱_키> \
  --dart-define=API_BASE_URL=https://api.example.invalid/api/v1
```

현재 기본 릴리즈 APK 경로:

```text
build/app/outputs/flutter-apk/app-release.apk
```

디버그 APK가 필요하면 다음 명령을 사용합니다.

```bash
flutter build apk --debug \
  --dart-define=KAKAO_NATIVE_APP_KEY=<카카오_네이티브_앱_키> \
  --dart-define=API_BASE_URL=https://api.example.invalid/api/v1
```

## Android 권한

앱은 다음 기능을 위해 Android 권한을 사용합니다.

- 인터넷 통신
- 네트워크 상태 확인
- 카메라 촬영
- 갤러리 이미지 선택
- 여행 커버 이미지 업로드
- 영수증 이미지 업로드
- 카카오 로그인 딥링크 처리

릴리즈 빌드에서도 백엔드 통신과 이미지 업로드가 동작하도록 `AndroidManifest.xml`에 네트워크 및 이미지 접근 권한이 설정되어 있습니다.

## 프로젝트 구조

```text
lib/
  config/       앱 설정과 개발용 플래그
  models/       유저, 여행, 영수증, 카드, 정산 모델
  providers/    앱 상태 관리
  screens/      화면 단위 UI
  services/     백엔드 API, 저장소, 카메라/이미지 서비스
  theme/        앱 테마
  utils/        금액, 환율, 정산 보조 로직
  widgets/      재사용 UI 컴포넌트

android/        Android 네이티브 설정 및 권한
assets/         폰트 등 정적 리소스
docs/           앱 소개 및 API 문서
```

## 백엔드 연동 메모

현재 앱은 `RestApiService`를 통해 FastAPI 백엔드와 통신합니다.

- API 기본 경로: `/api/v1`
- ngrok 사용 시 `ngrok-skip-browser-warning` 헤더를 자동 포함
- 카카오 로그인 후 서버 JWT를 저장해 앱 재실행 시 세션 복구
- 여행, 카드, 영수증, 정산 데이터는 백엔드 DB를 기준으로 동기화
- 카드 수수료, 환율, 예상 정산액, 여행 정산 결과는 백엔드 계산 값을 우선 사용
- 정산 API의 `grossTransfers`는 원래 흐름, `transfers`는 최종 상계 결과로 표시
- 영수증 이미지는 백엔드 업로드 후 Gemini 인식 API를 호출
- Gemini 무료 쿼터 초과 시 사용자 친화 메시지로 안내
- 서버 이미지 URL은 백엔드에서 반환한 media URL을 그대로 사용

## 개인정보 및 외부 AI 사용

TripScript는 영수증 인식을 위해 백엔드에서 Gemini API를 호출합니다. 프론트 앱에 Gemini API key를 넣지 않고, 백엔드가 업로드 이미지를 통제합니다.

현재 보호 방향:

- 카드번호 전체, CVC, 유효기간 저장 안 함
- 카드 끝 4자리는 선택적 식별용으로만 저장
- 사용자별 카드 DB 분리
- 같은 이미지 재인식 시 서버 캐시로 외부 전송 최소화
- Gemini 429/쿼터 에러는 짧은 안내 메시지로 변환
- 추후 전송 전 민감정보 마스킹과 이미지 보관기간 정책 적용 가능

## 현재 개발 방향

- 프론트는 Flutter 앱 경험과 입력 흐름을 담당합니다.
- 백엔드는 데이터 저장, 카드 수수료 정책, 환율, 정산 계산, 영수증 인식을 담당합니다.
- 영수증 인식은 현재 Gemini 기반 고정밀 파이프라인을 기본으로 사용합니다.
- 카드 수수료 리서치는 백엔드의 로컬 Ollama 모델을 사용하며, 카드사 대표 정책과 상품별 예외를 함께 관리합니다.
- 카드 상품 DB는 대표 수수료 정책과 주요 해외 특화 카드 override를 시작점으로 점진적으로 확장합니다.
