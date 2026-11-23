> 공개용 사본: 실행·인증 설정은 [PUBLIC_SETUP.md](../PUBLIC_SETUP.md)를 먼저 따르세요. 아래 기존 사용 설명의 이름·전화번호 로그인, 관리자 토큰 및 기본 주소 예시는 개발 이력입니다.

# TripScript Backend

TripScript Backend는 해외결제 특화 여행 정산 앱 TripScript의 FastAPI 서버입니다.

Flutter 앱에서 발생하는 회원, 카카오 로그인, 여행, 참여자, 영수증, 카드, 이미지 업로드, 영수증 인식, 환율, 수수료, 정산 요청을 처리합니다.

## 역할

- 사용자 등록, 조회, 수정, 탈퇴
- 카카오 로그인 액세스 토큰 검증 및 서비스 JWT 발급
- 닉네임 변경 시 여행/영수증 표시명 동기화
- 여행 생성, 수정, 삭제
- 초대 코드 기반 여행 참여
- 여행 국가, 커버 이미지, 기간 정보 저장
- 대표자/참여자 권한 검증
- 영수증 생성, 수정, 삭제
- 참여자는 본인 결제 영수증의 결제 정보만 수정 가능
- 품목별 수량 배분 저장
- 여행별 정산 결과 계산
- 원래 영수증별 부담 흐름과 최종 상계 송금 관계 동시 반환
- 사용자별 카드 프로필 저장
- 사용자 정산 수취 계좌 정보 저장
- 카드사/브랜드/신용/체크 기준 수수료 정책 제공
- 카드 상품 카탈로그와 해외 특화 카드 override 제공
- 카드명 기반 LLM 수수료 리서치
- 결제일 기준 환율 조회 및 캐시
- 카드/현금 결제 예상 원화 정산액 계산
- 여행 커버 이미지와 영수증 이미지 업로드
- Gemini 기반 영수증 이미지 인식
- 관리자 페이지용 API 제공
- 관리자 페이지용 운영 요약, 인식 로그, 데이터 조회 API 제공

## 기술 스택

- Python
- FastAPI
- Uvicorn
- SQLite
- Docker Compose
- Redis 컨테이너
- Tesseract OCR
- Gemini API
- Ollama
- ngrok

현재 핵심 데이터는 SQLite에 저장됩니다. Redis 컨테이너는 향후 캐시/비동기 작업 확장을 위해 함께 띄워두는 구조이며, 핵심 API 저장소는 SQLite입니다.

## 문서

- [DB 스키마 요약](docs/database_schema.md)

프론트 앱 소개 문서는 프론트 저장소의 `docs/app_introduction.md`를 참고합니다.

## 로컬 실행

가상환경으로 직접 실행할 수 있습니다.

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

상태 확인:

```bash
curl http://127.0.0.1:8000/health
```

API 문서:

```text
http://127.0.0.1:8000/docs
```

## Docker 실행

졸업작품 개발 중에는 Docker Compose 실행을 기본으로 사용합니다.

```bash
docker compose up --build -d
```

종료:

```bash
docker compose down
```

로그 확인:

```bash
docker compose logs -f api
```

## 서버컴 배포

현재 서버컴 라이브 경로는 다음을 기준으로 합니다.

```text
$HOME/tripscript-backend-live
```

서버컴에서 API 컨테이너를 다시 빌드합니다.

```bash
cd $HOME/tripscript-backend-live
docker compose -f docker-compose.yml up -d --build api
curl http://127.0.0.1:8000/health
```

관리 페이지는 별도 컨테이너로 분리되어 있습니다.

```bash
docker compose -f docker-compose.admin.yml up -d --build
```

## ngrok 공개 터널

외부 네트워크의 휴대폰 앱에서 서버컴 백엔드에 접속하려면 ngrok 터널을 함께 실행합니다.

서버의 `.env`에 다음 값을 설정합니다.

