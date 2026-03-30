use anyhow::Result;
use tracing::info;

use crate::cloud;
use crate::config::Config;
use crate::state::DeployState;

pub fn run(config: Config) -> Result<()> {
    let state = DeployState::load(&config.vm_name)?;

    info!(vm_name = %config.vm_name, csp = %config.csp, "Destroying deployment...");

    match config.csp.as_str() {
        "gcp" => cloud::gcp::destroy(&state)?,
        other => anyhow::bail!("CSP '{}' not yet supported", other),
    }

    // Remove state
    DeployState::remove(&config.vm_name)?;

    info!(vm_name = %config.vm_name, "Deployment destroyed");
    Ok(())
}
