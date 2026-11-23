# 공개용 코드 실행 안내

## 백엔드

저장소 루트에서 `cd backend` 후 `.env.example`을 `.env`로 복사합니다.
`JWT_SECRET_KEY`는 `python -c "import secrets; print(secrets.token_urlsafe(48))"`로 생성한 값으로 설정하세요.
Gemini 인식을 사용할 때만 `RECEIPT_GEMINI_API_KEY`를 실제 키로 채웁니다.
`.env`는 Git과 Docker 빌드에서 제외되며 Compose 실행 시에만 주입됩니다.

```bash
cd backend
python -m venv .venv
# Windows: .venv\Scripts\activate
# macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

또는 같은 폴더에서 `docker compose up --build api redis`를 실행합니다.
기본 DB는 `storage/tripscript.db`이며 로컬 실행과 Docker의 `/app/storage` 볼륨이 일치합니다.
현재 실제 데이터 구현은 SQLite 전용입니다. 기존 DATABASE_URL 값이 무시되던 문제를 수정했으며 다른 DB 엔진은 지원하지 않습니다.
API prefix는 `/api/v1`로 고정되어 있습니다. 기존 API_PREFIX는 호환용 설정이며 경로를 바꾸지 않습니다.

헬스 체크: `http://127.0.0.1:8000/health`.
로컬에서 문서가 필요하면 `.env`에 `ENABLE_API_DOCS=true`를 설정해 `/docs`를 엽니다.
웹 프론트/운영자 웹을 쓸 경우 `CORS_ORIGINS=["http://localhost:5174","http://127.0.0.1:8080"]`처럼 허용할 Origin만 지정합니다.

이름·전화번호 로그인은 기본 차단됩니다. 실제 사용자는 카카오로 로그인합니다.
테스트 데이터만 있는 로컬에서만 `APP_ENV=local`, `ENABLE_LEGACY_AUTH=true`로 켤 수 있습니다.
운영 환경에서는 `APP_ENV=production`을 사용하며 이 로그인 스위치를 켜면 시작이 거부됩니다.

## 프론트엔드

```bash
cd frontend
flutter pub get
# config/app.example.json을 config/app.local.json으로 복사한 후 값을 입력
flutter run --dart-define-from-file=config/app.local.json
```

Android 에뮬레이터에서 PC 백엔드에 접근할 때는 `API_BASE_URL=http://10.0.2.2:8000/api/v1`을 사용합니다.
실기기는 자신이 설정한 HTTPS 주소를 넣습니다. 코드 기본값은 PC용 loopback입니다.
카카오 앱 키는 JSON의 `KAKAO_NATIVE_APP_KEY`와 `android/local.properties`의 `kakao.native.app.key`에 같은 값을 넣으세요.
`android/local.properties.example`에는 SDK 경로 설정 예제가 있습니다.
카카오 콘솔에는 본인이 빌드한 서명의 KeyHash를 등록합니다. 기존 운영 KeyHash는 공개 문서에서 제거했습니다.

`flutter build apk --release --dart-define-from-file=config/app.local.json`으로 빌드합니다.
로컬 UI 확인은 `flutter run --dart-define=SKIP_LOGIN=true`를 사용합니다. 릴리즈에서는 무시됩니다.
로컬 이름·전화 로그인 테스트는 프론트 `ENABLE_LEGACY_LOGIN=true`와 백엔드의 로컬 전용 스위치를 모두 켭니다.
로그인 토큰, 관리자 토큰, Gemini 비밀키를 Flutter/Vite 빌드 설정에 넣지 마세요.
앱 키와 API 주소는 완성된 앱에서 추출할 수 있어 접근 제어 수단이 될 수 없습니다.

## 운영자 웹과 외부 터널

운영자 API는 기본 꺼져 있습니다. 로컬에서 `ENABLE_ADMIN_API=true`와 새 `ADMIN_API_TOKEN`(무작위 32자 이상)을 설정합니다.
`backend/admin_web`에서 `npm ci`, `npm run build`, `npm run dev`를 실행할 수 있습니다.
`.env.example`의 `VITE_API_BASE_URL`은 서버 주소 설정용이며 공개 번들에 포함됩니다. 비밀은 넣지 않습니다.
관리자 토큰은 화면에서 직접 입력하며 새로고침하면 다시 입력합니다.
Compose는 `backend`에서 `docker compose -f docker-compose.yml -f docker-compose.admin.yml up --build`를 사용합니다.
기본 운영자 웹 포트는 PC 내부에서만 접근할 수 있습니다.

터널을 쓰려면 `.env`에 본인의 `NGROK_AUTHTOKEN`과 `NGROK_DOMAIN`을 입력합니다.
백업/비상 복구는 `SERVER_HOST`, `REMOTE_DIR`, `PUBLIC_HEALTH_URL`을 로컬 환경에서 명시해야 합니다.
백업에는 `.env`와 개인정보 DB가 포함되므로 비공개 저장소 밖에 보관하세요.
실제 운영 서버, DNS, 방화벽, 키 폐기/재발급은 이번 소스 공개 작업에서 변경하지 않습니다.
