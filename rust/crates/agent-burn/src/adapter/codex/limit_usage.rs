use serde_json::Value;

use super::limits::{access_token, fetch_body};

const DAILY_BREAKDOWN_URL: &str =
    "https://chatgpt.com/backend-api/wham/usage/daily-token-usage-breakdown";

/// One day of the ChatGPT Codex usage dashboard: how much of the weekly limit
/// was consumed that day, split by product surface and by model.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct LimitUsageDay {
    pub(crate) date: String,
    pub(crate) used_percent: f64,
    /// `(surface, used_percent)`, largest first, zero entries dropped.
    pub(crate) surfaces: Vec<(String, f64)>,
    pub(crate) models: Vec<LimitUsageModel>,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct LimitUsageModel {
    pub(crate) model: String,
    pub(crate) speed: Option<String>,
    pub(crate) used_percent: f64,
}

/// Fetch the dashboard's daily weekly-limit breakdown. Empty when offline, when
/// no token is available, or on any network or schema error (never fatal).
pub(crate) fn daily_limit_usage(offline: bool) -> Vec<LimitUsageDay> {
    if offline {
        return Vec::new();
    }
    access_token()
        .and_then(|token| fetch_body(DAILY_BREAKDOWN_URL, &token))
        .map(|body| parse_daily_limit_usage(&body))
        .unwrap_or_default()
}

pub(super) fn parse_daily_limit_usage(body: &str) -> Vec<LimitUsageDay> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    if value
        .get("units")
        .and_then(Value::as_str)
        .is_some_and(|units| units != "percent")
    {
        return Vec::new();
    }
    let Some(days) = value.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut parsed = days.iter().filter_map(parse_day).collect::<Vec<_>>();
    parsed.sort_by(|a, b| a.date.cmp(&b.date));
    parsed
}

fn parse_day(day: &Value) -> Option<LimitUsageDay> {
    let date = day.get("date")?.as_str()?.to_string();
    let mut surfaces = day
        .get("product_surface_usage_values")
        .and_then(Value::as_object)
        .map(|values| {
            values
                .iter()
                .filter_map(|(surface, value)| Some((surface.clone(), positive(value)?)))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    surfaces.sort_by(|a, b| b.1.total_cmp(&a.1));
    let mut models = day
        .get("models")
        .and_then(Value::as_array)
        .map(|models| models.iter().filter_map(parse_model).collect::<Vec<_>>())
        .unwrap_or_default();
    models.sort_by(|a, b| b.used_percent.total_cmp(&a.used_percent));
    let used_percent = if surfaces.is_empty() {
        models
            .iter()
            .fold(0.0, |total, model| total + model.used_percent)
    } else {
        surfaces
            .iter()
            .fold(0.0, |total, (_, percent)| total + percent)
    };
    Some(LimitUsageDay {
        date,
        used_percent,
        surfaces,
        models,
    })
}

fn parse_model(model: &Value) -> Option<LimitUsageModel> {
    Some(LimitUsageModel {
        model: model.get("model")?.as_str()?.to_string(),
        speed: model
            .get("speed")
            .and_then(Value::as_str)
            .map(str::to_string),
        used_percent: positive(model.get("credits")?)?,
    })
}

fn positive(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .filter(|value| value.is_finite() && *value > 0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BODY: &str = r#"{
      "data": [
        {
          "date": "2026-09-02",
          "product_surface_usage_values": {"cli": 1.5, "desktop_app": 4.0, "web": 0.0},
          "models": [
            {"model": "gpt-5.6-sol", "speed": "standard", "credits": 5.0},
            {"model": "gpt-5.6-sol", "speed": "fast", "credits": 0.0},
            {"model": "gpt-image-2", "speed": "standard", "credits": 0.5}
          ],
          "attribution": []
        },
        {
          "date": "2026-09-01",
          "product_surface_usage_values": {"cli": 0.0},
          "models": [],
          "attribution": []
        }
      ],
      "group_by": "day",
      "units": "percent"
    }"#;

    #[test]
    fn parses_daily_weekly_limit_percent_by_surface_and_model() {
        let days = parse_daily_limit_usage(BODY);

        assert_eq!(days.len(), 2);
        assert_eq!(days[0].date, "2026-09-01");
        assert!(days[0].used_percent.is_sign_positive());
        assert_eq!(days[0].used_percent, 0.0);
        assert!(days[0].surfaces.is_empty());
        assert_eq!(days[1].used_percent, 5.5);
        assert_eq!(
            days[1].surfaces,
            vec![("desktop_app".to_string(), 4.0), ("cli".to_string(), 1.5)]
        );
        assert_eq!(
            days[1].models,
            vec![
                LimitUsageModel {
                    model: "gpt-5.6-sol".into(),
                    speed: Some("standard".into()),
                    used_percent: 5.0,
                },
                LimitUsageModel {
                    model: "gpt-image-2".into(),
                    speed: Some("standard".into()),
                    used_percent: 0.5,
                },
            ]
        );
    }

    #[test]
    fn rejects_non_percent_units_and_malformed_bodies() {
        assert!(
            parse_daily_limit_usage(r#"{"data":[{"date":"2026-09-01"}],"units":"credits"}"#)
                .is_empty()
        );
        assert!(parse_daily_limit_usage("not json").is_empty());
        assert!(parse_daily_limit_usage(r#"{"detail":"Not Found"}"#).is_empty());
    }
}
