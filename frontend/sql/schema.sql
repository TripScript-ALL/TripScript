-- TripScript / receiptocr — 모델(User, Trip, Receipt) 기준 관계형 스키마
-- 대상: SQLite 3 (Drift/sqflite 등). PostgreSQL은 주석 참고.
--
-- 매핑 요약
--   User        -> users
--   Trip        -> trips (+ trip_participants 로 List<String> participants)
--   Receipt     -> receipts (trip_id 로 Trip에 종속)

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- users  (lib/models/user.dart)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL,
  phone_number TEXT NOT NULL
);

-- ---------------------------------------------------------------------------
-- trips  (lib/models/trip.dart — participants·receipts 제외 컬럼)
-- 소유: Mock API의 getTrips(userId) 와 같이 user_id 로 User에 연결
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trips (
  id TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL,
  name TEXT NOT NULL,
  start_date TEXT NOT NULL,  -- ISO8601 (Dart DateTime.toIso8601String)
  end_date TEXT NOT NULL,
  host_name TEXT NOT NULL DEFAULT '',
  tile_color INTEGER,        -- Color.value, nullable
  cover_image_path TEXT,
  FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_trips_user_id ON trips (user_id);

-- ---------------------------------------------------------------------------
-- trip_participants — Trip.participants[] 순서 보존 (sort_order 0..n-1)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trip_participants (
  trip_id TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (trip_id, sort_order),
  FOREIGN KEY (trip_id) REFERENCES trips (id) ON DELETE CASCADE
);

-- ---------------------------------------------------------------------------
-- receipts  (lib/models/receipt.dart)
-- paid_by 는 앱과 동일하게 "참여자 표시 이름" 문자열 (FK 아님)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS receipts (
  id TEXT PRIMARY KEY NOT NULL,
  trip_id TEXT NOT NULL,
  store_name TEXT NOT NULL,
  amount REAL NOT NULL,
  date TEXT NOT NULL,        -- ISO8601
  category TEXT NOT NULL,
  image_path TEXT,
  paid_by TEXT NOT NULL,
  FOREIGN KEY (trip_id) REFERENCES trips (id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_receipts_trip_id ON receipts (trip_id);

-- ---------------------------------------------------------------------------
-- PostgreSQL 사용 시 예시 차이
--   - PRAGMA 제거
--   - REAL -> NUMERIC(12,2) 등으로 amount 정밀도 지정 권장
--   - TEXT 그대로 쓰거나 date 컬럼을 TIMESTAMPTZ 로 두고 앱에서 변환
-- ---------------------------------------------------------------------------
