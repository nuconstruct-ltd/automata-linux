use std::path::Path;
use std::process::Command;

use anyhow::{bail, Context, Result};
use tracing::info;

use crate::config::Config;

/// Get the disk cache directory for raw disk caching.
fn cache_dir() -> Result<std::path::PathBuf> {
    let dir = Config::disk_cache_dir()?.join("raw_cache");
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Ensure the disktools Docker image is available.
pub fn ensure_image(config: &Config) -> Result<()> {
    let image = &config.disktools_image;

    let output = Command::new("docker")
        .args(["image", "inspect", image])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();

    match output {
        Ok(status) if status.success() => {
            info!(image, "Disktools image available");
            return Ok(());
        }
        _ => {}
    }

    info!(image, "Pulling disktools image...");
    let status = Command::new("docker")
        .args(["pull", image])
        .status()
        .context("Failed to run docker pull. Is Docker installed and running?")?;

    if !status.success() {
        bail!("Failed to pull disktools image: {}", image);
    }

    Ok(())
}

/// Prepare disk: inject workload + generate token in a single mount/repack cycle.
/// Uses raw disk cache to skip extract on subsequent deploys.
/// Returns the API token string.
pub fn prepare_disk(
    config: &Config,
    disk_path: &Path,
    workload_dir: &Path,
) -> Result<String> {
    info!(disk = %disk_path.display(), "Preparing disk (workload + token)...");

    let disk_dir = disk_path.parent()
        .context("Disk path has no parent directory")?;
    let disk_name = disk_path.file_name()
        .context("Disk path has no filename")?
        .to_string_lossy();

    let cache = cache_dir()?;

    let mut cmd_args = vec![
        "prepare-disk".to_string(),
        disk_name.to_string(),
        "/workload".to_string(),
        config.csp.clone(),
        config.vm_name.clone(),
    ];

    if let Some(size) = config.boot_disk_size {
        cmd_args.push(format!("{}G", size));
    }

    let output = Command::new("docker")
        .args(["run", "--rm", "--privileged"])
        .args(["-v", &format!("{}:/disk", disk_dir.display())])
        .args(["-v", &format!("{}:/workload:ro", workload_dir.display())])
        .args(["-v", &format!("{}:/cache", cache.display())])
        .arg(&config.disktools_image)
        .args(&cmd_args)
        .output()
        .context("Failed to run disk preparation via Docker")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("Disk preparation failed: {}", stderr);
    }

    let token = String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_string();

    if token.is_empty() {
        bail!("Disk preparation returned empty token");
    }

    info!("Disk prepared (workload injected, token generated)");
    Ok(token)
}

/// Update disk with workload files.
pub fn update_disk(
    config: &Config,
    disk_path: &Path,
    workload_dir: &Path,
) -> Result<()> {
    info!(disk = %disk_path.display(), "Updating disk with workload...");

    let disk_dir = disk_path.parent()
        .context("Disk path has no parent directory")?;
    let disk_name = disk_path.file_name()
        .context("Disk path has no filename")?
        .to_string_lossy();

    let cache = cache_dir()?;

    let mut cmd_args = vec![
        "update-workload".to_string(),
        disk_name.to_string(),
        "/workload".to_string(),
    ];

    if let Some(size) = config.boot_disk_size {
        cmd_args.push(format!("{}G", size));
    }

    let status = Command::new("docker")
        .args(["run", "--rm", "--privileged"])
        .args(["-v", &format!("{}:/disk", disk_dir.display())])
        .args(["-v", &format!("{}:/workload:ro", workload_dir.display())])
        .args(["-v", &format!("{}:/cache", cache.display())])
        .arg(&config.disktools_image)
        .args(&cmd_args)
        .status()
        .context("Failed to run disk update via Docker")?;

    if !status.success() {
        bail!("Disk update failed");
    }

    info!("Disk updated successfully");
    Ok(())
}

/// Generate API token and embed hash in disk.
/// Returns the API token string.
pub fn generate_token(
    config: &Config,
    disk_path: &Path,
) -> Result<String> {
    info!("Generating API token...");

    let disk_dir = disk_path.parent()
        .context("Disk path has no parent directory")?;
    let disk_name = disk_path.file_name()
        .context("Disk path has no filename")?
        .to_string_lossy();

    let cache = cache_dir()?;

    let output = Command::new("docker")
        .args(["run", "--rm", "--privileged"])
        .args(["-v", &format!("{}:/disk", disk_dir.display())])
        .args(["-v", &format!("{}:/cache", cache.display())])
        .args([&config.disktools_image])
        .args(["generate-token", &disk_name, &config.csp, &config.vm_name])
        .output()
        .context("Failed to run token generation via Docker")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("Token generation failed: {}", stderr);
    }

    let token = String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_string();

    if token.is_empty() {
        bail!("Token generation returned empty token");
    }

    info!("API token generated");
    Ok(token)
}
