use anyhow::Result;
use tracing::info;

use crate::config::Config;
use crate::state::DeployState;
use crate::agent::client::AgentClient;

pub fn run(config: Config) -> Result<()> {
    let state = DeployState::load(&config.vm_name)?;

    let ip = state.ip.as_deref()
        .ok_or_else(|| anyhow::anyhow!("No IP found in state"))?;
    let token = state.api_token.as_deref()
        .ok_or_else(|| anyhow::anyhow!("No API token found in state"))?;

    let client = AgentClient::new(ip, token)?;
    let (offchain, onchain) = client.get_measurements()?;

    info!("Offchain measurement:");
    println!("{}", serde_json::to_string_pretty(&offchain)?);

    info!("Onchain measurement:");
    println!("{}", serde_json::to_string_pretty(&onchain)?);

    Ok(())
}
