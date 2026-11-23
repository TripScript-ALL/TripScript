import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';

type Summary = {
  users: number;
  kakaoUsers: number;
  phoneUsers: number;
  trips: number;
  receipts: number;
  cards: number;
  mediaFiles: number;
  exchangeRates: number;
  cardProducts: number;
  cardProductOverrides: number;
  dbIndexCount: number;
  dbIndexes: Array<{ name: string; table: string }>;
  totalSettlementKrw: number;
  mediaStorageBytes: number;
  paymentMethodCounts: Record<string, number>;
  currencyTotals: Record<string, number>;
  recognition: {
    totalRecognized: number;
    avgDurationMs: number;
    maxDurationMs: number;
    warningCount: number;
    cacheHits: number;
    providers: Record<string, number>;
    models: Record<string, number>;
    strategies: Record<string, number>;
  };
  cardResearch: {
    statusCounts: Record<string, number>;
    researchedCount: number;
    failedCount: number;
  };
  system: {
    appEnv: string;
    databaseUrl: string;
    storageDir: string;
    receiptRecognitionStrategy: string;
    receiptGeminiModel: string;
    receiptCloudFlattenEnabled: boolean;
    cardFeeResearchEnabled: boolean;
    cardFeeResearchModel: string;
  };
  latestReceipts: AdminReceipt[];
  latestTrips: AdminTrip[];
};

type AdminUser = {
  id: string;
  name: string;
  nickname?: string;
  displayName?: string;
  phoneNumber: string;
  kakaoUserId?: string;
  isKakaoLinked?: boolean;
  tripCount: number;
  cardCount: number;
};

type AdminTrip = {
  id: string;
  name: string;
  startDate?: string;
  endDate?: string;
  hostName: string;
  inviteCode?: string;
  participants?: string[];
  participantCount: number;
  receiptCount: number;
  totalKrw: number;
  totalsByCurrency?: Record<string, number>;
  coverImagePath?: string;
};

type AdminReceipt = {
  id: string;
  tripId: string;
  tripName: string;
  storeName: string;
  amount: number;
  currencyCode: string;
  date: string;
  paidBy: string;
  paymentMethod: string;
  estimatedKrwAmount?: number;
  actualKrwAmount?: number;
  settlementKrwAmount: number;
  itemCount: number;
  imagePath?: string;
  confidence?: number;
  warnings?: string[];
  cardIssuer?: string;
  cardBrand?: string;
  cardLast4?: string;
  cardIssuerFeeRate?: number;
  cardBrandFeeRate?: number;
  exchangeRateSource?: string;
  rateDateLabel?: string;
  recognition?: Record<string, unknown>;
};

type AdminCard = {
  id: string;
  userId: string;
  userName: string;
  userDisplayName?: string;
  name: string;
  company: string;
  brand: string;
  cardType: string;
  last4?: string;
  issuerFeeRate?: number;
  issuerFeeType?: string;
  issuerFeeFixedUsd?: number;
  brandFeeRate?: number;
  networkFeeWaived?: boolean;
  issuerFeeWaived?: boolean;
  productOverrideNote?: string;
  feeResearchStatus?: string;
  feeResearchSummary?: string;
  feeResearchSources?: Array<{ title?: string; url?: string }>;
  feeResearchCheckedAt?: string;
  feeResearchError?: string;
};

type AdminMedia = {
  id: string;
  kind: string;
  originalName?: string;
  contentType?: string;
  publicPath: string;
  sizeBytes: number;
  createdAt: string;
};

type ExchangeRate = {
  currencyCode: string;
  rateDate: string;
  krwPerUnit: number;
  asOfLabel: string;
  source: string;
};

type FeeCatalog = {
  asOfLabel: string;
  issuers: Array<{ id: string; label: string; rate: number; aliases: string[]; sourceUrl?: string }>;
  brands: Array<{ id: string; label: string; rate: number; aliases: string[]; sourceUrl?: string }>;
  products: Array<{ id?: string; name: string; company: string; brand: string; cardType: string; category: string }>;
  notes: string[];
};

type DataState = {
  summary?: Summary;
  users: AdminUser[];
  trips: AdminTrip[];
  receipts: AdminReceipt[];
  cards: AdminCard[];
  media: AdminMedia[];
  exchangeRates: ExchangeRate[];
  feeCatalog?: FeeCatalog;
};

type UploadResponse = {
  id: string;
  kind: string;
  url: string;
  path: string;
  contentType: string;
  sizeBytes: number;
  createdAt: string;
};

type RecognitionResult = Record<string, unknown>;

type TabKey =
  | 'dashboard'
  | 'insights'
  | 'users'
  | 'trips'
  | 'receipts'
  | 'cards'
  | 'media'
  | 'rates'
  | 'catalog'
  | 'recognition'
  | 'privacy'
  | 'system';

const tabs: Array<{ key: TabKey; label: string }> = [
  { key: 'dashboard', label: '대시보드' },
  { key: 'insights', label: '운영 인사이트' },
  { key: 'users', label: '사용자' },
  { key: 'trips', label: '여행' },
  { key: 'receipts', label: '영수증' },
  { key: 'cards', label: '카드' },
  { key: 'media', label: '미디어' },
  { key: 'rates', label: '환율' },
  { key: 'catalog', label: '수수료 DB' },
  { key: 'recognition', label: '인식 테스트' },
  { key: 'privacy', label: '개인정보/AI' },
  { key: 'system', label: '시스템' },
];

const emptyData: DataState = {
  users: [],
  trips: [],
  receipts: [],
  cards: [],
  media: [],
  exchangeRates: [],
};

