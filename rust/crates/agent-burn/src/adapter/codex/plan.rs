use std::fs;

use serde_json::Value;

use super::paths::{codex_usage_sources, collect_codex_usage_files};
use crate::TimestampMs;

/// A single rate-limit window reported by Codex (e.g. the 5h or weekly window).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct RateWindow {
    pub(crate) used_percent: f64,
    pub(crate) window_minutes: u64,
    pub(crate) resets_at: Option<i64>,
}

/// The most recent plan / rate-limit snapshot found in the Codex session logs
/// or the live ChatGPT usage endpoint.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct CodexPlanSnapshot {
    pub(crate) plan_type: String,
    pub(crate) limit_id: Option<String>,
    pub(crate) primary: Option<RateWindow>,
    pub(crate) secondary: Option<RateWindow>,
    pub(crate) reset_credits_available: Option<u32>,
}

impl CodexPlanSnapshot {
    /// Account weekly (or longer) window. A 5h meter is never treated as weekly.
    pub(crate) fn weekly_window(&self) -> Option<RateWindow> {
        const MIN_WEEKLY_MINUTES: u64 = 2 * 24 * 60;
        [self.primary, self.secondary]
            .into_iter()
            .flatten()
            .filter(|window| window.window_minutes >= MIN_WEEKLY_MINUTES)
            .max_by_key(|window| window.window_minutes)
    }

    /// The shorter rolling window when Codex still reports one (typically 5h).
    pub(crate) fn short_window(&self) -> Option<(u64, f64)> {
        [self.primary, self.secondary]
            .into_iter()
            .flatten()
            .filter(|window| window.window_minutes < 24 * 60)
            .max_by_key(|window| window.window_minutes)
            .map(|window| (window.window_minutes, window.used_percent))
    }

    pub(crate) fn is_account_limit(&self) -> bool {
        self.limit_id.as_deref().unwrap_or("codex") == "codex"
    }
}

/// Scan recent Codex session files for the latest *account* `rate_limits`
/// payload. Model-specific meters (e.g. Spark / `codex_bengalfox`) are skipped
/// so the weekly quota matches the ChatGPT dashboard, not a side limit.
///
/// Newer session files are inspected first. A larger scan window is needed
/// because recent rollouts often only record model-specific envelopes.
pub(crate) fn latest_plan_snapshot() -> Option<CodexPlanSnapshot> {
    latest_logged_snapshot().map(|(_, snapshot)| snapshot)
}

/// The newest account snapshot in the session logs, with the time Codex logged
/// it. These values come from the meter Codex enforced on a real request.
pub(super) fn latest_logged_snapshot() -> Option<(Option<TimestampMs>, CodexPlanSnapshot)> {
    const MAX_FILES_SCANNED: usize = 24;
    const TAIL_BYTES: usize = 64 * 1024;

    let sources = codex_usage_sources().ok()?;
    let mut files = Vec::new();
    for source in &sources {
        files.extend(collect_codex_usage_files(&source.dir));
    }
    sort_by_session_start(&mut files);
    for file in files.iter().rev().take(MAX_FILES_SCANNED) {
        if let Some(logged) = logged_snapshot_from_file(file, TAIL_BYTES) {
            return Some(logged);
        }
    }
    None
}

/// Session file names are timestamp-prefixed, so ordering by name alone is
/// chronological across every Codex home. Full paths would rank a whole home
/// (`~/.codex-video` after `~/.codex`) above newer sessions in another.
fn sort_by_session_start(files: &mut [std::path::PathBuf]) {
    files.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
}

fn logged_snapshot_from_file(
    path: &std::path::Path,
    tail_bytes: usize,
) -> Option<(Option<TimestampMs>, CodexPlanSnapshot)> {
    let contents = tail_string(path, tail_bytes)?;
    contents.lines().rev().find_map(|line| {
        let snapshot = line
            .contains("rate_limits")
            .then(|| snapshot_from_line(line))??;
        snapshot
            .is_account_limit()
            .then(|| (logged_at(line), snapshot))
    })
}

fn logged_at(line: &str) -> Option<TimestampMs> {
    let value = serde_json::from_str::<Value>(line).ok()?;
    crate::parse_ts_timestamp(value.get("timestamp")?.as_str()?)
}

fn tail_string(path: &std::path::Path, max_bytes: usize) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};

    let mut file = fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len() as usize;
    if len > max_bytes {
        file.seek(SeekFrom::End(-(max_bytes as i64))).ok()?;
    }
    let mut buf = String::new();
    file.read_to_string(&mut buf).ok()?;
    if len > max_bytes
        && let Some(idx) = buf.find('\n')
    {
        buf = buf[idx + 1..].to_string();
    }
    Some(buf)
}

fn snapshot_from_line(line: &str) -> Option<CodexPlanSnapshot> {
    let value = serde_json::from_str::<Value>(line).ok()?;
    let rate_limits = find_rate_limits(&value)?;
    let plan_type = rate_limits
        .get("plan_type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Some(CodexPlanSnapshot {
        plan_type,
        limit_id: rate_limits
            .get("limit_id")
            .and_then(Value::as_str)
            .map(str::to_string),
        primary: rate_window(rate_limits.get("primary")),
        secondary: rate_window(rate_limits.get("secondary")),
        reset_credits_available: None,
    })
}

