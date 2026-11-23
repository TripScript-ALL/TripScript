> 공개용 사본: 실행·인증 설정은 [PUBLIC_SETUP.md](../../PUBLIC_SETUP.md)를 먼저 따르세요. 아래 기존 사용 설명의 이름·전화번호 로그인, 관리자 토큰 및 기본 주소 예시는 개발 이력입니다.

# TripScript 서버컴 장애 대응

이 문서는 발표/시연 중 서버컴이 죽었을 때 노트북 WSL에서 백엔드와 ngrok을 임시로 올리는 절차입니다.

## 평소 백업

서버컴이 정상일 때 노트북에서 실행합니다.

```bash
cd $HOME/TripScript/backend
bash scripts/backup_server_to_laptop.sh
```

백업되는 것:

- 서버컴 live 백엔드 코드 스냅샷
- `.env`
- `storage/` 업로드 파일
- `storage/tripscript.db` SQLite DB

기본 백업 위치:

```text
$HOME/tripscript-backend-standby
```

## 서버컴 장애 시 실행

중요: 서버컴의 `tripscript-ngrok` 컨테이너와 노트북 비상 ngrok을 동시에 실행하면 안 됩니다. 같은 고정 ngrok 도메인을 쓰기 때문입니다.

서버컴이 꺼졌거나 서버컴 ngrok이 내려간 것이 확실할 때만 실행합니다.

```bash
cd $HOME/TripScript/backend
CONFIRM_SERVER_NGROK_DOWN=1 bash scripts/start_laptop_emergency.sh
```

성공하면 기존 앱이 바라보는 주소가 그대로 노트북 백엔드로 연결됩니다.

```text
https://api.example.invalid
```

스크립트는 WSL의 `docker` 명령을 먼저 찾고, 없으면 Windows Docker Desktop의 `docker.exe`를 자동으로 사용합니다. 그래도 실패하면 Docker Desktop이 켜져 있는지 확인합니다.

## 복구 후 내리기

서버컴을 다시 사용할 수 있게 되면 노트북 비상 서버를 먼저 내립니다.

```bash
cd $HOME/TripScript/backend
bash scripts/stop_laptop_emergency.sh
```

그 다음 서버컴에서 원래 백엔드/ngrok을 올립니다.

## 발표 당일 추천 루틴

1. 발표 전날 밤 `backup_server_to_laptop.sh` 실행
2. 발표 당일 아침 한 번 더 실행
3. 서버컴 장애 시 `start_laptop_emergency.sh` 실행
4. 발표 종료 후 `stop_laptop_emergency.sh` 실행
