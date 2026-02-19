use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Json, Router,
};
use jsonwebtoken::{encode, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tracing::{info, error, warn};

#[derive(Clone)]
struct AppState {
    tool_node_ip: String,
    node_net_subnet: String,
    current_mode: Arc<Mutex<Mode>>,
    api_key: Option<String>,
    authrpc_url: String,
    jwt_secret: [u8; 32],
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
enum Mode {
    #[serde(rename = "internet")]
    InternetOnly,
    #[serde(rename = "tool-node")]
    ToolNodeOnly,
}

#[derive(Debug, Deserialize)]
struct MaintenanceRequest {
    action: String,
}

#[derive(Debug, Serialize)]
struct MaintenanceResponse {
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

#[derive(Serialize)]
struct JwtClaims {
    iat: i64,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let tool_node_ip = std::env::var("TOOL_NODE_IP").unwrap_or_else(|_| "172.20.0.10".to_string());
    let node_net_subnet = std::env::var("NODE_NET_SUBNET").unwrap_or_else(|_| "172.20.0.0/24".to_string());
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".to_string());
    let api_key = std::env::var("CONTROLLER_API_KEY")
        .ok()
        .filter(|k| !k.is_empty());
    let authrpc_url = std::env::var("AUTHRPC_URL")
        .unwrap_or_else(|_| "http://172.20.0.10:8551".to_string());
    let jwt_secret_path = std::env::var("JWT_SECRET_PATH")
        .unwrap_or_else(|_| "/node/jwtsecret".to_string());

    let jwt_secret = read_jwt_secret(&jwt_secret_path);

    info!("Starting Controller");
    if api_key.is_some() {
        info!("API key configured - POST /maintenance endpoint enabled");
    } else {
        info!("No CONTROLLER_API_KEY set - POST /maintenance endpoint will reject all requests");
    }
    info!("Tool Node IP: {}", tool_node_ip);
    info!("Node Net Subnet: {}", node_net_subnet);
    info!("AuthRPC URL: {}", authrpc_url);

    // Initialize nftables and set default mode (tool-node only - isolated)
    init_nftables()?;
    apply_tool_node_mode(&tool_node_ip, &node_net_subnet)?;

    let state = AppState {
        tool_node_ip: tool_node_ip.clone(),
        node_net_subnet: node_net_subnet.clone(),
        current_mode: Arc::new(Mutex::new(Mode::ToolNodeOnly)),
        api_key,
        authrpc_url,
        jwt_secret,
    };

    let app = Router::new()
        .route("/mode", get(get_mode))
        .route("/status", get(get_status))
        .route("/maintenance", post(post_maintenance))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", port);
    info!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

// --- JWT + JSON-RPC for tool-node authrpc ---

fn read_jwt_secret(path: &str) -> [u8; 32] {
    match std::fs::read_to_string(path) {
        Ok(content) => {
            let hex_str = content.trim().trim_start_matches("0x");
            match hex::decode(hex_str) {
                Ok(bytes) if bytes.len() == 32 => {
                    let mut secret = [0u8; 32];
                    secret.copy_from_slice(&bytes);
                    info!("JWT secret loaded from {}", path);
                    secret
                }
                Ok(bytes) => {
                    warn!("JWT secret at {} has wrong length ({} bytes, expected 32). RPC calls will fail.", path, bytes.len());
                    [0u8; 32]
                }
                Err(e) => {
                    warn!("Failed to decode JWT secret hex at {}: {}. RPC calls will fail.", path, e);
                    [0u8; 32]
                }
            }
        }
        Err(e) => {
            warn!("Cannot read JWT secret from {}: {}. RPC calls to tool-node will fail.", path, e);
            [0u8; 32]
        }
    }
}

fn make_jwt_token(secret: &[u8; 32]) -> Result<String, String> {
    let iat = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("System time error: {}", e))?
        .as_secs() as i64;
    let claims = JwtClaims { iat };
    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret),
    )
    .map_err(|e| format!("Failed to create JWT: {}", e))
}

async fn call_tool_node_rpc(url: &str, secret: &[u8; 32], method: &str) -> Result<(), String> {
    let token = make_jwt_token(secret)?;

    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": [],
        "id": 1
    });

    let client = reqwest::Client::new();
    let resp = client
        .post(url)
        .header("Authorization", format!("Bearer {}", token))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("RPC request to {} failed: {}", url, e))?;

    let status = resp.status();
    let resp_body = resp.text().await.unwrap_or_default();

    if !status.is_success() {
        return Err(format!("RPC {} returned {}: {}", method, status, resp_body));
    }

    info!("RPC {} succeeded: {}", method, resp_body);
    Ok(())
}

