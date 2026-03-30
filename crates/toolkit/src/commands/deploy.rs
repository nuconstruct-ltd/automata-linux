use anyhow::{Context, Result};
use tracing::info;

use crate::agent::client::AgentClient;
use crate::cloud;
use crate::config::Config;
use crate::disk;
use crate::state::DeployState;
use crate::workload;

pub fn run(config: Config) -> Result<()> {
    info!(vm_name = %config.vm_name, csp = %config.csp, region = %config.region, "Starting deployment");

    // 1. Resolve workload
    let workload = workload::resolve::resolve(&config)?;
    info!(path = %workload.path.display(), "Workload resolved");

    // 2. Download disk image (cached)
    let disk_path = disk::download::download_disk(&config)?;

    // 3. Ensure disktools Docker image
    disk::docker_ops::ensure_image(&config)?;

    // 4. Copy disk to working directory (don't modify cached copy)
    let work_dir = tempfile::tempdir().context("Failed to create temp dir")?;
    let work_disk = work_dir.path().join(config.disk_filename());
    info!("Copying disk image to working directory...");
    std::fs::copy(&disk_path, &work_disk)
        .context("Failed to copy disk image")?;

    // 5. Prepare disk: inject workload + generate token (single mount/repack cycle)
    //    Uses raw disk cache (pigz for parallel compression)
    let token = disk::docker_ops::prepare_disk(&config, &work_disk, &workload.path)?;

    // 6. Create deployment state
    let mut state = DeployState::from_config(&config);
    state.api_token = Some(token.clone());

    // 7. Deploy to cloud
    match config.csp.as_str() {
        "gcp" => {
            cloud::gcp::deploy(&config, &work_disk, &mut state)?;
        }
        other => {
            anyhow::bail!("CSP '{}' not yet supported", other);
        }
    }

    // 8. Save state
    state.save()?;
    info!(state_file = %DeployState::state_path(&config.vm_name)?.display(), "State saved");

    // 9. Fetch golden measurements
    if let Some(ref ip) = state.ip {
        info!(ip, "Fetching golden measurements...");
        let client = AgentClient::new(ip, &token)?;
        match client.get_measurements() {
            Ok((offchain, onchain)) => {
                let measurements_dir = Config::state_dir()?.join("measurements");
                std::fs::create_dir_all(&measurements_dir)?;

                let offchain_path = measurements_dir.join(format!("{}-offchain.json", config.vm_name));
                let onchain_path = measurements_dir.join(format!("{}-onchain.json", config.vm_name));

                std::fs::write(&offchain_path, serde_json::to_string_pretty(&offchain)?)?;
                std::fs::write(&onchain_path, serde_json::to_string_pretty(&onchain)?)?;

                info!("Golden measurements saved");
            }
            Err(e) => {
                tracing::warn!(error = %e, "Failed to fetch measurements (VM may still be booting)");
            }
        }
    }

    info!(
        vm_name = %config.vm_name,
        ip = state.ip.as_deref().unwrap_or("pending"),
        "Deployment complete!"
    );

    Ok(())
}
