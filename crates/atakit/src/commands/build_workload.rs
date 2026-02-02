mod compose_parser;
mod packager;

use anyhow::{bail, Context, Result};
use clap::Args;
use tracing::info;

use crate::types::AtakitConfig;
use crate::Config;

#[derive(Args)]
pub struct BuildWorkload {
    /// Names of workloads to build (builds all if omitted)
    pub workloads: Vec<String>,
}

impl BuildWorkload {
    pub fn run(self, _config: &Config) -> Result<()> {
        let atakit_config = AtakitConfig::load()?;
        let workloads = self.resolve_workloads(&atakit_config)?;
        let project_dir = std::env::current_dir()?;
        let artifact_dir = project_dir.join("ata_artifacts");
        std::fs::create_dir_all(&artifact_dir)?;

        for wl_def in &workloads {
            info!(workload = %wl_def.name, "Building workload");
            let analysis = compose_parser::analyze(&project_dir, wl_def)
                .with_context(|| format!("Failed to analyze {:?}", wl_def.name))?;

            info!(
                measured = analysis.measured_files.len(),
                additional_data = analysis.additional_data_files.len(),
                images = analysis.images.len(),
                "Compose analysis complete"
            );

            packager::create_package(wl_def, &analysis, &project_dir, &artifact_dir)?;
            info!(output = %format!("ata_artifacts/{}.tar.gz", wl_def.name), "Package created");
        }

        info!("Build complete");
        Ok(())
    }

    fn resolve_workloads<'a>(
        &self,
        config: &'a AtakitConfig,
    ) -> Result<Vec<&'a crate::types::WorkloadDef>> {
        if self.workloads.is_empty() {
            if config.workloads.is_empty() {
                bail!("No workloads defined in atakit.json");
            }
            return Ok(config.workloads.iter().collect());
        }

        let mut result = Vec::new();
        for name in &self.workloads {
            let found = config.workloads.iter().find(|w| &w.name == name);
            match found {
                Some(w) => result.push(w),
                None => bail!(
                    "Workload '{}' not found in atakit.json. Available: {}",
                    name,
                    config
                        .workloads
                        .iter()
                        .map(|w| w.name.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            }
        }
        Ok(result)
    }
}
