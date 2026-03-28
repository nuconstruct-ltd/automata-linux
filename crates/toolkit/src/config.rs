use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

/// Main configuration loaded from cvm.yaml
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Config {
    /// Cloud service provider: gcp (only GCP supported for now)
    pub csp: String,

    /// GCP project ID
    #[serde(default)]
    pub project_id: Option<String>,

    /// Deployment region/zone
    pub region: String,

    /// VM instance type
    pub vm_type: String,

    /// VM instance name
    pub vm_name: String,

    /// Custom workload directory (optional — uses embedded template if omitted)
    #[serde(default)]
    pub workload_dir: Option<String>,

    /// Cloud storage bucket name
    #[serde(default)]
    pub bucket: Option<String>,

    /// Existing data disk name to attach
    #[serde(default)]
    pub attach_disk: Option<String>,

    /// Data disk size in GB
    #[serde(default = "default_disk_size")]
    pub disk_size: u32,

    /// Boot disk size in GB (GCP only)
    #[serde(default)]
    pub boot_disk_size: Option<u32>,

    /// Ports to open in firewall
    #[serde(default)]
    pub ports: Vec<u16>,

    /// Additional ports exposed by the operator service (added to controller's port mappings)
    #[serde(default)]
    pub operator_ports: Vec<u16>,

    /// GCP static IP name to create/use
    #[serde(default)]
    pub create_ip_name: Option<String>,

    /// Static IP address to use
    #[serde(default)]
    pub ip: Option<String>,

    /// Path to SSH public key file
    #[serde(default)]
    pub ssh_public_key_file: Option<String>,

    /// Runtime environment variables grouped by service (flattened into .env)
    #[serde(default)]
    pub env: EnvConfig,

    /// GitHub release tag for disk image download
    #[serde(default = "default_release_tag")]
    pub release_tag: String,

    /// Docker image for disk operations
    #[serde(default = "default_disktools_image")]
    pub disktools_image: String,

    /// Local image tar archives to copy into workload (for private images)
    #[serde(default)]
    pub image_tars: Vec<String>,

    /// Secret files to copy into workload/secrets/ (e.g. nodekey, leaders, authorized_keys)
    /// Map of filename -> local path
    #[serde(default)]
    pub secret_files: HashMap<String, String>,

    /// Container images used in workload (resolved at build time, baked into compose)
    #[serde(default)]
    pub images: ImageConfig,
}

/// Container image references. All have defaults.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ImageConfig {
    #[serde(default = "default_tool_node_image")]
    pub tool_node: String,
    #[serde(default = "default_lighthouse_image")]
    pub lighthouse: String,
    #[serde(default = "default_node_exporter_image")]
    pub node_exporter: String,
    #[serde(default = "default_promtail_image")]
    pub promtail: String,
    #[serde(default = "default_vmagent_image")]
    pub vmagent: String,
    #[serde(default = "default_controller_image")]
    pub controller: String,
    #[serde(default = "default_operator_image")]
    pub operator: String,
    #[serde(default = "default_socat_image")]
    pub socat: String,
    #[serde(default = "default_caddy_image")]
    pub caddy: String,
}

impl Default for ImageConfig {
    fn default() -> Self {
        Self {
            tool_node: default_tool_node_image(),
            lighthouse: default_lighthouse_image(),
            node_exporter: default_node_exporter_image(),
            promtail: default_promtail_image(),
            vmagent: default_vmagent_image(),
            controller: default_controller_image(),
            operator: default_operator_image(),
            socat: default_socat_image(),
            caddy: default_caddy_image(),
        }
    }
}