function stored(key: string, fallback: string) {
  const value = window.localStorage.getItem(key);
  if (!value) return fallback;
  const trimmed = value.trim();
  if (
    key === 'tripscript.admin.token' &&
    (trimmed === 'change-me-admin-token' ||
      trimmed.length < 20 ||
      (fallback.trim().length > 0 && trimmed !== fallback.trim()))
  ) {
    return fallback;
  }
  if (
    key === 'tripscript.admin.baseUrl' &&
    window.location.hostname !== 'localhost' &&
    window.location.hostname !== '127.0.0.1' &&
    (value.includes('127.0.0.1') || value.includes('localhost'))
  ) {
    return fallback;
  }
  return value;
}

function normalizeBaseUrl(value: string) {
  return value.trim().replace(/\/$/, '');
}

function defaultApiBaseUrl() {
  const envValue = import.meta.env.VITE_API_BASE_URL;
  if (envValue) return envValue;
  const hostname = window.location.hostname || '127.0.0.1';
  return `${window.location.protocol}//${hostname}:8000/api/v1`;
}

function formatKrw(value?: number) {
  return `${Math.round(value || 0).toLocaleString('ko-KR')}원`;
}

function formatBytes(value?: number) {
  const bytes = value || 0;
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function formatDurationMs(value?: number) {
  if (!value || value <= 0) return '-';
  if (value < 1000) return `${Math.round(value)}ms`;
  return `${(value / 1000).toFixed(1)}초`;
}

function percent(value?: number) {
  return `${(((value || 0) * 100)).toFixed(3)}%`;
}

function shortPercent(value?: number) {
  if (value === undefined || value === null) return '-';
  return `${(value * 100).toFixed(2)}%`;
}

function numberField(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function countText(counts?: Record<string, number>) {
  if (!counts || !Object.keys(counts).length) return '-';
  return Object.entries(counts)
    .map(([key, value]) => `${key} ${value}`)
    .join(' · ');
}

function includesQuery(values: Array<unknown>, query: string) {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return values.some((value) => String(value ?? '').toLowerCase().includes(q));
}

function statusLabel(status?: string) {
  const s = String(status || 'idle');
  const labels: Record<string, string> = {
    idle: '대기',
    running: '진행',
    done: '완료',
    uncertain: '불확실',
    failed: '실패',
  };
  return labels[s] || s;
}

async function fetchJson<T>(baseUrl: string, token: string, path: string): Promise<T> {
  const response = await fetch(`${normalizeBaseUrl(baseUrl)}${path}`, {
    headers: {
      Accept: 'application/json',
      'X-Admin-Token': token,
      'ngrok-skip-browser-warning': 'true',
    },
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`${response.status} ${response.statusText}: ${text.slice(0, 200)}`);
  }
  return response.json() as Promise<T>;
}

async function postJson<T>(
  baseUrl: string,
  token: string,
  path: string,
  body: Record<string, unknown>,
): Promise<T> {
  const response = await fetch(`${normalizeBaseUrl(baseUrl)}${path}`, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'X-Admin-Token': token,
      'ngrok-skip-browser-warning': 'true',
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`${response.status} ${response.statusText}: ${text.slice(0, 500)}`);
  }
  return response.json() as Promise<T>;
}

async function deleteJson(baseUrl: string, token: string, path: string): Promise<void> {
  const response = await fetch(`${normalizeBaseUrl(baseUrl)}${path}`, {
    method: 'DELETE',
    headers: {
      Accept: 'application/json',
      'X-Admin-Token': token,
      'ngrok-skip-browser-warning': 'true',
    },
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`${response.status} ${response.statusText}: ${text.slice(0, 500)}`);
  }
}

async function uploadReceiptImage(baseUrl: string, token: string, file: File): Promise<UploadResponse> {
  const form = new FormData();
  form.append('file', file);
  form.append('kind', 'receipt');
  const response = await fetch(`${normalizeBaseUrl(baseUrl)}/media/upload`, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'X-Admin-Token': token,
      'ngrok-skip-browser-warning': 'true',
    },
    body: form,
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`${response.status} ${response.statusText}: ${text.slice(0, 500)}`);
  }
  return response.json() as Promise<UploadResponse>;
}

