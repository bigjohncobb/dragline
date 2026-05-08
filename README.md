# Dragline

Dragline is an entity intelligence platform. It accumulates intelligence on targets — companies, exchanges, regulators, individuals — across any sector and geography. The primary interface is a change feed: a chronological list of what has materially changed across all watched targets since the last session.

## Stack

- **Perl 5.36+** / Mojolicious (full app) / Minion job queue
- **SQLite 3.38+** with WAL mode and sqlite-vec extension for vector embeddings
- **Mojolicious::Renderer** with Embedded Perl (EP) templates
- **Caddy** as reverse proxy (config in `deploy/`)
- External processes:
  - **Python crawl service** at `localhost:3002` (separate repo)
  - **R/Plumber scoring service** at `localhost:3003` (separate repo)

## Prerequisites

- Perl 5.36 or newer
- SQLite 3.38 or newer, compiled with the **sqlite-vec** extension loaded
- `cpanm` (App::cpanminus)
- Optional but recommended: `sqlite3` CLI for manual inspection

### sqlite-vec

The sqlite-vec extension must be available to SQLite. Either:
- Load it dynamically: `SELECT load_extension('vec0');`
- Compile SQLite with sqlite-vec statically linked
- On Debian/Ubuntu: install `libsqlite3-mod-vec` if available in your repository

Verify with: `sqlite3 -cmd "SELECT load_extension('vec0'); SELECT vec_version();"`

## Directory Layout

```
.
├── dragline.pl           # Main application
├── schema.sql            # Database schema, indexes, triggers, seed data
├── cpanfile              # Perl dependencies
├── lib/                  # Library modules
│   ├── Dragline/
│   │   ├── DB.pm
│   │   ├── Crypto.pm
│   │   ├── SSRF.pm
│   │   ├── Cost.pm
│   │   ├── LLM.pm
│   │   ├── Embed.pm
│   │   ├── Crawl.pm
│   │   ├── Brave.pm
│   │   ├── Forge.pm
│   │   ├── Controller/   # Route handlers
│   │   └── Job/          # Minion job classes
├── templates/            # EP templates
├── public/               # Static assets
├── t/                    # Test suite
└── deploy/               # systemd units, Caddy example, deploy scripts
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DRAGLINE_SECRET` | Yes | — | Min 32 chars. Used for session signing, AES-256-GCM encryption, and API key hashing. Changing this invalidates all sessions and encrypted settings. |
| `DRAGLINE_DB` | No | `./dragline.db` | Path to SQLite database file. |
| `DRAGLINE_MINION_DB` | No | `./minion.db` | Path to Minion SQLite backend. |
| `DRAGLINE_PORT` | No | `3001` | Port for Hypnotoad (production) or morbo (development). |
| `DRAGLINE_AIRGAP` | No | `0` | Set to `1` to disable external LLM providers and Brave/Forge. Routes all LLM calls to Ollama. |

## Database Initialization

On first startup, Dragline reads `schema.sql` and initialises the database automatically. The schema includes:
- All tables, indexes, and `updated_at` triggers
- One admin user (`admin` / `changeme`)
- Default settings rows for API keys and service URLs

No manual migration step is required for a fresh install.

## Running Locally

```bash
export DRAGLINE_SECRET="your-secret-minimum-32-chars-here"
export DRAGLINE_DB="./dragline.db"
cpanm --installdeps --local-lib local .
morbo dragline.pl
```

The app listens on `http://localhost:3001` by default.

Minion worker (separate terminal, required for all background jobs):

```bash
perl dragline.pl minion worker
```

For development with multiple workers:

```bash
perl dragline.pl minion worker -j 4
```

### Background Jobs

Dragline relies on Minion for all heavy lifting. Without a worker running, the following will queue but never execute:
- Web crawling (`CrawlStatic`, `CrawlJS`)
- PDF ingestion (`IngestPDF`)
- Forge sync (`ForgeSync`)
- Web discovery via Brave (`Discover`)
- Embedding generation (`Embed`)
- Dossier synthesis (`Synthesise`)
- Content scoring (`Score`)
- Gap detection (`GapDetect`)
- Scheduled maintenance (`CleanupEvents`, `ScheduleCrawls`)

## Running Tests

```bash
prove -lr t/
```

Tests use an in-memory SQLite database seeded from `schema.sql`. No external services are required. The test suite covers auth, projects, targets, content handling, people, API routes, and health checks.

## First Run

