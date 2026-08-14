# Restaurant Ops

A restaurant operations platform with a responsive Flutter client and a
FastAPI database API. Authenticated recordings are translated to English by
Sarvam, analyzed into structured operational reports by OpenAI, and surfaced
in both the Dashboard activity feed and Reports.

## What is included

- Flutter Web with Material 3, Riverpod, GoRouter, responsive drawer/navigation rail, dark theme, and authenticated route guards
- Login, workspace-aware dashboard and reports, authenticated AI audio processing, and settings screens
- FastAPI with async PostgreSQL access, user registration, login, token refresh, current-user, liveness, and database-readiness APIs
- Argon2 password hashing and short-lived access plus refresh JWTs
- Docker images, Docker Compose, Nginx SPA/proxy configuration, environment template, and Railway config-as-code

## Repository layout

```text
lib/
  models/       API-facing domain models
  providers/    Riverpod state and dependency providers
  routes/       GoRouter routes and auth guards
  screens/      Application pages
  services/     HTTP, auth, and token persistence
  theme/        Material 3 themes
  utils/        Constants and validation
  widgets/      Shared responsive UI
backend/
  api/          Route handlers and schemas
  auth/         JWT, hashing, and auth dependencies
  database/     SQLAlchemy engine, sessions, and bootstrap
  middleware/   HTTP middleware
  models/       Database models
  services/     Domain services
  utils/        Settings
```

## Run everything with Docker

Prerequisites: Docker Engine with Compose.

```bash
cp .env.example .env
docker compose up --build
```

Open the web app at `http://localhost:8080`. API documentation is at `http://localhost:8000/docs`. Compose creates the database schema on startup for local use.

Local development can optionally seed an administrator from environment-only
values. The seed is disabled by default and is configured with
`SEED_DEFAULT_ADMIN`, `DEFAULT_ADMIN_EMAIL`, `DEFAULT_ADMIN_FULL_NAME`, and
`DEFAULT_ADMIN_PASSWORD`. Keep those values in the ignored `.env` file or your
shell environment. Seeding is hard-disabled unless `APP_ENV` is `development`,
`dev`, or `local`, even if the seed flag is accidentally enabled.

To create or synchronize the development account explicitly on Windows
PowerShell without writing its plaintext password to the database:

```powershell
$env:APP_ENV='development'
$env:SEED_DEFAULT_ADMIN='true'
.\.venv\Scripts\python.exe -m backend.database.init_db
```

Set the three `DEFAULT_ADMIN_*` variables to credentials of your choice before
running the command. The seed will fail closed if any required value is absent.

The seed hashes the password with the same Argon2id implementation used by
login and stores only the resulting salted hash.

To create an additional operator account:

```bash
curl -X POST http://localhost:8000/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"operator@example.com","full_name":"Demo Operator","password":"change-me-now"}'
```

Use either account's email and password on the login screen.

## Run locally without Docker

On Windows, after `.venv` and `.env` have been created, the normal one-command
launcher applies Alembic migrations, starts the API, and opens Flutter in
Chrome:

```powershell
.\start_dev.ps1
```

Use `.\start_dev.ps1 -WebServer` when a browser should be opened manually.
The launcher runs a non-billable preflight first, verifies the database,
migration head, private audio storage, provider-key presence, and FFmpeg, and
refuses to take over a port owned by another project. Use `-BackendPort 8010`
only when a different port is intentionally needed; Flutter receives the same
URL automatically. Add `-CheckProviderDns` for DNS-only provider diagnostics.

FFmpeg and FFprobe must be available on `PATH` (or configured with
`FFMPEG_BINARY` and `FFPROBE_BINARY`). On Windows they can be installed with
`winget install --id Gyan.FFmpeg --exact`. The backend Docker image installs
FFmpeg automatically.

### API

Use Python 3.12+. Local development uses an automatically created SQLite
database, so PostgreSQL and Docker are not required.

```bash
python -m venv .venv
source .venv/bin/activate              # Windows: .venv\Scripts\activate
pip install -r backend/requirements-dev.txt
uvicorn backend.main:app --reload --port 8000
```

Copy `.env.example` to `.env` before starting the API if you want startup to
seed the development administrator. The default database is
`backend/restaurant_ops.db`; the development schema is created on startup. To
use PostgreSQL, set `DATABASE_URL` to an asyncpg connection URL.
Production environments should set `AUTO_CREATE_TABLES=false` and apply
versioned database migrations before startup.

Run migrations from the project root:

```powershell
.\.venv\Scripts\alembic.exe -c backend\alembic.ini upgrade head
```

The baseline adopts a compatible `users` table created by earlier development
versions without recreating it, so existing accounts and password hashes are
preserved. Fresh databases receive `users` before `refresh_sessions`.

### Web client

```bash
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000/api/v1
```

`API_BASE_URL` is optional for local web development. Without it, Flutter uses
the page's current host and API port `8000`. Development CORS accepts
`localhost` and `127.0.0.1` on any port, including Flutter's random web port.

Production build:

```bash
flutter build web --release --dart-define=API_BASE_URL=https://api.example.com/api/v1
```