function App() {
  const envBaseUrl = defaultApiBaseUrl();
  const envToken = '';
  window.localStorage.removeItem('tripscript.admin.token');
  const [baseUrl, setBaseUrl] = useState(() => stored('tripscript.admin.baseUrl', envBaseUrl));
  const [token, setToken] = useState(() => stored('tripscript.admin.token', envToken));
  const [tab, setTab] = useState<TabKey>('dashboard');
  const [data, setData] = useState<DataState>(emptyData);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lastLoadedAt, setLastLoadedAt] = useState<string | null>(null);
  const [query, setQuery] = useState('');

  const saveSettings = useCallback(() => {
    window.localStorage.setItem('tripscript.admin.baseUrl', normalizeBaseUrl(baseUrl));
    // The administrator enters a token per page session; never persist it.
  }, [baseUrl, token]);

  const loadData = useCallback(async () => {
    setLoading(true);
    setError(null);
    saveSettings();
    try {
      const [
        summary,
        users,
        trips,
        receipts,
        cards,
        media,
        exchangeRates,
        feeCatalog,
      ] = await Promise.all([
        fetchJson<Summary>(baseUrl, token, '/admin/summary'),
        fetchJson<{ items: AdminUser[] }>(baseUrl, token, '/admin/users'),
        fetchJson<{ items: AdminTrip[] }>(baseUrl, token, '/admin/trips'),
        fetchJson<{ items: AdminReceipt[] }>(baseUrl, token, '/admin/receipts'),
        fetchJson<{ items: AdminCard[] }>(baseUrl, token, '/admin/cards'),
        fetchJson<{ items: AdminMedia[] }>(baseUrl, token, '/admin/media'),
        fetchJson<{ items: ExchangeRate[] }>(baseUrl, token, '/admin/exchange-rates'),
        fetchJson<FeeCatalog>(baseUrl, token, '/payment/fee-catalog'),
      ]);
      setData({
        summary,
        users: users.items,
        trips: trips.items,
        receipts: receipts.items,
        cards: cards.items,
        media: media.items,
        exchangeRates: exchangeRates.items,
        feeCatalog,
      });
      setLastLoadedAt(new Date().toLocaleString('ko-KR'));
    } catch (err) {
      setError(err instanceof Error ? err.message : '관리 데이터를 불러오지 못했습니다.');
    } finally {
      setLoading(false);
    }
  }, [baseUrl, token, saveSettings]);

  useEffect(() => {
    void loadData();
  }, []);

  const selected = useMemo(() => tabs.find((item) => item.key === tab), [tab]);

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark">TS</span>
          <div>
            <strong>TripScript</strong>
            <small>Admin Console</small>
          </div>
        </div>
        <nav>
          {tabs.map((item) => (
            <button
              key={item.key}
              className={item.key === tab ? 'active' : ''}
              onClick={() => setTab(item.key)}
            >
              {item.label}
            </button>
          ))}
        </nav>
      </aside>

      <main className="content">
        <header className="topbar">
          <div>
            <h1>{selected?.label}</h1>
            <p>운영 데이터, Gemini 인식, 카드 수수료 리서치, 개인정보 흐름을 한곳에서 점검합니다.</p>
          </div>
          <button className="primary" onClick={() => void loadData()} disabled={loading}>
            {loading ? '불러오는 중' : '새로고침'}
          </button>
        </header>

        <section className="settings-strip">
          <label>
            API Base URL
            <input value={baseUrl} onChange={(event) => setBaseUrl(event.target.value)} />
          </label>
          <label>
            Admin Token
            <input value={token} onChange={(event) => setToken(event.target.value)} type="password" />
          </label>
          <button onClick={saveSettings}>저장</button>
          {lastLoadedAt && <span className="muted">최근 로드 {lastLoadedAt}</span>}
        </section>

        <section className="toolbar">
          <label>
            전체 검색
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="사용자, 여행, 상호명, 카드명, 통화, 상태 검색"
            />
          </label>
          <div className="chip-row">
            <span className="chip">API {normalizeBaseUrl(baseUrl).replace(/^https?:\/\//, '')}</span>
            <span className="chip">Gemini {data.summary?.system?.receiptGeminiModel || '-'}</span>
            <span className="chip">Card LLM {data.summary?.system?.cardFeeResearchModel || '-'}</span>
          </div>
        </section>

        {error && <div className="error-box">{error}</div>}

        {tab === 'dashboard' && <Dashboard data={data} />}
        {tab === 'insights' && <Insights data={data} />}
        {tab === 'users' && (
          <UsersSection
            users={data.users.filter((user) =>
              includesQuery([user.name, user.nickname, user.displayName, user.phoneNumber, user.kakaoUserId], query),
            )}
            baseUrl={baseUrl}
            token={token}
            onReload={() => void loadData()}
          />
        )}
        {tab === 'trips' && (
          <TripsTable
            trips={data.trips.filter((trip) =>
              includesQuery([trip.name, trip.hostName, trip.inviteCode, ...(trip.participants || [])], query),
            )}
          />
        )}
        {tab === 'receipts' && (
          <ReceiptsTable
            receipts={data.receipts.filter((receipt) =>
              includesQuery([
                receipt.tripName,
                receipt.storeName,
                receipt.paidBy,
                receipt.currencyCode,
                receipt.paymentMethod,
                receipt.cardIssuer,
                receipt.cardBrand,
                ...(receipt.warnings || []),
              ], query),
            )}
          />
        )}
        {tab === 'cards' && (
          <CardsTable
            cards={data.cards.filter((card) =>
              includesQuery([
                card.userName,
                card.userDisplayName,
                card.name,
                card.company,
                card.brand,
                card.cardType,
                card.feeResearchStatus,
                card.feeResearchSummary,
              ], query),
            )}
          />
        )}
        {tab === 'media' && <MediaTable media={data.media.filter((item) => includesQuery([item.kind, item.originalName, item.publicPath], query))} baseUrl={baseUrl} />}
        {tab === 'rates' && <RatesTable rates={data.exchangeRates.filter((rate) => includesQuery([rate.currencyCode, rate.rateDate, rate.source], query))} />}
        {tab === 'catalog' && <Catalog catalog={data.feeCatalog} />}
        {tab === 'recognition' && <RecognitionConsole baseUrl={baseUrl} token={token} />}
        {tab === 'privacy' && <PrivacyPanel data={data} />}
        {tab === 'system' && <SystemPanel data={data} baseUrl={baseUrl} />}
      </main>
    </div>
  );
}