/// Runtime environment variables grouped by service.
/// All maps are flattened into a single .env file at deploy time.
#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct EnvConfig {
    /// Tool Node: NETWORK, RELAY_SECRET_KEY, TEE_VERIFIER_ADDRESS, TOOL_DNS_ENDPOINT, HISTORY_BLOCKS, HISTORY_CHAIN
    #[serde(default)]
    pub tool_node: HashMap<String, String>,

    /// Lighthouse: CHECKPOINT_SYNC_URL, FEE_RECIPIENT
    #[serde(default)]
    pub lighthouse: HashMap<String, String>,

    /// Logging (Promtail → Loki): LOKI_HOST, LOKI_USER, LOKI_PASSWORD
    #[serde(default)]
    pub logging: HashMap<String, String>,

    /// Metrics (vmagent → Prometheus): METRICS_HOST, METRICS_USER, METRICS_PASSWORD
    #[serde(default)]
    pub metrics: HashMap<String, String>,

    /// Caddy reverse proxy: CADDY_RPC_DOMAIN, CADDY_CVM_DOMAIN, CADDY_CONTROLLER_DOMAIN
    #[serde(default)]
    pub caddy: HashMap<String, String>,

    /// Operator: SSH_PUBLIC_KEY
    #[serde(default)]
    pub operator: HashMap<String, String>,
}

impl EnvConfig {
    /// Flatten all service env maps into a single map.
    pub fn flatten(&self) -> HashMap<String, String> {
        let mut merged = HashMap::new();
        for map in [
            &self.tool_node,
            &self.lighthouse,
            &self.logging,
            &self.metrics,
            &self.caddy,
            &self.operator,
        ] {
            merged.extend(map.iter().map(|(k, v)| (k.clone(), v.clone())));
        }
        merged
    }
}

fn default_disk_size() -> u32 {
    10
}

fn default_release_tag() -> String {
    "v0.0.9".to_string()
}

fn default_disktools_image() -> String {
    "ghcr.io/nuconstruct-ltd/toolkit-disktools:latest".to_string()
}

fn default_tool_node_image() -> String {
    "gcr.io/constellation-458212/tool-node:ratls-13".to_string()
}
fn default_lighthouse_image() -> String {
    "docker.io/sigp/lighthouse:latest-unstable".to_string()
}
fn default_node_exporter_image() -> String {
    "docker.io/prom/node-exporter:v1.9.1".to_string()
}
fn default_promtail_image() -> String {
    "docker.io/grafana/promtail:latest".to_string()
}
fn default_vmagent_image() -> String {
    "docker.io/victoriametrics/vmagent:v1.108.1".to_string()
}
fn default_controller_image() -> String {
    "ghcr.io/nuconstruct-ltd/controller:latest".to_string()
}
fn default_operator_image() -> String {
    "ghcr.io/nuconstruct-ltd/operator:latest".to_string()
}
fn default_socat_image() -> String {
    "docker.io/alpine/socat:latest".to_string()
}
fn default_caddy_image() -> String {
    "docker.io/library/caddy:latest".to_string()
}

