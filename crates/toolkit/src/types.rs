#![allow(dead_code)]

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};

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
    /// Preserves unknown service-level keys.
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_tag: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_tar: Option<String>,
}

// ---------------------------------------------------------------------------
// GitHub Release types (for disk image download)
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct GitHubRelease {
    pub tag_name: String,
    pub assets: Vec<GitHubAsset>,
}

#[derive(Debug, Deserialize)]
pub struct GitHubAsset {
    pub name: String,
    pub url: String,
    pub browser_download_url: String,
    pub size: u64,
}

// ---------------------------------------------------------------------------
// CVM Agent API types
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct GoldenMeasurement {
    #[serde(flatten)]
    pub data: serde_json::Value,
}

#[derive(Debug, Deserialize)]
pub struct ContainerLog {
    pub name: String,
    pub log: String,
}