function Dashboard({ data }: { data: DataState }) {
  const s = data.summary;
  return (
    <>
      <section className="metric-grid">
        <Metric label="사용자" value={s?.users} />
        <Metric label="카카오 계정" value={s?.kakaoUsers} detail={`전화 ${s?.phoneUsers || 0}`} />
        <Metric label="여행" value={s?.trips} />
        <Metric label="영수증" value={s?.receipts} />
        <Metric label="카드" value={s?.cards} />
        <Metric label="미디어" value={s?.mediaFiles} detail={formatBytes(s?.mediaStorageBytes)} />
        <Metric label="정산 총액" value={formatKrw(s?.totalSettlementKrw)} />
        <Metric label="평균 인식시간" value={formatDurationMs(s?.recognition?.avgDurationMs)} detail={`${s?.recognition?.totalRecognized || 0}건`} />
        <Metric label="카드 리서치" value={s?.cardResearch?.researchedCount || 0} detail={`실패 ${s?.cardResearch?.failedCount || 0}`} />
        <Metric label="환율 캐시" value={s?.exchangeRates} />
        <Metric label="카드 상품" value={s?.cardProducts} detail={`override ${s?.cardProductOverrides || 0}`} />
      </section>
      <section className="status-grid">
        <StatusCard title="결제수단" value={countText(s?.paymentMethodCounts)} />
        <StatusCard title="통화별 현지금액" value={formatCurrencyTotals(s?.currencyTotals)} />
        <StatusCard title="Gemini 인식" value={countText(s?.recognition?.strategies)} detail={`cache hit ${s?.recognition?.cacheHits || 0}`} />
        <StatusCard title="카드 리서치 상태" value={countText(s?.cardResearch?.statusCounts)} />
      </section>
      <section className="two-column">
        <Panel title="최근 영수증">
          <ReceiptsTable receipts={s?.latestReceipts || []} compact />
        </Panel>
        <Panel title="최근 여행">
          <TripsTable trips={s?.latestTrips || []} compact />
        </Panel>
      </section>
    </>
  );
}

function Insights({ data }: { data: DataState }) {
  const receiptsWithWarnings = data.receipts.filter((receipt) => (receipt.warnings || []).length > 0);
  const slowReceipts = data.receipts
    .filter((receipt) => numberField(receipt.recognition?.durationMs))
    .sort((a, b) => (numberField(b.recognition?.durationMs) || 0) - (numberField(a.recognition?.durationMs) || 0))
    .slice(0, 8);
  const failedResearch = data.cards.filter((card) => card.feeResearchStatus === 'failed');
  const uncertainResearch = data.cards.filter((card) => card.feeResearchStatus === 'uncertain');

  return (
    <div className="insight-layout">
      <Panel title="운영 상태 요약">
        <div className="status-grid compact">
          <StatusCard title="Gemini 모델" value={data.summary?.system?.receiptGeminiModel || '-'} />
          <StatusCard title="인식 평균/최대" value={`${formatDurationMs(data.summary?.recognition?.avgDurationMs)} / ${formatDurationMs(data.summary?.recognition?.maxDurationMs)}`} />
          <StatusCard title="경고 있는 영수증" value={`${receiptsWithWarnings.length}건`} />
          <StatusCard title="수수료 리서치 확인 필요" value={`${failedResearch.length + uncertainResearch.length}건`} />
        </div>
      </Panel>
      <Panel title="인식 경고 영수증">
        <Table
          headers={['날짜', '여행', '상호', '경고', '신뢰도']}
          rows={receiptsWithWarnings.slice(0, 12).map((receipt) => [
            receipt.date,
            receipt.tripName,
            receipt.storeName,
            (receipt.warnings || []).join(' / '),
            receipt.confidence ?? '-',
          ])}
        />
      </Panel>
      <Panel title="느린 인식 요청">
        <Table
          headers={['상호', '여행', '시간', '모델', '캐시']}
          rows={slowReceipts.map((receipt) => [
            receipt.storeName,
            receipt.tripName,
            formatDurationMs(numberField(receipt.recognition?.durationMs)),
            stringValue(receipt.recognition?.llmModel),
            receipt.recognition?.cacheHit ? 'hit' : '-',
          ])}
        />
      </Panel>
      <Panel title="카드 리서치 확인 필요">
        <Table
          headers={['사용자', '카드', '상태', '오류/요약']}
          rows={[...failedResearch, ...uncertainResearch].slice(0, 12).map((card) => [
            card.userDisplayName || card.userName,
            card.name,
            statusLabel(card.feeResearchStatus),
            card.feeResearchError || card.feeResearchSummary || '-',
          ])}
        />
      </Panel>
    </div>
  );
}

function Metric({ label, value, detail }: { label: string; value?: number | string; detail?: string }) {
  return (
    <div className="metric">
      <small>{label}</small>
      <strong>{value ?? '-'}</strong>
      {detail && <span>{detail}</span>}
    </div>
  );
}

function StatusCard({ title, value, detail }: { title: string; value: React.ReactNode; detail?: string }) {
  return (
    <div className="status-card">
      <small>{title}</small>
      <strong>{value}</strong>
      {detail && <span>{detail}</span>}
    </div>
  );
}

function Panel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="panel">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

