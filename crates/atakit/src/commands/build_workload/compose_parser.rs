use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::types::{DockerCompose, WorkloadDef};

/// Result of analyzing a docker-compose file.
pub struct ComposeAnalysis {
    /// Path to the docker-compose file (relative to project root).
    pub compose_path: PathBuf,
    /// Files that are included in measurement (bundled into package).
    pub measured_files: Vec<PathBuf>,
    /// Files under additional-data/ that are excluded (operator-provided).
    pub additional_data_files: Vec<PathBuf>,
    /// Docker image actions (build locally or pull pre-published).
    pub images: Vec<ImageAction>,
}

pub enum ImageAction {
    /// Image has a `build:` directive — build locally and save as tar.
    Build {
        service: String,
        image_tag: String,
        compose_path: PathBuf,
    },
    /// Image is pre-published — only record the tag.
    Pull { service: String, tag: String },
}

/// Analyze the docker-compose file referenced by a workload definition.
pub fn analyze(project_dir: &Path, wl_def: &WorkloadDef) -> Result<ComposeAnalysis> {
    let compose_rel = PathBuf::from(&wl_def.docker_compose);
    let compose_abs = project_dir.join(&compose_rel);

    let content = std::fs::read_to_string(&compose_abs)
        .with_context(|| format!("Failed to read {}", compose_abs.display()))?;

    let compose: DockerCompose = serde_yaml::from_str(&content)
        .with_context(|| format!("Failed to parse {}", compose_abs.display()))?;

    // The directory containing the docker-compose file is the context base for
    // resolving relative paths within the compose file.
    let compose_dir = compose_abs
        .parent()
        .unwrap_or(Path::new("."));

    let mut measured_files: Vec<PathBuf> = Vec::new();
    let mut additional_data_files: Vec<PathBuf> = Vec::new();
    let mut images: Vec<ImageAction> = Vec::new();

    for (service_name, service) in &compose.services {
        // --- env_file ---
        for env_path_str in service.env_file.to_paths() {
            let rel = normalize_compose_path(compose_dir, &env_path_str, project_dir);
            classify_file(rel, &mut measured_files, &mut additional_data_files);
        }

        // --- volumes (bind mounts only) ---
        for vol in &service.volumes {
            if let Some(host_path) = extract_bind_mount_host(vol) {
                let rel = normalize_compose_path(compose_dir, &host_path, project_dir);
                classify_file(rel, &mut measured_files, &mut additional_data_files);
            }
        }

        // --- image / build ---
        match (&service.build, &service.image) {
            (Some(_build_val), Some(tag)) => {
                // Has both build and image — build locally, tag with image name.
                images.push(ImageAction::Build {
                    service: service_name.clone(),
                    image_tag: tag.clone(),
                    compose_path: compose_rel.clone(),
                });
            }
            (Some(_build_val), None) => {
                // Build directive without explicit image tag.
                let tag = format!("{}_{}", wl_def.name, service_name);
                images.push(ImageAction::Build {
                    service: service_name.clone(),
                    image_tag: tag,
                    compose_path: compose_rel.clone(),
                });
            }
            (None, Some(tag)) => {
                // Pre-published image — just record the tag.
                images.push(ImageAction::Pull {
                    service: service_name.clone(),
                    tag: tag.clone(),
                });
            }
            (None, None) => {
                // No image or build — skip (e.g., utility services).
            }
        }
    }

    // Deduplicate measured files.
    measured_files.sort();
    measured_files.dedup();
    additional_data_files.sort();
    additional_data_files.dedup();

    Ok(ComposeAnalysis {
        compose_path: compose_rel,
        measured_files,
        additional_data_files,
        images,
    })
}

/// Resolve a path from the docker-compose file to a project-relative path.
fn normalize_compose_path(compose_dir: &Path, raw: &str, project_dir: &Path) -> PathBuf {
    let abs = if raw.starts_with('/') {
        PathBuf::from(raw)
    } else {
        compose_dir.join(raw)
    };

    // Make relative to project root.
    abs.strip_prefix(project_dir)
        .map(|p| p.to_path_buf())
        .unwrap_or(abs)
}

/// Classify a file as measured or additional-data.
fn classify_file(
    rel_path: PathBuf,
    measured: &mut Vec<PathBuf>,
    additional_data: &mut Vec<PathBuf>,
) {
    let path_str = rel_path.to_string_lossy();
    if path_str.contains("additional-data/") || path_str.starts_with("additional-data") {
        additional_data.push(rel_path);
    } else {
        measured.push(rel_path);
    }
}

/// Extract the host path from a docker-compose volume string, if it is a bind
/// mount. Returns `None` for named volumes.
///
/// Formats:
///   `./host/path:/container/path[:ro]`  → Some("./host/path")
///   `/abs/path:/container/path`          → Some("/abs/path")
///   `named-volume:/container/path`       → None
fn extract_bind_mount_host(vol: &str) -> Option<String> {
    // Named volumes don't start with `.` or `/` and don't contain `:` before the
    // container path separator.
    let parts: Vec<&str> = vol.splitn(3, ':').collect();
    if parts.len() < 2 {
        return None;
    }
    let host = parts[0];
    // A bind mount starts with `.`, `/`, or `~`.
    if host.starts_with('.') || host.starts_with('/') || host.starts_with('~') {
        Some(host.to_string())
    } else {
        None // named volume
    }
}