1. **Change the admin password immediately.** Log in as `admin` / `changeme`, go to **Admin → Users**, and update the password.
2. **Configure API keys** in **Admin → Settings**:
   - **Anthropic** — used for complex reasoning tasks (forward assessment, executive summary, risk synthesis)
   - **Qwen / Alibaba** — used for dossier section synthesis and chunk summarisation
   - **Brave** — web discovery via Brave Search API
   - **Forge** — external intelligence feed
3. **Configure service URLs** in **Admin → Settings**:
   - `crawl_service_url` — default `http://localhost:3002`
   - `r_service_url` — default `http://localhost:3003`
   - `ollama_base_url` — default `http://localhost:11434`

Without API keys, dossier generation and discovery will fall back to Ollama (if configured) or fail gracefully.

### Default Settings

The database is seeded with empty encrypted slots for all API keys and sensible defaults for service URLs. All encrypted values are masked in the settings form.

## Airgap Mode

Set `DRAGLINE_AIRGAP=1` to operate without external API dependencies. In this mode:
- All LLM calls route to the configured Ollama instance
- Brave Search is disabled
- Forge sync is disabled
- Discovery and dossier generation still work if Ollama is running locally

## Deploying

1. Copy the systemd units from `deploy/` to `/etc/systemd/system/`:
   - `dragline@.service` — Hypnotoad application server
   - `dragline-worker@.service` — Minion worker pool
2. Create `/etc/dragline/$instance.env` (e.g. `/etc/dragline/1.env`):
   ```
   DRAGLINE_SECRET=your-secret-minimum-32-chars-here
   DRAGLINE_DB=/var/lib/dragline/dragline.db
   DRAGLINE_PORT=3001
   ```
3. Run `deploy/deploy.sh $instance`:
   ```bash
   ./deploy/deploy.sh 1
   ```

The deploy script pulls the latest code, installs dependencies, runs a syntax check, and restarts both services.

### Production Server

Use Hypnotoad, not morbo:

```bash
hypnotoad dragline.pl
```

Reload without dropping connections:

```bash
hypnotoad -s dragline.pl
```

### Reverse Proxy

A Caddy example is provided in `deploy/Caddyfile.example`. TLS is handled automatically via Let's Encrypt.

### Backup

Use `deploy/backup.sh $instance`:

```bash
./deploy/backup.sh 1
```

This creates a timestamped SQLite backup, compresses it with gzip, and prunes backups older than 30 days. Configure the backup destination in the script header.

## Crawl Service

Dragline expects a Python crawl service at `crawl_service_url` (default `http://localhost:3002`). The service must expose:

- `POST /crawl` — accepts `{"url": "..."}`, returns rendered page text
- `POST /extract` — accepts a PDF file upload, returns extracted text and tables

Jobs that depend on the crawl service (`CrawlJS`, `IngestPDF`) will fail with a clear error if the service is unreachable. See `crawl-service/README.md` for setup.

## R Service

Dragline expects an R/Plumber scoring service at `r_service_url` (default `http://localhost:3003`). The service provides:

- `POST /score` — content significance scoring (returns tier 1-163)
- `POST /gap-detect` — intelligence gap detection

Until the R service is running:
- `Score` jobs use source-type heuristics (Forge=30, crawl=40, PDF=70, upload=60)
- `GapDetect` jobs are no-ops

See `r-service/README.md` for setup.

## Security

- `DRAGLINE_SECRET` must be at least 32 characters. The app refuses to start if it is missing or too short.
- All passwords are hashed with bcrypt via `Crypt::Passphrase`.
- API keys and external secrets are encrypted with AES-256-GCM before storage.
- Session cookies are HMAC-signed, `HttpOnly`, `Secure`, `SameSite=Lax`.
- CSRF tokens are required on all non-GET forms.
- Rate limiting: expensive ops 5/min, write ops 30/min, read ops 120/min per IP.
- SSRF validation blocks private IP ranges, loopback, link-local, and metadata endpoints on all outbound HTTP requests.
- Uploaded files are validated by magic bytes, not file extension.

## Troubleshooting

**App exits on startup with "DRAGLINE_SECRET missing or too short"**
→ Set `DRAGLINE_SECRET` to a random string of at least 32 characters.

**"sqlite-vec extension not available"**
→ Ensure sqlite-vec is loaded. Check `SELECT vec_version();` in the SQLite CLI.

**Jobs queue but never execute**
→ Start a Minion worker: `perl dragline.pl minion worker`

**Crawl or PDF ingestion fails**
→ Verify the crawl service is running at the configured `crawl_service_url`.

**Significance tiers are all null**
→ The R scoring service is not running. Significance scoring is stubbed with heuristics until the service is available.

**Database locked errors**
→ Ensure WAL mode is enabled (Dragline sets this automatically). Avoid placing the database on network filesystems.
