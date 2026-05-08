-- Dragline Entity Intelligence Platform
-- Schema v0.1.0
-- SQLite with WAL mode and foreign key enforcement
-- Application code must also execute PRAGMA foreign_keys = ON on every connection.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS projects (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    description TEXT,
    created_at  DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at  DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS targets (
    id                  TEXT PRIMARY KEY,
    project_id          TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    canonical_name      TEXT NOT NULL,
    canonical_name_lower TEXT NOT NULL,
    entity_type         TEXT NOT NULL DEFAULT 'company'
        CHECK (entity_type IN ('company','exchange','regulator','agency','individual','other')),
    country             TEXT,
    jurisdiction        TEXT,
    primary_domain      TEXT,
    language_codes      TEXT NOT NULL DEFAULT '["en"]',
    notes               TEXT,
    active              INTEGER NOT NULL DEFAULT 1,
    created_at          DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at          DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (project_id, canonical_name_lower)
);

CREATE TABLE IF NOT EXISTS target_aliases (
    id          TEXT PRIMARY KEY,
    target_id   TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    alias       TEXT NOT NULL,
    alias_lower TEXT NOT NULL,
    created_at  DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id, alias_lower)
);

CREATE TABLE IF NOT EXISTS target_domains (
    id         TEXT PRIMARY KEY,
    target_id  TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    domain     TEXT NOT NULL,
    is_primary INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id, domain)
);

CREATE TABLE IF NOT EXISTS target_monitoring (
    id                  TEXT PRIMARY KEY,
    target_id           TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    forge_sync_cadence  TEXT NOT NULL DEFAULT 'daily'
        CHECK (forge_sync_cadence IN ('hourly','daily','weekly','disabled')),
    crawl_cadence       TEXT NOT NULL DEFAULT 'weekly'
        CHECK (crawl_cadence IN ('daily','weekly','monthly','disabled')),
    discover_cadence    TEXT NOT NULL DEFAULT 'weekly'
        CHECK (discover_cadence IN ('daily','weekly','monthly','disabled')),
    last_forge_sync_at  DATETIME,
    last_crawl_at       DATETIME,
    last_discover_at    DATETIME,
    next_forge_sync_at  DATETIME,
    next_crawl_at       DATETIME,
    next_discover_at    DATETIME,
    created_at          DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at          DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id)
);

CREATE TABLE IF NOT EXISTS forge_items (
    id            TEXT PRIMARY KEY,
    target_id     TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    forge_item_id TEXT NOT NULL,
    title         TEXT,
    url           TEXT,
    published_at  DATETIME,
    sentiment_score REAL,
    mention_count INTEGER,
    raw_json      TEXT,
    imported_at   DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id, forge_item_id)
);

CREATE TABLE IF NOT EXISTS crawl_queue (
    id           TEXT PRIMARY KEY,
    target_id    TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    url          TEXT NOT NULL,
    source       TEXT NOT NULL DEFAULT 'manual'
        CHECK (source IN ('manual','brave_discovery','forge_link','sitemap')),
    priority     INTEGER NOT NULL DEFAULT 5,
    status       TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','processing','complete','failed','skipped')),
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT,
    queued_at    DATETIME NOT NULL DEFAULT (datetime('now')),
    processed_at DATETIME,
    UNIQUE (target_id, url)
);

CREATE TABLE IF NOT EXISTS raw_content (
    id                TEXT PRIMARY KEY,
    target_id         TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    source_type       TEXT NOT NULL
        CHECK (source_type IN ('forge','crawl_static','crawl_js','pdf','upload')),
    source_url        TEXT,
    source_title      TEXT,
    content_text      TEXT NOT NULL,
    content_hash      TEXT NOT NULL,
    language_code     TEXT,
    significance_tier INTEGER
        CHECK (significance_tier IS NULL OR (significance_tier >= 1 AND significance_tier <= 163)),
    word_count        INTEGER,
    fetched_at        DATETIME,
    created_at        DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id, content_hash)
);

