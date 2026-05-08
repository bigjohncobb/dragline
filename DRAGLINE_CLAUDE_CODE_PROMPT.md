# Dragline — Claude Code Generation Prompt

You are building Dragline — a closed-source entity intelligence platform. Read this entire prompt before writing a single line of code. Generate all files completely. Do not summarise, do not truncate, do not use placeholders. Show each file with its full path as a header.

Generate in this order: schema.sql, cpanfile, dragline.pl, lib/Dragline/DB.pm, lib/Dragline/Crypto.pm, lib/Dragline/SSRF.pm, lib/Dragline/Cost.pm, lib/Dragline/LLM.pm, lib/Dragline/Embed.pm, lib/Dragline/Crawl.pm, lib/Dragline/Brave.pm, lib/Dragline/Forge.pm, then all controllers, then all job modules, then all templates, then all tests, then all deploy files, then README.md.

---

## 1. What Dragline Is

Dragline is an entity intelligence platform. It collects, stores, and synthesizes everything knowable about a target — companies, exchanges, regulators, individuals — across any sector, any geography, and any language. It is a durable intelligence accumulator that gets more complete over time without manual effort.

The primary interface when opening Dragline is a change feed: a chronological list of what has materially changed across all watched targets since the last session. Each change event shows what changed, which target, the source, and a summary.

Dragline is not a news aggregator. It is not a dashboard of charts. It is not a real-time system.

---

## 2. Stack

- Perl 5 / Mojolicious (full app, not Lite) / Minion job queue
- SQLite in WAL mode with sqlite-vec extension for vector embeddings
- Mojolicious::Renderer with Embedded Perl (ep) templates
- Caddy as reverse proxy (config provided in deploy/, not built into the app)
- R statistical layer — Plumber API running as a separate process. Stub the Score and GapDetect jobs with HTTP calls to http://localhost:3003. Do not implement the R service itself.
- Python crawl service — separate process exposing POST /crawl and POST /extract. Stub the CrawlJS and IngestPDF jobs with HTTP calls to http://localhost:3002. Do not implement the crawl service itself.

---

## 3. Reference Implementation — Chinaski

Chinaski is a working Mojolicious/Perl CMS built by this operator. Dragline follows identical patterns. Do not deviate from these conventions:

- Single `DRAGLINE_SECRET` environment variable required at startup. Process dies with a clear error message if missing.
- Single `DRAGLINE_DB` environment variable for database path. Default: `./dragline.db`.
- Single `DRAGLINE_AIRGAP` environment variable. Default: 0. When 1, all LLM calls route to Ollama only, Brave and Forge jobs fail gracefully.
- Session cookies are HMAC-signed using CryptX, SameSite=Lax, Secure, HttpOnly.
- Passwords hashed with Crypt::Passphrase (bcrypt).
- External API keys and secrets stored AES-256-GCM encrypted in the settings table via Crypto.pm.
- CSRF token on every non-GET form. Validated in every POST handler.
- CSP nonce generated per request. No unsafe-inline anywhere.
- Rate limiting: expensive ops 5/min per IP, write ops 30/min per IP, read ops 120/min per IP.
- X-Forwarded-For honoured only from loopback peers (127.0.0.1, ::1).
- SSRF validation on every outbound HTTP request via SSRF.pm.
- Uploaded files validated by magic byte sniffing, not file extension.
- morbo for development, Hypnotoad for production.
- `prove -lr t/` for tests. Tests use in-memory SQLite seeded from schema.sql. No external services required in tests.
- Flash messages for all form outcomes (success and error).
- All datetimes stored as ISO 8601 UTC strings.
- All JSON fields validated before insert.
- Foreign keys enforced: every database connection must execute `PRAGMA foreign_keys = ON` immediately after opening.
- Transactions for all multi-step writes.
- UUIDs generated in Perl for all primary keys.
- Error pages for 404 and 500.

---

## 4. schema.sql

Generate complete, production-ready SQL. Include all tables, indexes, triggers, and seed data. Every table that has updated_at gets a trigger to maintain it automatically.

### Tables

**projects**
```
id TEXT PRIMARY KEY
name TEXT NOT NULL
description TEXT
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**targets**
```
id TEXT PRIMARY KEY
project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE
canonical_name TEXT NOT NULL
canonical_name_lower TEXT NOT NULL
entity_type TEXT NOT NULL DEFAULT 'company'
  CHECK (entity_type IN ('company','exchange','regulator','agency','individual','other'))
country TEXT -- ISO 3166-1 alpha-2
jurisdiction TEXT
primary_domain TEXT
language_codes TEXT NOT NULL DEFAULT '["en"]' -- JSON array of ISO 639-1 codes
notes TEXT
active INTEGER NOT NULL DEFAULT 1
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
UNIQUE (project_id, canonical_name_lower)
```

**target_aliases**
```
id TEXT PRIMARY KEY
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE
alias TEXT NOT NULL
alias_lower TEXT NOT NULL
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
UNIQUE (target_id, alias_lower)
```

**target_domains**
```
id TEXT PRIMARY KEY
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE
domain TEXT NOT NULL
is_primary INTEGER NOT NULL DEFAULT 0
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
UNIQUE (target_id, domain)
```

**target_monitoring**
```
id TEXT PRIMARY KEY
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE UNIQUE
forge_sync_cadence TEXT NOT NULL DEFAULT 'daily'
  CHECK (forge_sync_cadence IN ('hourly','daily','weekly','disabled'))
crawl_cadence TEXT NOT NULL DEFAULT 'weekly'
  CHECK (crawl_cadence IN ('daily','weekly','monthly','disabled'))
discover_cadence TEXT NOT NULL DEFAULT 'weekly'
  CHECK (discover_cadence IN ('daily','weekly','monthly','disabled'))