impl Config {
    /// Load configuration from a YAML file.
    pub fn load(path: &Path) -> Result<Self> {
        let content = fs::read_to_string(path)
            .with_context(|| format!("Failed to read config file: {}", path.display()))?;
        let config: Config = serde_yaml::from_str(&content)
            .with_context(|| format!("Failed to parse config file: {}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    /// Validate the configuration.
    pub fn validate(&self) -> Result<()> {
        match self.csp.as_str() {
            "gcp" => self.validate_gcp()?,
            other => bail!("Unsupported CSP: '{}'. Currently only 'gcp' is supported.", other),
        }
        Ok(())
    }

    fn validate_gcp(&self) -> Result<()> {
        if self.project_id.as_ref().map_or(true, |s| s.is_empty()) {
            bail!("'project_id' is required for GCP deployments");
        }

        // Validate VM type supports CVM
        let vm_type = &self.vm_type;
        let is_tdx = vm_type.starts_with("c3-standard-");
        let is_snp = vm_type.starts_with("n2d-standard-");

        if !is_tdx && !is_snp {
            bail!(
                "VM type '{}' does not support Confidential Computing.\n\
                 Supported types:\n\
                 - c3-standard-* (TDX)\n\
                 - n2d-standard-* (SEV-SNP)",
                vm_type
            );
        }

        // Validate region
        let region = &self.region;
        if is_tdx {
            let valid_regions = [
                "asia-southeast1", "europe-west4", "us-central1",
            ];
            let region_prefix = region.rsplitn(2, '-').collect::<Vec<_>>();
            let zone_base = if region_prefix.len() == 2 {
                region_prefix[1].to_string()
            } else {
                region.clone()
            };
            if !valid_regions.iter().any(|r| zone_base.starts_with(r)) {
                bail!(
                    "Region '{}' does not support TDX (c3-standard-*).\nSupported: {}",
                    region,
                    valid_regions.join(", ")
                );
            }
        }

        Ok(())
    }

    /// Get the SSH public key content.
    pub fn ssh_public_key(&self) -> Result<Option<String>> {
        // Check if env.operator has SSH_PUBLIC_KEY
        if let Some(key) = self.env.operator.get("SSH_PUBLIC_KEY") {
            if !key.is_empty() {
                return Ok(Some(key.clone()));
            }
        }

        // Read from file
        if let Some(file_path) = &self.ssh_public_key_file {
            let expanded = shellexpand::tilde(file_path);
            let path = PathBuf::from(expanded.as_ref());
            if path.exists() {
                let key = fs::read_to_string(&path)
                    .with_context(|| format!("Failed to read SSH key: {}", path.display()))?
                    .trim()
                    .to_string();
                return Ok(Some(key));
            }
        }

        Ok(None)
    }

    /// Generate .env file content from all env sections (flattened).
    pub fn generate_dotenv(&self) -> String {
        let flat = self.env.flatten();
        let mut lines: Vec<String> = Vec::new();
        // Sort keys for deterministic output
        let mut keys: Vec<&String> = flat.keys().collect();
        keys.sort();
        for key in keys {
            let value = &flat[key];
            // Quote values that contain spaces or special chars
            if value.contains(' ') || value.contains('"') || value.contains('\'') {
                lines.push(format!("{}=\"{}\"", key, value.replace('"', "\\\"")));
            } else {
                lines.push(format!("{}={}", key, value));
            }
        }
        lines.join("\n") + "\n"
    }

    /// Apply all template substitutions (images + operator ports).
    pub fn apply_to_template(&self, template: &str) -> String {
        let result = template
            .replace("{{TOOL_NODE_IMAGE}}", &self.images.tool_node)
            .replace("{{LIGHTHOUSE_IMAGE}}", &self.images.lighthouse)
            .replace("{{NODE_EXPORTER_IMAGE}}", &self.images.node_exporter)
            .replace("{{PROMTAIL_IMAGE}}", &self.images.promtail)
            .replace("{{VMAGENT_IMAGE}}", &self.images.vmagent)
            .replace("{{CONTROLLER_IMAGE}}", &self.images.controller)
            .replace("{{OPERATOR_IMAGE}}", &self.images.operator)
            .replace("{{SOCAT_IMAGE}}", &self.images.socat)
            .replace("{{CADDY_IMAGE}}", &self.images.caddy);

        // Generate operator port lines for docker-compose
        let operator_ports = if self.operator_ports.is_empty() {
            String::new()
        } else {
            self.operator_ports
                .iter()
                .map(|p| format!("      - \"{}:{}\"", p, p))
                .collect::<Vec<_>>()
                .join("\n")
                + "\n"
        };
        result.replace("{{OPERATOR_PORTS}}\n", &operator_ports)
    }

    /// Get the GCP confidential compute type based on VM type.
    pub fn confidential_compute_type(&self) -> &str {
        if self.vm_type.starts_with("c3-standard-") {
            "TDX"
        } else {
            "SEV_SNP"
        }
    }

    /// Get the disk filename for this CSP.
    pub fn disk_filename(&self) -> &str {
        match self.csp.as_str() {
            "gcp" => "gcp_disk.tar.gz",
            "aws" => "aws_disk.vmdk",
            "azure" => "azure_disk.vhd",
            _ => "gcp_disk.tar.gz",
        }
    }

    /// Get the state directory (~/.toolkit/state/)
    pub fn state_dir() -> Result<PathBuf> {
        let dir = dirs::home_dir()
            .context("Could not determine home directory")?
            .join(".toolkit")
            .join("state");
        fs::create_dir_all(&dir)?;
        Ok(dir)
    }

    /// Get the disk cache directory (~/.toolkit/disks/)
    pub fn disk_cache_dir() -> Result<PathBuf> {
        let dir = dirs::home_dir()
            .context("Could not determine home directory")?
            .join(".toolkit")
            .join("disks");
        fs::create_dir_all(&dir)?;
        Ok(dir)
    }
}
