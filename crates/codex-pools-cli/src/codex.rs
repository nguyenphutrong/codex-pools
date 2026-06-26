use std::collections::BTreeMap;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;
use uuid::Uuid;
use walkdir::WalkDir;

use crate::analytics::{
    build_snapshot, AnalyticsScanResult, SessionAnalytics, TokenUsage, ToolCallSummary,
};
use crate::cache::AnalyticsCache;

pub fn scan_instance(
    instance_id: Uuid,
    instance_name: String,
    codex_home: PathBuf,
    cache_db: Option<PathBuf>,
) -> Result<AnalyticsScanResult> {
    let cache = AnalyticsCache::open(cache_db)?;
    let index = read_session_index(&codex_home);
    let mut candidates = Vec::new();
    let mut skipped_file_count = 0;

    for directory in [SessionDirectory::Sessions, SessionDirectory::Archived] {
        let root = codex_home.join(directory.dirname());
        if !root.exists() {
            continue;
        }
        for entry in WalkDir::new(&root)
            .follow_links(false)
            .into_iter()
            .filter_map(Result::ok)
        {
            let path = entry.path();
            if !entry.file_type().is_file()
                || path.extension().and_then(|value| value.to_str()) != Some("jsonl")
            {
                continue;
            }
            match read_thread(
                path,
                directory,
                &codex_home,
                instance_id,
                &instance_name,
                &index,
            ) {
                Some(candidate) => candidates.push(candidate),
                None => skipped_file_count += 1,
            }
        }
    }

    candidates.sort_by(|left, right| match (left.updated_at, right.updated_at) {
        (Some(left_date), Some(right_date)) if left_date != right_date => {
            right_date.cmp(&left_date)
        }
        (Some(_), None) => std::cmp::Ordering::Less,
        (None, Some(_)) => std::cmp::Ordering::Greater,
        _ => right.file_size_bytes.cmp(&left.file_size_bytes),
    });

    let mut sessions = Vec::new();
    let mut live_keys = Vec::new();
    for candidate in candidates {
        live_keys.push(candidate.cache_key.clone());
        if let Some(session) = cache.get_session(
            &candidate.cache_key,
            candidate.file_modified_at_ms,
            candidate.file_size_bytes,
        )? {
            sessions.push(session);
            continue;
        }

        match read_analytics(&candidate, &index) {
            Some(session) => {
                cache.upsert_session(
                    &candidate.cache_key,
                    &candidate.instance_id.to_string(),
                    &candidate.codex_home,
                    &candidate.relative_rollout_path,
                    candidate.file_modified_at_ms,
                    candidate.file_size_bytes,
                    &session,
                )?;
                sessions.push(session);
            }
            None => skipped_file_count += 1,
        }
    }
    cache.prune_instance(&instance_id.to_string(), &live_keys)?;

    Ok(AnalyticsScanResult {
        snapshot: build_snapshot(sessions),
        skipped_file_count,
    })
}

#[derive(Clone, Copy)]
enum SessionDirectory {
    Sessions,
    Archived,
}

impl SessionDirectory {
    fn dirname(self) -> &'static str {
        match self {
            SessionDirectory::Sessions => "sessions",
            SessionDirectory::Archived => "archived_sessions",
        }
    }

    fn is_archived(self) -> bool {
        matches!(self, SessionDirectory::Archived)
    }
}

struct Candidate {
    id: String,
    thread_id: String,
    instance_id: Uuid,
    instance_name: String,
    codex_home: String,
    title: String,
    workspace_path: Option<String>,
    rollout_path: String,
    relative_rollout_path: String,
    updated_at: Option<DateTime<Utc>>,
    is_archived: bool,
    file_modified_at_ms: i64,
    file_size_bytes: i64,
    cache_key: String,
}