last_forge_sync_at DATETIME
last_crawl_at DATETIME
last_discover_at DATETIME
next_forge_sync_at DATETIME
next_crawl_at DATETIME
next_discover_at DATETIME
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**forge_items**
```
id TEXT PRIMARY KEY
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE
forge_item_id TEXT NOT NULL -- external ID from Forge API, for dedup
title TEXT
url TEXT
published_at DATETIME
sentiment_score REAL
mention_count INTEGER
raw_json TEXT -- full Forge API response stored for reference
imported_at DATETIME NOT NULL DEFAULT (datetime('now'))
UNIQUE (target_id, forge_item_id)
```

**crawl_queue**
```
id TEXT PRIMARY KEY
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE
url TEXT NOT NULL
source TEXT NOT NULL DEFAULT 'manual'
  CHECK (source IN ('manual','brave_discovery','forge_link','sitemap'))
priority INTEGER NOT NULL DEFAULT 5
status TEXT NOT NULL DEFAULT 'pending'
  CHECK (status IN ('pending','processing','complete','failed','skipped'))
attempts INTEGER NOT NULL DEFAULT 0
last_error TEXT
queued_at DATETIME NOT NULL DEFAULT (datetime('now'))
processed_at DATETIME
UNIQUE (target_id, url)
```

**raw_content**
```
id TEXT PRIMARY KEY
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE
source_type TEXT NOT NULL
  CHECK (source_type IN ('forge','crawl_static','crawl_js','pdf','upload'))
source_url TEXT
source_title TEXT
content_text TEXT NOT NULL
content_hash TEXT NOT NULL -- SHA-256 of content_text, for dedup
language_code TEXT -- ISO 639-1, detected on ingestion
significance_tier INTEGER -- 1-163, NULL until scored
  CHECK (significance_tier IS NULL OR (significance_tier >= 1 AND significance_tier <= 163))
word_count INTEGER
fetched_at DATETIME
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
UNIQUE (target_id, content_hash)
```

**raw_content_embeddings**
```
id TEXT PRIMARY KEY
raw_content_id TEXT NOT NULL REFERENCES raw_content(id) ON DELETE CASCADE UNIQUE
embedding BLOB NOT NULL -- sqlite-vec format
model TEXT NOT NULL DEFAULT 'text-embedding-v4'
dimensions INTEGER NOT NULL DEFAULT 1024
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**change_events**
```
id TEXT PRIMARY KEY
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE
event_type TEXT NOT NULL
  CHECK (event_type IN ('new_content','gap_detected','dossier_updated','crawl_failed','forge_sync','discovery_complete'))
summary TEXT NOT NULL
source_url TEXT
raw_content_id TEXT REFERENCES raw_content(id) ON DELETE SET NULL
severity TEXT NOT NULL DEFAULT 'info'
  CHECK (severity IN ('info','low','medium','high','critical'))
seen INTEGER NOT NULL DEFAULT 0
seen_at DATETIME
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**dossiers**
```
id TEXT PRIMARY KEY
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE UNIQUE
status TEXT NOT NULL DEFAULT 'draft'
  CHECK (status IN ('draft','current','stale','generating'))
generated_at DATETIME
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**dossier_sections**
```
id TEXT PRIMARY KEY
dossier_id TEXT NOT NULL REFERENCES dossiers(id) ON DELETE CASCADE
section_number INTEGER NOT NULL CHECK (section_number BETWEEN 1 AND 10)
section_name TEXT NOT NULL
content TEXT
model_used TEXT
token_count INTEGER
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
UNIQUE (dossier_id, section_number)
```

**people**
```
id TEXT PRIMARY KEY
canonical_name TEXT NOT NULL
canonical_name_lower TEXT NOT NULL
nationality TEXT -- ISO 3166-1 alpha-2
bio_summary TEXT
merged_into TEXT REFERENCES people(id) ON DELETE SET NULL
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**person_roles**
```
id TEXT PRIMARY KEY
person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE
target_id TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE
title TEXT NOT NULL
started_at DATE
ended_at DATE
is_current INTEGER NOT NULL DEFAULT 1
source_url TEXT
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**person_connections**
```
id TEXT PRIMARY KEY
person_id_a TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE
person_id_b TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE
relationship_type TEXT NOT NULL
  CHECK (relationship_type IN ('revolving_door','shared_board','political_affiliation','family_ownership','legal_co_appearance'))
notes TEXT
source_url TEXT
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
CHECK (person_id_a < person_id_b) -- prevents duplicate bidirectional edges
```

**api_keys**
```
id TEXT PRIMARY KEY
name TEXT NOT NULL -- human label for this key
key_hash TEXT NOT NULL UNIQUE -- SHA-256 hash of the actual key
key_prefix TEXT NOT NULL -- first 8 chars of actual key, for display
role TEXT NOT NULL DEFAULT 'readonly'
  CHECK (role IN ('readonly','analyst','admin'))
