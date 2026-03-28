use anyhow::Result;
use tracing::info;

use crate::agent::client::AgentClient;
use crate::config::Config;
use crate::state::DeployState;
use crate::workload;

pub fn run(config: Config) -> Result<()> {
    let state = DeployState::load(&config.vm_name)?;

    let ip = state.ip.as_deref()
        .ok_or_else(|| anyhow::anyhow!("No IP found in state for '{}'", config.vm_name))?;
    let token = state.api_token.as_deref()
        .ok_or_else(|| anyhow::anyhow!("No API token found in state for '{}'", config.vm_name))?;

    // Resolve workload
    let workload = workload::resolve::resolve(&config)?;

    // Update via CVM agent
    let client = AgentClient::new(ip, token)?;
    client.update_workload(&workload.path)?;

    info!(vm_name = %config.vm_name, ip, "Workload updated");
    Ok(())
}
