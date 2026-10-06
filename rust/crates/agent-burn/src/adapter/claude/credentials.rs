use std::{fs, path::PathBuf};

use serde_json::{Value, json};

use crate::{TimestampMs, home};

#[cfg(target_os = "macos")]
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
/// Claude Code refreshes a token this long before it expires.
const EXPIRY_MARGIN_MS: i64 = 5 * 60_000;

/// Claude Code's OAuth sign-in as stored in the Keychain or `.credentials.json`.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct OAuthToken {
    pub(super) access_token: String,
    pub(super) expires_at: Option<TimestampMs>,
    pub(super) refresh_token: Option<String>,
    pub(super) scopes: Vec<String>,
    pub(super) client_id: Option<String>,
}

impl OAuthToken {
    pub(super) fn is_expired(&self, now: TimestampMs) -> bool {
        self.expires_at.is_some_and(|expires_at| now >= expires_at)
    }

    pub(super) fn expires_soon(&self, now: TimestampMs) -> bool {
        self.expires_at
            .is_some_and(|expires_at| now.as_millis() + EXPIRY_MARGIN_MS >= expires_at.as_millis())
    }
}

/// A token endpoint answer, already resolved to absolute expiry times.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct RefreshedToken {
    pub(super) access_token: String,
    pub(super) refresh_token: String,
    pub(super) expires_at: TimestampMs,
    pub(super) refresh_token_expires_at: Option<TimestampMs>,
    pub(super) scopes: Option<Vec<String>>,
}

/// The whole stored credential JSON, kept intact so a write only replaces
/// the renewed `claudeAiOauth` fields.
#[derive(Clone, Debug)]
pub(super) struct Credentials {
    raw: Value,
    store: Store,
}

#[derive(Clone, Debug)]
enum Store {
    #[cfg(target_os = "macos")]
    Keychain {
        account: String,
    },
    File(PathBuf),
}

impl Credentials {
    pub(super) fn load() -> Option<Self> {
        #[cfg(target_os = "macos")]
        if let Some(credentials) = keychain() {
            return Some(credentials);
        }
        let path = credentials_file()?;
        Some(Self {
            raw: parse(&fs::read_to_string(&path).ok()?)?,
            store: Store::File(path),
        })
    }

    #[cfg(test)]
    pub(super) fn from_value(raw: Value) -> Self {
        Self {
            raw,
            store: Store::File(PathBuf::new()),
        }
    }

    pub(super) fn token(&self) -> Option<OAuthToken> {
        token_from(&self.raw)
    }

    /// Writes the renewed sign-in the way Claude Code does, so every running
    /// `claude` session adopts it instead of refreshing again.
    pub(super) fn save(&self, refreshed: &RefreshedToken) -> bool {
        let Some(updated) = merge(&self.raw, refreshed) else {
            return false;
        };
        let text = updated.to_string();
        match &self.store {
            #[cfg(target_os = "macos")]
            Store::Keychain { account } => write_keychain(account, &text),
            Store::File(path) => write_file(path, &text),
        }
    }
}

fn parse(text: &str) -> Option<Value> {
    serde_json::from_str::<Value>(text.trim())
        .ok()
        .filter(Value::is_object)
}

fn token_from(value: &Value) -> Option<OAuthToken> {
    let oauth = value.get("claudeAiOauth")?;
    let text = |key: &str| {
        oauth
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    };
    Some(OAuthToken {
        access_token: text("accessToken")?,
        expires_at: oauth
            .get("expiresAt")
            .and_then(Value::as_i64)
            .map(TimestampMs::from_millis),
        refresh_token: text("refreshToken"),
        scopes: oauth
            .get("scopes")
            .and_then(Value::as_array)
            .map(|scopes| {
                scopes
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
        client_id: text("clientId"),
    })
}

fn merge(raw: &Value, refreshed: &RefreshedToken) -> Option<Value> {
    let mut updated = raw.clone();
    let oauth = updated.get_mut("claudeAiOauth")?.as_object_mut()?;
    oauth.insert("accessToken".into(), json!(refreshed.access_token));
    oauth.insert("refreshToken".into(), json!(refreshed.refresh_token));
    oauth.insert("expiresAt".into(), json!(refreshed.expires_at.as_millis()));
    if let Some(expires_at) = refreshed.refresh_token_expires_at {
        oauth.insert(
            "refreshTokenExpiresAt".into(),
            json!(expires_at.as_millis()),
        );
    }
    if let Some(scopes) = &refreshed.scopes {
        oauth.insert("scopes".into(), json!(scopes));
    }
    Some(updated)
}

fn credentials_file() -> Option<PathBuf> {
    Some(home::home_dir()?.join(".claude").join(".credentials.json"))
}

fn write_file(path: &PathBuf, text: &str) -> bool {
    let temp = path.with_extension(format!("json.{}", std::process::id()));
    if fs::write(&temp, text).is_err() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&temp, fs::Permissions::from_mode(0o600));
    }
    if fs::rename(&temp, path).is_err() {
        let _ = fs::remove_file(&temp);
        return false;
    }
    true
}