active INTEGER NOT NULL DEFAULT 1
last_used_at DATETIME
request_count INTEGER NOT NULL DEFAULT 0
expires_at DATETIME
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**cost_records**
```
id TEXT PRIMARY KEY
provider TEXT NOT NULL
operation TEXT NOT NULL
model TEXT
input_tokens INTEGER
output_tokens INTEGER
estimated_cost_usd REAL
target_id TEXT REFERENCES targets(id) ON DELETE SET NULL
job_id TEXT
status TEXT NOT NULL DEFAULT 'success'
  CHECK (status IN ('success','failed'))
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**settings**
```
key TEXT PRIMARY KEY
value TEXT
is_encrypted INTEGER NOT NULL DEFAULT 0
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**users**
```
id TEXT PRIMARY KEY
username TEXT NOT NULL
username_lower TEXT NOT NULL UNIQUE
password_hash TEXT NOT NULL
role TEXT NOT NULL DEFAULT 'analyst'
  CHECK (role IN ('admin','analyst'))
active INTEGER NOT NULL DEFAULT 1
last_login_at DATETIME
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

**login_attempts**
```
id TEXT PRIMARY KEY
ip_address TEXT NOT NULL
attempted_at DATETIME NOT NULL DEFAULT (datetime('now'))
success INTEGER NOT NULL DEFAULT 0
```

**audit_log**
```
id TEXT PRIMARY KEY
user_id TEXT REFERENCES users(id) ON DELETE SET NULL
action TEXT NOT NULL
entity_type TEXT
entity_id TEXT
changes TEXT -- JSON
ip_address TEXT
user_agent TEXT
created_at DATETIME NOT NULL DEFAULT (datetime('now'))
```

### Indexes

Create indexes on:
- targets(project_id), targets(active), targets(canonical_name_lower)
- target_aliases(target_id), target_aliases(alias_lower)
- target_domains(target_id)
- target_monitoring(next_forge_sync_at), target_monitoring(next_crawl_at)
- forge_items(target_id), forge_items(forge_item_id), forge_items(published_at)
- crawl_queue(target_id), crawl_queue(status), crawl_queue(priority)
- raw_content(target_id), raw_content(content_hash), raw_content(source_type), raw_content(created_at)
- raw_content_embeddings(raw_content_id)
- change_events(target_id), change_events(seen), change_events(created_at), change_events(severity)
- dossiers(target_id), dossiers(status)
- dossier_sections(dossier_id)
- people(canonical_name_lower)
- person_roles(person_id), person_roles(target_id), person_roles(is_current)
- person_connections(person_id_a), person_connections(person_id_b)
- api_keys(key_hash), api_keys(active)
- cost_records(provider), cost_records(target_id), cost_records(created_at)
- login_attempts(ip_address), login_attempts(attempted_at)
- audit_log(user_id), audit_log(entity_type), audit_log(created_at)

### Triggers

Generate updated_at triggers for: projects, targets, target_monitoring, dossiers, dossier_sections, people, person_roles, api_keys, users, settings.

### Seed Data

Insert:
- One admin user: username 'admin', role 'admin', password 'changeme' stored as a bcrypt hash placeholder (use '$2b$12$placeholder' — the deploy script will prompt to change it on first run)
- Default settings rows:
  - anthropic_api_key (empty, is_encrypted=1)
  - qwen_api_key (empty, is_encrypted=1)
  - alibaba_api_key (empty, is_encrypted=1)
  - brave_api_key (empty, is_encrypted=1)
  - forge_api_url (empty, is_encrypted=0)
  - forge_api_key (empty, is_encrypted=1)
  - ollama_base_url ('http://localhost:11434', is_encrypted=0)
  - crawl_service_url ('http://localhost:3002', is_encrypted=0)
  - r_service_url ('http://localhost:3003', is_encrypted=0)
  - crawl_content_threshold ('500', is_encrypted=0) -- min chars before escalating to crawl service
  - default_embed_model ('text-embedding-v4', is_encrypted=0)
  - app_version ('0.1.0', is_encrypted=0)

---

## 5. cpanfile

Declare all non-core dependencies. Every module must be available in Debian stable or CPAN. No exotic modules.

Required modules:
- Mojolicious (includes Minion)
- Minion::Backend::SQLite (SQLite backend for Minion)
- DBI
- DBD::SQLite
- Crypt::Passphrase
- Crypt::Passphrase::Bcrypt
- CryptX (HMAC, AES-256-GCM)
- Data::UUID (UUID generation)
- Digest::SHA (SHA-256 for content hashing and API key hashing)
- JSON::PP or JSON::XS (JSON encode/decode)
- MIME::Base64 (for encrypted value encoding)
- File::Slurp or Path::Tiny (file reading for schema.sql)
- List::Util (core, but declare anyway)
- Scalar::Util (core)
- POSIX (core)

---

## 6. dragline.pl

Full Mojolicious application file. Not Lite.

### Startup sequence

1. Read and validate DRAGLINE_SECRET — die with clear message if missing or shorter than 32 chars
2. Read DRAGLINE_DB (default ./dragline.db)
3. Read DRAGLINE_AIRGAP (default 0)
4. Read DRAGLINE_PORT (default 3001)
5. Load schema.sql and initialise database if it does not exist
6. Register Minion plugin with SQLite backend (./minion.db or DRAGLINE_MINION_DB env var)
7. Register all Minion job classes
8. Register all helpers
9. Register all routes
10. Set up sessions (secret from DRAGLINE_SECRET)
11. Set up static file serving from public/

### Helpers

Register these helpers available in all controllers and templates:

**db** — returns a connected DBI database handle with foreign_keys=ON and WAL mode set. Connection is cached per request.

**current_user** — returns the currently logged-in user hashref from session, or undef.

**require_login** — redirect to /login if no current_user. Use in before hooks on protected route groups.

**require_admin** — redirect to / with flash error if current_user role is not admin.

**require_api_key** — for API routes. Validates Bearer token in Authorization header against api_keys table. Sets stash->{api_user} with role. Returns 401 JSON if missing or invalid.

**csrf_token** — generates and stores a CSRF token in the session. Returns the token string.

**validate_csrf** — validates POST param _csrf_token against session token. Returns 1 if valid, 0 if not.

**log_audit(action, entity_type, entity_id, changes)** — inserts into audit_log with current user, IP, user agent.

**encrypt_value(plaintext)** — encrypts using AES-256-GCM with key derived from DRAGLINE_SECRET. Returns base64-encoded ciphertext.

**decrypt_value(ciphertext)** — decrypts. Returns plaintext.

**get_setting(key)** — fetches from settings table, decrypts if is_encrypted=1.

**set_setting(key, value, is_encrypted)** — upserts into settings table, encrypts if is_encrypted=1.

**new_uuid** — returns a new UUID string.

**content_hash(text)** — returns SHA-256 hex digest of text.

**check_ssrf(url)** — validates URL against SSRF blocklist. Returns 1 if safe, 0 if blocked.

**rate_limit(tier)** — checks rate limit for current IP. tier is 'expensive', 'write', or 'read'. Returns 1 if allowed, 0 if exceeded. Limits: expensive=5/min, write=30/min, read=120/min.

**airgap_mode** — returns 1 if DRAGLINE_AIRGAP is set, 0 otherwise.

### Routes

All routes except /login, /logout, /health require login (before hook on the protected group).

Admin routes additionally require admin role.

API routes use Bearer token auth via require_api_key helper.

```
GET  /health                          -- no auth, JSON response
GET  /login
POST /login
GET  /logout