fn read_thread(
    rollout_path: &Path,
    directory: SessionDirectory,
    codex_home: &Path,
    instance_id: Uuid,
    instance_name: &str,
    index: &BTreeMap<String, Value>,
) -> Option<Candidate> {
    let first_line = first_non_empty_line(rollout_path).ok().flatten()?;
    let metadata = Value::Object(decode_object(&first_line)?);
    let payload = metadata.get("payload").and_then(Value::as_object);
    let thread_id = payload
        .and_then(|object| {
            string_value(object.get("id")).or_else(|| string_value(object.get("session_id")))
        })
        .or_else(|| string_value(metadata.get("id")))
        .or_else(|| string_value(metadata.get("session_id")))?;
    let relative_rollout_path = relative_path(codex_home, rollout_path)?;
    let attributes = std::fs::metadata(rollout_path).ok()?;
    let file_modified_at_ms = attributes
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0);
    let file_size_bytes = attributes.len() as i64;
    let index_object = index.get(&thread_id);
    let updated_at = index_object
        .and_then(updated_at_in)
        .or_else(|| millis_to_date(file_modified_at_ms));
    let workspace_path = payload
        .and_then(|object| string_value(object.get("cwd")))
        .or_else(|| index_object.and_then(workspace_path_in));
    let title = index_object
        .and_then(title_in)
        .or_else(|| title_in(&metadata))
        .unwrap_or_else(|| thread_id.clone());
    let cache_key = format!("{}:{relative_rollout_path}", instance_id);
    Some(Candidate {
        id: format!("{}:{}:{relative_rollout_path}", instance_id, thread_id),
        thread_id,
        instance_id,
        instance_name: instance_name.to_string(),
        codex_home: codex_home.to_string_lossy().to_string(),
        title,
        workspace_path,
        rollout_path: rollout_path.to_string_lossy().to_string(),
        relative_rollout_path,
        updated_at,
        is_archived: directory.is_archived(),
        file_modified_at_ms,
        file_size_bytes,
        cache_key,
    })
}

fn read_analytics(
    candidate: &Candidate,
    index: &BTreeMap<String, Value>,
) -> Option<SessionAnalytics> {
    let first_line = first_non_empty_line(Path::new(&candidate.rollout_path))
        .ok()
        .flatten()?;
    let metadata = Value::Object(decode_object(&first_line)?);
    let payload = metadata.get("payload").and_then(Value::as_object);
    let mut parser = RolloutAnalyticsParser::default();
    for_each_non_empty_line(Path::new(&candidate.rollout_path), |line| {
        if let Some(object) = decode_object(line) {
            parser.consume(&Value::Object(object));
        }
    })
    .ok()?;

    let index_object = index.get(&candidate.thread_id);
    let title = index_object
        .and_then(title_in)
        .or_else(|| parser.first_user_title.clone())
        .or_else(|| title_in(&metadata))
        .unwrap_or_else(|| candidate.title.clone());
    let created_at = payload.and_then(|object| date_value(object.get("timestamp")));
    let updated_at = candidate.updated_at.or(parser.last_event_at);
    let mut estimated_cost = 0.0;
    let mut has_priced_model = false;
    for (model, usage) in &parser.model_usage {
        if let Some(cost) = crate::pricing::estimated_cost(model, usage) {
            estimated_cost += cost;
            has_priced_model = true;
        }
    }
    let tool_calls = parser
        .tool_calls
        .into_iter()
        .map(|(name, count)| ToolCallSummary { name, count })
        .collect::<Vec<_>>();

    Some(SessionAnalytics {
        id: candidate.id.clone(),
        thread_id: candidate.thread_id.clone(),
        instance_id: candidate.instance_id,
        instance_name: candidate.instance_name.clone(),
        codex_home: candidate.codex_home.clone(),
        title,
        workspace_path: candidate.workspace_path.clone(),
        rollout_path: candidate.rollout_path.clone(),
        relative_rollout_path: candidate.relative_rollout_path.clone(),
        created_at,
        updated_at,
        is_archived: candidate.is_archived,
        source: payload.and_then(|object| string_value(object.get("source"))),
        originator: payload.and_then(|object| string_value(object.get("originator"))),
        cli_version: payload.and_then(|object| string_value(object.get("cli_version"))),
        model_provider: payload.and_then(|object| string_value(object.get("model_provider"))),
        user_message_count: parser.user_message_count,
        assistant_message_count: parser.assistant_message_count,
        system_message_count: parser.system_message_count,
        user_character_count: parser.user_character_count,
        assistant_character_count: parser.assistant_character_count,
        token_usage: parser.token_usage,
        models: parser.models,
        tool_calls,
        estimated_cost: has_priced_model.then_some(estimated_cost),
    })
}

#[derive(Default)]
struct RolloutAnalyticsParser {
    current_model: Option<String>,
    previous_total_usage: Option<RawTokenUsage>,
    first_user_title: Option<String>,
    last_event_at: Option<DateTime<Utc>>,
    user_message_count: i64,
    assistant_message_count: i64,
    system_message_count: i64,
    user_character_count: i64,
    assistant_character_count: i64,
    token_usage: TokenUsage,
    model_usage: BTreeMap<String, TokenUsage>,
    models: Vec<String>,
    tool_calls: BTreeMap<String, i64>,
}