#[cfg(target_os = "macos")]
fn keychain() -> Option<Credentials> {
    use std::process::Command;

    let secret = Command::new("security")
        .args(["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"])
        .output()
        .ok()
        .filter(|output| output.status.success())?;
    let raw = parse(&String::from_utf8(secret.stdout).ok()?)?;
    let attributes = Command::new("security")
        .args(["find-generic-password", "-s", KEYCHAIN_SERVICE])
        .output()
        .ok();
    let account = attributes
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .and_then(|text| keychain_account(&text))
        .or_else(|| std::env::var("USER").ok())?;
    Some(Credentials {
        raw,
        store: Store::Keychain { account },
    })
}

#[cfg(target_os = "macos")]
fn keychain_account(attributes: &str) -> Option<String> {
    let line = attributes
        .lines()
        .find(|line| line.trim_start().starts_with("\"acct\"<blob>="))?;
    let value = line.split_once("=\"")?.1.strip_suffix('"')?;
    Some(value.to_string()).filter(|value| !value.is_empty() && !value.contains('"'))
}

/// `security -i` reads the command from stdin, so the secret never appears
/// in the process list. `-X` takes the payload as hex, like Claude Code.
#[cfg(target_os = "macos")]
fn write_keychain(account: &str, text: &str) -> bool {
    use std::{
        io::Write,
        process::{Command, Stdio},
    };

    let hex = text
        .bytes()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let command = format!(
        "add-generic-password -U -a \"{account}\" -s \"{KEYCHAIN_SERVICE}\" -X \"{hex}\"\n"
    );
    let Ok(mut child) = Command::new("security")
        .arg("-i")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    let written = child
        .stdin
        .take()
        .is_some_and(|mut stdin| stdin.write_all(command.as_bytes()).is_ok());
    child.wait().is_ok_and(|status| status.success()) && written
}

#[cfg(test)]
mod tests {
    use super::*;

    const STORED: &str = r#"{
      "claudeAiOauth": {
        "accessToken": "sk-ant-oat-old",
        "refreshToken": "sk-ant-ort-old",
        "expiresAt": 1800000000000,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_20x"
      },
      "mcpOAuth": {"server": {"accessToken": "keep-me"}}
    }"#;

    #[test]
    fn reads_access_and_refresh_tokens_with_scopes() {
        let token = token_from(&parse(STORED).unwrap()).unwrap();
        assert_eq!(token.access_token, "sk-ant-oat-old");
        assert_eq!(token.refresh_token.as_deref(), Some("sk-ant-ort-old"));
        assert_eq!(token.scopes, ["user:inference", "user:profile"]);
        assert_eq!(token.client_id, None);

        let expires_at = TimestampMs::from_millis(1_800_000_000_000);
        assert!(!token.is_expired(expires_at.checked_sub_millis(1).unwrap()));
        assert!(token.is_expired(expires_at));
        assert!(token.expires_soon(expires_at.checked_sub_millis(60_000).unwrap()));
        assert!(!token.expires_soon(expires_at.checked_sub_millis(600_000).unwrap()));

        let without_expiry = token_from(&json!({"claudeAiOauth": {"accessToken": "sk"}})).unwrap();
        assert!(!without_expiry.is_expired(expires_at));
        assert!(token_from(&json!({"claudeAiOauth": {"accessToken": ""}})).is_none());
    }

    #[test]
    fn merge_replaces_only_renewed_fields() {
        let refreshed = RefreshedToken {
            access_token: "sk-ant-oat-new".into(),
            refresh_token: "sk-ant-ort-new".into(),
            expires_at: TimestampMs::from_millis(1_800_028_800_000),
            refresh_token_expires_at: None,
            scopes: None,
        };
        let merged = merge(&parse(STORED).unwrap(), &refreshed).unwrap();
        let oauth = &merged["claudeAiOauth"];
        assert_eq!(oauth["accessToken"], "sk-ant-oat-new");
        assert_eq!(oauth["refreshToken"], "sk-ant-ort-new");
        assert_eq!(oauth["expiresAt"], 1_800_028_800_000_i64);
        assert_eq!(oauth["scopes"], json!(["user:inference", "user:profile"]));
        assert_eq!(oauth["subscriptionType"], "max");
        assert_eq!(oauth["rateLimitTier"], "default_claude_max_20x");
        assert_eq!(merged["mcpOAuth"]["server"]["accessToken"], "keep-me");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn reads_keychain_account_attribute() {
        let attributes = "keychain: \"/Users/me/Library/Keychains/login.keychain-db\"\nattributes:\n    \"acct\"<blob>=\"melvynx\"\n    \"svce\"<blob>=\"Claude Code-credentials\"\n";
        assert_eq!(keychain_account(attributes).as_deref(), Some("melvynx"));
        assert_eq!(keychain_account("    \"acct\"<blob>=<NULL>"), None);
    }
}