## API endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Process liveness |
| `GET` | `/api/v1/health` | Database readiness |
| `POST` | `/api/v1/auth/register` | Create an operator |
| `POST` | `/api/v1/auth/login` | Issue access and refresh JWTs |
| `POST` | `/api/v1/auth/refresh` | Rotate the presented refresh token into a new token pair |
| `POST` | `/api/v1/auth/logout` | Revoke the presented authenticated refresh session |
| `GET` | `/api/v1/auth/me` | Return the authenticated operator |
| `GET` | `/api/v1/workspaces/context` | Return the caller's database-backed workspace, role, and location access |
| `POST` | `/api/v1/workspaces` | Create a workspace with an owner membership and first location |
| `POST` | `/api/v1/workspaces/{id}/locations` | Create a location as a workspace owner |
| `GET` | `/api/v1/workspaces/{id}/members` | List members as a workspace owner |
| `POST` | `/api/v1/workspaces/{id}/members` | Add an existing operator as an owner or member |
| `GET` | `/api/v1/dashboard?workspace_id=...&location_id=...&service_date=YYYY-MM-DD` | Return the authorized location's daily Dashboard snapshot and recent activity |
| `GET` | `/api/v1/reports?workspace_id=...&start_date=...&end_date=...` | Return an authorized workspace report, optionally filtered by location |
| `GET` | `/api/v1/reports/export.csv?workspace_id=...&start_date=...&end_date=...` | Export authorized workspace report rows as CSV |
| `GET` | `/api/v1/reports/{report_id}/pdf` | Download a tenant-authorized A4 AI audio report PDF |
| `POST` | `/api/v1/audio-uploads` | Validate/store authenticated multipart audio, run AI processing, and create a location-scoped Dashboard activity |
| `GET` | `/api/v1/audio-uploads?workspace_id=...&location_id=...&limit=50` | List the authenticated operator's upload history for an authorized location |
| `POST` | `/api/v1/audio-uploads/{id}/retry?workspace_id=...&location_id=...` | Resume failed AI processing from the stored audio or persisted English transcript |
| `GET` | `/api/v1/audio-uploads/{id}/audio?workspace_id=...&location_id=...` | Stream authenticated, browser-playable audio without exposing its storage key |
| `GET` | `/api/v1/audio-uploads/{id}/download?workspace_id=...&location_id=...` | Download an owned, ready audio object in the active tenant context |
| `DELETE` | `/api/v1/audio-uploads/{id}?workspace_id=...&location_id=...` | Delete owned audio content and its generated report/activity |

Dashboard responses are sourced from the date-scoped
`dashboard_daily_snapshots`, `dashboard_hourly_sales`, and
`dashboard_activities` tables. Dates without stored operational data return a
successful empty payload; the API does not manufacture demo metrics.

Workspace membership is checked from the database on every protected request.
Owners can create locations and manage memberships; members have read access to
Dashboard and Reports. Authenticated callers receive HTTP 404 for workspaces or
locations they cannot access. `report_locations` remains the canonical location
table for both reporting and workspace context.

The workspace migration deliberately leaves existing locations, Dashboard
snapshots, and activities unowned. These legacy rows are not visible through
tenant-scoped APIs until an operator performs an explicit, reviewed ownership
backfill; the migration never guesses ownership.

Audio uploads support valid MP3, WAV, M4A, AAC, OGG/Opus (including normal
WhatsApp PTT), and MP4 audio files up to 100 MiB and two hours. The API streams
the upload to private storage, verifies its real container/codec with FFprobe,
and normalizes a temporary provider copy to 16 kHz mono PCM WAV with FFmpeg;
the original remains available for playback. Recordings up to 30 seconds use
Sarvam's synchronous `saaras:v3` translate path. Longer recordings use the
asynchronous batch path with a persisted job ID, bounded polling, and
restart-safe resume. `unknown` enables Sarvam language auto-detection and every
successful provider output used for analysis is English.

After translation, OpenAI structured output is validated and one persisted
operations report plus one `AI Audio Monitor` Dashboard activity are committed
atomically. A failed Sarvam upload remains retryable; a persisted transcript is
reused if only OpenAI failed. Completed duplicate audio returns the existing
upload/report IDs without another provider call. Reports include the full
English transcript and can be downloaded as tenant-authorized, paginated A4
PDFs. Configure
`SARVAM_API_KEY` and `OPENAI_API_KEY` only through environment secrets.
`AUDIO_LOCAL_STORAGE_PATH` must point to durable, non-public storage. The
included Compose configuration mounts a named volume; multi-replica production
deployments should replace the local storage adapter with shared S3-compatible
object storage and configure a real malware scanner.

## Production configuration

Never deploy the example secrets. At minimum, set `DATABASE_URL`, a randomly generated `JWT_SECRET_KEY`, `CORS_ORIGINS`, `APP_ENV=production`, `AUTO_CREATE_TABLES=false`, `SEED_DEFAULT_ADMIN=false`, and `DOCS_ENABLED=false`. Terminate TLS at the platform/load balancer and keep PostgreSQL private.

The included `railway.toml` deploys the API from `backend/Dockerfile`. Add a Railway PostgreSQL service, map its async connection URL to `DATABASE_URL`, and set the remaining variables above. The Dockerfile honors Railway's injected `PORT`.

The browser stores JWTs in web storage for this foundation. Refresh tokens are
hashed server-side, rotated on every exchange, revoked on logout, and their
reuse revokes the user's other active refresh sessions. For a hardened public
deployment, prefer a same-origin backend-for-frontend using Secure, HttpOnly,
SameSite cookies so browser scripts cannot read session credentials.

## Audio processing boundary

The audio route authorizes the selected location before storage and returns a
completed processing result containing the English transcript, structured
analysis, report ID, activity ID, location, source, and processing time.
External AI failures return a controlled error, leave retryable upload
metadata, and do not create a partial report or Dashboard activity.
