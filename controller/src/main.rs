use axum::{
    extract::State,
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::process::Command;
use std::sync::{Arc, Mutex};
use tokio::signal::unix::{signal, SignalKind};
use tracing::{info, error};

#[derive(Clone)]
struct AppState {
    tool_node_ip: String,
    node_net_subnet: String,
    current_mode: Arc<Mutex<Mode>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
enum Mode {
    #[serde(rename = "internet")]
    InternetOnly,
    #[serde(rename = "tool-node")]
    ToolNodeOnly,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let tool_node_ip = std::env::var("TOOL_NODE_IP").unwrap_or_else(|_| "172.20.0.10".to_string());
    let node_net_subnet = std::env::var("NODE_NET_SUBNET").unwrap_or_else(|_| "172.20.0.0/24".to_string());
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".to_string());

    info!("Starting Controller (signal-based mode switching)");
    info!("Tool Node IP: {}", tool_node_ip);
    info!("Node Net Subnet: {}", node_net_subnet);
    info!("SIGUSR2 toggles between modes (from CVM agent maintenance mode)");

    // Initialize nftables and set default mode (tool-node only - isolated)
    init_nftables()?;
    apply_tool_node_mode(&tool_node_ip, &node_net_subnet)?;

    let state = AppState {
        tool_node_ip: tool_node_ip.clone(),
        node_net_subnet: node_net_subnet.clone(),
        current_mode: Arc::new(Mutex::new(Mode::ToolNodeOnly)),
    };

    // Clone state for signal handlers
    let signal_state = state.clone();

    // Spawn signal handler task
    tokio::spawn(async move {
        handle_signals(signal_state).await;
    });

    // HTTP server only exposes read-only endpoints
    let app = Router::new()
        .route("/mode", get(get_mode))
        .route("/status", get(get_status))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", port);
    info!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn handle_signals(state: AppState) {
    let mut sigusr2 = signal(SignalKind::user_defined2()).expect("Failed to register SIGUSR2");

    loop {
        sigusr2.recv().await;
        
        // Toggle mode on SIGUSR2 (sent by CVM agent when maintenance mode changes)
        let current = {
            let mode = state.current_mode.lock().unwrap();
            mode.clone()
        };
        
        match current {
            Mode::ToolNodeOnly => {
                // Maintenance enabled -> switch to internet mode
                info!("[SIGNAL] SIGUSR2 received - maintenance ENABLED, switching to Internet mode");
                if let Err(e) = apply_internet_mode(&state.tool_node_ip) {
                    error!("Failed to apply internet mode: {}", e);
                } else {
                    let mut mode = state.current_mode.lock().unwrap();
                    *mode = Mode::InternetOnly;
                    info!("Mode switched to: internet (WAN access, SSH allowed)");
                }
            }
            Mode::InternetOnly => {
                // Maintenance disabled -> switch to tool-node mode
                info!("[SIGNAL] SIGUSR2 received - maintenance DISABLED, switching to Tool-node mode");
                if let Err(e) = apply_tool_node_mode(&state.tool_node_ip, &state.node_net_subnet) {
                    error!("Failed to apply tool-node mode: {}", e);
                } else {
                    let mut mode = state.current_mode.lock().unwrap();
                    *mode = Mode::ToolNodeOnly;
                    info!("Mode switched to: tool-node (isolated, SSH blocked)");
                }
            }
        }
    }
}

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
    
    // Internet mode (maintenance enabled):
    // - Allow WAN access (outbound)
    // - Block tool-node access
    // - Allow SSH from outside (input)
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
    
    // Tool-node mode (maintenance disabled / isolated):
    // - Block WAN access (outbound)
    // - Allow tool-node access
    // - Block SSH from outside (input on port 22)
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