fn notify_tool_node(state: &AppState, mode: &Mode) {
    let method = match mode {
        Mode::InternetOnly => "maintenance_stopAPIFeed",
        Mode::ToolNodeOnly => "maintenance_startAPIFeed",
    };
    let url = state.authrpc_url.clone();
    let secret = state.jwt_secret;
    let method = method.to_string();
    tokio::spawn(async move {
        info!("Calling tool-node RPC: {}", method);
        if let Err(e) = call_tool_node_rpc(&url, &secret, &method).await {
            error!("Failed to call {}: {}", method, e);
        }
    });
}

// --- nftables ---

fn init_nftables() -> anyhow::Result<()> {
    info!("Initializing nftables");

    // Delete existing table if present (clean slate)
    run_nft(&["delete", "table", "ip", "filter"]).ok();

    // Create new table
    run_nft(&["add", "table", "ip", "filter"])?;

    // Create output chain with filter hook
    run_nft(&[
        "add", "chain", "ip", "filter", "output",
        "{ type filter hook output priority 0 ; policy accept ; }"
    ])?;

    // Create input chain with filter hook (for SSH blocking)
    run_nft(&[
        "add", "chain", "ip", "filter", "input",
        "{ type filter hook input priority 0 ; policy accept ; }"
    ])?;

    Ok(())
}

fn apply_internet_mode(tool_node_ip: &str) -> anyhow::Result<()> {
    info!("Applying Internet Only mode rules (atomic)");

    let ruleset = format!(
        r#"flush chain ip filter output
flush chain ip filter input
add rule ip filter output ct state established,related accept
add rule ip filter output ip daddr {} drop"#,
        tool_node_ip
    );

    run_nft_atomic(&ruleset)?;
    Ok(())
}

fn apply_tool_node_mode(tool_node_ip: &str, node_net_subnet: &str) -> anyhow::Result<()> {
    info!("Applying Tool Node Only mode rules (atomic)");

    let ruleset = format!(
        r#"flush chain ip filter output
flush chain ip filter input
add rule ip filter input tcp dport 22 drop
add rule ip filter output ip daddr 127.0.0.0/8 accept
add rule ip filter output ct state established,related accept
add rule ip filter output ip daddr {} accept
add rule ip filter output ip daddr {} accept
add rule ip filter output drop"#,
        tool_node_ip, node_net_subnet
    );

    run_nft_atomic(&ruleset)?;
    Ok(())
}

// --- HTTP handlers ---

async fn get_mode(State(state): State<AppState>) -> String {
    let mode = state.current_mode.lock().unwrap();
    match *mode {
        Mode::InternetOnly => "internet".to_string(),
        Mode::ToolNodeOnly => "tool-node".to_string(),
    }
}

async fn get_status(State(state): State<AppState>) -> Json<Mode> {
    let mode = state.current_mode.lock().unwrap();
    Json(mode.clone())
}

