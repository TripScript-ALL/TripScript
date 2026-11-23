# TripScript Backend DB Schema

TripScript backend uses SQLite in Docker. The live database file is mounted under `storage/tripscript.db`, so container rebuilds do not delete service data as long as the storage volume remains.

The schema is normalized around user identity while keeping Flutter compatibility. The API still returns participant names as strings, but backend rows keep user ids where the app can identify the real account.

## Identity And Trip Tables

| Table | Key | Purpose |
| --- | --- | --- |
| `users` | `id` | Service users. Kakao users store `kakao_user_id`; visible app name is `nickname` when present, otherwise `name`. |
| `trips` | `id` | Trip metadata. `host_user_id` is the normalized owner reference and `host_name` is the current display snapshot. |
| `trip_participants` | `(trip_id, name)` | Ordered trip participants. `user_id` links a participant to a registered user when possible; `name` remains the display snapshot for anonymous/manual participants. |
| `user_trips` | `(user_id, trip_id)` | Which trips appear in each user's trip list and in what order. |

### Naming Rule

- `users.name`: canonical login identity or Kakao fallback name.
- `users.nickname`: user-facing display name.
- `displayName`: `nickname` if present, otherwise `name`.
- Trip, receipt, and split screens should show the display name.
- Backend treats `name`, `nickname`, and display name as aliases for permission checks.
- When a user changes nickname, backend synchronizes existing trip host labels, participant labels, receipt payer labels, and item split labels from old aliases to the new display name.

This keeps old string-based Flutter screens working while letting the DB move toward `user_id` joins.

## Auth And Account Lifecycle

Current auth storage:

| Column | Purpose |
| --- | --- |
| `users.access_token` | Compatibility token field. The API also issues JWTs through `/auth/kakao` and `/me`. |
| `users.kakao_user_id` | Kakao account identifier. This is the stable external login key. |
| `users.nickname` | User-facing display name. |
| `users.settlement_bank_name` | Bank name used when other participants send settlement money. |
| `users.settlement_account_number` | Settlement receiving account number. |
| `users.settlement_account_holder` | Settlement account holder label. |

Account deletion behavior:

- Delete user row.
- Delete user's card profiles.
- Remove the user from participant rows.
- Remove `user_trips` rows.
- If the deleted user owns a trip, delete that trip for all users.
- Shared-trip receipt history can remain as display-name snapshots when needed for settlement history.

## Receipt Tables

| Table | Key | Purpose |
| --- | --- | --- |
| `receipts` | `id` | Receipt payment metadata, selected payment method, card/cash fee fields, exchange-rate fields, recognition payload, and server-calculated KRW estimate. |
| `receipt_items` | `id` | Itemized receipt rows. |
| `receipt_item_splits` | `(receipt_item_id, person_name)` | Per-person quantity allocation for each receipt item. This is still name-based for Flutter compatibility; future migration should add participant/user references. |

Important receipt fields:

- `paid_by`: display-name snapshot of the payer.
- `currency_code`: local receipt currency.
- `payment_method`: `card` or `cash`.
- `actual_krw_amount`: user-entered actual card billing amount. If present, settlement uses it first.
- `estimated_krw_amount`: backend estimated settlement amount.
- `local_to_usd_rate`, `usd_amount`, `usd_to_krw_rate`, `base_krw_amount`: card calculation trace.
- `exchange_rate_source`, `rate_date_label`: exchange-rate basis shown in the app.
- `recognition_json`: Gemini/OCR recognition metadata.

Settlement results are not persisted as a separate table. They are calculated from receipts, receipt items, item splits, participants, and user account snapshots whenever `/settlement` is requested.

The API returns both:

- `grossTransfers`: original per-receipt obligation flow to each payer.
- `transfers`: netted final settlement after offsetting mutual obligations.
- `receiptBreakdown`: trace data for explaining which receipt/items produced each obligation.

## Card And Fee Tables

