> 공개용 사본: 실행·인증 설정은 [PUBLIC_SETUP.md](../../PUBLIC_SETUP.md)를 먼저 따르세요. 아래 기존 사용 설명의 이름·전화번호 로그인, 관리자 토큰 및 기본 주소 예시는 개발 이력입니다.

# TripScript REST API Memo

이 문서는 Flutter `ApiService`와 현재 FastAPI 백엔드 구현을 맞춰 정리한 메모입니다.

## 1. 공통

| 항목 | 값 |
| --- | --- |
| API prefix | `/api/v1` |
| 형식 | JSON, `Content-Type: application/json` |
| 인증 | `Authorization: Bearer <access_token>` |
| ID | 문자열 UUID |
| 시간 | ISO 8601 문자열 |

ngrok을 사용할 때 Flutter `RestApiService`는 다음 헤더를 자동 포함합니다.

```text
ngrok-skip-browser-warning: true
```

오류 응답은 `detail` 또는 `{ "error": { "message": "..." } }` 형태를 받을 수 있습니다. 앱은 `ApiException.message`로 변환해 사용자에게 보여줍니다.

Gemini 쿼터 오류처럼 외부 서비스 원문이 길게 오는 경우 앱과 서버가 짧은 한글 메시지로 변환합니다.

## 2. 인증과 사용자

### 2.1 카카오 로그인

```
POST /api/v1/auth/kakao
```

요청:

```json
{ "accessToken": "kakao-access-token" }
```

응답:

```json
{
  "id": "user-id",
  "name": "카카오4891715090",
  "nickname": "콩순이콤퓨터",
  "phoneNumber": "",
  "kakaoUserId": "4891715090",
  "accessToken": "service-jwt"
}
```

카카오에서 이름/전화번호 권한을 받을 수 없는 경우가 있으므로, 서버는 카카오 id 기반 기본 이름을 만들고 앱은 닉네임 설정을 유도합니다.

### 2.2 현재 사용자 복구

```
GET /api/v1/me
Authorization: Bearer ...
```

저장된 JWT로 앱 재시작 시 세션을 복구합니다.

### 2.3 이름 + 전화번호 조회

```
GET /api/v1/users/lookup?name={name}&phoneNumber={phone}
```

기존 이름/전화번호 로그인 흐름용입니다.

### 2.4 회원 등록

```
POST /api/v1/users
```

```json
{ "name": "홍길동", "phoneNumber": "01012345678" }
```

### 2.5 프로필 수정

```
PATCH /api/v1/users/{userId}
Authorization: Bearer ...
```

```json
{
  "name": "카카오4891715090",
  "nickname": "콩순이콤퓨터",
  "phoneNumber": "",
  "settlementBankName": "국민은행",
  "settlementAccountNumber": "1234567890",
  "settlementAccountHolder": "이규하"
}
```

닉네임 변경 후 백엔드는 여행 대표자, 참여자, 영수증 결제자, 품목 배분 이름을 새 표시명으로 동기화합니다.
정산 계좌 정보는 정산 화면에서 내가 돈을 받아야 할 때 상대방에게 보여줄 입금 정보로 사용됩니다.

### 2.6 회원탈퇴

```
DELETE /api/v1/users/{userId}
Authorization: Bearer ...
```

동작:

- 사용자 계정 삭제
- 개인 카드 삭제
- 참여자로 들어간 여행에서 참여자 제거
- 대표자로 만든 여행은 전체 삭제

## 3. 여행

### 3.1 여행 목록

```
GET /api/v1/users/{userId}/trips
Authorization: Bearer ...
```

응답:

```json
{
  "items": [
    {
      "id": "trip-id",
      "name": "스위스 남프랑스",
      "startDate": "2025-03-10T00:00:00.000",
      "endDate": "2025-03-18T00:00:00.000",
      "participants": ["콩순이콤퓨터", "친구"],
      "hostName": "콩순이콤퓨터",
      "hostUserId": "user-id",
      "inviteCode": "ABC123",
      "countries": ["스페인", "프랑스"],
      "tileColor": null,
      "coverImagePath": "/api/v1/media/trip_cover/...",
      "receipts": []
    }
  ]
}
```

### 3.2 여행 생성

```
POST /api/v1/users/{userId}/trips
Authorization: Bearer ...
```

대표자는 서버에서 현재 사용자 기준으로 확정됩니다.

프론트는 여행 생성 시 방문 국가를 검색 가능한 선택 UI로 받으며, 서버는 `countries` 배열을 여행 표시와 영수증 현지 시간 안내에 사용합니다.

### 3.3 초대 코드 참여

```
POST /api/v1/users/{userId}/trips/join
Authorization: Bearer ...
```

```json
{ "inviteCode": "ABC123" }
```

### 3.4 여행 수정

```
PUT /api/v1/users/{userId}/trips/{tripId}
Authorization: Bearer ...
```

대표자만 여행 기간, 커버 이미지, 참여자 등 핵심 정보를 수정할 수 있습니다.

### 3.5 여행 나가기