async fn post_maintenance(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<MaintenanceRequest>,
) -> (StatusCode, Json<MaintenanceResponse>) {
    // Auth check: require CONTROLLER_API_KEY to be set and matched
    match &state.api_key {
        None => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(MaintenanceResponse {
                    status: "error".to_string(),
                    mode: None,
                    previous_mode: None,
                    message: Some("API key not configured on server".to_string()),
                }),
            );
        }
        Some(expected_key) => {
            let auth_header = headers
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            let provided_key = auth_header.strip_prefix("Bearer ").unwrap_or("");
            if provided_key != expected_key {
                return (
                    StatusCode::UNAUTHORIZED,
                    Json(MaintenanceResponse {
                        status: "error".to_string(),
                        mode: None,
                        previous_mode: None,
                        message: Some("Invalid or missing API key".to_string()),
                    }),
                );
            }
        }
    }

    // Determine target mode from action
    let target_mode = match payload.action.as_str() {
        "enable" => Mode::InternetOnly,
        "disable" => Mode::ToolNodeOnly,
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(MaintenanceResponse {
                    status: "error".to_string(),
                    mode: None,
                    previous_mode: None,
                    message: Some(format!(
                        "Invalid action '{}'. Use 'enable' or 'disable'.",
                        payload.action
                    )),
                }),
            );
        }
    };

    // Read current mode
    let previous_mode = {
        let mode = state.current_mode.lock().unwrap();
        mode.clone()
    };

    let previous_str = match previous_mode {
        Mode::InternetOnly => "internet",
        Mode::ToolNodeOnly => "tool-node",
    };

    // If already in the target mode, return success without re-applying rules
    if previous_mode == target_mode {
        return (
            StatusCode::OK,
            Json(MaintenanceResponse {
                status: "ok".to_string(),
                mode: Some(previous_str.to_string()),
                previous_mode: Some(previous_str.to_string()),
                message: Some("Already in requested mode".to_string()),
            }),
        );
    }

    // Apply the mode switch
    let result = match target_mode {
        Mode::InternetOnly => {
            info!("[API] Maintenance ENABLED, switching to Internet mode");
            apply_internet_mode(&state.tool_node_ip)
        }
        Mode::ToolNodeOnly => {
            info!("[API] Maintenance DISABLED, switching to Tool-node mode");
            apply_tool_node_mode(&state.tool_node_ip, &state.node_net_subnet)
        }
    };

    match result {
        Ok(()) => {
            let mut mode = state.current_mode.lock().unwrap();
            *mode = target_mode.clone();
            let new_str = match target_mode {
                Mode::InternetOnly => "internet",
                Mode::ToolNodeOnly => "tool-node",
            };
            info!("Mode switched to: {} (via API)", new_str);
            drop(mode);
            notify_tool_node(&state, &target_mode);
            (
                StatusCode::OK,
                Json(MaintenanceResponse {
                    status: "ok".to_string(),
                    mode: Some(new_str.to_string()),
                    previous_mode: Some(previous_str.to_string()),
                    message: None,
                }),
            )
        }
        Err(e) => {
            error!("Failed to apply mode via API: {}", e);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(MaintenanceResponse {
                    status: "error".to_string(),
                    mode: None,
                    previous_mode: None,
                    message: Some(format!("Failed to apply mode: {}", e)),
                }),
            )
        }
    }
}

// --- nft helpers ---

fn run_nft(args: &[&str]) -> anyhow::Result<()> {
    info!("Running nft {}", args.join(" "));
    let output = Command::new("nft")
        .args(args)
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("nft failed: {}", stderr);
    }
    Ok(())
}

fn run_nft_atomic(ruleset: &str) -> anyhow::Result<()> {
    use std::io::Write;
    use std::process::Stdio;

    info!("Running nft atomic transaction:\n{}", ruleset);

    let mut child = Command::new("nft")
        .arg("-f")
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    // Write ruleset to stdin
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(ruleset.as_bytes())?;
    }

    let output = child.wait_with_output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("nft atomic transaction failed: {}", stderr);
    }
    Ok(())
}
