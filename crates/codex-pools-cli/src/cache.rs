use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};

use crate::analytics::SessionAnalytics;

const SCHEMA_VERSION: i64 = 1;
pub const PARSER_VERSION: i64 = 1;

pub struct AnalyticsCache {
    conn: Connection,
}

impl AnalyticsCache {
    pub fn open(path: Option<PathBuf>) -> Result<Self> {
        let path = path.unwrap_or_else(default_cache_path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create cache directory {}", parent.display()))?;
        }
        let conn = Connection::open(&path)
            .with_context(|| format!("open analytics cache {}", path.display()))?;
        let cache = Self { conn };
        cache.initialize()?;
        Ok(cache)
    }

    pub fn get_session(
        &self,
        cache_key: &str,
        file_modified_at_ms: i64,
        file_size_bytes: i64,
    ) -> Result<Option<SessionAnalytics>> {
        let row = self
            .conn
            .query_row(
                r#"
                SELECT session_json FROM analytics_sessions
                WHERE cache_key = ?
                  AND file_modified_at_ms = ?
                  AND file_size_bytes = ?
                  AND parser_version = ?
                "#,
                params![
                    cache_key,
                    file_modified_at_ms,
                    file_size_bytes,
                    PARSER_VERSION
                ],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        row.map(|json| serde_json::from_str(&json).context("decode cached session"))
            .transpose()
    }

    pub fn upsert_session(
        &self,
        cache_key: &str,
        instance_id: &str,
        codex_home: &str,
        relative_rollout_path: &str,
        file_modified_at_ms: i64,
        file_size_bytes: i64,
        session: &SessionAnalytics,
    ) -> Result<()> {
        let session_json = serde_json::to_string(session)?;
        self.conn.execute(
            r#"
            INSERT INTO analytics_sessions (
                cache_key, instance_id, codex_home, relative_rollout_path,
                file_modified_at_ms, file_size_bytes, parser_version, session_json, analyzed_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(cache_key) DO UPDATE SET
                instance_id = excluded.instance_id,
                codex_home = excluded.codex_home,
                relative_rollout_path = excluded.relative_rollout_path,
                file_modified_at_ms = excluded.file_modified_at_ms,
                file_size_bytes = excluded.file_size_bytes,
                parser_version = excluded.parser_version,
                session_json = excluded.session_json,
                analyzed_at_ms = excluded.analyzed_at_ms
            "#,
            params![
                cache_key,
                instance_id,
                codex_home,
                relative_rollout_path,
                file_modified_at_ms,
                file_size_bytes,
                PARSER_VERSION,
                session_json,
                chrono::Utc::now().timestamp_millis()
            ],
        )?;
        Ok(())
    }

    pub fn prune_instance(&self, instance_id: &str, live_keys: &[String]) -> Result<()> {
        if live_keys.is_empty() {
            self.conn.execute(
                "DELETE FROM analytics_sessions WHERE instance_id = ?",
                params![instance_id],
            )?;
            return Ok(());
        }
        let mut statement = self
            .conn
            .prepare("SELECT cache_key FROM analytics_sessions WHERE instance_id = ?")?;
        let cached_keys = statement
            .query_map(params![instance_id], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let live = live_keys.iter().collect::<std::collections::BTreeSet<_>>();
        for key in cached_keys {
            if !live.contains(&key) {
                self.conn.execute(
                    "DELETE FROM analytics_sessions WHERE cache_key = ?",
                    params![key],
                )?;
            }
        }
        Ok(())
    }

    fn initialize(&self) -> Result<()> {
        self.conn.pragma_update(None, "journal_mode", "WAL")?;
        self.conn.pragma_update(None, "synchronous", "NORMAL")?;
        let schema_version = self
            .conn
            .query_row(
                "SELECT value FROM metadata WHERE key = 'schema_version'",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .ok()
            .flatten()
            .and_then(|value| value.parse::<i64>().ok());
        if schema_version.is_some_and(|version| version != SCHEMA_VERSION) {
            self.conn.execute_batch(
                r#"
                DROP TABLE IF EXISTS analytics_sessions;
                DROP TABLE IF EXISTS metadata;
                "#,
            )?;
        }
        self.conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS analytics_sessions (
                cache_key TEXT PRIMARY KEY,
                instance_id TEXT NOT NULL,
                codex_home TEXT NOT NULL,
                relative_rollout_path TEXT NOT NULL,
                file_modified_at_ms INTEGER NOT NULL,
                file_size_bytes INTEGER NOT NULL,
                parser_version INTEGER NOT NULL,
                session_json TEXT NOT NULL,
                analyzed_at_ms INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_analytics_sessions_instance
                ON analytics_sessions(instance_id);
            CREATE INDEX IF NOT EXISTS idx_analytics_sessions_home
                ON analytics_sessions(codex_home);
            "#,
        )?;
        self.conn.execute(
            "INSERT OR REPLACE INTO metadata (key, value) VALUES ('schema_version', ?)",
            params![SCHEMA_VERSION.to_string()],
        )?;
        Ok(())
    }
}

fn default_cache_path() -> PathBuf {
    if cfg!(target_os = "macos") {
        if let Some(home) = dirs::home_dir() {
            return home
                .join("Library")
                .join("Application Support")
                .join("Codex Pools")
                .join("Analytics")
                .join("analytics-cache.sqlite");
        }
    }
    dirs::data_dir()
        .unwrap_or_else(|| Path::new(".").to_path_buf())
        .join("Codex Pools")
        .join("Analytics")
        .join("analytics-cache.sqlite")
}