impl RolloutAnalyticsParser {
    fn consume(&mut self, object: &Value) {
        if let Some(timestamp) = date_value(object.get("timestamp")) {
            self.last_event_at = Some(
                self.last_event_at
                    .map_or(timestamp, |current| current.max(timestamp)),
            );
        }
        match object.get("type").and_then(Value::as_str) {
            Some("turn_context") => {
                if let Some(model) = object.get("payload").and_then(extract_model) {
                    self.current_model = Some(model.clone());
                    self.models.push(model);
                }
            }
            Some("response_item") => {
                if let Some(payload) = object.get("payload") {
                    self.consume_response_item(payload);
                }
            }
            Some("event_msg") => self.consume_event_message(object),
            _ => {}
        }
    }

    fn consume_response_item(&mut self, payload: &Value) {
        let payload_type = payload
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if payload_type == "message" {
            match payload.get("role").and_then(Value::as_str) {
                Some("user") => {
                    let text = extract_content_text(payload.get("content"), &["input_text"]);
                    if text.is_empty() || is_bootstrap_message(&text) {
                        return;
                    }
                    self.user_message_count += 1;
                    self.user_character_count += text.chars().count() as i64;
                    if self.first_user_title.is_none() {
                        self.first_user_title = Some(clean_prompt(&text));
                    }
                }
                Some("assistant") => {
                    let text =
                        extract_content_text(payload.get("content"), &["output_text", "text"]);
                    self.assistant_message_count += 1;
                    self.assistant_character_count += text.chars().count() as i64;
                }
                Some("system") => self.system_message_count += 1,
                _ => {}
            }
            if let Some(model) = extract_model(payload) {
                self.current_model = Some(model.clone());
                self.models.push(model);
            }
            return;
        }

        if payload_type == "reasoning" {
            let text = payload
                .get("summary")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.get("text").and_then(Value::as_str))
                        .map(str::trim)
                        .filter(|text| !text.is_empty())
                        .collect::<Vec<_>>()
                        .join("\n")
                })
                .unwrap_or_default();
            self.assistant_character_count += text.chars().count() as i64;
            return;
        }

        if matches!(
            payload_type,
            "function_call" | "custom_tool_call" | "web_search_call"
        ) {
            let name = payload
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| {
                    if payload_type == "web_search_call" {
                        "web_search"
                    } else {
                        "tool"
                    }
                    .to_string()
                });
            *self.tool_calls.entry(name).or_insert(0) += 1;
        }
    }

    fn consume_event_message(&mut self, object: &Value) {
        let Some(payload) = object.get("payload") else {
            return;
        };
        if payload.get("type").and_then(Value::as_str) != Some("token_count") {
            return;
        }
        let info = payload.get("info").unwrap_or(&Value::Null);
        let last_usage = raw_usage(info.get("last_token_usage"));
        let total_usage = raw_usage(info.get("total_token_usage"));
        let usage = last_usage.or_else(|| {
            total_usage
                .as_ref()
                .map(|total| total.subtracting(self.previous_total_usage.as_ref()))
        });
        if let Some(total_usage) = total_usage {
            self.previous_total_usage = Some(total_usage);
        }
        let Some(usage) = usage else { return };
        let delta = usage.delta();
        if delta.total_tokens() <= 0 {
            return;
        }
        self.token_usage.add(&delta);
        let model = extract_model(info)
            .or_else(|| extract_model(payload))
            .or_else(|| self.current_model.clone());
        if let Some(model) = model {
            self.current_model = Some(model.clone());
            self.models.push(model.clone());
            self.model_usage.entry(model).or_default().add(&delta);
        }
    }
}

#[derive(Clone)]
struct RawTokenUsage {
    input_tokens: i64,
    cached_input_tokens: i64,
    output_tokens: i64,
    cache_write_tokens: i64,
}

impl RawTokenUsage {
    fn delta(&self) -> TokenUsage {
        let cache_read = self.cached_input_tokens.min(self.input_tokens).max(0);
        TokenUsage {
            input_tokens: (self.input_tokens - cache_read).max(0),
            output_tokens: self.output_tokens.max(0),
            cache_read_tokens: cache_read,
            cache_write_tokens: self.cache_write_tokens.max(0),
        }
    }