```text
NGROK_AUTHTOKEN=...
NGROK_DOMAIN=api.example.invalid
```

실행:

```bash
docker compose -f docker-compose.yml -f docker-compose.ngrok.yml up -d
```

확인:

```bash
curl https://api.example.invalid/health \
  -H 'ngrok-skip-browser-warning: true'
```

같은 ngrok 고정 도메인은 한 번에 한 곳에서만 잡을 수 있습니다. 노트북에서 `ngrok.exe`가 실행 중이면 서버컴 ngrok이 `ERR_NGROK_334`로 실패할 수 있으므로, 서버컴으로 이전할 때는 노트북의 ngrok 프로세스를 먼저 종료해야 합니다.

## 환경 변수

기본값은 `.env.example`에 있습니다.

```text
APP_NAME=TripScript Backend
APP_ENV=local
DEBUG=false
API_PREFIX=/api

DATABASE_URL=sqlite:///./storage/tripscript.db
REDIS_URL=redis://redis:6379/0

JWT_SECRET_KEY=<GENERATE_RANDOM_SECRET_32_CHARS_OR_MORE>
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=10080

STORAGE_DIR=storage

RECEIPT_RECOGNITION_STRATEGY=cloud_gemini
RECEIPT_GEMINI_API_KEY=
RECEIPT_GEMINI_MODEL=gemini-2.5-flash
RECEIPT_CLOUD_LLM_FLATTEN_ENABLED=true

RECEIPT_LLM_BASE_URL=http://ollama:11434
RECEIPT_LLM_PROVIDER=ollama_vision
RECEIPT_LLM_MODEL=qwen2.5vl:7b
RECEIPT_TEXT_LLM_MODEL=qwen2.5:1.5b

CARD_FEE_RESEARCH_ENABLED=true
CARD_FEE_RESEARCH_MODEL=qwen2.5:3b
CARD_FEE_RESEARCH_TIMEOUT_SECONDS=90
CARD_FEE_RESEARCH_MAX_SOURCES=4
```

실제 배포 환경에서는 `.env`를 따로 만들고 비밀값을 교체하는 방식이 좋습니다.

## 데이터 저장 위치

Docker 실행 시 SQLite DB와 업로드 파일은 `storage/` 아래에 유지됩니다.

```text
storage/
  tripscript.db
  media/
```

컨테이너를 재빌드해도 `storage/` 볼륨이 남아 있으면 회원, 여행, 영수증, 카드, 이미지 데이터가 유지됩니다.

개발 중 전체 데이터를 초기화하려면 Docker 컨테이너를 내린 뒤 `storage/tripscript.db`와 관련 WAL/SHM 파일을 삭제합니다.

## 주요 API

기본 API prefix:

```text
/api/v1
```

대표 엔드포인트:

