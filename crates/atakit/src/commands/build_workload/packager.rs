use std::fs::File;
use std::path::Path;
use std::process::Command;

use anyhow::{bail, Context, Result};
use tracing::{info, warn};
use flate2::write::GzEncoder;
use flate2::Compression;

use crate::types::{DockerImageEntry, WorkloadDef, WorkloadManifest};

use super::compose_parser::{ComposeAnalysis, ImageAction};

/// Create a tar.gz workload package.
pub fn create_package(
    wl_def: &WorkloadDef,
    analysis: &ComposeAnalysis,
    project_dir: &Path,
    artifact_dir: &Path,
) -> Result<()> {
    let output_path = artifact_dir.join(format!("{}.tar.gz", wl_def.name));
    let file = File::create(&output_path)
        .with_context(|| format!("Failed to create {}", output_path.display()))?;
    let enc = GzEncoder::new(file, Compression::default());
    let mut tar = tar::Builder::new(enc);

    let prefix = &wl_def.name;

    // 1. Add docker-compose file.
    let compose_abs = project_dir.join(&analysis.compose_path);
    tar.append_path_with_name(&compose_abs, format!("{}/docker-compose.yml", prefix))
        .with_context(|| {
            format!(
                "Failed to add docker-compose: {}",
                compose_abs.display()
            )
        })?;

    // 2. Add measured files.
    for rel in &analysis.measured_files {
        let abs = project_dir.join(rel);
        if !abs.exists() {
            warn!(path = %rel.display(), "Measured file not found, skipping");
            continue;
        }
        let archive_name = format!("{}/measured/{}", prefix, rel.display());
        if abs.is_file() {
            tar.append_path_with_name(&abs, &archive_name)
                .with_context(|| format!("Failed to add {}", rel.display()))?;
        }
    }

    // 3. Handle Docker images.
    let mut manifest_images: Vec<DockerImageEntry> = Vec::new();

    for action in &analysis.images {
        match action {
            ImageAction::Build {
                service,
                image_tag,
                compose_path,
            } => {
                // Build the image via docker compose.
                let compose_abs = project_dir.join(compose_path);
                info!(service, "Building Docker image");
                let status = Command::new("docker")
                    .args(["compose", "-f"])
                    .arg(&compose_abs)
                    .args(["build", service])
                    .status()
                    .context("Failed to run docker compose build")?;
                if !status.success() {
                    bail!("docker compose build failed for service '{}'", service);
                }

                // Save the image to a temporary tar.
                let image_tar_name = format!("{}.tar", service);
                let image_tar_path = artifact_dir.join(&image_tar_name);
                info!(image_tag, "Saving Docker image");
                let status = Command::new("docker")
                    .args(["save", "-o"])
                    .arg(&image_tar_path)
                    .arg(image_tag)
                    .status()
                    .context("Failed to run docker save")?;
                if !status.success() {
                    bail!("docker save failed for image '{}'", image_tag);
                }

                // Add the image tar to the archive.
                let archive_name = format!("{}/images/{}", prefix, image_tar_name);
                tar.append_path_with_name(&image_tar_path, &archive_name)
                    .with_context(|| {
                        format!("Failed to add image tar: {}", image_tar_name)
                    })?;

                // Clean up the temporary tar.
                let _ = std::fs::remove_file(&image_tar_path);

                manifest_images.push(DockerImageEntry {
                    service: service.clone(),
                    image_tag: Some(image_tag.clone()),
                    image_tar: Some(image_tar_name),
                });
            }
            ImageAction::Pull { service, tag } => {
                manifest_images.push(DockerImageEntry {
                    service: service.clone(),
                    image_tag: Some(tag.clone()),
                    image_tar: None,
                });
            }
        }
    }

    // 4. Create and add manifest.json.
    let manifest = WorkloadManifest {
        name: wl_def.name.clone(),
        docker_compose: "docker-compose.yml".to_string(),
        measured_files: analysis
            .measured_files
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect(),
        additional_data_files: analysis
            .additional_data_files
            .iter()
            .map(|p| p.to_string_lossy().to_string())
            .collect(),
        docker_images: manifest_images,
    };

    let manifest_json = serde_json::to_string_pretty(&manifest)?;
    let manifest_bytes = manifest_json.as_bytes();

    let mut header = tar::Header::new_gnu();
    header.set_size(manifest_bytes.len() as u64);
    header.set_mode(0o644);
    header.set_cksum();
    tar.append_data(
        &mut header,
        format!("{}/manifest.json", prefix),
        manifest_bytes,
    )
    .context("Failed to add manifest.json")?;

    // 5. Finalize the archive.
    let enc = tar.into_inner().context("Failed to finalize tar archive")?;
    enc.finish().context("Failed to finish gzip compression")?;

    Ok(())
}
