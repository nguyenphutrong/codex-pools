use chrono::{DateTime, Local, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
}

impl TokenUsage {
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_write_tokens
    }

    pub fn add(&mut self, other: &TokenUsage) {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCallSummary {
    pub name: String,
    pub count: i64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSummary {
    pub name: String,
    pub count: i64,
    pub usage: TokenUsage,
    pub estimated_cost: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionAnalytics {
    pub id: String,
    #[serde(rename = "threadID")]
    pub thread_id: String,
    #[serde(rename = "instanceID")]
    pub instance_id: Uuid,
    pub instance_name: String,
    pub codex_home: String,
    pub title: String,
    pub workspace_path: Option<String>,
    pub rollout_path: String,
    pub relative_rollout_path: String,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub is_archived: bool,
    pub source: Option<String>,
    pub originator: Option<String>,
    pub cli_version: Option<String>,
    pub model_provider: Option<String>,
    pub user_message_count: i64,
    pub assistant_message_count: i64,
    pub system_message_count: i64,
    pub user_character_count: i64,
    pub assistant_character_count: i64,
    pub token_usage: TokenUsage,
    pub models: Vec<String>,
    pub tool_calls: Vec<ToolCallSummary>,
    pub estimated_cost: Option<f64>,
}

impl SessionAnalytics {
    pub fn message_count(&self) -> i64 {
        self.user_message_count + self.assistant_message_count + self.system_message_count
    }

    pub fn primary_model(&self) -> Option<String> {
        most_frequent(&self.models)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectAnalytics {
    pub folder: String,
    pub name: String,
    pub session_count: i64,
    pub message_count: i64,
    pub token_usage: TokenUsage,
    pub estimated_cost: f64,
    pub first_seen_at: Option<DateTime<Utc>>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub instances: std::collections::BTreeMap<String, i64>,
    pub top_models: Vec<ModelSummary>,
    pub top_tools: Vec<ToolCallSummary>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CostBucket {
    pub name: String,
    pub cost: f64,
    pub session_count: i64,
    pub token_usage: TokenUsage,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CostBreakdown {
    pub total_cost: f64,
    pub unknown_pricing_model_count: i64,
    pub by_model: Vec<CostBucket>,
    pub by_project: Vec<CostBucket>,
    pub by_instance: Vec<CostBucket>,
    pub by_month: Vec<CostBucket>,
    pub top_sessions: Vec<SessionAnalytics>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DailyActivity {
    pub day: String,
    pub session_count: i64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyticsOverview {
    pub total_sessions: i64,
    pub archived_sessions: i64,
    pub total_projects: i64,
    pub total_messages: i64,
    pub total_tool_calls: i64,
    pub token_usage: TokenUsage,
    pub estimated_cost: f64,
    pub first_seen_at: Option<DateTime<Utc>>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub top_models: Vec<ModelSummary>,
    pub top_tools: Vec<ToolCallSummary>,
    pub sessions_by_month: Vec<CostBucket>,
    pub daily_activity: Vec<DailyActivity>,
    pub hourly_activity: Vec<i64>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyticsSnapshot {
    pub sessions: Vec<SessionAnalytics>,
    pub projects: Vec<ProjectAnalytics>,
    pub overview: AnalyticsOverview,
    pub costs: CostBreakdown,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyticsScanResult {
    pub snapshot: AnalyticsSnapshot,
    pub skipped_file_count: i64,
}

pub fn build_snapshot(mut sessions: Vec<SessionAnalytics>) -> AnalyticsSnapshot {
    sessions.sort_by(|left, right| {
        match (
            left.updated_at.or(left.created_at),
            right.updated_at.or(right.created_at),
        ) {
            (Some(left_date), Some(right_date)) if left_date != right_date => {
                right_date.cmp(&left_date)
            }
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            _ => left.title.to_lowercase().cmp(&right.title.to_lowercase()),
        }
    });

    let mut total_usage = TokenUsage::default();
    let mut total_messages = 0;
    let mut total_tool_calls = 0;
    let mut model_counts = std::collections::BTreeMap::<String, i64>::new();
    let mut model_usage = std::collections::BTreeMap::<String, TokenUsage>::new();
    let mut tool_counts = std::collections::BTreeMap::<String, i64>::new();
    let mut month_buckets = std::collections::BTreeMap::<String, (i64, TokenUsage, f64)>::new();
    let mut day_buckets = std::collections::BTreeMap::<String, i64>::new();
    let mut hourly = vec![0; 24];
    let mut first_seen_at: Option<DateTime<Utc>> = None;
    let mut last_seen_at: Option<DateTime<Utc>> = None;
    let mut unknown_pricing = std::collections::BTreeSet::<String>::new();

    for session in &sessions {
        total_usage.add(&session.token_usage);
        total_messages += session.message_count();
        total_tool_calls += session
            .tool_calls
            .iter()
            .map(|tool| tool.count)
            .sum::<i64>();

        if let Some(date) = session.updated_at.or(session.created_at) {
            first_seen_at = Some(first_seen_at.map_or(date, |current| current.min(date)));
            last_seen_at = Some(last_seen_at.map_or(date, |current| current.max(date)));
            let month = date.format("%Y-%m").to_string();
            let month_entry = month_buckets
                .entry(month)
                .or_insert((0, TokenUsage::default(), 0.0));
            month_entry.0 += 1;
            month_entry.1.add(&session.token_usage);
            month_entry.2 += session.estimated_cost.unwrap_or(0.0);

            *day_buckets
                .entry(date.format("%Y-%m-%d").to_string())
                .or_insert(0) += 1;
            let hour = date.with_timezone(&Local).hour() as usize;
            if hour < hourly.len() {
                hourly[hour] += 1;
            }
        }

        for model in &session.models {
            let normalized =
                crate::pricing::normalize_model_name(model).unwrap_or_else(|| model.clone());
            *model_counts.entry(normalized.clone()).or_insert(0) += 1;
            if crate::pricing::price_for(&normalized).is_none() {
                unknown_pricing.insert(normalized);
            }
        }

        if let Some(primary_model) = session.primary_model() {
            let normalized =
                crate::pricing::normalize_model_name(&primary_model).unwrap_or(primary_model);
            model_usage
                .entry(normalized)
                .or_default()
                .add(&session.token_usage);
        }

        for tool in &session.tool_calls {
            *tool_counts.entry(tool.name.clone()).or_insert(0) += tool.count;
        }
    }

    let projects = build_projects(&sessions);
    let costs = build_costs(&sessions, &projects, unknown_pricing.len() as i64);
    let sessions_by_month = month_buckets
        .into_iter()
        .map(|(name, (session_count, token_usage, cost))| CostBucket {
            name,
            cost,
            session_count,
            token_usage,
        })
        .collect();
    let daily_activity = day_buckets
        .into_iter()
        .map(|(day, session_count)| DailyActivity { day, session_count })
        .collect();
    let archived_sessions = sessions
        .iter()
        .filter(|session| session.is_archived)
        .count() as i64;
    let overview = AnalyticsOverview {
        total_sessions: sessions.len() as i64,
        archived_sessions,
        total_projects: projects.len() as i64,
        total_messages,
        total_tool_calls,
        token_usage: total_usage,
        estimated_cost: costs.total_cost,
        first_seen_at,
        last_seen_at,
        top_models: make_model_summaries(model_counts, model_usage, 10),
        top_tools: make_tool_summaries(tool_counts, 10),
        sessions_by_month,
        daily_activity,
        hourly_activity: hourly,
    };

    AnalyticsSnapshot {
        sessions,
        projects,
        overview,
        costs,
    }
}

fn build_projects(sessions: &[SessionAnalytics]) -> Vec<ProjectAnalytics> {
    let mut grouped = std::collections::BTreeMap::<String, Vec<&SessionAnalytics>>::new();
    for session in sessions {
        let folder = session
            .workspace_path
            .as_ref()
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .unwrap_or("(no project)")
            .to_string();
        grouped.entry(folder).or_default().push(session);
    }

    let mut projects = grouped
        .into_iter()
        .map(|(folder, items)| {
            let mut usage = TokenUsage::default();
            let mut message_count = 0;
            let mut estimated_cost = 0.0;
            let mut instances = std::collections::BTreeMap::<String, i64>::new();
            let mut model_counts = std::collections::BTreeMap::<String, i64>::new();
            let mut model_usage = std::collections::BTreeMap::<String, TokenUsage>::new();
            let mut tool_counts = std::collections::BTreeMap::<String, i64>::new();
            let mut first_seen_at: Option<DateTime<Utc>> = None;
            let mut last_seen_at: Option<DateTime<Utc>> = None;

            for item in &items {
                usage.add(&item.token_usage);
                message_count += item.message_count();
                estimated_cost += item.estimated_cost.unwrap_or(0.0);
                *instances.entry(item.instance_name.clone()).or_insert(0) += 1;
                if let Some(date) = item.updated_at.or(item.created_at) {
                    first_seen_at = Some(first_seen_at.map_or(date, |current| current.min(date)));
                    last_seen_at = Some(last_seen_at.map_or(date, |current| current.max(date)));
                }
                for model in &item.models {
                    let normalized = crate::pricing::normalize_model_name(model)
                        .unwrap_or_else(|| model.clone());
                    *model_counts.entry(normalized).or_insert(0) += 1;
                }
                if let Some(primary_model) = item.primary_model() {
                    let normalized = crate::pricing::normalize_model_name(&primary_model)
                        .unwrap_or(primary_model);
                    model_usage
                        .entry(normalized)
                        .or_default()
                        .add(&item.token_usage);
                }
                for tool in &item.tool_calls {
                    *tool_counts.entry(tool.name.clone()).or_insert(0) += tool.count;
                }
            }

            ProjectAnalytics {
                name: project_name(&folder),
                folder,
                session_count: items.len() as i64,
                message_count,
                token_usage: usage,
                estimated_cost,
                first_seen_at,
                last_seen_at,
                instances,
                top_models: make_model_summaries(model_counts, model_usage, 6),
                top_tools: make_tool_summaries(tool_counts, 6),
            }
        })
        .collect::<Vec<_>>();

    projects.sort_by(|left, right| {
        right
            .session_count
            .cmp(&left.session_count)
            .then_with(|| left.name.cmp(&right.name))
    });
    projects
}

fn build_costs(
    sessions: &[SessionAnalytics],
    projects: &[ProjectAnalytics],
    unknown_pricing_model_count: i64,
) -> CostBreakdown {
    let mut by_model = std::collections::BTreeMap::<String, (i64, TokenUsage, f64)>::new();
    let mut by_instance = std::collections::BTreeMap::<String, (i64, TokenUsage, f64)>::new();
    let mut by_month = std::collections::BTreeMap::<String, (i64, TokenUsage, f64)>::new();

    for session in sessions {
        let cost = session.estimated_cost.unwrap_or(0.0);
        let instance_entry = by_instance.entry(session.instance_name.clone()).or_insert((
            0,
            TokenUsage::default(),
            0.0,
        ));
        instance_entry.0 += 1;
        instance_entry.1.add(&session.token_usage);
        instance_entry.2 += cost;

        if let Some(date) = session.updated_at.or(session.created_at) {
            let month_entry = by_month.entry(date.format("%Y-%m").to_string()).or_insert((
                0,
                TokenUsage::default(),
                0.0,
            ));
            month_entry.0 += 1;
            month_entry.1.add(&session.token_usage);
            month_entry.2 += cost;
        }

        if let Some(model) = session.primary_model() {
            let normalized = crate::pricing::normalize_model_name(&model).unwrap_or(model);
            let model_entry =
                by_model
                    .entry(normalized.clone())
                    .or_insert((0, TokenUsage::default(), 0.0));
            model_entry.0 += 1;
            model_entry.1.add(&session.token_usage);
            model_entry.2 +=
                crate::pricing::estimated_cost(&normalized, &session.token_usage).unwrap_or(0.0);
        }
    }

    let mut by_project = projects
        .iter()
        .map(|project| CostBucket {
            name: project.name.clone(),
            cost: project.estimated_cost,
            session_count: project.session_count,
            token_usage: project.token_usage.clone(),
        })
        .collect::<Vec<_>>();
    by_project.sort_by(|left, right| {
        right
            .cost
            .partial_cmp(&left.cost)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.name.cmp(&right.name))
    });

    let mut top_sessions = sessions
        .iter()
        .filter(|session| session.estimated_cost.unwrap_or(0.0) > 0.0)
        .cloned()
        .collect::<Vec<_>>();
    top_sessions.sort_by(|left, right| {
        right
            .estimated_cost
            .unwrap_or(0.0)
            .partial_cmp(&left.estimated_cost.unwrap_or(0.0))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    top_sessions.truncate(20);

    CostBreakdown {
        total_cost: sessions
            .iter()
            .map(|session| session.estimated_cost.unwrap_or(0.0))
            .sum(),
        unknown_pricing_model_count,
        by_model: make_cost_buckets(by_model, true),
        by_project,
        by_instance: make_cost_buckets(by_instance, true),
        by_month: make_cost_buckets(by_month, false),
        top_sessions,
    }
}

fn make_model_summaries(
    counts: std::collections::BTreeMap<String, i64>,
    usage_by_model: std::collections::BTreeMap<String, TokenUsage>,
    limit: usize,
) -> Vec<ModelSummary> {
    let mut summaries = counts
        .into_iter()
        .map(|(name, count)| {
            let usage = usage_by_model.get(&name).cloned().unwrap_or_default();
            let estimated_cost = crate::pricing::estimated_cost(&name, &usage);
            ModelSummary {
                name,
                count,
                usage,
                estimated_cost,
            }
        })
        .collect::<Vec<_>>();
    summaries.sort_by(|left, right| {
        right
            .count
            .cmp(&left.count)
            .then_with(|| left.name.cmp(&right.name))
    });
    summaries.truncate(limit);
    summaries
}

fn make_tool_summaries(
    counts: std::collections::BTreeMap<String, i64>,
    limit: usize,
) -> Vec<ToolCallSummary> {
    let mut summaries = counts
        .into_iter()
        .map(|(name, count)| ToolCallSummary { name, count })
        .collect::<Vec<_>>();
    summaries.sort_by(|left, right| {
        right
            .count
            .cmp(&left.count)
            .then_with(|| left.name.cmp(&right.name))
    });
    summaries.truncate(limit);
    summaries
}

fn make_cost_buckets(
    values: std::collections::BTreeMap<String, (i64, TokenUsage, f64)>,
    sort_by_cost: bool,
) -> Vec<CostBucket> {
    let mut buckets = values
        .into_iter()
        .map(|(name, (session_count, token_usage, cost))| CostBucket {
            name,
            cost,
            session_count,
            token_usage,
        })
        .collect::<Vec<_>>();
    buckets.sort_by(|left, right| {
        if sort_by_cost {
            right
                .cost
                .partial_cmp(&left.cost)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| left.name.cmp(&right.name))
        } else {
            left.name.cmp(&right.name)
        }
    });
    buckets
}

fn most_frequent(values: &[String]) -> Option<String> {
    let mut counts = std::collections::BTreeMap::<String, i64>::new();
    for value in values {
        *counts.entry(value.clone()).or_insert(0) += 1;
    }
    counts
        .into_iter()
        .max_by(|left, right| left.1.cmp(&right.1).then_with(|| right.0.cmp(&left.0)))
        .map(|item| item.0)
}

fn project_name(folder: &str) -> String {
    if folder == "(no project)" {
        return folder.to_string();
    }
    std::path::Path::new(folder)
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or(folder)
        .to_string()
}

trait TimelikeHour {
    fn hour(&self) -> u32;
}

impl TimelikeHour for DateTime<Local> {
    fn hour(&self) -> u32 {
        chrono::Timelike::hour(self)
    }
}