| Method | Path | 설명 |
| --- | --- | --- |
| `GET` | `/health` | 서버 상태 확인 |
| `POST` | `/api/v1/auth/kakao` | 카카오 액세스 토큰으로 로그인 |
| `GET` | `/api/v1/me` | 현재 JWT 사용자 조회 |
| `GET` | `/api/v1/users/lookup` | 이름/전화번호 기반 사용자 조회 |
| `POST` | `/api/v1/users` | 사용자 생성 |
| `PATCH` | `/api/v1/users/{user_id}` | 사용자 정보 수정 |
| `DELETE` | `/api/v1/users/{user_id}` | 회원탈퇴 |
| `GET` | `/api/v1/users/{user_id}/cards` | 사용자 카드 목록 |
| `POST` | `/api/v1/users/{user_id}/cards` | 카드 등록 |
| `PUT` | `/api/v1/users/{user_id}/cards` | 카드 목록 저장 |
| `GET` | `/api/v1/users/{user_id}/trips` | 사용자 여행 목록 |
| `POST` | `/api/v1/users/{user_id}/trips` | 여행 생성 |
| `POST` | `/api/v1/users/{user_id}/trips/join` | 초대 코드로 여행 참여 |
| `PUT` | `/api/v1/users/{user_id}/trips/{trip_id}` | 여행 수정 |
| `POST` | `/api/v1/users/{user_id}/trips/{trip_id}/leave` | 여행 나가기 |
| `DELETE` | `/api/v1/users/{user_id}/trips/{trip_id}` | 대표자 여행 삭제 |
| `GET` | `/api/v1/users/{user_id}/trips/{trip_id}/cards` | 참여자 카드 목록 조회 |
| `GET` | `/api/v1/users/{user_id}/trips/{trip_id}/receipts` | 영수증 목록 |
| `POST` | `/api/v1/users/{user_id}/trips/{trip_id}/receipts` | 영수증 생성 |
| `PUT` | `/api/v1/users/{user_id}/trips/{trip_id}/receipts/{receipt_id}` | 영수증 수정 |
| `PUT` | `/api/v1/users/{user_id}/trips/{trip_id}/receipts/{receipt_id}/items/{item_index}` | 영수증 품목 chunk 저장 |
| `DELETE` | `/api/v1/users/{user_id}/trips/{trip_id}/receipts/{receipt_id}` | 영수증 삭제 |
| `GET` | `/api/v1/users/{user_id}/trips/{trip_id}/settlement` | 여행 정산 결과 |
| `GET` | `/api/v1/payment/fee-catalog` | 카드사, 브랜드, 카드 상품 수수료 카탈로그 |
| `POST` | `/api/v1/payment/estimate` | 결제 예상 원화 정산액 계산 |
| `POST` | `/api/v1/media/upload` | 여행 커버/영수증 이미지 업로드 |
| `GET` | `/api/v1/media/{kind}/{filename}` | 업로드 이미지 조회 |
| `POST` | `/api/v1/receipts/recognize` | 업로드된 영수증 이미지 인식 |
| `POST` | `/api/v1/receipts/recognize/compare` | 인식 파이프라인 비교 |
| `POST` | `/api/v1/receipts/recognize-text` | OCR 텍스트 기반 영수증 초안 생성 |

## 인증과 권한

카카오 로그인 또는 이름/전화번호 로그인 후 서버는 사용자별 access token을 반환합니다. 앱은 이 토큰을 `Authorization: Bearer ...`로 보냅니다.

경로에 `{user_id}`가 있는 API는 JWT subject와 path user id가 다르면 403을 반환합니다.

여행 권한:

- 대표자: 여행 정보, 기간, 커버 이미지, 참여자, 모든 영수증 결제 정보 수정 가능
- 참여자: 본인 결제 영수증 생성/수정/삭제 가능
- 참여자: 타인 결제 영수증의 결제 정보 수정 불가
- 참여자: 품목 분배 수정 가능
- 닉네임 변경 이후에도 `name`, `nickname`, display name alias를 비교해 권한을 판단

회원탈퇴:

- 사용자 계정 삭제
- 개인 카드 삭제
- 참여자로 들어간 여행에서는 참여자 목록에서 제거
- 대표자로 만든 여행은 전체 삭제

닉네임/표시명:

- Kakao Developers에서 사업자 인증 없이 이름/전화번호 권한을 받기 어려운 상황을 고려해, 카카오 로그인 사용자는 `kakao_user_id` 기반으로 계정을 만들고 앱에서 닉네임을 입력한다.
- 닉네임 변경 시 기존 여행 대표자명, 참여자명, 영수증 결제자명, 품목 분배명을 새 표시명으로 동기화한다.
- 권한 판단은 기존 문자열 데이터와 호환되도록 `name`, `nickname`, display name alias를 함께 비교한다.

## 영수증 인식

현재 기본 영수증 인식은 Gemini 기반입니다.