CREATE TABLE IF NOT EXISTS raw_content_embeddings (
    id             TEXT PRIMARY KEY,
    raw_content_id TEXT NOT NULL REFERENCES raw_content(id) ON DELETE CASCADE,
    embedding      BLOB NOT NULL,
    model          TEXT NOT NULL DEFAULT 'text-embedding-v4',
    dimensions     INTEGER NOT NULL DEFAULT 1024,
    created_at     DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (raw_content_id)
);

CREATE TABLE IF NOT EXISTS change_events (
    id             TEXT PRIMARY KEY,
    target_id      TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    event_type     TEXT NOT NULL
        CHECK (event_type IN ('new_content','gap_detected','dossier_updated','crawl_failed','forge_sync','discovery_complete')),
    summary        TEXT NOT NULL,
    source_url     TEXT,
    raw_content_id TEXT REFERENCES raw_content(id) ON DELETE SET NULL,
    severity       TEXT NOT NULL DEFAULT 'info'
        CHECK (severity IN ('info','low','medium','high','critical')),
    seen           INTEGER NOT NULL DEFAULT 0,
    seen_at        DATETIME,
    created_at     DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS dossiers (
    id           TEXT PRIMARY KEY,
    target_id    TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    status       TEXT NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft','current','stale','generating')),
    generated_at DATETIME,
    created_at   DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at   DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id)
);

CREATE TABLE IF NOT EXISTS dossier_sections (
    id             TEXT PRIMARY KEY,
    dossier_id     TEXT NOT NULL REFERENCES dossiers(id) ON DELETE CASCADE,
    section_number INTEGER NOT NULL CHECK (section_number BETWEEN 1 AND 10),
    section_name   TEXT NOT NULL,
    content        TEXT,
    model_used     TEXT,
    token_count    INTEGER,
    created_at     DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at     DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (dossier_id, section_number)
);

