> 공개용 사본: 실행·인증 설정은 [PUBLIC_SETUP.md](../../PUBLIC_SETUP.md)를 먼저 따르세요. 아래 기존 사용 설명의 이름·전화번호 로그인, 관리자 토큰 및 기본 주소 예시는 개발 이력입니다.

# TripScript Admin

TripScript Admin은 TripScript 운영 데이터를 조회하기 위한 별도 관리 웹입니다.

이 디렉터리는 백엔드 레포 안에 포함된 React/Vite 관리 웹입니다. 서버 컴퓨터에서 Docker 또는 Vite 개발 서버로 실행하는 것을 기준으로 합니다.

## 앱 서비스와의 경계

TripScript Admin은 일반 사용자가 접근하는 앱 서비스가 아니라 운영자용 관리 도구입니다.

- Flutter 앱 사용자 화면과 분리된 운영자 화면입니다.
- 앱 사용자 화면에는 포함하지 않습니다.
- `/api/v1/admin/*`, `/api/v1/payment/fee-catalog`, `/api/v1/receipts/recognize*` API를 사용합니다.
- `ADMIN_API_TOKEN`을 가진 운영자만 접근하는 것을 전제로 합니다.
- 대부분 read-only이지만, 시연/개발 편의를 위해 테스트 사용자 생성/삭제와 영수증 인식 테스트를 제공합니다.
- 수수료 DB 직접 편집, 영수증 삭제, 미디어 삭제 같은 위험한 기능은 별도 관리자 인증과 감사 로그를 만든 뒤 추가하는 것을 권장합니다.

즉, 이 사이트는 “서비스 기능”이 아니라 “운영/관리 백오피스”입니다.

## 기능

- 운영 요약 대시보드
- 운영 인사이트
- 사용자 목록 조회
- 테스트 사용자 생성/삭제
- 여행 목록과 참여자/초대코드/통화별 지출 조회
- 영수증 목록과 예상/실제/정산 원화 금액, AI 인식 상태 조회
- 사용자별 카드 프로필과 LLM 수수료 리서치 상태 조회
- 정산 계산에 필요한 사용자 계좌/표시명 상태 점검
- 업로드 미디어 조회
- 환율 캐시 조회
- 카드사/브랜드/카드상품 수수료 카탈로그 조회
- Gemini/OCR 영수증 인식 테스트와 파이프라인 비교
- 영수증 인식 성공/실패, 처리 시간, 에러 유형 확인
- Gemini 쿼터/일시 장애 같은 외부 AI 실패 원인 확인
- 개인정보/외부 AI 사용 점검 패널
- 시스템 설정 및 데이터 볼륨 확인

관리 사이트의 삭제 기능은 현재 사용자 삭제에 한정됩니다. 실제 운영 단계에서는 관리자 계정, 감사 로그, 2차 확인을 추가해야 합니다.

현재 앱 서비스가 다루는 핵심 운영 지표는 다음입니다.

- 사용자/카카오 로그인 계정 상태
- 여행, 참여자, 초대 코드, 방문 국가
- 영수증 이미지와 인식 결과
- 카드 수수료 리서치 상태
- 환율 캐시와 결제 예상 원화 금액
- 정산 API가 반환하는 원래 흐름과 최종 상계 결과

## 백엔드 요구사항

백엔드에 다음 환경 변수를 설정해야 합니다.

```text
ENABLE_ADMIN_API=true
ADMIN_API_TOKEN=<GENERATE_RANDOM_SECRET_32_CHARS_OR_MORE>
```

관리 웹은 API 요청에 `X-Admin-Token` 헤더를 포함합니다.

## 개발 실행

```bash
npm install
npm run dev
```

기본 개발 주소:

```text
http://127.0.0.1:5174
```

화면 상단에서 API Base URL과 Admin Token을 입력할 수 있습니다.

예시 API Base URL:

```text
http://127.0.0.1:8000/api/v1
https://api.example.invalid/api/v1
```

## Docker 실행

백엔드 루트에서 실행:

```bash
docker compose -f docker-compose.yml -f docker-compose.admin.yml up -d --build admin
```

admin 웹 디렉터리 단독 실행:

```bash
docker compose up --build -d
```

기본 접속 주소:

```text
http://127.0.0.1:8080
```

## 빌드

```bash
npm run build
```

빌드 결과는 `dist/`에 생성됩니다.

## 서버컴 운영 메모

서버 컴퓨터에서 운영할 때 권장 구성은 다음과 같습니다.

```text
TripScript Backend  : FastAPI Docker, 8000 포트
TripScript Admin    : nginx Docker, 8080 포트
외부 접근           : Tailscale 또는 nginx reverse proxy
```

관리 사이트는 운영 데이터가 보이므로 public ngrok에 그대로 노출하지 않는 것을 권장합니다. 필요한 경우 Tailscale 내부망 또는 Basic Auth/reverse proxy 뒤에 두는 편이 안전합니다.