```text
RECEIPT_RECOGNITION_STRATEGY=cloud_gemini
RECEIPT_GEMINI_MODEL=gemini-2.5-flash
```

파이프라인:

```text
이미지 업로드
→ 백엔드 storage 저장
→ 평면화/리사이즈
→ Gemini 2.5 Flash 호출
→ 앱 영수증 스키마 JSON 생성
→ 총액/품목 검증
→ 결과 반환
```

쿼터 대응:

- Gemini 429 응답에서 `retry in Ns` 또는 `retry-after`를 읽는다.
- 45초 이하면 서버가 한 번 대기 후 자동 재시도한다.
- 같은 이미지, 같은 통화, 같은 모델 설정은 메모리 캐시를 사용한다.
- 사용자에게는 긴 Gemini 원문 대신 짧은 한글 메시지를 반환한다.

예시:

```bash
curl -X POST http://127.0.0.1:8000/api/v1/receipts/recognize \
  -H 'Content-Type: application/json' \
  -d '{"imagePath":"/api/v1/media/receipt/example.jpg","currencyCode":"EUR"}'
```

보조 파이프라인으로 OCR + 로컬 LLM 구조도 남아 있습니다.

```text
RECEIPT_LLM_PROVIDER=ollama_vision
RECEIPT_LLM_BASE_URL=http://ollama:11434
RECEIPT_LLM_MODEL=qwen2.5vl:7b
RECEIPT_TEXT_LLM_MODEL=qwen2.5:1.5b
```

## 카드 수수료 리서치

카드 수수료 리서치는 Gemini가 아니라 로컬 Ollama를 사용합니다.

```text
CARD_FEE_RESEARCH_ENABLED=true
CARD_FEE_RESEARCH_MODEL=qwen2.5:3b
RECEIPT_LLM_BASE_URL=http://ollama:11434
```

흐름:

```text
카드 추가
→ 백그라운드 리서치 예약
→ DuckDuckGo 검색으로 카드사/상품설명서 후보 수집
→ 검색 결과 title/url/snippet을 evidence로 구성
→ Ollama qwen2.5:3b에 JSON 추출 요청
→ issuerFeeRate, brandFeeRate, summary, sources 저장
```

카드 프로필에는 리서치 상태가 함께 저장됩니다.

- `feeResearchStatus`: `idle`, `running`, `done`, `uncertain`, `failed`
- `feeResearchSummary`
- `feeResearchSources`
- `feeResearchCheckedAt`
- `feeResearchError`

## DB 구조

현재 SQLite DB는 다음 주요 테이블을 사용합니다.

| 테이블 | 역할 |
| --- | --- |
| `users` | 사용자 계정, 카카오 id, 닉네임 |
| `trips` | 여행 기본 정보와 대표자 user id |
| `trip_participants` | 여행 참여자 목록과 user id 매핑 |
| `user_trips` | 사용자별 여행 목록 매핑 |
| `receipts` | 영수증 결제 정보와 서버 계산 금액 |
| `receipt_items` | 영수증 품목 |
| `receipt_item_splits` | 품목별 참여자 수량 배분 |
| `card_profiles` | 사용자별 카드 프로필과 수수료 리서치 결과 |
| `card_fee_catalog` | 카드사/브랜드 대표 수수료 카탈로그 |
| `card_issuer_fee_policies` | 카드사, 브랜드, 신용/체크별 수수료 정책 |
| `card_products` | 카드 상품명 카탈로그 |
| `card_product_fee_overrides` | 트래블카드 등 상품별 예외 정책 |
| `exchange_rates` | 날짜별 환율 캐시 |
| `media_files` | 업로드 이미지 메타데이터 |

더 자세한 내용은 [DB 스키마 요약](docs/database_schema.md)을 참고합니다.

## 결제 계산 방향

카드 결제는 다음 흐름으로 예상 원화 정산액을 계산합니다.