function UsersSection({
  users,
  baseUrl,
  token,
  onReload,
}: {
  users: AdminUser[];
  baseUrl: string;
  token: string;
  onReload: () => void;
}) {
  const [name, setName] = useState('');
  const [phoneNumber, setPhoneNumber] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const createUser = async () => {
    const trimmedName = name.trim();
    const normalizedPhone = phoneNumber.replace(/\D/g, '');
    if (!trimmedName || !normalizedPhone) {
      setError('이름과 전화번호를 입력해 주세요.');
      return;
    }
    setBusy(true);
    setError(null);
    setMessage(null);
    try {
      const user = await postJson<AdminUser>(baseUrl, token, '/admin/users', {
        name: trimmedName,
        phoneNumber: normalizedPhone,
      });
      setName('');
      setPhoneNumber('');
      setMessage(`${user.name} 사용자를 생성했습니다.`);
      onReload();
    } catch (err) {
      setError(err instanceof Error ? err.message : '사용자 생성에 실패했습니다.');
    } finally {
      setBusy(false);
    }
  };

  const deleteUser = async (user: AdminUser) => {
    const ok = window.confirm(
      `${user.name} 사용자를 삭제할까요?\n\n사용자 계정, 사용자별 카드, 사용자-여행 연결이 삭제됩니다.`,
    );
    if (!ok) return;
    setBusy(true);
    setError(null);
    setMessage(null);
    try {
      await deleteJson(baseUrl, token, `/admin/users/${encodeURIComponent(user.id)}`);
      setMessage(`${user.name} 사용자를 삭제했습니다.`);
      onReload();
    } catch (err) {
      setError(err instanceof Error ? err.message : '사용자 삭제에 실패했습니다.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Panel title="사용자 목록">
      <div className="inline-form">
        <label>
          이름
          <input
            value={name}
            onChange={(event) => setName(event.target.value)}
            placeholder="홍길동"
          />
        </label>
        <label>
          전화번호
          <input
            value={phoneNumber}
            onChange={(event) => setPhoneNumber(event.target.value)}
            placeholder="01012345678"
          />
        </label>
        <button className="primary" onClick={() => void createUser()} disabled={busy}>
          사용자 생성
        </button>
      </div>
      {message && <div className="success-box">{message}</div>}
      {error && <div className="error-box">{error}</div>}
      <Table
        headers={['표시명', '계정명', '로그인', '전화번호', '여행', '카드', 'ID', '관리']}
        rows={users.map((user) => [
          user.displayName || user.nickname || user.name,
          user.name,
          user.isKakaoLinked ? `Kakao ${user.kakaoUserId || ''}` : '전화번호',
          user.phoneNumber,
          user.tripCount,
          user.cardCount,
          <code>{user.id}</code>,
          <button className="danger" onClick={() => void deleteUser(user)} disabled={busy}>
            삭제
          </button>,
        ])}
      />
    </Panel>
  );
}

function TripsTable({ trips, compact = false }: { trips: AdminTrip[]; compact?: boolean }) {
  return (
    <Table
      headers={compact ? ['여행', '대표자', '영수증', '총액'] : ['여행', '기간', '대표자', '참여자', '영수증', '통화별 합계', '총액', '초대코드']}
      rows={trips.map((trip) =>
        compact
          ? [trip.name, trip.hostName, trip.receiptCount, formatKrw(trip.totalKrw)]
          : [
              trip.name,
              `${trip.startDate || '-'} ~ ${trip.endDate || '-'}`,
              trip.hostName,
              (trip.participants || []).join(', '),
              trip.receiptCount,
              formatCurrencyTotals(trip.totalsByCurrency),
              formatKrw(trip.totalKrw),
              trip.inviteCode || '-',
            ],
      )}
    />
  );
}

function ReceiptsTable({ receipts, compact = false }: { receipts: AdminReceipt[]; compact?: boolean }) {
  return (
    <Table
      headers={compact ? ['날짜', '상호', '여행', '정산액'] : ['날짜', '여행', '상호', '결제자', '결제', '카드', '현지금액', '예상', '실제', '정산액', '품목', 'AI', '경고']}
      rows={receipts.map((receipt) =>
        compact
          ? [receipt.date, receipt.storeName, receipt.tripName, formatKrw(receipt.settlementKrwAmount)]
          : [
              receipt.date,
              receipt.tripName,
              receipt.storeName,
              receipt.paidBy,
              receipt.paymentMethod,
              receipt.paymentMethod === 'cash'
                ? '현금'
                : [receipt.cardIssuer, receipt.cardBrand, receipt.cardLast4 ? `끝 ${receipt.cardLast4}` : '']
                    .filter(Boolean)
                    .join(' · ') || '-',
              `${Number(receipt.amount || 0).toLocaleString('ko-KR')} ${receipt.currencyCode}`,
              formatKrw(receipt.estimatedKrwAmount),
              receipt.actualKrwAmount ? formatKrw(receipt.actualKrwAmount) : '-',
              formatKrw(receipt.settlementKrwAmount),
              receipt.itemCount,
              <div className="stacked-cell">
                <span>{stringValue(receipt.recognition?.llmProvider)} / {stringValue(receipt.recognition?.llmModel)}</span>
                <small>{formatDurationMs(numberField(receipt.recognition?.durationMs))} · {receipt.recognition?.cacheHit ? 'cache hit' : 'fresh'}</small>
                <small>confidence {receipt.confidence ?? '-'}</small>
              </div>,
              (receipt.warnings || []).length ? (receipt.warnings || []).join(' / ') : '-',
            ],
      )}
    />
  );
}

function CardsTable({ cards }: { cards: AdminCard[] }) {
  return (
    <Panel title="사용자 카드">
      <div className="status-grid compact">
        <StatusCard title="전체 카드" value={`${cards.length}장`} />
        <StatusCard title="리서치 완료" value={`${cards.filter((card) => card.feeResearchStatus === 'done').length}장`} />
        <StatusCard title="확인 필요" value={`${cards.filter((card) => ['failed', 'uncertain'].includes(card.feeResearchStatus || '')).length}장`} />
        <StatusCard title="면제 후보" value={`${cards.filter((card) => card.networkFeeWaived || card.issuerFeeWaived).length}장`} />
      </div>
      <Table
        headers={['사용자', '카드명', '카드사', '종류', '브랜드', '끝번호', '브랜드 수수료', '카드사 수수료', '리서치', '요약/출처']}
        rows={cards.map((card) => [
          card.userDisplayName || card.userName,
          card.name,
          card.company,
          card.cardType,
          card.brand,
          card.last4 || '-',
          card.networkFeeWaived ? '면제' : percent(card.brandFeeRate),
          card.issuerFeeWaived
            ? '면제'
            : card.issuerFeeType === 'fixed_usd'
              ? `$${card.issuerFeeFixedUsd || 0}`
              : percent(card.issuerFeeRate),
          <span className={`badge ${card.feeResearchStatus || 'idle'}`}>{statusLabel(card.feeResearchStatus)}</span>,
          <div className="stacked-cell">
            <span>{card.feeResearchSummary || card.productOverrideNote || card.feeResearchError || '-'}</span>
            {(card.feeResearchSources || []).slice(0, 2).map((source, index) => (
              source.url ? <a key={index} href={source.url} target="_blank" rel="noreferrer">{source.title || source.url}</a> : null
            ))}
          </div>,
        ])}
      />
    </Panel>
  );
}

function MediaTable({ media, baseUrl }: { media: AdminMedia[]; baseUrl: string }) {
  const origin = normalizeBaseUrl(baseUrl).replace(/\/api\/v1$/, '');
  return (
    <Panel title="업로드 미디어">
      <Table
        headers={['종류', '파일', '용량', '생성일', '경로']}
        rows={media.map((item) => [
          item.kind,
          item.originalName || item.contentType || '-',
          formatBytes(item.sizeBytes),
          item.createdAt,
          <a href={`${origin}${item.publicPath}`} target="_blank" rel="noreferrer">{item.publicPath}</a>,
        ])}
      />
    </Panel>
  );
}

function RatesTable({ rates }: { rates: ExchangeRate[] }) {
  return (
    <Panel title="환율 캐시">
      <Table
        headers={['통화', '날짜', 'KRW/Unit', '라벨', '출처']}
        rows={rates.map((rate) => [
          rate.currencyCode,
          rate.rateDate,
          Number(rate.krwPerUnit).toLocaleString('ko-KR'),
          rate.asOfLabel,
          rate.source,
        ])}
      />
    </Panel>
  );
}

function Catalog({ catalog }: { catalog?: FeeCatalog }) {
  if (!catalog) return <Panel title="수수료 DB">데이터가 없습니다.</Panel>;
  return (
    <div className="catalog-layout">
      <Panel title="국제브랜드 수수료">
        <Table
          headers={['브랜드', '수수료', '별칭']}
          rows={catalog.brands.map((brand) => [brand.label, percent(brand.rate), brand.aliases.join(', ')])}
        />
      </Panel>
      <Panel title="카드사 대표 수수료">
        <Table
          headers={['카드사', '수수료', '별칭']}
          rows={catalog.issuers.map((issuer) => [issuer.label, percent(issuer.rate), issuer.aliases.join(', ')])}
        />
      </Panel>
      <Panel title="카드 상품 카탈로그">
        <Table
          headers={['상품', '회사', '종류', '브랜드', '카테고리']}
          rows={catalog.products.map((product) => [
            product.name,
            product.company,
            product.cardType,
            product.brand,
            product.category,
          ])}
        />
      </Panel>
    </div>
  );
}

function RecognitionConsole({ baseUrl, token }: { baseUrl: string; token: string }) {
  const [file, setFile] = useState<File | null>(null);
  const [currencyCode, setCurrencyCode] = useState('KRW');
  const [strategy, setStrategy] = useState('cloud_gemini');
  const [ocrText, setOcrText] = useState('');
  const [upload, setUpload] = useState<UploadResponse | null>(null);
  const [result, setResult] = useState<RecognitionResult | null>(null);
  const [compareResult, setCompareResult] = useState<RecognitionResult | null>(null);
  const [timing, setTiming] = useState<{ uploadMs?: number; recognizeMs?: number; totalMs?: number }>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const imagePreviewUrl = useMemo(() => (file ? URL.createObjectURL(file) : null), [file]);
  const uploadedImageUrl = upload?.url || null;

  useEffect(() => {
    return () => {
      if (imagePreviewUrl) URL.revokeObjectURL(imagePreviewUrl);
    };
  }, [imagePreviewUrl]);

  const runImageRecognition = async () => {
    if (!file) {
      setError('영수증 이미지를 먼저 선택해 주세요.');
      return;
    }
    setBusy(true);
    setError(null);
    setResult(null);
    setTiming({});
    try {
      const totalStart = performance.now();
      const uploadStart = performance.now();
      const uploaded = await uploadReceiptImage(baseUrl, token, file);
      const uploadMs = performance.now() - uploadStart;
      setUpload(uploaded);
      const recognizeStart = performance.now();
      const recognized = await postJson<RecognitionResult>(
        baseUrl,
        token,
        '/receipts/recognize',
        {
          imagePath: uploaded.path,
          imageUrl: uploaded.url,
          currencyCode,
          recognitionStrategy: strategy,
        },
      );
      const recognizeMs = performance.now() - recognizeStart;
      setTiming({
        uploadMs,
        recognizeMs,
        totalMs: performance.now() - totalStart,
      });
      setResult(recognized);
      if (typeof recognized.ocrText === 'string') {
        setOcrText(recognized.ocrText);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : '인식 요청에 실패했습니다.');
    } finally {
      setBusy(false);
    }
  };

  const runCompare = async () => {
    if (!upload?.path && !file) {
      setError('비교할 영수증 이미지를 먼저 선택해 주세요.');
      return;
    }
    setBusy(true);
    setError(null);
    setCompareResult(null);
    try {
      const uploaded = upload || (file ? await uploadReceiptImage(baseUrl, token, file) : null);
      if (!uploaded) throw new Error('이미지 업로드 정보가 없습니다.');
      setUpload(uploaded);
      const started = performance.now();
      const compared = await postJson<RecognitionResult>(
        baseUrl,
        token,
        '/receipts/recognize/compare',
        {
          imagePath: uploaded.path,
          imageUrl: uploaded.url,
          currencyCode,
          strategies: ['cloud_gemini', 'hybrid'],
        },
      );
      setTiming((prev) => ({ ...prev, totalMs: performance.now() - started }));
      setCompareResult(compared);
    } catch (err) {
      setError(err instanceof Error ? err.message : '파이프라인 비교 요청에 실패했습니다.');
    } finally {
      setBusy(false);
    }
  };

  const runTextRecognition = async () => {
    if (!ocrText.trim()) {
      setError('OCR 원문 텍스트를 입력해 주세요.');
      return;
    }
    setBusy(true);
    setError(null);
    setResult(null);
    setTiming({});
    try {
      const recognizeStart = performance.now();
      const recognized = await postJson<RecognitionResult>(
        baseUrl,
        token,
        '/receipts/recognize-text',
        {
          ocrText,
          currencyCode,
          imagePath: upload?.path,
          imageUrl: upload?.url,
        },
      );
      setTiming({
        recognizeMs: performance.now() - recognizeStart,
        totalMs: performance.now() - recognizeStart,
      });
      setResult(recognized);
    } catch (err) {
      setError(err instanceof Error ? err.message : '텍스트 파싱 요청에 실패했습니다.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="recognition-layout">
      <Panel title="영수증 이미지 인식">
        <div className="form-grid">
          <label>
            이미지
            <input
              type="file"
              accept="image/*"
              onChange={(event) => {
                setFile(event.target.files?.[0] || null);
                setUpload(null);
                setResult(null);
              }}
            />
          </label>
          <label>
            기본 통화
            <select value={currencyCode} onChange={(event) => setCurrencyCode(event.target.value)}>
              {['KRW', 'USD', 'EUR', 'JPY', 'CNY', 'GBP', 'CHF', 'SEK', 'NOK', 'DKK', 'ISK', 'PLN', 'CZK', 'HUF'].map((code) => (
                <option key={code} value={code}>{code}</option>
              ))}
            </select>
          </label>
          <label>
            인식 전략
            <select value={strategy} onChange={(event) => setStrategy(event.target.value)}>
              <option value="cloud_gemini">Gemini 기본</option>
              <option value="hybrid">OCR + LLM fallback</option>
              <option value="hybrid_flatten">OCR flatten</option>
            </select>
          </label>
        </div>

        <div className="recognition-actions">
          <button className="primary" onClick={() => void runImageRecognition()} disabled={busy || !file}>
            {busy ? '처리 중' : '이미지 업로드 후 OCR/LLM 실행'}
          </button>
          <button onClick={() => void runCompare()} disabled={busy || (!file && !upload)}>
            Gemini/OCR 비교
          </button>
          <button onClick={() => void runTextRecognition()} disabled={busy || !ocrText.trim()}>
            OCR 텍스트만 다시 파싱
          </button>
        </div>

        {error && <div className="error-box">{error}</div>}

        <div className="preview-grid">
          <div className="image-preview">
            {imagePreviewUrl ? (
              <img src={imagePreviewUrl} alt="선택한 영수증" />
            ) : (
              <span>이미지를 선택하면 미리보기가 표시됩니다.</span>
            )}
          </div>
          <div className="summary-list">
            <InfoRow label="업로드 URL" value={uploadedImageUrl || '-'} />
            <InfoRow label="파일 크기" value={upload ? formatBytes(upload.sizeBytes) : '-'} />
            <InfoRow label="업로드 시간" value={formatDurationMs(timing.uploadMs)} />
            <InfoRow label="인식 요청 시간" value={formatDurationMs(timing.recognizeMs)} />
            <InfoRow label="전체 처리 시간" value={formatDurationMs(timing.totalMs)} />
            <InfoRow
              label="서버 인식 시간"
              value={formatDurationMs(numberField(result?.recognition && (result.recognition as Record<string, unknown>).durationMs))}
            />
            <InfoRow
              label="파이프라인"
              value={stringValue(result?.recognition && (result.recognition as Record<string, unknown>).pipeline)}
            />
            <InfoRow label="상호명" value={stringValue(result?.storeName)} />
            <InfoRow label="금액" value={result ? `${Number(result.amount || 0).toLocaleString('ko-KR')} ${result.currencyCode || ''}` : '-'} />
            <InfoRow label="날짜" value={stringValue(result?.date)} />
            <InfoRow label="신뢰도" value={result ? String(result.confidence ?? '-') : '-'} />
          </div>
        </div>
      </Panel>

      <Panel title="OCR 원문">
        <textarea
          className="ocr-textarea"
          value={ocrText}
          onChange={(event) => setOcrText(event.target.value)}
          placeholder="이미지 인식 후 OCR 원문이 여기에 표시됩니다. 직접 붙여넣고 텍스트 파싱만 다시 실행할 수도 있습니다."
        />
      </Panel>

      <Panel title="인식 결과 JSON">
        <pre className="json-viewer">{result ? JSON.stringify(result, null, 2) : '아직 인식 결과가 없습니다.'}</pre>
      </Panel>

      <Panel title="파이프라인 비교 JSON">
        <pre className="json-viewer">{compareResult ? JSON.stringify(compareResult, null, 2) : '아직 비교 결과가 없습니다.'}</pre>
      </Panel>
    </div>
  );
}

function PrivacyPanel({ data }: { data: DataState }) {
  const receiptImages = data.media.filter((item) => item.kind === 'receipt');
  const cardsWithLast4 = data.cards.filter((card) => card.last4);
  const cloudRecognized = data.receipts.filter((receipt) => receipt.recognition?.llmProvider === 'gemini');
  return (
    <div className="insight-layout">
      <Panel title="개인정보/외부 AI 점검">
        <div className="status-grid compact">
          <StatusCard title="Gemini 전송 후보" value={`${cloudRecognized.length}건`} detail="영수증 이미지 인식" />
          <StatusCard title="저장된 영수증 이미지" value={`${receiptImages.length}개`} detail={formatBytes(receiptImages.reduce((sum, item) => sum + (item.sizeBytes || 0), 0))} />
          <StatusCard title="끝번호 저장 카드" value={`${cardsWithLast4.length}장`} detail="전체 카드번호 미저장" />
          <StatusCard title="API Key 위치" value="Backend only" detail="앱 APK에 미포함" />
        </div>
      </Panel>
      <Panel title="심사 대응 포인트">
        <div className="checklist">
          <label><input type="checkbox" checked readOnly /> Gemini API key는 백엔드 서버에만 보관합니다.</label>
          <label><input type="checkbox" checked readOnly /> 카드번호 전체, CVC, 유효기간은 저장하지 않습니다.</label>
          <label><input type="checkbox" checked readOnly /> 카드 끝 4자리는 식별 편의용으로만 선택 저장합니다.</label>
          <label><input type="checkbox" checked readOnly /> 같은 영수증 이미지는 서버 캐시로 중복 외부 전송을 줄입니다.</label>
          <label><input type="checkbox" checked readOnly /> 로컬 OCR/LLM 파이프라인을 fallback으로 유지할 수 있는 구조입니다.</label>
          <label><input type="checkbox" readOnly /> 운영 단계에서는 사용자 동의, 이미지 보관기간, 민감정보 마스킹을 추가해야 합니다.</label>
        </div>
      </Panel>
      <Panel title="외부 AI 사용 문구">
        <pre className="json-viewer privacy-copy">
{`클라우드 LLM은 정확도 검증을 위해 선택했지만, 개인정보 보호를 위해 백엔드 통제, 최소 저장, 카드번호 미수집, 사용자 동의, 로컬 대체 파이프라인을 전제로 설계했습니다.`}
        </pre>
      </Panel>
      <Panel title="AI 인식 사용 현황">
        <Table
          headers={['상호', '여행', 'Provider', 'Model', '시간', '경고']}
          rows={data.receipts.slice(0, 20).map((receipt) => [
            receipt.storeName,
            receipt.tripName,
            stringValue(receipt.recognition?.llmProvider),
            stringValue(receipt.recognition?.llmModel),
            formatDurationMs(numberField(receipt.recognition?.durationMs)),
            (receipt.warnings || []).join(' / ') || '-',
          ])}
        />
      </Panel>
    </div>
  );
}

function SystemPanel({ data, baseUrl }: { data: DataState; baseUrl: string }) {
  const system = data.summary?.system;
  return (
    <div className="insight-layout">
      <Panel title="서버 설정">
        <div className="summary-list">
          <InfoRow label="API Base URL" value={baseUrl} />
          <InfoRow label="환경" value={system?.appEnv || '-'} />
          <InfoRow label="DB" value={system?.databaseUrl || '-'} />
          <InfoRow label="Storage" value={system?.storageDir || '-'} />
          <InfoRow label="미디어 용량" value={formatBytes(data.summary?.mediaStorageBytes)} />
          <InfoRow label="DB 인덱스" value={`${data.summary?.dbIndexCount || 0}개`} />
        </div>
      </Panel>
      <Panel title="AI/인식 설정">
        <div className="summary-list">
          <InfoRow label="영수증 전략" value={system?.receiptRecognitionStrategy || '-'} />
          <InfoRow label="Gemini 모델" value={system?.receiptGeminiModel || '-'} />
          <InfoRow label="Cloud flatten" value={String(system?.receiptCloudFlattenEnabled ?? '-')} />
          <InfoRow label="카드 리서치" value={String(system?.cardFeeResearchEnabled ?? '-')} />
          <InfoRow label="카드 리서치 모델" value={system?.cardFeeResearchModel || '-'} />
        </div>
      </Panel>
      <Panel title="데이터 볼륨">
        <div className="metric-grid small">
          <Metric label="사용자" value={data.summary?.users} />
          <Metric label="여행" value={data.summary?.trips} />
          <Metric label="영수증" value={data.summary?.receipts} />
          <Metric label="카드" value={data.summary?.cards} />
          <Metric label="미디어" value={data.summary?.mediaFiles} />
          <Metric label="환율" value={data.summary?.exchangeRates} />
          <Metric label="카드상품" value={data.summary?.cardProducts} />
          <Metric label="override" value={data.summary?.cardProductOverrides} />
        </div>
      </Panel>
      <Panel title="DB 인덱스">
        <Table
          headers={['테이블', '인덱스']}
          rows={(data.summary?.dbIndexes || []).map((index) => [
            index.table,
            <code>{index.name}</code>,
          ])}
        />
      </Panel>
    </div>
  );
}

function InfoRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="info-row">
      <small>{label}</small>
      <span>{value || '-'}</span>
    </div>
  );
}

function stringValue(value: unknown) {
  if (value === null || value === undefined || value === '') return '-';
  return String(value);
}

function Table({ headers, rows }: { headers: string[]; rows: Array<Array<React.ReactNode>> }) {
  if (!rows.length) return <div className="empty">표시할 데이터가 없습니다.</div>;
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>{headers.map((header) => <th key={header}>{header}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((row, rowIndex) => (
            <tr key={rowIndex}>
              {row.map((cell, cellIndex) => <td key={cellIndex}>{cell}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function formatCurrencyTotals(totals?: Record<string, number>) {
  if (!totals || !Object.keys(totals).length) return '-';
  return Object.entries(totals)
    .map(([currency, amount]) => `${Number(amount).toLocaleString('ko-KR')} ${currency}`)
    .join(' · ');
}

createRoot(document.getElementById('root')!).render(<App />);