| Table | Key | Purpose |
| --- | --- | --- |
| `card_profiles` | `id` | User-owned cards. Separated by `user_id`; stores card name, issuer, brand, type, last4, fee fields, and researched fee metadata. |
| `card_fee_catalog` | `id` | Representative issuer/brand overseas fee rates. |
| `card_issuer_fee_policies` | `id` | Issuer + card type + optional brand policy for credit/check overseas purchase fees. |
| `card_products` | `id` | Card product name catalog. |
| `card_product_fee_overrides` | `id` | Product-level exceptions such as travel-card waivers, cashback, or foreign-wallet behavior. |

### Card Research Fields

`card_profiles` contains LLM research metadata:

| Field | Purpose |
| --- | --- |
| `fee_research_status` | `idle`, `running`, `done`, `uncertain`, `failed` |
| `fee_research_summary` | Short explanation extracted by the LLM |
| `fee_research_sources_json` | Source title/url list |
| `fee_research_checked_at` | Last research timestamp |
| `fee_research_error` | Short failure message |

Card fee research flow:

```text
card_profiles insert/update
→ background research task
→ DuckDuckGo search result collection
→ Ollama qwen2.5:3b JSON extraction
→ card profile fee fields update
```

This does not use Gemini quota. It uses `RECEIPT_LLM_BASE_URL` and `CARD_FEE_RESEARCH_MODEL`.

## Exchange And Media Tables

| Table | Key | Purpose |
| --- | --- | --- |
| `exchange_rates` | `(currency_code, rate_date)` | Cached KRW exchange rates by payment date. |
| `media_files` | `id` | Uploaded trip cover and receipt image metadata. Actual files live under `storage/media`. |

Media rows store:

- media kind: `trip_cover`, `receipt`, etc.
- original filename
- content type
- storage path
- public path
- size bytes
- created timestamp

## Receipt Recognition State

Gemini recognition does not have a separate table yet. It stores results in:

- `receipts.recognition_json`
- `receipts.image_path`
- `media_files`

The runtime also keeps a small in-memory Gemini result cache keyed by:

- image hash
- currency code
- Gemini model
- preprocessing mode
- image max edge and JPEG quality

This cache reduces duplicate Gemini calls for the same receipt image but is not persistent across API container restarts.

## Current Normalization Boundary

Implemented now:

- Users are first-class records.
- Kakao login maps to `users.kakao_user_id`.
- Trips can point to their owner through `host_user_id`.
- Participants can point to users through `trip_participants.user_id`.
- User card profiles are separated by `user_id`.
- Card research metadata is persisted with the card profile.
- Media metadata is persisted separately from receipt rows.

Still intentionally compatible with the current Flutter model:

- `participants`, `paidBy`, and item `quantityByPerson` are returned as display strings.
- Receipt split rows are still keyed by `person_name`.
- Receipt payer is stored as a display snapshot instead of a normalized `payer_user_id`.

Recommended next migration:

- Add `payer_user_id` to `receipts`.
- Add `participant_user_id` or `trip_participant_id` to `receipt_item_splits`.
- Return structured participants (`id`, `displayName`, `role`) to the frontend.
- Keep a derived string list only for older screens.

## Indexing

The backend creates indexes for common access paths:

- `user_trips(user_id)` and `user_trips(trip_id)`.
- `trips(host_user_id)`.
- `trip_participants(trip_id)` and `trip_participants(user_id)`.
- receipts and receipt items by parent id.
- card profiles by user.
- card products and issuer fee policies by lookup fields.
- media files by kind.

## Privacy Notes

Current privacy-oriented design choices:

- Full card number, CVC, and card expiry are not stored.
- Card last4 is optional and used only for user-side identification.
- Gemini API key is backend-only.
- Receipt images are uploaded to the backend first; clients do not directly call cloud AI APIs.
- Recognition output stores app schema fields and metadata, not arbitrary LLM transcripts by default.
- Future production hardening should add image retention periods, deletion jobs, and sensitive-pattern masking before cloud recognition.