```text
현지통화 결제금액
→ 현지통화에서 USD 환산
→ 국제브랜드 수수료 반영
→ USD에서 KRW 환산
→ 국내 카드사 해외서비스 수수료 반영
→ 정산 반영 원화 금액
```

현금 결제는 카드 수수료를 적용하지 않고, 사용자가 입력한 환전 환율을 기준으로 원화 금액을 계산합니다.

실제 카드앱에서 확인한 원화 청구액이 있으면 예상 계산액보다 실제 청구액을 우선 반영합니다.

## 정산 계산 방향

정산 API는 저장된 영수증, 품목, 참여자별 수량 배분, 서버 계산 원화 금액을 기준으로 요청 시점에 결과를 계산합니다.

```text
영수증별 정산 기준 원화 금액
→ 품목별 참여자 수량 배분
→ 참여자별 부담액 계산
→ 영수증 결제자에게 보내야 하는 원래 흐름 생성
→ 참여자 간 채권/채무를 상계한 최종 송금 관계 생성
```

응답에는 두 가지 송금 목록이 함께 들어갑니다.

- `grossTransfers`: 각 영수증의 결제자에게 원래 보내야 하는 부담 흐름
- `transfers`: 서로 주고받을 금액을 상계한 최종 송금 관계

Flutter 앱은 이를 `원래 흐름 / 최종 상계` 토글로 표시합니다. `receiptBreakdown`에는 정산 신뢰도를 위해 어떤 영수증과 품목에서 금액이 나왔는지 추적 가능한 데이터를 포함합니다.

## 개인정보와 외부 AI 사용

영수증 이미지는 Gemini로 전송될 수 있으므로 발표와 운영 단계에서 다음 설명이 필요합니다.

- 프론트 앱은 외부 LLM API key를 보관하지 않는다.
- 백엔드가 이미지 업로드, 전송, 저장을 통제한다.
- 정산에 필요한 필드만 구조화해 DB에 저장한다.
- 카드번호 전체, CVC, 유효기간은 저장하지 않는다.
- 카드 끝 4자리는 선택적 식별 정보로만 저장한다.
- 같은 이미지 재인식은 캐시로 외부 전송을 줄인다.
- 향후 사용자 동의, 이미지 자동 삭제, 민감정보 마스킹, 로컬 인식 fallback을 추가할 수 있다.

## 테스트

```bash
pytest
```

현재 기능이 커졌으므로 다음 테스트를 우선 추가하는 것이 좋습니다.

- 카카오 로그인 사용자 생성/복구
- 닉네임 변경 후 여행 표시명 동기화
- 대표자/참여자 영수증 권한
- 회원탈퇴 데이터 정리
- 영수증 저장 chunk 처리
- 카드 수수료 계산
- 정산 결과 계산
- `grossTransfers`와 `transfers` 분리 검증
- Gemini 429 메시지 변환

## 프론트 연동

Flutter 앱은 빌드 또는 실행 시 `API_BASE_URL`로 이 서버 주소를 받습니다.

```bash
flutter run \
  --dart-define=API_BASE_URL=https://api.example.invalid/api/v1
```

카카오 로그인도 함께 빌드하려면:

```bash
flutter run \
  --dart-define=KAKAO_NATIVE_APP_KEY=<카카오_네이티브_앱_키> \
  --dart-define=API_BASE_URL=https://api.example.invalid/api/v1
```

## 향후 작업

- Gemini 유료 티어 또는 Billing 연결
- 이미지 원본 자동 삭제 정책
- 영수증 인식 전 민감정보 마스킹
- 카드 상품 DB 확장
- 카드사 공식 약관 기반 수수료 검증
- 환율 API 고도화
- 카드사 접수일/매입일 기준 환율 보정
- 관리자용 카드 상품/수수료 관리 화면
- `payer_user_id`, `receipt_item_splits.user_id` 추가
- 영수증 이미지 보관기간/자동 삭제 정책
