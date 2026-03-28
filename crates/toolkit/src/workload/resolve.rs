use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use tempfile::TempDir;
use tracing::info;

use crate::config::Config;
use super::templates;

/// Resolved workload directory with optional temp dir handle.
pub struct ResolvedWorkload {
    pub path: PathBuf,
    /// Hold this to keep the temp dir alive.
    _temp_dir: Option<TempDir>,
}

/// Resolve the workload source: custom dir or embedded template.
pub fn resolve(config: &Config) -> Result<ResolvedWorkload> {
    if let Some(ref workload_dir) = config.workload_dir {
        // User specified a custom workload directory
        let path = PathBuf::from(workload_dir);
        if !path.exists() {
            bail!("Workload directory not found: {}", path.display());
        }
        if !path.join("docker-compose.yml").exists() {
            bail!("No docker-compose.yml found in workload directory: {}", path.display());
        }

        info!(path = %path.display(), "Using custom workload directory");

        // Write .env from config
        write_dotenv(config, &path)?;

        // Copy image tars and secret files
        copy_image_tars(config, &path)?;
        copy_secret_files(config, &path)?;

        Ok(ResolvedWorkload {
            path,
            _temp_dir: None,
        })
    } else {
        // Use embedded template
        info!("Using built-in workload template");

        let temp_dir = TempDir::new().context("Failed to create temp directory")?;
        let workload_path = temp_dir.path().to_path_buf();

        // Write embedded template files (resolves {{IMAGE}} placeholders)
        templates::write_all(&workload_path, config)?;

        // Write .env from config
        write_dotenv(config, &workload_path)?;

        // Copy image tars and secret files
        copy_image_tars(config, &workload_path)?;
        copy_secret_files(config, &workload_path)?;

        Ok(ResolvedWorkload {
            path: workload_path,
            _temp_dir: Some(temp_dir),
        })
    }
}

/// Copy image tar archives into workload directory.
fn copy_image_tars(config: &Config, workload_dir: &Path) -> Result<()> {
    if config.image_tars.is_empty() {
        return Ok(());
    }

    for tar_path in &config.image_tars {
        let src = PathBuf::from(tar_path);
        if !src.exists() {
            bail!("Image tar not found: {}", src.display());
        }
        let filename = src.file_name()
            .context("Image tar has no filename")?;
        let dest = workload_dir.join(filename);
        fs::copy(&src, &dest)
            .with_context(|| format!("Failed to copy image tar: {}", src.display()))?;
        info!(src = %src.display(), dest = %dest.display(), "Copied image tar");
    }

    Ok(())
}

/// Copy secret files into workload/secrets/.
fn copy_secret_files(config: &Config, workload_dir: &Path) -> Result<()> {
    if config.secret_files.is_empty() {
        return Ok(());
    }

    let secrets_dir = workload_dir.join("secrets");
    fs::create_dir_all(&secrets_dir)?;

    for (filename, src_path) in &config.secret_files {
        let src = PathBuf::from(src_path);
        if !src.exists() {
            bail!("Secret file not found: {}", src.display());
        }
        let dest = secrets_dir.join(filename);
        fs::copy(&src, &dest)
            .with_context(|| format!("Failed to copy secret: {}", src.display()))?;
        info!(filename, "Copied secret file");
    }

    Ok(())
}

/// Write .env file from config's env map.
fn write_dotenv(config: &Config, workload_dir: &Path) -> Result<()> {
    let content = config.generate_dotenv();
    let env_path = workload_dir.join(".env");
    fs::write(&env_path, &content)
        .with_context(|| format!("Failed to write .env to {}", env_path.display()))?;
    info!(path = %env_path.display(), "Generated .env file");
    Ok(())
}