fn find_rate_limits(value: &Value) -> Option<&Value> {
    if let Some(rate_limits) = value
        .get("payload")
        .and_then(|payload| payload.get("rate_limits"))
        && rate_limits.get("primary").is_some()
    {
        return Some(rate_limits);
    }
    find_rate_limits_recursive(value)
}

fn find_rate_limits_recursive(value: &Value) -> Option<&Value> {
    match value {
        Value::Object(map) => {
            if let Some(rate_limits) = map.get("rate_limits")
                && rate_limits.get("primary").is_some()
            {
                return Some(rate_limits);
            }
            map.values().find_map(find_rate_limits_recursive)
        }
        Value::Array(items) => items.iter().find_map(find_rate_limits_recursive),
        _ => None,
    }
}

fn rate_window(value: Option<&Value>) -> Option<RateWindow> {
    let window = value?;
    Some(RateWindow {
        used_percent: window.get("used_percent")?.as_f64()?,
        window_minutes: window.get("window_minutes")?.as_u64()?,
        resets_at: window.get("resets_at").and_then(Value::as_i64),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plan_and_windows_from_token_count_line() {
        let line = r#"{"timestamp":"2026-06-13T10:09:32.856Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":17.0,"window_minutes":300,"resets_at":1781347306},"secondary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1781764829},"plan_type":"pro"}}}"#;

        let snapshot = snapshot_from_line(line).unwrap();

        assert_eq!(snapshot.plan_type, "pro");
        assert_eq!(snapshot.limit_id.as_deref(), Some("codex"));
        assert_eq!(
            snapshot.primary,
            Some(RateWindow {
                used_percent: 17.0,
                window_minutes: 300,
                resets_at: Some(1781347306),
            })
        );
        assert_eq!(
            snapshot.secondary,
            Some(RateWindow {
                used_percent: 7.0,
                window_minutes: 10080,
                resets_at: Some(1781764829),
            })
        );
    }

    #[test]
    fn ignores_lines_without_rate_limits() {
        let line = r#"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#;
        assert!(snapshot_from_line(line).is_none());
    }

    #[test]
    fn orders_sessions_by_start_time_across_codex_homes() {
        let mut files = [
            "/h/.codex/sessions/2026/09/30/rollout-2026-09-30T12-04-41-a.jsonl",
            "/h/.codex-video/sessions/2026/09/17/rollout-2026-09-17T09-00-00-b.jsonl",
            "/h/.codex/sessions/2026/09/29/rollout-2026-09-29T08-00-00-c.jsonl",
        ]
        .map(std::path::PathBuf::from);

        sort_by_session_start(&mut files);

        assert!(files[2].ends_with("rollout-2026-09-30T12-04-41-a.jsonl"));
        assert!(files[0].ends_with("rollout-2026-09-17T09-00-00-b.jsonl"));
    }

    #[test]
    fn prefers_account_envelope_when_file_ends_on_spark() {
        let contents = [
            r#"{"timestamp":"2026-06-13T10:09:32.856Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":85.0,"window_minutes":10080,"resets_at":9},"plan_type":"pro"}}}"#,
            r#"{"payload":{"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1},"secondary":{"used_percent":100.0,"window_minutes":10080,"resets_at":2},"plan_type":null}}}"#,
        ]
        .join("\n");
        let dir = std::env::temp_dir().join(format!("agent-burn-plan-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.jsonl");
        std::fs::write(&path, contents).unwrap();

        let (logged_at, snapshot) = logged_snapshot_from_file(&path, 64 * 1024).unwrap();

        std::fs::remove_dir_all(&dir).ok();
        assert_eq!(
            logged_at,
            crate::parse_ts_timestamp("2026-06-13T10:09:32.856Z")
        );
        assert_eq!(snapshot.plan_type, "pro");
        assert_eq!(snapshot.weekly_window().unwrap().used_percent, 85.0);
    }

    #[test]
    fn parses_null_plan_type_and_rejects_spark_as_account_limit() {
        let line = r#"{"payload":{"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1},"secondary":{"used_percent":100.0,"window_minutes":10080,"resets_at":2},"plan_type":null}}}"#;

        let snapshot = snapshot_from_line(line).unwrap();

        assert!(snapshot.plan_type.is_empty());
        assert!(!snapshot.is_account_limit());
    }

    #[test]
    fn five_hour_only_snapshot_is_not_a_weekly_quota() {
        let snapshot = CodexPlanSnapshot {
            plan_type: "pro".into(),
            limit_id: Some("codex".into()),
            primary: Some(RateWindow {
                used_percent: 40.0,
                window_minutes: 300,
                resets_at: Some(1),
            }),
            secondary: None,
            reset_credits_available: None,
        };

        assert!(snapshot.weekly_window().is_none());
        assert_eq!(snapshot.short_window(), Some((300, 40.0)));
    }

    #[test]
    fn treats_weekly_primary_as_the_account_quota() {
        let line = r#"{"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":85.0,"window_minutes":10080,"resets_at":1788954006},"secondary":null,"plan_type":"pro"}}}"#;

        let snapshot = snapshot_from_line(line).unwrap();

        assert!(snapshot.is_account_limit());
        assert_eq!(
            snapshot.weekly_window(),
            Some(RateWindow {
                used_percent: 85.0,
                window_minutes: 10080,
                resets_at: Some(1788954006),
            })
        );
    }
}