    fn subtracting(&self, previous: Option<&RawTokenUsage>) -> RawTokenUsage {
        RawTokenUsage {
            input_tokens: (self.input_tokens
                - previous.map(|value| value.input_tokens).unwrap_or(0))
            .max(0),
            cached_input_tokens: (self.cached_input_tokens
                - previous.map(|value| value.cached_input_tokens).unwrap_or(0))
            .max(0),
            output_tokens: (self.output_tokens
                - previous.map(|value| value.output_tokens).unwrap_or(0))
            .max(0),
            cache_write_tokens: (self.cache_write_tokens
                - previous.map(|value| value.cache_write_tokens).unwrap_or(0))
            .max(0),
        }
    }
}

fn raw_usage(value: Option<&Value>) -> Option<RawTokenUsage> {
    let object = value?.as_object()?;
    let input_tokens = int_value(object.get("input_tokens"));
    let cached_input_tokens = int_value(object.get("cached_input_tokens"))
        + int_value(object.get("cache_read_input_tokens"));
    let output_tokens = int_value(object.get("output_tokens"));
    let cache_write_tokens = int_value(object.get("cache_creation_input_tokens"))
        + int_value(object.get("cache_write_input_tokens"));
    let total_tokens = int_value(object.get("total_tokens"));
    if input_tokens <= 0
        && cached_input_tokens <= 0
        && output_tokens <= 0
        && cache_write_tokens <= 0
        && total_tokens <= 0
    {
        return None;
    }
    Some(RawTokenUsage {
        input_tokens,
        cached_input_tokens,
        output_tokens,
        cache_write_tokens,
    })
}

fn read_session_index(codex_home: &Path) -> BTreeMap<String, Value> {
    let index_path = codex_home.join("session_index.jsonl");
    let Ok(file) = File::open(index_path) else {
        return BTreeMap::new();
    };
    let mut map = BTreeMap::new();
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        let Some(object) = decode_object(&line) else {
            continue;
        };
        let value = Value::Object(object);
        let id = value
            .get("id")
            .and_then(Value::as_str)
            .or_else(|| value.get("session_id").and_then(Value::as_str))
            .or_else(|| value.get("thread_id").and_then(Value::as_str));
        if let Some(id) = id {
            map.insert(id.to_string(), value);
        }
    }
    map
}

fn first_non_empty_line(path: &Path) -> Result<Option<String>> {
    let file = File::open(path).with_context(|| format!("open {}", path.display()))?;
    for line in BufReader::new(file).lines() {
        let line = line?;
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            return Ok(Some(trimmed.to_string()));
        }
    }
    Ok(None)
}

fn for_each_non_empty_line(path: &Path, mut body: impl FnMut(&str)) -> Result<()> {
    let file = File::open(path).with_context(|| format!("open {}", path.display()))?;
    for line in BufReader::new(file).lines() {
        let line = line?;
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            body(trimmed);
        }
    }
    Ok(())
}

fn decode_object(line: &str) -> Option<serde_json::Map<String, Value>> {
    serde_json::from_str::<Value>(line)
        .ok()?
        .as_object()
        .cloned()
}

fn string_value(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(value) => {
            let trimmed = value.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_string())
        }
        Value::Number(value) => Some(value.to_string()),
        _ => None,
    }
}

fn int_value(value: Option<&Value>) -> i64 {
    match value {
        Some(Value::Number(number)) => number
            .as_i64()
            .unwrap_or_else(|| number.as_f64().unwrap_or(0.0) as i64),
        Some(Value::String(value)) => value.parse::<i64>().unwrap_or(0),
        _ => 0,
    }
}

fn date_value(value: Option<&Value>) -> Option<DateTime<Utc>> {
    match value? {
        Value::String(value) => DateTime::parse_from_rfc3339(value)
            .ok()
            .map(|date| date.with_timezone(&Utc)),
        Value::Number(value) => {
            let raw = value.as_i64()?;
            if raw > 10_000_000_000 {
                Utc.timestamp_millis_opt(raw).single()
            } else {
                Utc.timestamp_opt(raw, 0).single()
            }
        }
        _ => None,
    }
}

fn millis_to_date(value: i64) -> Option<DateTime<Utc>> {
    Utc.timestamp_millis_opt(value).single()
}

fn title_in(value: &Value) -> Option<String> {
    if let Some(payload_title) = value.get("payload").and_then(title_in) {
        return Some(payload_title);
    }
    ["thread_name", "threadName", "title", "name"]
        .iter()
        .find_map(|key| string_value(value.get(*key)))
}

fn workspace_path_in(value: &Value) -> Option<String> {
    value
        .get("payload")
        .and_then(|payload| string_value(payload.get("cwd")))
        .or_else(|| string_value(value.get("cwd")))
}