# Protected routes (require_login)
GET  /                                -- Dashboard::index (change feed)
POST /changes/:id/seen                -- Dashboard::mark_seen
POST /changes/seen-all                -- Dashboard::mark_all_seen

GET  /projects                        -- Projects::index
GET  /projects/new                    -- Projects::new_form
POST /projects                        -- Projects::create
GET  /projects/:id                    -- Projects::show
GET  /projects/:id/edit               -- Projects::edit_form
POST /projects/:id                    -- Projects::update
POST /projects/:id/delete             -- Projects::delete

GET  /targets                         -- Targets::index (all targets)
GET  /projects/:project_id/targets/new  -- Targets::new_form
POST /projects/:project_id/targets      -- Targets::create
GET  /targets/:id                     -- Targets::show
GET  /targets/:id/edit                -- Targets::edit_form
POST /targets/:id                     -- Targets::update
POST /targets/:id/delete              -- Targets::delete
POST /targets/:id/activate            -- Targets::activate
POST /targets/:id/deactivate          -- Targets::deactivate
POST /targets/:id/aliases             -- Targets::add_alias
POST /targets/:id/aliases/:alias_id/delete  -- Targets::delete_alias
POST /targets/:id/domains             -- Targets::add_domain
POST /targets/:id/domains/:domain_id/delete -- Targets::delete_domain
GET  /targets/:id/monitoring          -- Targets::monitoring_form
POST /targets/:id/monitoring          -- Targets::update_monitoring

GET  /targets/:id/content             -- Content::index
POST /targets/:id/content/crawl       -- Content::queue_crawl (queues CrawlStatic job)
POST /targets/:id/content/upload      -- Content::upload (PDF or text, magic byte validation)
POST /targets/:id/content/discover    -- Content::queue_discover (queues Discover job)
POST /targets/:id/content/forge-sync  -- Content::queue_forge_sync (queues ForgeSync job)

GET  /targets/:id/dossier             -- Dossiers::show
POST /targets/:id/dossier/generate    -- Dossiers::generate (queues Synthesise job)

GET  /people                          -- People::index
GET  /people/new                      -- People::new_form
POST /people                          -- People::create
GET  /people/:id                      -- People::show
GET  /people/:id/edit                 -- People::edit_form
POST /people/:id                      -- People::update
POST /people/:id/delete               -- People::delete
POST /people/:id/roles                -- People::add_role
POST /people/:id/roles/:role_id/delete -- People::delete_role
POST /people/:id/connections          -- People::add_connection
POST /people/:id/connections/:conn_id/delete -- People::delete_connection

# Admin routes (require_admin)
GET  /admin/health                    -- Admin::health
GET  /admin/settings                  -- Admin::settings_form
POST /admin/settings                  -- Admin::update_settings
GET  /admin/costs                     -- Admin::costs
GET  /admin/audit                     -- Admin::audit_log
GET  /admin/users                     -- Admin::users
GET  /admin/users/new                 -- Admin::new_user_form
POST /admin/users                     -- Admin::create_user
POST /admin/users/:id/delete          -- Admin::delete_user
GET  /admin/api-keys                  -- Admin::api_keys
POST /admin/api-keys                  -- Admin::create_api_key
POST /admin/api-keys/:id/delete       -- Admin::delete_api_key
POST /admin/api-keys/:id/rotate       -- Admin::rotate_api_key

