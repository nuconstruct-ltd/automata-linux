use std::fs;
use std::path::PathBuf;

use anyhow::{Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};

use crate::config::Config;

/// Deployment state persisted to disk.
/// Replaces the _artifacts/ flat file approach.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DeployState {
    pub vm_name: String,
    pub csp: String,
    pub region: String,

    #[serde(default)]
    pub project_id: Option<String>,

    #[serde(default)]
    pub ip: Option<String>,

    #[serde(default)]
    pub api_token: Option<String>,

    #[serde(default)]
    pub bucket: Option<String>,

    #[serde(default)]
    pub image_name: Option<String>,

    #[serde(default)]
    pub firewall_rule: Option<String>,

    #[serde(default)]
    pub disk_name: Option<String>,

    #[serde(default)]
    pub static_ip_name: Option<String>,

    #[serde(default)]
    pub created_at: Option<String>,
}

impl DeployState {
    /// Create a new state from config.
    pub fn from_config(config: &Config) -> Self {
        DeployState {
            vm_name: config.vm_name.clone(),
            csp: config.csp.clone(),
            region: config.region.clone(),
            project_id: config.project_id.clone(),
            ip: None,
            api_token: None,
            bucket: config.bucket.clone(),
            image_name: None,
            firewall_rule: None,
            disk_name: config.attach_disk.clone(),
            static_ip_name: config.create_ip_name.clone(),
            created_at: Some(Utc::now().to_rfc3339()),
        }
    }

    /// Get the state file path for a VM name.
    pub fn state_path(vm_name: &str) -> Result<PathBuf> {
        let dir = Config::state_dir()?;
        Ok(dir.join(format!("{}.yaml", vm_name)))
    }

    /// Load state from disk.
    pub fn load(vm_name: &str) -> Result<Self> {
        let path = Self::state_path(vm_name)?;
        let content = fs::read_to_string(&path)
            .with_context(|| format!("No deployment state found for '{}'. Deploy first.", vm_name))?;
        serde_yaml::from_str(&content)
            .with_context(|| format!("Failed to parse state file: {}", path.display()))
    }

    /// Save state to disk.
    pub fn save(&self) -> Result<()> {
        let path = Self::state_path(&self.vm_name)?;
        let content = serde_yaml::to_string(self)
            .context("Failed to serialize state")?;
        fs::write(&path, content)
            .with_context(|| format!("Failed to write state file: {}", path.display()))?;
        Ok(())
    }

    /// Remove state file.
    pub fn remove(vm_name: &str) -> Result<()> {
        let path = Self::state_path(vm_name)?;
        if path.exists() {
            fs::remove_file(&path)?;
        }
        Ok(())
    }
}