fn updated_at_in(value: &Value) -> Option<DateTime<Utc>> {
    [
        "updated_at",
        "updatedAt",
        "last_updated_at",
        "lastUpdatedAt",
    ]
    .iter()
    .find_map(|key| date_value(value.get(*key)))
}

fn extract_model(value: &Value) -> Option<String> {
    string_value(value.get("model"))
        .or_else(|| string_value(value.get("model_name")))
        .or_else(|| value.get("info").and_then(extract_model))
        .or_else(|| value.get("metadata").and_then(extract_model))
}

fn extract_content_text(value: Option<&Value>, accepted_types: &[&str]) -> String {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    let content_type = item.get("type").and_then(Value::as_str)?;
                    if !accepted_types.contains(&content_type) {
                        return None;
                    }
                    item.get("text")
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|text| !text.is_empty())
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn is_bootstrap_message(text: &str) -> bool {
    let trimmed = text.trim();
    trimmed.starts_with("<user_instructions>") || trimmed.starts_with("<environment_context>")
}

fn clean_prompt(text: &str) -> String {
    let cleaned = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if cleaned.chars().count() > 120 {
        cleaned.chars().take(120).collect()
    } else {
        cleaned
    }
}

fn relative_path(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    Some(
        relative
            .components()
            .map(|component| component.as_os_str().to_string_lossy())
            .collect::<Vec<_>>()
            .join("/"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_usage_diffs_cumulative_totals_without_negative_deltas() {
        let previous = RawTokenUsage {
            input_tokens: 100,
            cached_input_tokens: 40,
            output_tokens: 20,
            cache_write_tokens: 0,
        };
        let current = RawTokenUsage {
            input_tokens: 90,
            cached_input_tokens: 50,
            output_tokens: 50,
            cache_write_tokens: 10,
        };
        let delta = current.subtracting(Some(&previous)).delta();
        assert_eq!(delta.input_tokens, 0);
        assert_eq!(delta.cache_read_tokens, 0);
        assert_eq!(delta.output_tokens, 30);
        assert_eq!(delta.cache_write_tokens, 10);
    }

    #[test]
    fn clean_prompt_skips_extra_whitespace() {
        assert_eq!(clean_prompt("  hello\n\nworld  "), "hello world");
    }

    #[test]
    fn scan_instance_parses_rollout_and_reuses_cache() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("codex-home");
        let rollout = home.join("sessions/2026/06/26/rollout-thread.jsonl");
        std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
        std::fs::write(
            &rollout,
            r#"{"type":"session_meta","timestamp":"2026-06-26T01:00:00Z","payload":{"id":"thread","cwd":"/repo/app","source":"cli","originator":"codex","cli_version":"1.0","model_provider":"openai"}}
{"type":"response_item","timestamp":"2026-06-26T01:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>ignored</environment_context>"}]}}
{"type":"response_item","timestamp":"2026-06-26T01:02:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Build a parser"}]}}
{"type":"turn_context","timestamp":"2026-06-26T01:03:00Z","payload":{"model":"gpt-5"}}
{"type":"response_item","timestamp":"2026-06-26T01:04:00Z","payload":{"type":"function_call","name":"shell","arguments":"{}","call_id":"call_1"}}
{"type":"event_msg","timestamp":"2026-06-26T01:05:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":200,"total_tokens":1200}}}}
"#,
        )
        .unwrap();
        std::fs::write(
            home.join("session_index.jsonl"),
            r#"{"id":"thread","thread_name":"Indexed Title","updated_at":"2026-06-26T01:06:00Z"}"#,
        )
        .unwrap();
        let cache = temp.path().join("cache.sqlite");
        let instance_id = Uuid::parse_str("11111111-2222-3333-4444-555555555555").unwrap();

        let first = scan_instance(
            instance_id,
            "Work".to_string(),
            home.clone(),
            Some(cache.clone()),
        )
        .unwrap();
        let second = scan_instance(instance_id, "Work".to_string(), home, Some(cache)).unwrap();

        let session = first.snapshot.sessions.first().unwrap();
        assert_eq!(session.thread_id, "thread");
        assert_eq!(session.title, "Indexed Title");
        assert_eq!(session.workspace_path.as_deref(), Some("/repo/app"));
        assert_eq!(session.user_message_count, 1);
        assert_eq!(session.token_usage.input_tokens, 900);
        assert_eq!(session.token_usage.cache_read_tokens, 100);
        assert_eq!(session.token_usage.output_tokens, 200);
        assert_eq!(session.tool_calls.first().unwrap().name, "shell");
        assert_eq!(second.snapshot.sessions, first.snapshot.sessions);
    }
}