CREATE TABLE IF NOT EXISTS people (
    id                   TEXT PRIMARY KEY,
    canonical_name       TEXT NOT NULL,
    canonical_name_lower TEXT NOT NULL,
    nationality          TEXT,
    bio_summary          TEXT,
    merged_into          TEXT REFERENCES people(id) ON DELETE SET NULL,
    created_at           DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at           DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS person_roles (
    id         TEXT PRIMARY KEY,
    person_id  TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    target_id  TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    title      TEXT NOT NULL,
    started_at DATE,
    ended_at   DATE,
    is_current INTEGER NOT NULL DEFAULT 1,
    source_url TEXT,
    created_at DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS person_connections (
    id                TEXT PRIMARY KEY,
    person_id_a       TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    person_id_b       TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    relationship_type TEXT NOT NULL
        CHECK (relationship_type IN ('revolving_door','shared_board','political_affiliation','family_ownership','legal_co_appearance')),
    notes      TEXT,
    source_url TEXT,
    created_at DATETIME NOT NULL DEFAULT (datetime('now')),
    CHECK (person_id_a < person_id_b),
    UNIQUE (person_id_a, person_id_b, relationship_type)
);

CREATE TABLE IF NOT EXISTS api_keys (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    key_hash      TEXT NOT NULL UNIQUE,
    key_prefix    TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'readonly'
        CHECK (role IN ('readonly','analyst','admin')),
    active        INTEGER NOT NULL DEFAULT 1,
    last_used_at  DATETIME,
    request_count INTEGER NOT NULL DEFAULT 0,
    expires_at    DATETIME,
    created_at    DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at    DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS cost_records (
    id                TEXT PRIMARY KEY,
    provider          TEXT NOT NULL,
    operation         TEXT NOT NULL,
    model             TEXT,
    input_tokens      INTEGER,
    output_tokens     INTEGER,
    estimated_cost_usd REAL,
    target_id         TEXT REFERENCES targets(id) ON DELETE SET NULL,
    job_id            TEXT,
    status            TEXT NOT NULL DEFAULT 'success'
        CHECK (status IN ('success','failed')),
    created_at        DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS settings (
    key          TEXT PRIMARY KEY,
    value        TEXT,
    is_encrypted INTEGER NOT NULL DEFAULT 0,
    updated_at   DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,
    username      TEXT NOT NULL,
    username_lower TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role          TEXT NOT NULL DEFAULT 'analyst'
        CHECK (role IN ('admin','analyst')),
    active        INTEGER NOT NULL DEFAULT 1,
    last_login_at DATETIME,
    created_at    DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at    DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS login_attempts (
    id           TEXT PRIMARY KEY,
    ip_address   TEXT NOT NULL,
    attempted_at DATETIME NOT NULL DEFAULT (datetime('now')),
    success      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS audit_log (
    id          TEXT PRIMARY KEY,
    user_id     TEXT REFERENCES users(id) ON DELETE SET NULL,
    action      TEXT NOT NULL,
    entity_type TEXT,
    entity_id   TEXT,
    changes     TEXT,
    ip_address  TEXT,
    user_agent  TEXT,
    created_at  DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS person_merge_log (
    id                     TEXT PRIMARY KEY,
    primary_person_id      TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    merged_person_id       TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    merged_person_name     TEXT NOT NULL,
    roles_reassigned       INTEGER NOT NULL DEFAULT 0,
    connections_reassigned INTEGER NOT NULL DEFAULT 0,
    performed_by           TEXT REFERENCES users(id) ON DELETE SET NULL,
    merge_note             TEXT,
    created_at             DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS gap_signals (
    id                TEXT PRIMARY KEY,
    target_id         TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    gap_type          TEXT NOT NULL
        CHECK (gap_type IN (
            'media_silence','website_freeze','financial_silence',
            'personnel_silence','content_silence'
        )),
    gap_days          INTEGER NOT NULL,
    severity          TEXT NOT NULL CHECK (severity IN ('low','medium','high')),
    is_active         INTEGER NOT NULL DEFAULT 1,
    first_detected_at DATETIME NOT NULL DEFAULT (datetime('now')),
    last_checked_at   DATETIME NOT NULL DEFAULT (datetime('now')),
    resolved_at       DATETIME,
    UNIQUE (target_id, gap_type)
);

CREATE TABLE IF NOT EXISTS forward_assessments (
    id                  TEXT PRIMARY KEY,
    target_id           TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    dossier_id          TEXT NOT NULL REFERENCES dossiers(id) ON DELETE CASCADE,
    base_case           TEXT NOT NULL,
    downside_case       TEXT NOT NULL,
    upside_case         TEXT NOT NULL,
    recommended_posture TEXT NOT NULL
        CHECK (recommended_posture IN
            ('monitor','engage','avoid','investigate','escalate')),
    posture_rationale   TEXT NOT NULL,
    executive_actions   TEXT NOT NULL,
    watch_list          TEXT,
    model_used          TEXT,
    created_at          DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at          DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id)
);

CREATE TABLE IF NOT EXISTS job_steps (
    id          TEXT PRIMARY KEY,
    scope_type  TEXT NOT NULL,
    scope_id    TEXT NOT NULL,
    step_name   TEXT NOT NULL,
    result_json TEXT,
    created_at  DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (scope_type, scope_id, step_name)
);

CREATE TABLE IF NOT EXISTS monitor_runs (
    id          TEXT PRIMARY KEY,
    target_id   TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    run_type    TEXT NOT NULL DEFAULT 'full'
        CHECK (run_type IN ('content','forge','full')),
    status      TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('running','complete','failed')),
    started_at  DATETIME NOT NULL DEFAULT (datetime('now')),
    completed_at DATETIME,
    created_at  DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS monitor_deltas (
    id              TEXT PRIMARY KEY,
    monitor_run_id  TEXT NOT NULL REFERENCES monitor_runs(id) ON DELETE CASCADE,
    target_id       TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    delta_type      TEXT NOT NULL
        CHECK (delta_type IN ('new_content','updated_content','removed_content',
                               'new_forge_item','updated_dossier')),
    source_type     TEXT
        CHECK (source_type IN ('raw_content','forge_item','dossier_section')),
    source_id       TEXT,
    description     TEXT NOT NULL,
    severity        TEXT NOT NULL DEFAULT 'info'
        CHECK (severity IN ('info','low','medium','high','critical')),
    created_at      DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS event_timeline (
    id              TEXT PRIMARY KEY,
    target_id       TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    event_date      DATE,
    event_type      TEXT NOT NULL DEFAULT 'general'
        CHECK (event_type IN ('general','corporate','legal','financial',
                               'personnel','regulatory','media','sanctions')),
    description     TEXT NOT NULL,
    source_url      TEXT,
    source_section  TEXT,
    confidence      TEXT NOT NULL DEFAULT 'medium'
        CHECK (confidence IN ('low','medium','high')),
    created_at      DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS dossier_versions (
    id              TEXT PRIMARY KEY,
    dossier_id      TEXT NOT NULL REFERENCES dossiers(id) ON DELETE CASCADE,
    target_id       TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    version_number  INTEGER NOT NULL,
    snapshot_json   TEXT NOT NULL,
    created_by      TEXT,
    created_at      DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (dossier_id, version_number)
);

CREATE TABLE IF NOT EXISTS sanctions_matches (
    id              TEXT PRIMARY KEY,
    target_id       TEXT REFERENCES targets(id) ON DELETE CASCADE,
    person_id       TEXT REFERENCES people(id) ON DELETE SET NULL,
    match_type      TEXT NOT NULL
        CHECK (match_type IN ('target','person')),
    entity_name     TEXT NOT NULL,
    matched_name    TEXT NOT NULL,
    dataset         TEXT,
    score           REAL,
    match_data      TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','confirmed','dismissed')),
    created_at      DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at      DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS domain_whois (
    id              TEXT PRIMARY KEY,
    domain          TEXT NOT NULL,
    target_id       TEXT REFERENCES targets(id) ON DELETE CASCADE,
    registrar       TEXT,
    registrant_name TEXT,
    registrant_org  TEXT,
    created_date    DATETIME,
    updated_date    DATETIME,
    expiry_date     DATETIME,
    name_servers    TEXT,
    raw_json        TEXT,
    fetched_at      DATETIME,
    created_at      DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS domain_dns_records (
    id          TEXT PRIMARY KEY,
    domain      TEXT NOT NULL,
    target_id   TEXT REFERENCES targets(id) ON DELETE CASCADE,
    record_type TEXT NOT NULL,
    record_value TEXT NOT NULL,
    ttl         INTEGER,
    fetched_at  DATETIME,
    created_at  DATETIME NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_targets_project_id        ON targets(project_id);
CREATE INDEX IF NOT EXISTS idx_targets_active            ON targets(active);
CREATE INDEX IF NOT EXISTS idx_targets_canonical_lower   ON targets(canonical_name_lower);

CREATE INDEX IF NOT EXISTS idx_target_aliases_target_id  ON target_aliases(target_id);
CREATE INDEX IF NOT EXISTS idx_target_aliases_lower      ON target_aliases(alias_lower);

CREATE INDEX IF NOT EXISTS idx_target_domains_target_id  ON target_domains(target_id);

CREATE INDEX IF NOT EXISTS idx_target_mon_next_forge     ON target_monitoring(next_forge_sync_at);
CREATE INDEX IF NOT EXISTS idx_target_mon_next_crawl     ON target_monitoring(next_crawl_at);
CREATE INDEX IF NOT EXISTS idx_target_mon_next_discover  ON target_monitoring(next_discover_at);

CREATE INDEX IF NOT EXISTS idx_forge_items_target_id     ON forge_items(target_id);
CREATE INDEX IF NOT EXISTS idx_forge_items_item_id       ON forge_items(forge_item_id);
CREATE INDEX IF NOT EXISTS idx_forge_items_published_at  ON forge_items(published_at);

CREATE INDEX IF NOT EXISTS idx_crawl_queue_target_id     ON crawl_queue(target_id);
CREATE INDEX IF NOT EXISTS idx_crawl_queue_status        ON crawl_queue(status);
CREATE INDEX IF NOT EXISTS idx_crawl_queue_priority      ON crawl_queue(priority);

CREATE INDEX IF NOT EXISTS idx_raw_content_target_id     ON raw_content(target_id);
CREATE INDEX IF NOT EXISTS idx_raw_content_hash          ON raw_content(content_hash);
CREATE INDEX IF NOT EXISTS idx_raw_content_source_type   ON raw_content(source_type);
CREATE INDEX IF NOT EXISTS idx_raw_content_created_at    ON raw_content(created_at);

CREATE INDEX IF NOT EXISTS idx_rce_raw_content_id        ON raw_content_embeddings(raw_content_id);

CREATE INDEX IF NOT EXISTS idx_change_events_target_id   ON change_events(target_id);
CREATE INDEX IF NOT EXISTS idx_change_events_seen        ON change_events(seen);
CREATE INDEX IF NOT EXISTS idx_change_events_created_at  ON change_events(created_at);
CREATE INDEX IF NOT EXISTS idx_change_events_severity    ON change_events(severity);

CREATE INDEX IF NOT EXISTS idx_dossiers_target_id        ON dossiers(target_id);
CREATE INDEX IF NOT EXISTS idx_dossiers_status           ON dossiers(status);

CREATE INDEX IF NOT EXISTS idx_dossier_sections_dossier  ON dossier_sections(dossier_id);

CREATE INDEX IF NOT EXISTS idx_people_canonical_lower    ON people(canonical_name_lower);

CREATE INDEX IF NOT EXISTS idx_person_roles_person_id    ON person_roles(person_id);
CREATE INDEX IF NOT EXISTS idx_person_roles_target_id    ON person_roles(target_id);
CREATE INDEX IF NOT EXISTS idx_person_roles_is_current   ON person_roles(is_current);

CREATE INDEX IF NOT EXISTS idx_person_conn_person_a      ON person_connections(person_id_a);
CREATE INDEX IF NOT EXISTS idx_person_conn_person_b      ON person_connections(person_id_b);

CREATE INDEX IF NOT EXISTS idx_api_keys_hash             ON api_keys(key_hash);
CREATE INDEX IF NOT EXISTS idx_api_keys_active           ON api_keys(active);

CREATE INDEX IF NOT EXISTS idx_cost_records_provider     ON cost_records(provider);
CREATE INDEX IF NOT EXISTS idx_cost_records_target_id    ON cost_records(target_id);
CREATE INDEX IF NOT EXISTS idx_cost_records_created_at   ON cost_records(created_at);

CREATE INDEX IF NOT EXISTS idx_login_attempts_ip         ON login_attempts(ip_address);
CREATE INDEX IF NOT EXISTS idx_login_attempts_at         ON login_attempts(attempted_at);

CREATE INDEX IF NOT EXISTS idx_audit_log_user_id         ON audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_entity_type     ON audit_log(entity_type);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at      ON audit_log(created_at);

CREATE INDEX IF NOT EXISTS idx_gap_signals_target_id     ON gap_signals(target_id);
CREATE INDEX IF NOT EXISTS idx_gap_signals_active        ON gap_signals(is_active);

CREATE INDEX IF NOT EXISTS idx_forward_assessments_target_id ON forward_assessments(target_id);
CREATE INDEX IF NOT EXISTS idx_forward_assessments_dossier_id ON forward_assessments(dossier_id);

CREATE INDEX IF NOT EXISTS idx_monitor_runs_target_id    ON monitor_runs(target_id);
CREATE INDEX IF NOT EXISTS idx_monitor_runs_status       ON monitor_runs(status);
CREATE INDEX IF NOT EXISTS idx_monitor_deltas_run_id     ON monitor_deltas(monitor_run_id);
CREATE INDEX IF NOT EXISTS idx_monitor_deltas_target_id  ON monitor_deltas(target_id);
CREATE INDEX IF NOT EXISTS idx_monitor_deltas_severity   ON monitor_deltas(severity);

CREATE INDEX IF NOT EXISTS idx_event_timeline_target_id  ON event_timeline(target_id);
CREATE INDEX IF NOT EXISTS idx_event_timeline_date       ON event_timeline(event_date);
CREATE INDEX IF NOT EXISTS idx_event_timeline_type       ON event_timeline(event_type);

CREATE INDEX IF NOT EXISTS idx_dossier_versions_dossier  ON dossier_versions(dossier_id);
CREATE INDEX IF NOT EXISTS idx_dossier_versions_target   ON dossier_versions(target_id);

CREATE INDEX IF NOT EXISTS idx_sanctions_matches_target  ON sanctions_matches(target_id);
CREATE INDEX IF NOT EXISTS idx_sanctions_matches_person  ON sanctions_matches(person_id);
CREATE INDEX IF NOT EXISTS idx_sanctions_matches_status  ON sanctions_matches(status);

CREATE INDEX IF NOT EXISTS idx_domain_whois_domain       ON domain_whois(domain);
CREATE INDEX IF NOT EXISTS idx_domain_whois_target       ON domain_whois(target_id);
CREATE INDEX IF NOT EXISTS idx_domain_dns_domain         ON domain_dns_records(domain);
CREATE INDEX IF NOT EXISTS idx_domain_dns_target         ON domain_dns_records(target_id);

-- ============================================================
-- TRIGGERS — maintain updated_at automatically
-- ============================================================

CREATE TRIGGER IF NOT EXISTS trg_projects_updated_at
AFTER UPDATE ON projects
FOR EACH ROW
BEGIN
    UPDATE projects SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_targets_updated_at
AFTER UPDATE ON targets
FOR EACH ROW
BEGIN
    UPDATE targets SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_target_monitoring_updated_at
AFTER UPDATE ON target_monitoring
FOR EACH ROW
BEGIN
    UPDATE target_monitoring SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_dossiers_updated_at
AFTER UPDATE ON dossiers
FOR EACH ROW
BEGIN
    UPDATE dossiers SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_dossier_sections_updated_at
AFTER UPDATE ON dossier_sections
FOR EACH ROW
BEGIN
    UPDATE dossier_sections SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_people_updated_at
AFTER UPDATE ON people
FOR EACH ROW
BEGIN
    UPDATE people SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_person_roles_updated_at
AFTER UPDATE ON person_roles
FOR EACH ROW
BEGIN
    UPDATE person_roles SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_api_keys_updated_at
AFTER UPDATE ON api_keys
FOR EACH ROW
BEGIN
    UPDATE api_keys SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_users_updated_at
AFTER UPDATE ON users
FOR EACH ROW
BEGIN
    UPDATE users SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_settings_updated_at
AFTER UPDATE ON settings
FOR EACH ROW
BEGIN
    UPDATE settings SET updated_at = datetime('now') WHERE key = NEW.key;
END;

CREATE TRIGGER IF NOT EXISTS trg_gap_signals_checked_at
AFTER UPDATE ON gap_signals
FOR EACH ROW
BEGIN
    UPDATE gap_signals SET last_checked_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_forward_assessments_updated_at
AFTER UPDATE ON forward_assessments
FOR EACH ROW
BEGIN
    UPDATE forward_assessments SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_sanctions_matches_updated_at
AFTER UPDATE ON sanctions_matches
FOR EACH ROW
BEGIN
    UPDATE sanctions_matches SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- ============================================================
-- SEED DATA
-- ============================================================

-- Default admin user. Deploy script must prompt operator to change password on first run.
-- password_hash is a placeholder — not a valid bcrypt hash. The app will reject login until
-- the operator sets a real password via the admin UI or CLI.
INSERT OR IGNORE INTO users (id, username, username_lower, password_hash, role, active, created_at, updated_at)
VALUES (
    '00000000-0000-0000-0000-000000000001',
    'admin',
    'admin',
    '$2b$12$placeholder',
    'admin',
    1,
    datetime('now'),
    datetime('now')
);

-- Default settings. Encrypted fields start empty, operator sets real values via admin UI.
INSERT OR IGNORE INTO settings (key, value, is_encrypted, updated_at) VALUES
    ('anthropic_api_key',        '',                       1, datetime('now')),
    ('qwen_api_key',             '',                       1, datetime('now')),
    ('alibaba_api_key',          '',                       1, datetime('now')),
    ('brave_api_key',            '',                       1, datetime('now')),
    ('forge_api_url',            '',                       0, datetime('now')),
    ('forge_api_key',            '',                       1, datetime('now')),
    ('ollama_base_url',          'http://localhost:11434', 0, datetime('now')),
    ('crawl_service_url',        'http://localhost:3002',  0, datetime('now')),
    ('r_service_url',            'http://localhost:3003',  0, datetime('now')),
    ('crawl_content_threshold',  '500',                    0, datetime('now')),
    ('default_embed_model',      'text-embedding-v4',      0, datetime('now')),
    ('opensanctions_api_key',    '',                       1, datetime('now')),
    ('app_version',              '0.2.0',                  0, datetime('now'));
