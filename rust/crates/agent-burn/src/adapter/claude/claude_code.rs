use std::fs;

use serde_json::Value;

use crate::{TimestampMs, home};

/// The usage body Claude Code itself cached in `~/.claude.json`, with when
/// Anthropic returned it. Ignored when it belongs to another signed-in account.
pub(super) fn cached_usage() -> Option<(String, TimestampMs)> {
    let path = home::home_dir()?.join(".claude.json");
    cached_usage_from(&fs::read_to_string(path).ok()?)
}

fn cached_usage_from(json: &str) -> Option<(String, TimestampMs)> {
    let value = serde_json::from_str::<Value>(json).ok()?;
    let cached = value.get("cachedUsageUtilization")?;
    let account = value
        .get("oauthAccount")
        .and_then(|account| account.get("accountUuid"))
        .and_then(Value::as_str);
    let cached_account = cached.get("accountUuid").and_then(Value::as_str);
    if account.is_some() && cached_account.is_some() && account != cached_account {
        return None;
    }
    let fetched_at = cached.get("fetchedAtMs").and_then(Value::as_i64)?;
    let utilization = cached.get("utilization").filter(|body| body.is_object())?;
    Some((
        utilization.to_string(),
        TimestampMs::from_millis(fetched_at),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_claude_code_cached_usage_body() {
        let (body, fetched_at) = cached_usage_from(
            r#"{
              "oauthAccount": {"accountUuid": "acct-1"},
              "cachedUsageUtilization": {
                "fetchedAtMs": 1791249739562,
                "accountUuid": "acct-1",
                "utilization": {"five_hour": {"utilization": 11, "resets_at": "2026-10-06T04:40:00Z"}}
              }
            }"#,
        )
        .unwrap();
        assert_eq!(fetched_at, TimestampMs::from_millis(1_791_249_739_562));
        let body = serde_json::from_str::<Value>(&body).unwrap();
        assert_eq!(body["five_hour"]["utilization"], 11);
    }

    #[test]
    fn ignores_cached_usage_from_another_account() {
        assert!(
            cached_usage_from(
                r#"{
                  "oauthAccount": {"accountUuid": "acct-2"},
                  "cachedUsageUtilization": {"fetchedAtMs": 1, "accountUuid": "acct-1", "utilization": {}}
                }"#,
            )
            .is_none()
        );
        assert!(cached_usage_from(r#"{"cachedUsageUtilization": {"fetchedAtMs": 1}}"#).is_none());
        assert!(cached_usage_from("not json").is_none());
    }
}
