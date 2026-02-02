#![allow(dead_code)]

use std::collections::HashMap;
use std::path::Path;

use anyhow::{Context, Result};
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// atakit.json configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct AtakitConfig {
    pub workloads: Vec<WorkloadDef>,
    #[serde(default)]
    pub platforms: Vec<String>,
    #[serde(default)]
    pub disks: Vec<DiskDef>,
    #[serde(default)]
    pub deployment: HashMap<String, DeploymentDef>,
}

impl AtakitConfig {
    /// Load atakit.json from the given directory (or current working directory).
    pub fn load_from(dir: &Path) -> Result<Self> {
        let path = dir.join("atakit.json");
        let content = std::fs::read_to_string(&path)
            .with_context(|| format!("Failed to read {}", path.display()))?;
        serde_json::from_str(&content)
            .with_context(|| format!("Failed to parse {}", path.display()))
    }

    /// Load atakit.json from the current working directory.
    pub fn load() -> Result<Self> {
        Self::load_from(&std::env::current_dir()?)
    }
}

#[derive(Debug, Deserialize)]
pub struct WorkloadDef {
    pub name: String,
    /// Relative path to the docker-compose file.
    pub docker_compose: String,
}

#[derive(Debug, Deserialize)]
pub struct DiskDef {
    pub name: String,
    pub size: String,
    #[serde(default)]
    pub encryption: Option<DiskEncryption>,
}

#[derive(Debug, Deserialize)]
pub struct DiskEncryption {
    pub enable: bool,
    #[serde(default = "default_key_security")]
    pub encryption_key_security: String,
}

fn default_key_security() -> String {
    "standard".to_string()
}

#[derive(Debug, Deserialize)]
pub struct DeploymentDef {
    #[serde(default)]
    pub platforms: HashMap<String, PlatformConfig>,
}

#[derive(Debug, Deserialize)]
pub struct PlatformConfig {
    #[serde(default)]
    pub vmtype: Option<String>,
    #[serde(default)]
    pub region: Option<String>,
}

// ---------------------------------------------------------------------------
// Docker Compose (minimal representation for file extraction)
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, Serialize)]
pub struct DockerCompose {
    #[serde(default)]
    pub services: IndexMap<String, ComposeService>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volumes: Option<IndexMap<String, serde_yaml::Value>>,
    /// Preserves unknown top-level keys (e.g. `version`, `networks`, `configs`).
    #[serde(flatten)]
    pub extra: IndexMap<String, serde_yaml::Value>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct ComposeService {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub build: Option<serde_yaml::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub volumes: Vec<String>,
    #[serde(default, skip_serializing_if = "EnvFileEntry::is_none")]
    pub env_file: EnvFileEntry,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ports: Vec<String>,
    /// Preserves unknown service-level keys (e.g. `environment`, `depends_on`, `restart`).
    #[serde(flatten)]
    pub extra: IndexMap<String, serde_yaml::Value>,
}

/// `env_file` can be a single string or a list of strings.
#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(untagged)]
pub enum EnvFileEntry {
    #[default]
    None,
    Single(String),
    Multiple(Vec<String>),
}

impl EnvFileEntry {
    pub fn is_none(&self) -> bool {
        matches!(self, EnvFileEntry::None)
    }

    pub fn to_paths(&self) -> Vec<String> {
        match self {
            EnvFileEntry::None => vec![],
            EnvFileEntry::Single(s) => vec![s.clone()],
            EnvFileEntry::Multiple(v) => v.clone(),
        }
    }
}

// ---------------------------------------------------------------------------
// Workload manifest (embedded inside the tar.gz package)
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct WorkloadManifest {
    pub name: String,
    pub docker_compose: String,
    pub measured_files: Vec<String>,
    pub additional_data_files: Vec<String>,
    pub docker_images: Vec<DockerImageEntry>,
}

#[derive(Debug, Serialize)]
pub struct DockerImageEntry {
    pub service: String,
    /// For pre-published images (no build directive).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_tag: Option<String>,
    /// Filename of the saved tar inside the package (for locally built images).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_tar: Option<String>,
}