```
POST /api/v1/users/{userId}/trips/{tripId}/leave
Authorization: Bearer ...
```

대표자는 이 API로 나갈 수 없습니다. 대표자가 여행을 끝내려면 여행 삭제를 사용합니다.

### 3.6 여행 삭제

```
DELETE /api/v1/users/{userId}/trips/{tripId}
Authorization: Bearer ...
```

대표자만 호출할 수 있으며, 삭제 시 모든 사용자의 여행 목록에서 제거됩니다.

## 4. 카드

### 4.1 사용자 카드 목록

```
GET /api/v1/users/{userId}/cards
Authorization: Bearer ...
```

카드는 사용자별로 분리됩니다.

### 4.2 카드 추가

```
POST /api/v1/users/{userId}/cards
Authorization: Bearer ...
```

```json
{
  "name": "카드 상품명",
  "company": "신한카드",
  "brand": "VISA",
  "cardType": "credit",
  "last4": "1234"
}
```

카드 추가 후 백엔드는 백그라운드로 카드 수수료 리서치를 예약합니다.

### 4.3 카드 목록 저장

```
PUT /api/v1/users/{userId}/cards
Authorization: Bearer ...
```

```json
{ "items": [ /* CardProfile[] */ ] }
```

### 4.4 여행 참여자 카드 조회

```
GET /api/v1/users/{userId}/trips/{tripId}/cards?participantName={name}
Authorization: Bearer ...
```

대표자는 참여자별 카드를 조회할 수 있고, 일반 참여자는 본인 카드만 조회할 수 있습니다.

### 4.5 카드 수수료 카탈로그

```
GET /api/v1/payment/fee-catalog
```

응답에는 카드사/브랜드 대표 수수료, 카드 상품명 카탈로그, 상품별 override가 포함됩니다.

## 5. 영수증

### 5.1 영수증 목록

```
GET /api/v1/users/{userId}/trips/{tripId}/receipts
Authorization: Bearer ...
```

서버는 결제 예상 원화 금액을 계산해 반환합니다.

### 5.2 영수증 생성

```
POST /api/v1/users/{userId}/trips/{tripId}/receipts
Authorization: Bearer ...
```

```json
{
  "id": "optional-client-id",
  "storeName": "EROSKI CALA DOR",
  "amount": 87.22,
  "currencyCode": "EUR",
  "date": "2025-03-12T18:30:00.000",
  "category": "마트",
  "paidBy": "콩순이콤퓨터",
  "paymentMethod": "card",
  "cardType": "credit",
  "cardIssuer": "신한카드",
  "cardBrand": "VISA",
  "cardLast4": "1234",
  "items": []
}
```

권한:

- 대표자는 모든 결제자의 영수증 생성/수정 가능
- 참여자는 본인 표시명과 일치하는 `paidBy` 영수증만 생성/수정 가능
- 서버는 `name`, `nickname`, `displayName` alias를 모두 비교

### 5.3 영수증 수정

```
PUT /api/v1/users/{userId}/trips/{tripId}/receipts/{receiptId}
Authorization: Bearer ...
```

영수증 metadata와 품목을 한 번에 보낼 수 있습니다. 앱은 큰 영수증 저장 안정성을 위해 metadata와 items를 나눠 저장하는 chunk 흐름도 사용합니다.

### 5.4 영수증 품목 chunk 저장

```
PUT /api/v1/users/{userId}/trips/{tripId}/receipts/{receiptId}/items/{itemIndex}
Authorization: Bearer ...
```

```json
{
  "name": "Pasta",
  "quantity": 2,
  "unitPrice": 1.29,
  "lineTotal": 2.58,
  "category": "식비",
  "quantityByPerson": {
    "콩순이콤퓨터": 1,
    "친구": 1
  }
}
```

### 5.5 영수증 삭제

```
DELETE /api/v1/users/{userId}/trips/{tripId}/receipts/{receiptId}
Authorization: Bearer ...
```

대표자 또는 결제자 본인만 삭제할 수 있습니다.

## 6. 이미지 업로드와 영수증 인식

### 6.1 이미지 업로드

```
POST /api/v1/media/upload
Content-Type: multipart/form-data
Authorization: Bearer ...
```

필드:

- `file`: 이미지 파일
- `kind`: `receipt` 또는 `trip_cover`

응답:

```json
{
  "id": "media-id",
  "kind": "receipt",
  "url": "https://.../api/v1/media/receipt/file.jpg",
  "path": "/api/v1/media/receipt/file.jpg",
  "contentType": "image/jpeg",
  "sizeBytes": 123456,
  "createdAt": "2026-05-15T00:00:00Z"
}
```

### 6.2 영수증 이미지 인식

```
POST /api/v1/receipts/recognize
Authorization: Bearer ...
```

```json
{
  "imagePath": "/api/v1/media/receipt/file.jpg",
  "currencyCode": "EUR"
}
```

현재 기본 전략은 `cloud_gemini`입니다.

