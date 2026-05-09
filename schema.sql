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
        CHECK (source_type IN ('forge','crawl_static','bucket_js','pdf','upload')),
    source_url        TEXT,
    source_title      TEXT,
    content_text      TEXT NOT NULL,
    content_hash      TEXT NOT NULL,
    language_code     TEXT,
    significance_tier INTEGER
        CHECK (significance_tier IS NULL OR (significance_tier >= 1 AND significance_tier <= 163)),
    word_count        INTEGER,
    storage_key       TEXT,
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

CREATE TABLE IF NOT EXISTS document_extractions (
    id              TEXT PRIMARY KEY,
    raw_content_id  TEXT NOT NULL REFERENCES raw_content(id) ON DELETE CASCADE,
    extraction_type TEXT NOT NULL DEFAULT 'structured',
    extracted_json  TEXT,
    model_used      TEXT,
    confidence      REAL,
    status          TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','complete','failed')),
    created_at      DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS ner_entities (
    id              TEXT PRIMARY KEY,
    raw_content_id  TEXT NOT NULL REFERENCES raw_content(id) ON DELETE CASCADE,
    entity_text     TEXT NOT NULL,
    entity_type     TEXT NOT NULL CHECK (entity_type IN ('PER','ORG','LOC','MISC')),
    confidence      REAL,
    language        TEXT,
    model_used      TEXT NOT NULL DEFAULT 'wikineural-multilingual-ner',
    created_at      DATETIME NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_ner_entities_content ON ner_entities(raw_content_id);
CREATE INDEX IF NOT EXISTS idx_ner_entities_type    ON ner_entities(entity_type);
CREATE INDEX IF NOT EXISTS idx_ner_entities_text    ON ner_entities(entity_text);

CREATE TABLE IF NOT EXISTS change_events (
    id             TEXT PRIMARY KEY,
    target_id      TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    event_type     TEXT NOT NULL
        CHECK (event_type IN ('new_content','updated_content','gap_detected','dossier_updated','crawl_failed','forge_sync','discovery_complete')),
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

CREATE TABLE IF NOT EXISTS org_structure (
    id                TEXT PRIMARY KEY,
    parent_target_id  TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    child_target_id   TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    relationship_type TEXT NOT NULL
        CHECK (relationship_type IN ('subsidiary','parent','owner','affiliate','branch')),
    percent_ownership REAL,
    notes             TEXT,
    created_at        DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at        DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (parent_target_id, child_target_id, relationship_type)
);

CREATE TABLE IF NOT EXISTS peer_relationships (
    id                TEXT PRIMARY KEY,
    target_id_a       TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    target_id_b       TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    relationship_type TEXT NOT NULL
        CHECK (relationship_type IN ('competitor','partner','supplier','client','peer')),
    notes             TEXT,
    created_at        DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at        DATETIME NOT NULL DEFAULT (datetime('now')),
    CHECK (target_id_a < target_id_b),
    UNIQUE (target_id_a, target_id_b, relationship_type)
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
    primary_person_id      TEXT NOT NULL REFERENCES people(id) ON DELETE RESTRICT,
    merged_person_id       TEXT NOT NULL REFERENCES people(id) ON DELETE RESTRICT,
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
    id                TEXT PRIMARY KEY,
    target_id         TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    event_date        DATE,
    event_type        TEXT NOT NULL DEFAULT 'general'
        CHECK (event_type IN ('general','corporate','legal','financial',
                               'personnel','regulatory','media','sanctions')),
    description       TEXT NOT NULL,
    description_hash  TEXT,
    source_url        TEXT,
    source_section    TEXT,
    confidence        TEXT NOT NULL DEFAULT 'medium'
        CHECK (confidence IN ('low','medium','high')),
    created_at        DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id, event_date, description_hash)
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
    updated_at      DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id, person_id, entity_name, matched_name, dataset)
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
    created_at      DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (domain, target_id)
);

CREATE TABLE IF NOT EXISTS domain_dns_records (
    id           TEXT PRIMARY KEY,
    domain       TEXT NOT NULL,
    target_id    TEXT REFERENCES targets(id) ON DELETE CASCADE,
    record_type  TEXT NOT NULL,
    record_value TEXT NOT NULL,
    ttl          INTEGER,
    fetched_at   DATETIME,
    created_at   DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (domain, target_id, record_type, record_value)
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

CREATE INDEX IF NOT EXISTS idx_doc_extractions_raw_content ON document_extractions(raw_content_id);

CREATE INDEX IF NOT EXISTS idx_org_structure_parent      ON org_structure(parent_target_id);
CREATE INDEX IF NOT EXISTS idx_org_structure_child       ON org_structure(child_target_id);

CREATE INDEX IF NOT EXISTS idx_peer_rel_a                ON peer_relationships(target_id_a);
CREATE INDEX IF NOT EXISTS idx_peer_rel_b                ON peer_relationships(target_id_b);

CREATE INDEX IF NOT EXISTS idx_person_merge_log_primary  ON person_merge_log(primary_person_id);
CREATE INDEX IF NOT EXISTS idx_person_merge_log_merged   ON person_merge_log(merged_person_id);

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

CREATE TRIGGER IF NOT EXISTS trg_org_structure_updated_at
AFTER UPDATE ON org_structure
FOR EACH ROW
BEGIN
    UPDATE org_structure SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_peer_relationships_updated_at
AFTER UPDATE ON peer_relationships
FOR EACH ROW
BEGIN
    UPDATE peer_relationships SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TABLE IF NOT EXISTS raw_content_diffs (
    id                 TEXT PRIMARY KEY,
    target_id          TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    old_raw_content_id TEXT REFERENCES raw_content(id) ON DELETE SET NULL,
    new_raw_content_id TEXT NOT NULL REFERENCES raw_content(id) ON DELETE CASCADE,
    source_url         TEXT,
    old_hash           TEXT NOT NULL,
    new_hash           TEXT NOT NULL,
    diff_text          TEXT,
    word_count_delta   INTEGER,
    created_at         DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS watched_sources (
    id              TEXT PRIMARY KEY,
    target_id       TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    url             TEXT NOT NULL,
    watch_cadence   TEXT NOT NULL DEFAULT 'daily'
        CHECK (watch_cadence IN ('hourly','daily','weekly')),
    last_checked_at DATETIME,
    next_check_at   DATETIME,
    active          INTEGER NOT NULL DEFAULT 1,
    created_at      DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at      DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE (target_id, url)
);

CREATE TABLE IF NOT EXISTS domain_blocklist (
    id         TEXT PRIMARY KEY,
    domain     TEXT NOT NULL UNIQUE,
    reason     TEXT,
    created_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    created_at DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS adversarial_checks (
    id                    TEXT PRIMARY KEY,
    target_id             TEXT NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
    dossier_id            TEXT NOT NULL REFERENCES dossiers(id) ON DELETE CASCADE,
    section_number        INTEGER NOT NULL,
    original_text         TEXT NOT NULL,
    cross_validation_text TEXT,
    agreement_score       REAL,
    model_used            TEXT,
    status                TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','complete','failed')),
    created_at            DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at            DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS backup_logs (
    id               TEXT PRIMARY KEY,
    backup_type      TEXT NOT NULL DEFAULT 'full'
        CHECK (backup_type IN ('full','incremental')),
    status           TEXT NOT NULL DEFAULT 'running'
        CHECK (status IN ('running','complete','failed')),
    file_path        TEXT,
    file_size_bytes  INTEGER,
    checksum         TEXT,
    error_message    TEXT,
    started_at       DATETIME NOT NULL DEFAULT (datetime('now')),
    completed_at     DATETIME,
    created_at       DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at       DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_raw_content_diffs_target ON raw_content_diffs(target_id);
CREATE INDEX IF NOT EXISTS idx_raw_content_diffs_url     ON raw_content_diffs(source_url);
CREATE INDEX IF NOT EXISTS idx_raw_content_diffs_created ON raw_content_diffs(created_at);

CREATE INDEX IF NOT EXISTS idx_watched_sources_target    ON watched_sources(target_id);
CREATE INDEX IF NOT EXISTS idx_watched_sources_next      ON watched_sources(next_check_at);
CREATE INDEX IF NOT EXISTS idx_watched_sources_active    ON watched_sources(active);

CREATE INDEX IF NOT EXISTS idx_domain_blocklist_domain   ON domain_blocklist(domain);

CREATE INDEX IF NOT EXISTS idx_adversarial_checks_target ON adversarial_checks(target_id);
CREATE INDEX IF NOT EXISTS idx_adversarial_checks_status ON adversarial_checks(status);

CREATE INDEX IF NOT EXISTS idx_backup_logs_status        ON backup_logs(status);
CREATE INDEX IF NOT EXISTS idx_backup_logs_started       ON backup_logs(started_at);

CREATE TRIGGER IF NOT EXISTS trg_watched_sources_updated_at
AFTER UPDATE ON watched_sources
FOR EACH ROW
BEGIN
    UPDATE watched_sources SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_adversarial_checks_updated_at
AFTER UPDATE ON adversarial_checks
FOR EACH ROW
BEGIN
    UPDATE adversarial_checks SET updated_at = datetime('now') WHERE id = NEW.id;
END;

CREATE TABLE IF NOT EXISTS bookmarks (
    id             TEXT PRIMARY KEY,
    user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    raw_content_id TEXT NOT NULL REFERENCES raw_content(id) ON DELETE CASCADE,
    notes          TEXT,
    created_at     DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE(user_id, raw_content_id)
);

CREATE TABLE IF NOT EXISTS bookmark_collections (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    created_at DATETIME NOT NULL DEFAULT (datetime('now')),
    UNIQUE(user_id, name)
);

CREATE TABLE IF NOT EXISTS bookmark_collection_items (
    collection_id TEXT NOT NULL REFERENCES bookmark_collections(id) ON DELETE CASCADE,
    bookmark_id   TEXT NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
    added_at      DATETIME NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY(collection_id, bookmark_id)
);

CREATE TABLE IF NOT EXISTS saved_queries (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    label       TEXT NOT NULL,
    query_text  TEXT NOT NULL,
    search_type TEXT NOT NULL CHECK(search_type IN ('text','semantic')),
    created_at  DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS webhook_configs (
    id          TEXT PRIMARY KEY,
    user_id     TEXT REFERENCES users(id) ON DELETE CASCADE,
    target_id   TEXT REFERENCES targets(id) ON DELETE CASCADE,
    url         TEXT NOT NULL,
    secret      TEXT,
    event_types TEXT NOT NULL DEFAULT '[]',
    is_active   INTEGER NOT NULL DEFAULT 1,
    created_at  DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at  DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS webhook_deliveries (
    id                   TEXT PRIMARY KEY,
    webhook_config_id    TEXT NOT NULL REFERENCES webhook_configs(id) ON DELETE CASCADE,
    event_type           TEXT NOT NULL,
    payload              TEXT NOT NULL,
    attempt_count        INTEGER NOT NULL DEFAULT 0,
    last_response_status INTEGER,
    last_response_body   TEXT,
    delivered_at         DATETIME,
    last_error           TEXT,
    created_at           DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at           DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS user_notifications (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    change_event_id TEXT REFERENCES change_events(id) ON DELETE CASCADE,
    target_id       TEXT REFERENCES targets(id) ON DELETE CASCADE,
    event_type      TEXT NOT NULL,
    message         TEXT NOT NULL,
    is_read         INTEGER NOT NULL DEFAULT 0,
    created_at      DATETIME NOT NULL DEFAULT (datetime('now')),
    updated_at      DATETIME NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS notification_preferences (
    user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    event_type    TEXT NOT NULL,
    notify_in_app INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(user_id, event_type)
);

CREATE INDEX IF NOT EXISTS idx_bookmarks_user ON bookmarks(user_id);
CREATE INDEX IF NOT EXISTS idx_bookmark_collection_items_collection ON bookmark_collection_items(collection_id);
CREATE INDEX IF NOT EXISTS idx_saved_queries_user ON saved_queries(user_id);
CREATE INDEX IF NOT EXISTS idx_webhook_configs_user ON webhook_configs(user_id);
CREATE INDEX IF NOT EXISTS idx_webhook_configs_target ON webhook_configs(target_id);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_config ON webhook_deliveries(webhook_config_id);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_pending ON webhook_deliveries(delivered_at) WHERE delivered_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_user_notifications_user_unread ON user_notifications(user_id, is_read, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_notifications_target ON user_notifications(target_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_monitor_deltas_unique ON monitor_deltas(monitor_run_id, delta_type, source_id);
CREATE INDEX IF NOT EXISTS idx_job_steps_scope ON job_steps(scope_type, scope_id);

-- ============================================================
-- RATE LIMITING
-- ============================================================

CREATE TABLE IF NOT EXISTS rate_limit_windows (
    bucket_key  TEXT PRIMARY KEY,
    timestamps  TEXT NOT NULL DEFAULT '[]',
    updated_at  REAL NOT NULL DEFAULT (unixepoch())
);

-- ============================================================
-- MIGRATIONS (ALTER TABLE statements are safe to re-run;
--   DB.pm ignores "duplicate column name" errors)
-- ============================================================

ALTER TABLE backup_logs        ADD COLUMN updated_at DATETIME NOT NULL DEFAULT (datetime('now'));
ALTER TABLE webhook_configs    ADD COLUMN updated_at DATETIME NOT NULL DEFAULT (datetime('now'));
ALTER TABLE webhook_deliveries ADD COLUMN updated_at DATETIME NOT NULL DEFAULT (datetime('now'));
ALTER TABLE user_notifications ADD COLUMN updated_at DATETIME NOT NULL DEFAULT (datetime('now'));

-- Recreate person_merge_log with RESTRICT FKs so merge audit records survive
-- independently of the referenced person rows being deleted.
-- DB.pm tolerates the DROP on replay (no such table → ignored).
CREATE TABLE IF NOT EXISTS person_merge_log_v2 (
    id                     TEXT PRIMARY KEY,
    primary_person_id      TEXT NOT NULL REFERENCES people(id) ON DELETE RESTRICT,
    merged_person_id       TEXT NOT NULL REFERENCES people(id) ON DELETE RESTRICT,
    merged_person_name     TEXT NOT NULL,
    roles_reassigned       INTEGER NOT NULL DEFAULT 0,
    connections_reassigned INTEGER NOT NULL DEFAULT 0,
    performed_by           TEXT REFERENCES users(id) ON DELETE SET NULL,
    merge_note             TEXT,
    created_at             DATETIME NOT NULL DEFAULT (datetime('now'))
);
INSERT OR IGNORE INTO person_merge_log_v2 SELECT * FROM person_merge_log;
DROP TABLE IF EXISTS person_merge_log;
ALTER TABLE person_merge_log_v2 RENAME TO person_merge_log;
CREATE INDEX IF NOT EXISTS idx_person_merge_log_primary  ON person_merge_log(primary_person_id);
CREATE INDEX IF NOT EXISTS idx_person_merge_log_merged   ON person_merge_log(merged_person_id);

-- ============================================================
-- FTS5 FULL-TEXT SEARCH
-- ============================================================

CREATE VIRTUAL TABLE IF NOT EXISTS raw_content_fts USING fts5(
    raw_content_id UNINDEXED,
    content_text,
    source_title
);

CREATE TRIGGER IF NOT EXISTS trg_raw_content_fts_insert
AFTER INSERT ON raw_content
BEGIN
    INSERT INTO raw_content_fts(raw_content_id, content_text, source_title)
    VALUES (NEW.id, NEW.content_text, NEW.source_title);
END;

CREATE TRIGGER IF NOT EXISTS trg_raw_content_fts_update
AFTER UPDATE ON raw_content
BEGIN
    UPDATE raw_content_fts SET
        content_text = NEW.content_text,
        source_title = NEW.source_title
    WHERE raw_content_id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_raw_content_fts_delete
AFTER DELETE ON raw_content
BEGIN
    DELETE FROM raw_content_fts WHERE raw_content_id = OLD.id;
END;

-- ============================================================
-- TRIGGERS — updated_at maintenance
-- (DROP + CREATE ensures the correct column is used even when
--  migrating from the broken triggers that updated created_at)
-- ============================================================

DROP TRIGGER IF EXISTS trg_raw_content_diffs_updated_at;

DROP TRIGGER IF EXISTS trg_backup_logs_updated_at;
CREATE TRIGGER trg_backup_logs_updated_at
AFTER UPDATE ON backup_logs
FOR EACH ROW
BEGIN
    UPDATE backup_logs SET updated_at = datetime('now') WHERE id = NEW.id;
END;

DROP TRIGGER IF EXISTS trg_webhook_configs_updated_at;
CREATE TRIGGER trg_webhook_configs_updated_at
AFTER UPDATE ON webhook_configs
FOR EACH ROW
BEGIN
    UPDATE webhook_configs SET updated_at = datetime('now') WHERE id = NEW.id;
END;

DROP TRIGGER IF EXISTS trg_webhook_deliveries_updated_at;
CREATE TRIGGER trg_webhook_deliveries_updated_at
AFTER UPDATE ON webhook_deliveries
FOR EACH ROW
BEGIN
    UPDATE webhook_deliveries SET updated_at = datetime('now') WHERE id = NEW.id;
END;

DROP TRIGGER IF EXISTS trg_user_notifications_updated_at;
CREATE TRIGGER trg_user_notifications_updated_at
AFTER UPDATE ON user_notifications
FOR EACH ROW
BEGIN
    UPDATE user_notifications SET updated_at = datetime('now') WHERE id = NEW.id;
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

INSERT OR IGNORE INTO settings (key, value, is_encrypted, updated_at) VALUES
    ('anthropic_api_key',             '',                       1, datetime('now')),
    ('qwen_api_key',                  '',                       1, datetime('now')),
    ('alibaba_api_key',               '',                       1, datetime('now')),
    ('brave_api_key',                 '',                       1, datetime('now')),
    ('forge_api_url',                 '',                       0, datetime('now')),
    ('forge_api_key',                 '',                       1, datetime('now')),
    ('ollama_base_url',               'http://localhost:11434', 0, datetime('now')),
    ('crawl_service_url',             'http://localhost:3002',  0, datetime('now')),
    ('r_service_url',                 'http://localhost:3003',  0, datetime('now')),
    ('crawl_content_threshold',       '500',                    0, datetime('now')),
    ('default_embed_model',           'text-embedding-v4',      0, datetime('now')),
    ('opensanctions_api_key',         '',                       1, datetime('now')),
    ('app_version',                   '0.2.0',                  0, datetime('now')),
    ('adversarial_check_enabled',     '0',                      0, datetime('now')),
    ('adversarial_check_sample_rate', '10',                     0, datetime('now')),
    ('backup_enabled',                '0',                      0, datetime('now')),
    ('backup_schedule',               'daily',                  0, datetime('now')),
    ('backup_s3_endpoint',            '',                       0, datetime('now')),
    ('backup_s3_bucket',              '',                       0, datetime('now')),
    ('backup_s3_access_key',          '',                       1, datetime('now')),
    ('backup_s3_secret_key',          '',                       1, datetime('now')),
    ('backup_retention_days',         '30',                     0, datetime('now')),
    ('content_s3_endpoint',           '',                       0, datetime('now')),
    ('content_s3_bucket',             '',                       0, datetime('now')),
    ('content_s3_access_key',         '',                       1, datetime('now')),
    ('content_s3_secret_key',         '',                       1, datetime('now'));
