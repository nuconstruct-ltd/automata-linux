use std::path::Path;
use std::process::Command;

use anyhow::{bail, Context, Result};
use tracing::info;

use crate::config::{self, Config};
use crate::types::PlatformConfig;

pub fn deploy(
    cfg: &Config,
    deployment_name: &str,
    platform_config: &PlatformConfig,
    artifact_dir: &Path,
    additional_data_dir: &Path,
) -> Result<()> {
    let vm_type = platform_config
        .vmtype
        .as_deref()
        .unwrap_or("Standard_DC2es_v6");
    let region = platform_config.region.as_deref().unwrap_or("East US");

    let vm_name = deployment_name;
    let resource_group = format!("{}_Rg", vm_name);
    let suffix = config::random_suffix(4);
    let storage_account = {
        let mut name: String = config::sanitize_name(vm_name).chars().take(20).collect();
        name.push_str(&suffix);
        while name.len() < 3 {
            name.push('0');
        }
        name
    };

    let tar_path = super::gcp::find_workload_artifact(artifact_dir, deployment_name)?;

    info!(
        platform = "Azure",
        vm_name,
        vm_type,
        region,
        resource_group = %resource_group,
        storage_account = %storage_account,
        workload = %tar_path.display(),
        "Deployment configuration"
    );

    // 1. Check CSP dependencies.
    cfg.run_script_default("check_csp_deps.sh", &["azure"])?;

    // 2. Create resource group.
    info!("Creating resource group");
    run_cmd(
        "az",
        &[
            "group",
            "create",
            "--name",
            &resource_group,
            "--location",
            region,
        ],
    )?;

    // 3. Create storage account and upload workload.
    info!("Creating storage account and uploading workload");
    run_cmd(
        "az",
        &[
            "storage",
            "account",
            "create",
            "--name",
            &storage_account,
            "--resource-group",
            &resource_group,
            "--location",
            region,
            "--sku",
            "Standard_LRS",
        ],
    )?;

    let container_name = "workloads";
    run_cmd(
        "az",
        &[
            "storage",
            "container",
            "create",
            "--name",
            container_name,
            "--account-name",
            &storage_account,
        ],
    )?;

    let tar_filename = tar_path
        .file_name()
        .unwrap()
        .to_string_lossy()
        .to_string();
    run_cmd(
        "az",
        &[
            "storage",
            "blob",
            "upload",
            "--account-name",
            &storage_account,
            "--container-name",
            container_name,
            "--name",
            &tar_filename,
            "--file",
            &tar_path.to_string_lossy(),
        ],
    )?;

    // 4. Upload additional-data if present.
    if additional_data_dir.is_dir() {
        info!("Uploading additional-data");
        for entry in std::fs::read_dir(additional_data_dir)? {
            let entry = entry?;
            if entry.file_type()?.is_file() {
                let name = entry.file_name().to_string_lossy().to_string();
                run_cmd(
                    "az",
                    &[
                        "storage",
                        "blob",
                        "upload",
                        "--account-name",
                        &storage_account,
                        "--container-name",
                        container_name,
                        "--name",
                        &format!("additional-data/{}", name),
                        "--file",
                        &entry.path().to_string_lossy(),
                    ],
                )?;
            }
        }
    }

    // 5. Create CVM instance.
    info!("Creating CVM instance");
    run_cmd(
        "az",
        &[
            "vm",
            "create",
            "--resource-group",
            &resource_group,
            "--name",
            vm_name,
            "--size",
            vm_type,
            "--location",
            region,
            "--security-type",
            "ConfidentialVM",
        ],
    )?;

    info!(vm_name, "Azure deployment complete");
    Ok(())
}

fn run_cmd(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(args)
        .status()
        .with_context(|| format!("Failed to run {} {}", program, args.join(" ")))?;
    if !status.success() {
        bail!("{} failed with status {}", program, status);
    }
    Ok(())
}