# Minion web UI
GET  /admin/jobs/*                    -- Minion web UI mounted at /admin/jobs

# API routes (Bearer token auth)
GET  /api/targets                     -- Api::targets
GET  /api/targets/:id                 -- Api::target
GET  /api/targets/:id/content         -- Api::content
GET  /api/targets/:id/dossier         -- Api::dossier
GET  /api/change-feed                 -- Api::change_feed
POST /api/targets/:id/content/upload  -- Api::upload_content
```

### Minion Job Registration

Register all job classes in startup:

```perl
$app->minion->add_task(crawl_static   => 'Dragline::Job::CrawlStatic');
$app->minion->add_task(crawl_js       => 'Dragline::Job::CrawlJS');
$app->minion->add_task(ingest_pdf     => 'Dragline::Job::IngestPDF');
$app->minion->add_task(forge_sync     => 'Dragline::Job::ForgeSync');
$app->minion->add_task(discover       => 'Dragline::Job::Discover');
$app->minion->add_task(embed          => 'Dragline::Job::Embed');
$app->minion->add_task(synthesise     => 'Dragline::Job::Synthesise');
$app->minion->add_task(score          => 'Dragline::Job::Score');
$app->minion->add_task(gap_detect     => 'Dragline::Job::GapDetect');
$app->minion->add_task(cleanup_events => 'Dragline::Job::CleanupEvents');
$app->minion->add_task(schedule_crawls => 'Dragline::Job::ScheduleCrawls');
```

### Login Rate Limiting

On POST /login: check login_attempts for the IP. If 5 or more failed attempts in the last 60 seconds, return 429 with lockout message. On successful login, do not insert a failure record. On failed login, insert a failure record. Prune login_attempts older than 10 minutes periodically.

---

## 7. Core Library Modules

### lib/Dragline/DB.pm

Handles database initialisation. On first run (database file does not exist), reads schema.sql from the application root and executes it. Returns a DBI handle. Sets PRAGMA foreign_keys = ON and PRAGMA journal_mode = WAL on every new connection.

### lib/Dragline/Crypto.pm

AES-256-GCM encryption and decryption using CryptX. Key is derived from DRAGLINE_SECRET using SHA-256. Ciphertext is stored as base64(iv + tag + ciphertext). HMAC-SHA256 signing for session cookies.

### lib/Dragline/SSRF.pm

Validates outbound URLs before any HTTP request. Blocks:
- Private IPv4 ranges (RFC 1918): 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
- Loopback: 127.0.0.0/8
- Link-local: 169.254.0.0/16
- CGNAT: 100.64.0.0/10
- IPv6 loopback, link-local, ULA
- Metadata endpoints: 169.254.169.254
- Non-HTTP/HTTPS schemes
- Ports other than 80, 443, 8080, 8443 (configurable)

Returns (1, undef) if safe. Returns (0, "reason") if blocked.

### lib/Dragline/Cost.pm

Records LLM and API costs to cost_records table. Provides:
- record(provider, operation, model, input_tokens, output_tokens, cost_usd, target_id, job_id, status)
- summary(days) — returns total cost for last N days by provider
- by_target(target_id) — returns cost breakdown for a target

### lib/Dragline/LLM.pm

Abstracted LLM provider routing with automatic failover and cost recording.

Providers and their task assignments:
- Claude Sonnet: forward_assessment, executive_summary, risk_synthesis (complex reasoning)
- Qwen Plus: section_synthesis (8 of the 10 dossier sections)
- Qwen Flash: chunk_summarisation (map phase, cheap and fast)
- Ollama: all tasks when DRAGLINE_AIRGAP=1 (uses model from ollama_base_url setting)

Methods:
- complete(task_type, system_prompt, user_prompt, max_tokens) — routes to correct provider, records cost, returns (response_text, provider_used, tokens_used)
- providers_for_task(task_type) — returns ordered list of providers to try
- call_anthropic(prompt_args) — raw Anthropic API call via Mojo::UserAgent
- call_qwen(prompt_args) — raw Qwen API call via Mojo::UserAgent
- call_ollama(prompt_args) — Ollama API call via Mojo::UserAgent

On provider failure, try the next provider in the fallback chain. Log each failure. Record cost only on success.

When DRAGLINE_AIRGAP=1, skip all non-Ollama providers regardless of task_type.

### lib/Dragline/Embed.pm

Alibaba text-embedding-v4 via raw HTTP to DashScope OpenAI-compatible endpoint.

- embed(text) — returns arrayref of 1024 floats. Checks in-memory cache first (SHA-256 keyed). On cache miss, calls API. Heegner retry backoff: wait 1s, then 3s, then 7s before giving up.
- embed_batch(texts_arrayref) — single API call for multiple texts. Returns arrayref of arrayrefs. Preserves order.
- Cache is in-memory (hash). Acceptable to lose on restart.
- Records cost to Cost.pm on each API call.
- When DRAGLINE_AIRGAP=1, calls local Ollama embedding endpoint instead.

### lib/Dragline/Crawl.pm

Static web crawling via Mojo::UserAgent and crawl service integration.

- fetch_static(url) — fetches URL, extracts text. Returns (text, title, final_url, word_count, error).
  - Sets a realistic browser User-Agent
  - Follows up to 5 redirects
  - Times out after 30 seconds
  - Validates URL via SSRF.pm before fetching
  - Extracts title from <title> tag
  - Strips HTML tags for plain text
  - Checks word count against crawl_content_threshold setting
  - If word count is below threshold, sets a flag indicating JS rendering may be needed
- fetch_via_service(url) — POSTs to crawl service POST /crawl. Returns (text, title, final_url, word_count, error).
- extract_pdf_via_service(file_bytes, filename) — POSTs to crawl service POST /extract. Returns (text, detected_tables_json, error).
- is_js_heavy(response) — heuristic: returns 1 if body is small but has many script tags, or if body contains known SPA markers (ng-app, data-reactroot, __NEXT_DATA__, etc.)

### lib/Dragline/Brave.pm

Brave Search API client via Mojo::UserAgent.

- search(query, count) — calls https://api.search.brave.com/res/v1/web/search with X-Subscription-Token header. Returns arrayref of result hashrefs (url, title, description). Default count: 20.
- search_for_target(target) — generates 3-5 search queries for a target using its canonical name, aliases, and country. Returns all results deduplicated by URL.
- Validates API key is configured before calling. Returns empty list with logged warning if key missing or DRAGLINE_AIRGAP=1.

### lib/Dragline/Forge.pm

Forge API client via Mojo::UserAgent.

- sync_target(target_id, target_name) — calls Forge API to get recent items mentioning the target. Returns arrayref of item hashrefs. Deduplicates against forge_items table using forge_item_id.
- Stores new items in forge_items table and creates raw_content records for each.
- Creates a change_event for each batch of new items found.
- Returns (new_count, error).
- Returns (0, "airgap mode") if DRAGLINE_AIRGAP=1.
- Returns (0, "forge not configured") if forge_api_url or forge_api_key not set.

---

## 8. Controllers

### lib/Dragline/Controller/Auth.pm

**login_form** (GET /login) — render login template. Redirect to / if already logged in.

**login** (POST /login) — validate CSRF, check rate limit, look up user by username_lower, verify password with Crypt::Passphrase. On success: set session user_id and role, update last_login_at, log audit, redirect to /. On failure: insert login_attempt, flash error, re-render form.

**logout** (GET /logout) — clear session, log audit, redirect to /login.

### lib/Dragline/Controller/Dashboard.pm

**index** (GET /) — fetch last 100 change_events ordered by created_at DESC, joined with targets for target name. Pass to template. Include unseen count in stash.

**mark_seen** (POST /changes/:id/seen) — update change_events set seen=1, seen_at=now where id=:id. Return JSON {ok:1}.

**mark_all_seen** (POST /changes/seen-all) — update all unseen events. Return JSON {ok:1, count:N}.

### lib/Dragline/Controller/Projects.pm

Full CRUD. index, new_form, create, show, edit_form, update, delete.

- create: validate name not empty, insert project, create audit log entry, redirect to /projects/:id
- show: fetch project with target count
- update: validate, update, audit log
- delete: check no targets exist (or cascade — your choice, but warn user), audit log

### lib/Dragline/Controller/Targets.pm

Full CRUD plus alias, domain, monitoring, activate/deactivate management.

- create: validate canonical_name, set canonical_name_lower, check uniqueness within project, insert target, create target_monitoring row with defaults, create audit log
- show: fetch target with aliases, domains, monitoring config, recent change_events (last 10), people with current roles, raw content count, dossier status
- add_alias: validate, insert target_aliases
- delete_alias: delete from target_aliases
- add_domain: validate domain format, insert target_domains
- delete_domain: delete from target_domains
- activate/deactivate: set active flag
- update_monitoring: update target_monitoring cadences, recalculate next_*_at timestamps

### lib/Dragline/Controller/Content.pm

**index** — list raw_content for target, paginated (20 per page), ordered by created_at DESC. Show source type, title, word count, significance tier, language.

**queue_crawl** — validate URL via SSRF.pm, check not already in crawl_queue, insert into crawl_queue, enqueue CrawlStatic Minion job, flash success.

**upload** — accept multipart file upload. Validate magic bytes (PDF: %PDF, text: UTF-8 decodeable). Store temp file. Enqueue IngestPDF or appropriate job. Flash success with job ID.

**queue_discover** — validate rate limit (expensive tier), enqueue Discover Minion job, flash success.

**queue_forge_sync** — validate rate limit (write tier), enqueue ForgeSync Minion job, flash success.

### lib/Dragline/Controller/Dossiers.pm

**show** — fetch dossier and all dossier_sections for target. If no dossier exists, show prompt to generate. Show sections in order 1-10. Show generation status if currently generating.

**generate** — validate rate limit (expensive tier). If dossier already generating (status='generating'), flash warning and redirect. Otherwise set dossier status to 'generating' (create if not exists), enqueue Synthesise Minion job, flash success.

### lib/Dragline/Controller/People.pm

Full CRUD plus role and connection management.

- index: list all people with role count and target count
- show: person with all roles (joined with targets), all connections (joined with other people)
- create/update: validate canonical_name, set canonical_name_lower
- add_role: validate person_id, target_id, title, insert person_roles
- delete_role: delete from person_roles
- add_connection: validate both person IDs exist, validate relationship_type, ensure person_id_a < person_id_b for dedup
- delete_connection: delete from person_connections

### lib/Dragline/Controller/Admin.pm

**health** — check DB connectivity, check Minion queue depth, check last backup timestamp from settings, return stash for template.

**settings_form** — fetch all settings rows, decrypt encrypted ones for display (show as masked). Render form.

**update_settings** — for each setting key in the form, validate and upsert. Encrypt if is_encrypted=1. Log audit. Flash success.

**costs** — aggregate cost_records by provider and by day for last 30 days. Pass to template.

**audit_log** — paginated audit_log, 50 per page, filterable by action and entity_type.

**users** — list all users.

**create_user** — validate username unique, hash password with Crypt::Passphrase, insert user.

**delete_user** — prevent deleting own account. Soft-delete by setting active=0.

**api_keys** — list all API keys (show prefix, role, last_used_at, request_count).

**create_api_key** — generate a random 32-byte key, store SHA-256 hash, store first 8 chars as prefix, store name and role. Return the full key once (never stored in plaintext, show in flash or one-time display).

**delete_api_key** — set active=0.

**rotate_api_key** — generate new key, update hash and prefix, preserve name and role.

### lib/Dragline/Controller/Api.pm

All routes return JSON. Use require_api_key helper.

**targets** — return all active targets with project name, entity type, country.

**target** — return single target with aliases, domains, monitoring config, dossier status.

**content** — return raw_content for target, paginated, with significance_tier and language_code.

**dossier** — return dossier sections as JSON array if dossier exists and status is 'current'. Return 404 if no current dossier.

**change_feed** — return last 50 change_events across all targets. Accepts ?since=ISO8601 parameter.

**upload_content** — accept JSON body with {url, source_type} or multipart file. Enqueue appropriate job. Return {ok:1, job_id:X}.

---

## 9. Minion Jobs

### lib/Dragline/Job/CrawlStatic.pm

Args: {target_id, url, crawl_queue_id (optional)}

1. Mark crawl_queue item as 'processing' if crawl_queue_id provided
2. Validate URL via SSRF.pm — fail job if blocked
3. Call Crawl::fetch_static(url)
4. If word count below threshold and is_js_heavy hint set, log warning and suggest CrawlJS
5. Check content_hash against raw_content for this target — skip if duplicate
6. Insert raw_content record (source_type='crawl_static')
7. Create change_event (event_type='new_content', severity='info')
8. Update crawl_queue item to 'complete' if crawl_queue_id provided
9. Update target_monitoring last_crawl_at
10. Enqueue Embed job for the new raw_content_id

On failure: update crawl_queue to 'failed' with error, create change_event (event_type='crawl_failed', severity='low'), retry up to 3 times with exponential backoff.

### lib/Dragline/Job/CrawlJS.pm

Args: {target_id, url, crawl_queue_id (optional)}

1. Mark crawl_queue item as 'processing' if provided
2. Validate URL via SSRF.pm
3. GET crawl_service_url setting, POST to {crawl_service_url}/crawl with {url}
4. On success: same as CrawlStatic from step 5 onwards (source_type='crawl_js')
5. On crawl service unavailable: fail job with clear error message

### lib/Dragline/Job/IngestPDF.pm

Args: {target_id, file_path (temp file), filename, source_url (optional)}

1. Read file bytes from file_path
2. POST to {crawl_service_url}/extract with file bytes
3. Parse response: {text, tables (JSON), error}
4. Check content_hash against raw_content — skip if duplicate
5. Insert raw_content (source_type='pdf')
6. Create change_event
7. Delete temp file
8. Enqueue Embed job

### lib/Dragline/Job/ForgeSync.pm

Args: {target_id}

1. Fetch target canonical_name and aliases from DB
2. Call Forge::sync_target(target_id, canonical_name)
3. Returns (new_count, error)
4. Update target_monitoring last_forge_sync_at and next_forge_sync_at
5. If new_count > 0: create change_event (event_type='forge_sync', summary="N new items from Forge")
6. Enqueue Embed jobs for each new raw_content_id

### lib/Dragline/Job/Discover.pm

Args: {target_id}

1. Fetch target
2. Call Brave::search_for_target(target)
3. For each result URL:
   - Check not already in crawl_queue or raw_content for this target
   - Insert into crawl_queue (source='brave_discovery')
   - Enqueue CrawlStatic job
4. Create change_event (event_type='discovery_complete', summary="N URLs queued for crawl")
5. Update target_monitoring last_discover_at and next_discover_at

### lib/Dragline/Job/Embed.pm

Args: {raw_content_id}

1. Fetch raw_content by id
2. Check raw_content_embeddings — skip if already embedded
3. Call Embed::embed(content_text)
4. Store embedding blob in raw_content_embeddings
5. Enqueue Score job for this raw_content_id

### lib/Dragline/Job/Synthesise.pm

Args: {target_id}

The map-reduce dossier generation pipeline.

**Map phase** — chunk summarisation:
1. Fetch all raw_content for target, ordered by significance_tier DESC, created_at DESC
2. Split content into chunks of ~2000 words each
3. For each chunk, call LLM::complete(task_type='chunk_summarisation', ...) with Qwen Flash
4. Collect all chunk summaries

**Reduce phase** — generate 10 sections in order:

Section assignments:
1. Identity and Overview — Qwen Plus
2. Key People — Qwen Plus
3. Organisational Structure — Qwen Plus
4. Operational Profile — Qwen Plus
5. Document Archive — Qwen Plus
6. Event Timeline — Qwen Plus
7. Media and Sentiment — Qwen Plus
8. Risk and Flags — Qwen Plus
9. Financial Instruments — Qwen Plus
10. Forward Assessment — Claude Sonnet

For each section:
- Build a system prompt specific to the section
- Feed relevant chunk summaries as context
- Call LLM::complete with appropriate model
- Upsert into dossier_sections
- Update dossier status to 'generating' with section progress

After all 10 sections complete:
- Set dossier status to 'current', generated_at to now
- Create change_event (event_type='dossier_updated', severity='info')

On failure: set dossier status to 'draft', log error.

### lib/Dragline/Job/Score.pm

Args: {raw_content_id}

Stub implementation. When R service is available:
1. Fetch raw_content
2. POST to {r_service_url}/score with {text, source_type, word_count}
3. Parse response {tier: integer 1-163}
4. Update raw_content significance_tier

For now: log that R service is not yet available, set significance_tier to a default based on source_type heuristic:
- forge: 30
- crawl_static: 40
- crawl_js: 40
- pdf: 70
- upload: 60

### lib/Dragline/Job/GapDetect.pm

Args: {target_id}

Stub implementation. When R service is available:
1. Gather content freshness data for target
2. POST to {r_service_url}/gap-detect with data
3. Parse gap findings
4. Create risk flag change_events for detected gaps

For now: log that R service is not yet available. Do nothing else.

### lib/Dragline/Job/CleanupEvents.pm

Args: {} (no args, runs on schedule)

Delete change_events where seen=1 and seen_at < datetime('now', '-30 days').
Log count of deleted records.

### lib/Dragline/Job/ScheduleCrawls.pm

Args: {} (no args, runs on schedule every hour)

1. Query target_monitoring where next_forge_sync_at <= now() and forge_sync_cadence != 'disabled'
2. For each: enqueue ForgeSync job, update next_forge_sync_at based on cadence
3. Query target_monitoring where next_crawl_at <= now() and crawl_cadence != 'disabled'
4. For each: fetch primary_domain and target_domains, enqueue CrawlStatic for each domain
5. Query target_monitoring where next_discover_at <= now() and discover_cadence != 'disabled'
6. For each: enqueue Discover job

---

## 10. Templates

Use Mojolicious EP format (.html.ep). No JavaScript frameworks. Minimal JS only where necessary (form confirmation dialogs, mark-seen XHR).

### layouts/default.html.ep

Full HTML5 document. Include:
- CSP header via nonce: `<script nonce="<%= nonce %>">` pattern
- Navigation: Dragline logo/name, links to Dashboard, Targets, People, Projects, Admin (if admin role)
- Flash message display (success in green, error in red)
- Current user display and logout link
- Main content block
- Clean minimal CSS inline or in public/dragline.css — no external CDN dependencies

### templates/auth/login.html.ep

Simple centred login form. Username, password, CSRF token. No registration link.

### templates/dashboard/index.html.ep

Change feed. For each change_event:
- Target name (linked to /targets/:id)
- Event type badge
- Severity badge (colour coded)
- Summary text
- Source URL if present (external link)
- Time ago (e.g. "3 hours ago")
- Mark as seen button (XHR POST to /changes/:id/seen)

"Mark all seen" button at top.
Unseen count in page title / header.
Pagination if more than 100 events.

### templates/projects/list.html.ep
Table of projects with target count. New project button.

### templates/projects/new.html.ep and edit.html.ep
Simple form: name, description.

### templates/projects/show.html.ep
Project details. List of targets in this project. Links to add target.

### templates/targets/list.html.ep
Table of all targets across all projects. Columns: name, project, entity type, country, active status, content count, dossier status. Filter by project. New target button.

### templates/targets/new.html.ep and edit.html.ep
Fields: canonical_name, entity_type (select), country (text), jurisdiction, primary_domain, language_codes, notes. Project shown but not editable on edit form.

### templates/targets/show.html.ep
Full target view:
- Header with name, entity type, country, active status
- Quick action buttons: Crawl, Forge Sync, Discover, Generate Dossier
- Aliases list with add/delete
- Domains list with add/delete
- Recent change events (last 10)
- People with current roles
- Stats: content count, dossier status, last crawl, last forge sync

### templates/targets/content.html.ep
Paginated list of raw_content. For each item: source type badge, title, word count, significance tier, language, fetched date. Manual crawl form. Upload form. Discover button.

### templates/targets/dossier.html.ep
If no dossier: prompt with generate button.
If generating: progress indicator showing which sections are complete.
If current: show all 10 sections in collapsible panels, generated_at timestamp, regenerate button.
If stale: show sections with stale warning banner, regenerate button.

### templates/people/list.html.ep
Table: canonical name, nationality, role count, connected target count.

### templates/people/new.html.ep and edit.html.ep
Fields: canonical_name, nationality, bio_summary.

### templates/people/show.html.ep
Person details, roles table (target, title, period, current), connections table, add role form, add connection form.

### templates/monitoring/edit.html.ep
Cadence selects for forge_sync, crawl, discover. Show last run times and next scheduled times.

### templates/admin/health.html.ep
DB status, Minion queue depth (pending/running/failed), last cleanup run, settings status (which keys are configured).

### templates/admin/settings.html.ep
Form with all settings. Encrypted fields show masked value. Clear instructions on what each setting does.

### templates/admin/costs.html.ep
Total cost last 30 days. Table by provider. Simple text-based bar representation of daily costs (no JS charts).

### templates/admin/audit.html.ep
Paginated audit log. Columns: time, user, action, entity type, entity ID. Filter by action.

### templates/admin/users.html.ep
User list with role, active status, last login. Add user form inline. Delete button.

### templates/admin/api_keys.html.ep
Key list: name, prefix (e.g. "dk_abc123.."), role, last used, request count, active status. Create key form. On creation, show full key once with copy button (JS).

---

## 11. Tests

### t/helper.pl

Sets up a test Mojolicious app using in-memory SQLite (:memory:). Loads schema.sql. Creates test admin user. Creates test analyst user. Exports: app(), admin_session(), analyst_session(), db().

### t/auth.t

- Login with correct credentials succeeds
- Login with wrong password fails
- Login with nonexistent user fails
- Session persists across requests
- Logout clears session
- 5 failed logins triggers rate limit on 6th attempt
- Protected route redirects to login without session

### t/projects.t

- Create project succeeds
- Create project with empty name fails validation
- Update project name
- Delete empty project
- List projects shows correct count

### t/targets.t

- Create target succeeds
- Duplicate canonical_name within same project fails
- Same canonical_name in different project succeeds
- Add alias
- Delete alias
- Add domain
- Delete domain
- Activate and deactivate target
- Update monitoring cadences

### t/content.t

- Queue crawl job validates URL
- Queue crawl job rejects private IP (SSRF)
- Upload PDF validates magic bytes
- Upload non-PDF as PDF is rejected
- Duplicate content hash is skipped

### t/people.t

- Create person
- Add role to person for target
- Add connection between two people
- Duplicate connection (same pair, same type) is rejected

### t/api.t

- Request without Bearer token returns 401
- Request with invalid token returns 401
- Request with valid token returns data
- GET /api/targets returns JSON array
- GET /api/targets/:id returns target JSON
- GET /api/change-feed returns events
- ?since= parameter filters events

### t/health.t

- GET /health returns 200 JSON with status field
- No authentication required

---

## 12. Deploy Files

### deploy/dragline@.service

systemd unit template. Include:
```
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=yes
ProtectHome=yes
MemoryMax=2G
CPUQuota=200%
```

Environment variables: DRAGLINE_SECRET, DRAGLINE_DB, DRAGLINE_PORT. Read from /etc/dragline/%i.env (not committed, operator creates).

ExecStart: hypnotoad dragline.pl
ExecReload: hypnotoad -s dragline.pl (reload without downtime)
WorkingDirectory: install path

### deploy/dragline-worker@.service

Separate systemd unit for Minion worker. Same hardening. ExecStart: perl dragline.pl minion worker -j 4 (4 concurrent jobs).

### deploy/Caddyfile.example

Reverse proxy to localhost:DRAGLINE_PORT. TLS via Let's Encrypt. Forward auth header for session.

### deploy/deploy.sh

Arguments: instance identifier (e.g. "1" or "prod").

Steps:
1. cd to install directory
2. git pull origin main --rebase
3. git reset --hard origin/main
4. cpanm --installdeps --local-lib local .
5. perl -c dragline.pl || exit 1 (syntax check)
6. systemctl restart dragline@$1
7. systemctl restart dragline-worker@$1
8. echo "Deployed successfully"

### deploy/backup.sh

Arguments: instance identifier.

1. Read DRAGLINE_DB path from env file
2. sqlite3 $DRAGLINE_DB ".backup backup_$(date +%Y%m%d_%H%M%S).db"
3. Compress with gzip
4. Move to backup destination (configured in script header)
5. Delete backups older than 30 days
6. Log completion

---

## 13. README.md

Cover:
- What Dragline is (two sentences)
- Stack
- Prerequisites (Perl 5.36+, SQLite 3.38+ with sqlite-vec, cpanm)
- Running locally (env vars, morbo command, Minion worker command)
- Running tests (prove -lr t/)
- First run (change admin password, configure API keys in settings)
- Deploying (deploy.sh usage)
- Crawl service (brief note that it's a separate Python process, link to its own README)
- R service (brief note that it's a separate R process, link to its own README)

---

## Final Instructions

- Generate every file completely. No truncation. No placeholders. No "implement this later" comments in code.
- Stub files for Score.pm and GapDetect.pm are acceptable — they should work and log clearly that R service integration is pending.
- All Perl should be clean modern Perl with use strict; use warnings; use utf8; at the top of every file.
- All SQL should be valid SQLite syntax.
- Templates should be functional and readable — not beautiful, but usable.
- Tests should actually test what they claim to test.
- The whole thing should run with morbo dragline.pl after cpanm --installdeps . and setting the three required env vars.
