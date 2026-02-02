mod azure;
mod gcp;

use anyhow::{bail, Result};
use clap::Args;
use tracing::{info, warn};

use crate::types::AtakitConfig;
use crate::Config;

/// Deploy workloads to cloud platforms using atakit.json configuration.
#[derive(Args)]
pub struct Deploy {
    /// Comma-separated platforms to deploy to (e.g., "gcp,azure")
    #[arg(long, value_delimiter = ',')]
    pub platforms: Vec<String>,

    /// Deployment names from atakit.json (deploys all if omitted)
    pub deployments: Vec<String>,
}

impl Deploy {
    pub fn run(self, config: &Config) -> Result<()> {
        let atakit_config = AtakitConfig::load()?;
        let project_dir = std::env::current_dir()?;
        let artifact_dir = project_dir.join("ata_artifacts");
        let additional_data_dir = project_dir.join("additional-data");

        let deployment_names: Vec<String> = if self.deployments.is_empty() {
            atakit_config.deployment.keys().cloned().collect()
        } else {
            self.deployments.clone()
        };

        if deployment_names.is_empty() {
            bail!("No deployments defined in atakit.json");
        }

        for dep_name in &deployment_names {
            let dep_def = atakit_config
                .deployment
                .get(dep_name)
                .ok_or_else(|| {
                    anyhow::anyhow!(
                        "Deployment '{}' not found in atakit.json. Available: {}",
                        dep_name,
                        atakit_config
                            .deployment
                            .keys()
                            .cloned()
                            .collect::<Vec<_>>()
                            .join(", ")
                    )
                })?;

            let target_platforms: Vec<&String> = if self.platforms.is_empty() {
                dep_def.platforms.keys().collect()
            } else {
                self.platforms
                    .iter()
                    .filter(|p| dep_def.platforms.contains_key(p.as_str()))
                    .collect()
            };

            if target_platforms.is_empty() {
                warn!(deployment = %dep_name, "No matching platforms, skipping");
                continue;
            }

            for platform in target_platforms {
                let platform_config = &dep_def.platforms[platform.as_str()];
                info!(deployment = %dep_name, platform = %platform, "Deploying");

                match platform.as_str() {
                    "gcp" => gcp::deploy(
                        config,
                        dep_name,
                        platform_config,
                        &artifact_dir,
                        &additional_data_dir,
                    )?,
                    "azure" => azure::deploy(
                        config,
                        dep_name,
                        platform_config,
                        &artifact_dir,
                        &additional_data_dir,
                    )?,
                    other => bail!("Unsupported platform: {}", other),
                }
            }
        }

        info!("Deployment complete");
        Ok(())
    }
}
