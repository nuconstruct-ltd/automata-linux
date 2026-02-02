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
        .unwrap_or("c3-standard-4");
    let region = platform_config
        .region
        .as_deref()
        .unwrap_or("asia-southeast1-b");

    // Derive names.
    let vm_name = deployment_name;
    let bucket = config::generate_name(vm_name, 6);

    // Find workload tar.gz.
    // Convention: deployment name maps to a workload with the same base name,
    // or we look for any .tar.gz in the artifact dir.
    let tar_path = find_workload_artifact(artifact_dir, deployment_name)?;

    info!(
        platform = "GCP",
        vm_name,
        vm_type,
        region,
        bucket = %bucket,
        workload = %tar_path.display(),
        "Deployment configuration"
    );

    // 1. Check CSP dependencies.
    cfg.run_script_default("check_csp_deps.sh", &["gcp"])?;

    // 2. Create GCS bucket and upload workload.
    info!("Uploading workload to GCS");
    let bucket_url = format!("gs://{}", bucket);
    if run_cmd("gsutil", &["mb", "-l", region, &bucket_url]).is_err() {
        info!("Bucket may already exist, continuing");
    }

    let tar_filename = tar_path
        .file_name()
        .unwrap()
        .to_string_lossy()
        .to_string();
    run_cmd(
        "gsutil",
        &[
            "cp",
            &tar_path.to_string_lossy(),
            &format!("{}/{}", bucket_url, tar_filename),
        ],
    )?;

    // 3. Upload additional-data if present.
    if additional_data_dir.is_dir() {
        info!("Uploading additional-data");
        run_cmd(
            "gsutil",
            &[
                "-m",
                "cp",
                "-r",
                &additional_data_dir.to_string_lossy(),
                &format!("{}/additional-data/", bucket_url),
            ],
        )?;
    }

    // 4. Create CVM instance.
    info!("Creating CVM instance");
    let workload_url = format!("{}/{}", bucket_url, tar_filename);
    let metadata = format!(
        "workload-url={},startup-script-url={}",
        workload_url, workload_url
    );

    run_cmd(
        "gcloud",
        &[
            "compute",
            "instances",
            "create",
            vm_name,
            "--zone",
            region,
            "--machine-type",
            vm_type,
            "--metadata",
            &metadata,
            "--confidential-compute-type=TDX",
            "--min-cpu-platform=AUTOMATIC",
        ],
    )?;

    info!(vm_name, "GCP deployment complete");
    Ok(())
}

pub(crate) fn find_workload_artifact(artifact_dir: &Path, deployment_name: &str) -> Result<std::path::PathBuf> {
    // Try exact match first (deployment name might include a suffix like "-tdx").
    let exact = artifact_dir.join(format!("{}.tar.gz", deployment_name));
    if exact.exists() {
        return Ok(exact);
    }

    // Try stripping common suffixes (-tdx, -gcp, -azure).
    for suffix in ["-tdx", "-gcp", "-azure"] {
        if let Some(base) = deployment_name.strip_suffix(suffix) {
            let path = artifact_dir.join(format!("{}.tar.gz", base));
            if path.exists() {
                return Ok(path);
            }
        }
    }

    // List available artifacts for error message.
    let available: Vec<String> = std::fs::read_dir(artifact_dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.path()
                        .extension()
                        .map(|ext| ext == "gz")
                        .unwrap_or(false)
                })
                .map(|e| e.file_name().to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default();

    bail!(
        "No workload artifact found for deployment '{}'. Available in {}: [{}]",
        deployment_name,
        artifact_dir.display(),
        available.join(", ")
    );
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
