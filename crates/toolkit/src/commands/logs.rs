use anyhow::Result;

use crate::config::Config;
use crate::state::DeployState;
use crate::agent::client::AgentClient;

pub fn run(config: Config, containers: Vec<String>) -> Result<()> {
    let state = DeployState::load(&config.vm_name)?;

    let ip = state.ip.as_deref()
        .ok_or_else(|| anyhow::anyhow!("No IP found in state"))?;
    let token = state.api_token.as_deref()
        .ok_or_else(|| anyhow::anyhow!("No API token found in state"))?;

    let client = AgentClient::new(ip, token)?;
    let logs = client.get_logs(&containers)?;

    println!("{}", logs);
    Ok(())
}
