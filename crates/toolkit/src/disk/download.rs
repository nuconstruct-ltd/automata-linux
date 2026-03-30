use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use indicatif::{ProgressBar, ProgressStyle};
use tracing::info;

use crate::config::Config;

const REPO: &str = "automata-network/automata-linux";

/// Download disk image from GitHub releases.
/// Returns the path to the downloaded disk file.
pub fn download_disk(config: &Config) -> Result<PathBuf> {
    let disk_dir = Config::disk_cache_dir()?;
    let filename = config.disk_filename();
    let disk_path = disk_dir.join(filename);

    // Check if already cached
    if disk_path.exists() {
        info!(path = %disk_path.display(), "Disk image already cached");
        return Ok(disk_path);
    }

    let tag = &config.release_tag;
    info!(tag, filename, "Downloading disk image from GitHub...");

    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(3600))
        .build()?;

    // Fetch release info
    let api_url = if tag == "latest" {
        format!("https://api.github.com/repos/{}/releases/latest", REPO)
    } else {
        format!("https://api.github.com/repos/{}/releases/tags/{}", REPO, tag)
    };

    let mut req = client.get(&api_url)
        .header("User-Agent", "toolkit");

    if let Ok(token) = std::env::var("GITHUB_TOKEN") {
        req = req.header("Authorization", format!("Bearer {}", token));
    }

    let release: crate::types::GitHubRelease = req
        .send()
        .context("Failed to fetch release info from GitHub")?
        .json()
        .context("Failed to parse release info")?;

    // Find the disk asset
    let asset = release.assets.iter()
        .find(|a| a.name == filename)
        .with_context(|| format!(
            "Disk image '{}' not found in release {}. Available: {}",
            filename,
            release.tag_name,
            release.assets.iter().map(|a| a.name.as_str()).collect::<Vec<_>>().join(", ")
        ))?;

    // Download with progress bar
    let mut req = client.get(&asset.browser_download_url)
        .header("User-Agent", "toolkit");

    if let Ok(token) = std::env::var("GITHUB_TOKEN") {
        req = req.header("Authorization", format!("Bearer {}", token));
    }

    let resp = req.send().context("Failed to start download")?;
    let total_size = resp.content_length().unwrap_or(asset.size);

    let pb = ProgressBar::new(total_size);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{spinner:.green} [{bar:40.cyan/blue}] {bytes}/{total_bytes} ({eta})")
            .unwrap()
            .progress_chars("#>-"),
    );

    let mut file = File::create(&disk_path)
        .with_context(|| format!("Failed to create {}", disk_path.display()))?;

    let bytes = resp.bytes().context("Failed to read response body")?;
    pb.set_position(bytes.len() as u64);
    file.write_all(&bytes)?;
    pb.finish_with_message("Downloaded");

    info!(path = %disk_path.display(), "Disk image downloaded");

    // Also download secure boot certs
    download_secure_boot_certs(&client, &release, &disk_dir)?;

    Ok(disk_path)
}

fn download_secure_boot_certs(
    client: &reqwest::blocking::Client,
    release: &crate::types::GitHubRelease,
    disk_dir: &Path,
) -> Result<()> {
    let cert_dir = disk_dir.join("secure_boot");
    if cert_dir.join("PK.crt").exists() {
        info!("Secure boot certs already present");
        return Ok(());
    }

    let asset = match release.assets.iter().find(|a| a.name == "secure-boot-certs.zip") {
        Some(a) => a,
        None => {
            info!("No secure-boot-certs.zip in release, skipping");
            return Ok(());
        }
    };

    info!("Downloading secure boot certificates...");

    let mut req = client.get(&asset.browser_download_url)
        .header("User-Agent", "toolkit");

    if let Ok(token) = std::env::var("GITHUB_TOKEN") {
        req = req.header("Authorization", format!("Bearer {}", token));
    }

    let resp = req.send().context("Failed to download certs")?;
    let bytes = resp.bytes()?;

    let zip_path = disk_dir.join("secure-boot-certs.zip");
    fs::write(&zip_path, &bytes)?;

    // Extract
    fs::create_dir_all(&cert_dir)?;
    let file = File::open(&zip_path)?;
    let mut archive = zip::ZipArchive::new(file)?;
    archive.extract(&cert_dir)?;

    // Cleanup zip
    let _ = fs::remove_file(&zip_path);

    info!("Secure boot certificates extracted");
    Ok(())
}