```text
이미지 업로드
→ 서버 평면화/리사이즈
→ Gemini 2.5 Flash
→ 영수증 JSON
→ 총액/품목 검증
```

쿼터 대응:

- 같은 이미지 결과는 서버 메모리 캐시 사용
- Gemini 429가 오면 짧은 시간 한 번 자동 재시도
- 그래도 실패하면 사용자 친화 메시지 반환

### 6.3 인식 파이프라인 비교

```
POST /api/v1/receipts/recognize/compare
```

```json
{
  "imagePath": "/api/v1/media/receipt/file.jpg",
  "currencyCode": "EUR",
  "strategies": ["hybrid", "cloud_gemini"]
}
```

관리/디버깅용으로 전략별 성공 여부와 결과를 비교합니다.

## 7. 정산과 결제 계산

### 7.1 예상 결제 원화 계산

```
POST /api/v1/payment/estimate
```

입력은 `Receipt` JSON과 동일합니다.

카드 계산 흐름:

```text
현지통화 결제금액
→ 현지통화에서 USD 환산
→ 국제브랜드 수수료 반영
→ USD에서 KRW 환산
→ 국내 카드사 해외서비스 수수료 반영
→ 정산 반영 원화 금액
```

현금 결제는 사용자가 입력한 환전 환율을 우선 사용합니다.

실제 카드앱 청구액(`actualKrwAmount`)이 있으면 예상액보다 우선 반영합니다.

### 7.2 여행 정산 결과

```
GET /api/v1/users/{userId}/trips/{tripId}/settlement
Authorization: Bearer ...
```

응답에는 참여자별 지출/부담액, 송금 관계, 영수증별 ledger가 포함됩니다.

주요 필드:

```json
{
  "balances": [
    {
      "participant": "콩순이콤퓨터",
      "paid": 95684,
      "share": 19137,
      "balance": 76547
    }
  ],
  "grossTransfers": [
    {
      "from": "친구",
      "to": "콩순이콤퓨터",
      "amount": 19137
    }
  ],
  "transfers": [
    {
      "from": "친구",
      "to": "콩순이콤퓨터",
      "amount": 19137
    }
  ],
  "receiptBreakdown": []
}
```

- `grossTransfers`: 각 영수증의 결제자에게 원래 보내야 하는 부담 흐름
- `transfers`: 서로 주고받을 금액을 상계한 최종 송금 관계
- Flutter 정산 화면은 `원래 흐름 / 최종 상계` 토글로 두 값을 분리해 표시합니다.
- 보낼 돈, 받을 돈, 다른 정산 탭은 현재 로그인 사용자의 표시명을 기준으로 분류합니다.

## 8. Flutter ApiService 매핑

| Dart 메서드 | HTTP |
| --- | --- |
| `getCurrentUser` | `GET /me` |
| `loginWithKakaoAccessToken` | `POST /auth/kakao` |
| `getUserByNameAndPhone` | `GET /users/lookup` |
| `registerUser` | `POST /users` |
| `updateUser` | `PATCH /users/{userId}` |
| `deleteUser` | `DELETE /users/{userId}` |
| `getTrips` | `GET /users/{userId}/trips` |
| `saveTrip` | `POST /users/{userId}/trips` |
| `updateTrip` | `PUT /users/{userId}/trips/{tripId}` |
| `deleteTrip` | `DELETE /users/{userId}/trips/{tripId}` |
| `leaveTrip` | `POST /users/{userId}/trips/{tripId}/leave` |
| `joinTripByInviteCode` | `POST /users/{userId}/trips/join` |
| `getReceipts` | `GET /users/{userId}/trips/{tripId}/receipts` |
| `createReceipt` | `POST /users/{userId}/trips/{tripId}/receipts` |
| `updateReceipt` | `PUT /users/{userId}/trips/{tripId}/receipts/{receiptId}` |
| `deleteReceiptItem` | `DELETE /users/{userId}/trips/{tripId}/receipts/{receiptId}` |
| `uploadMedia` | `POST /media/upload` |
| `recognizeReceiptImage` | `POST /receipts/recognize` |
| `getSettlementSummary` | `GET /users/{userId}/trips/{tripId}/settlement` |
| `getCardProfiles` | `GET /users/{userId}/cards` |
| `saveCardProfiles` | `PUT /users/{userId}/cards` |
| `createCardProfile` | `POST /users/{userId}/cards` |
| `getTripParticipantCardProfiles` | `GET /users/{userId}/trips/{tripId}/cards` |
| `getPaymentFeeCatalog` | `GET /payment/fee-catalog` |
| `estimateReceiptPayment` | `POST /payment/estimate` |

## 9. HTTP 상태 코드

| 상황 | 코드 |
| --- | --- |
| 성공 조회/수정 | 200 |
| 생성 | 201 |
| 삭제 | 204 |
| 잘못된 입력 | 400 |
| 인증 실패 | 401 |
| 권한 없음 | 403 |
| 없음 | 404 |
| 중복/충돌 | 409 |
| Gemini 쿼터 초과 | 429 |
| 외부 AI/서버 오류 | 502/503 |
