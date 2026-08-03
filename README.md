# Restaurant Ops

A production-oriented foundation for a restaurant operations platform. The repository contains a responsive Flutter Web client and a FastAPI/PostgreSQL API with JWT authentication. Task 1 intentionally contains no AI models, transcription, analysis, or third-party AI integrations.

## What is included

- Flutter Web with Material 3, Riverpod, GoRouter, responsive drawer/navigation rail, dark theme, and authenticated route guards
- Login, dashboard, reports, audio selection, and settings screens
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

### API

Use Python 3.12+. Local development uses an automatically created SQLite
database, so PostgreSQL and Docker are not required.

```bash
python -m venv .venv
source .venv/bin/activate              # Windows: .venv\Scripts\activate
pip install -r backend/requirements.txt
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

## Production configuration

Never deploy the example secrets. At minimum, set `DATABASE_URL`, a randomly generated `JWT_SECRET_KEY`, `CORS_ORIGINS`, `APP_ENV=production`, `AUTO_CREATE_TABLES=false`, `SEED_DEFAULT_ADMIN=false`, and `DOCS_ENABLED=false`. Terminate TLS at the platform/load balancer and keep PostgreSQL private.

The included `railway.toml` deploys the API from `backend/Dockerfile`. Add a Railway PostgreSQL service, map its async connection URL to `DATABASE_URL`, and set the remaining variables above. The Dockerfile honors Railway's injected `PORT`.

The browser stores JWTs in web storage for this foundation. Refresh tokens are
hashed server-side, rotated on every exchange, revoked on logout, and their
reuse revokes the user's other active refresh sessions. For a hardened public
deployment, prefer a same-origin backend-for-frontend using Secure, HttpOnly,
SameSite cookies so browser scripts cannot read session credentials.

## Deliberate Task 1 boundary

The audio page only validates local file selection. It does not upload, transcribe, analyze, or call any AI service. Those capabilities belong to a later task.
