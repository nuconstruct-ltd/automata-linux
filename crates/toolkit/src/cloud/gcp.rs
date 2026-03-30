use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
// use base64::Engine;
use tracing::info;

use google_cloud_compute_v1::client::{
    Addresses, Disks, Firewalls, GlobalOperations, Images, Instances, ZoneOperations,
};
use google_cloud_compute_v1::model;

use crate::config::Config;
use crate::state::DeployState;

/// Run an async block inside a new tokio runtime.
fn block_on<F: std::future::Future<Output = Result<T>>, T>(f: F) -> Result<T> {
    // Install default rustls crypto provider (required when multiple TLS backends coexist)
    let _ = rustls::crypto::ring::default_provider().install_default();
    tokio::runtime::Runtime::new()?.block_on(f)
}

/// Get a GCP auth token for REST API calls.
async fn get_auth_token() -> Result<String> {
    let provider = gcp_auth::provider().await
        .context("Failed to authenticate with GCP. Run: gcloud auth application-default login")?;
    let scopes = &["https://www.googleapis.com/auth/cloud-platform"];
    let token = provider.token(scopes).await
        .context("Failed to get auth token")?;
    Ok(token.as_str().to_string())
}

/// Deploy a CVM to GCP.
pub fn deploy(config: &Config, disk_path: &Path, state: &mut DeployState) -> Result<()> {
    let project = config.project_id.as_deref()
        .context("project_id is required for GCP")?;
    let bucket = config.bucket.as_deref().unwrap_or(&config.vm_name);

    block_on(async {
        // Storage operations via REST API
        let token = get_auth_token().await?;
        let http = reqwest::Client::new();

        create_bucket(&http, &token, project, bucket, &config.region).await?;
        state.bucket = Some(bucket.to_string());

        upload_disk(&http, &token, bucket, disk_path).await?;

        // Compute operations via SDK
        let image_name = format!("{}-image", config.vm_name);
        create_image(project, &image_name, bucket, disk_path, config).await?;
        state.image_name = Some(image_name.clone());

        let fw_name = format!("{}-fw", config.vm_name);
        create_firewall(project, &fw_name, config).await?;
        state.firewall_rule = Some(fw_name);

        let ip = create_vm(config, project, &image_name, state).await?;
        state.ip = Some(ip);

        Ok(())
    })
}

/// Destroy all GCP resources.
pub fn destroy(state: &DeployState) -> Result<()> {
    let project = state.project_id.as_deref()
        .context("No project_id in state")?;

    block_on(async {
        // Delete VM
        info!(vm = %state.vm_name, "Deleting VM...");
        if let Ok(client) = Instances::builder().build().await {
            let _ = client.delete()
                .set_project(project)
                .set_zone(&state.region)
                .set_instance(&state.vm_name)
                .send().await;
            tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        }

        // Delete firewall rule
        if let Some(ref fw) = state.firewall_rule {
            info!(rule = fw, "Deleting firewall rule...");
            if let Ok(client) = Firewalls::builder().build().await {
                let _ = client.delete()
                    .set_project(project)
                    .set_firewall(fw)
                    .send().await;
            }
        }

        // Delete image
        if let Some(ref image) = state.image_name {
            info!(image, "Deleting VM image...");
            if let Ok(client) = Images::builder().build().await {
                let _ = client.delete()
                    .set_project(project)
                    .set_image(image)
                    .send().await;
            }
        }

        // Delete bucket via REST
        if let Some(ref bucket) = state.bucket {
            info!(bucket, "Deleting storage bucket...");
            if let Ok(token) = get_auth_token().await {
                let http = reqwest::Client::new();
                let _ = delete_bucket(&http, &token, bucket).await;
            }
        }

        // Delete static IP
        if let Some(ref ip_name) = state.static_ip_name {
            info!(ip_name, "Releasing static IP...");
            let region = extract_region(&state.region);
            if let Ok(client) = Addresses::builder().build().await {
                let _ = client.delete()
                    .set_project(project)
                    .set_region(&region)
                    .set_address(ip_name)
                    .send().await;
            }
        }

        info!("GCP resources destroyed");
        Ok(())
    })
}

// --- GCS REST API helpers ---

const GCS_BASE: &str = "https://storage.googleapis.com/storage/v1";
const GCS_UPLOAD: &str = "https://storage.googleapis.com/upload/storage/v1";

async fn create_bucket(
    http: &reqwest::Client,
    token: &str,
    project: &str,
    bucket: &str,
    region: &str,
) -> Result<()> {
    // Check if bucket exists
    let resp = http.get(format!("{}/b/{}", GCS_BASE, bucket))
        .bearer_auth(token)
        .send().await?;
    if resp.status().is_success() {
        info!(bucket, "Bucket already exists");
        return Ok(());
    }

    let location = extract_region(region);
    info!(bucket, location = %location, "Creating storage bucket...");

    let body = serde_json::json!({
        "name": bucket,
        "location": location,
        "iamConfiguration": {
            "uniformBucketLevelAccess": { "enabled": true }
        }
    });

    let resp = http.post(format!("{}/b?project={}", GCS_BASE, project))
        .bearer_auth(token)
        .json(&body)
        .send().await?;

    if !resp.status().is_success() {
        let err = resp.text().await.unwrap_or_default();
        bail!("Failed to create bucket '{}': {}", bucket, err);
    }

    Ok(())
}

async fn upload_disk(
    http: &reqwest::Client,
    token: &str,
    bucket: &str,
    disk_path: &Path,
) -> Result<()> {
    let filename = disk_path.file_name()
        .context("No filename")?
        .to_string_lossy()
        .to_string();

    let file_size = fs::metadata(disk_path)?.len();
    info!(bucket, filename = %filename, size_mb = file_size / 1_048_576, "Uploading disk image...");

    // Use resumable upload for large files
    // Step 1: Initiate resumable upload
    let init_resp = http.post(format!(
        "{}/b/{}/o?uploadType=resumable&name={}",
        GCS_UPLOAD, bucket, filename
    ))
        .bearer_auth(token)
        .header("Content-Type", "application/json")
        .header("X-Upload-Content-Type", "application/octet-stream")
        .header("X-Upload-Content-Length", file_size.to_string())
        .body("{}")
        .send().await?;

    if !init_resp.status().is_success() {
        let err = init_resp.text().await.unwrap_or_default();
        bail!("Failed to initiate upload: {}", err);
    }

    let upload_url = init_resp.headers()
        .get("location")
        .context("No upload URL in response")?
        .to_str()?
        .to_string();

    // Step 2: Upload file content
    let file_bytes = tokio::fs::read(disk_path).await
        .with_context(|| format!("Failed to read {}", disk_path.display()))?;

    let resp = http.put(&upload_url)
        .header("Content-Length", file_size.to_string())
        .header("Content-Type", "application/octet-stream")
        .body(file_bytes)
        .send().await?;

    if !resp.status().is_success() {
        let err = resp.text().await.unwrap_or_default();
        bail!("Failed to upload disk image: {}", err);
    }

    info!("Disk image uploaded");
    Ok(())
}

async fn delete_bucket(
    http: &reqwest::Client,
    token: &str,
    bucket: &str,
) -> Result<()> {
    // List objects
    let resp = http.get(format!("{}/b/{}/o", GCS_BASE, bucket))
        .bearer_auth(token)
        .send().await?;

    if resp.status().is_success() {
        let body: serde_json::Value = resp.json().await?;
        if let Some(items) = body["items"].as_array() {
            for item in items {
                if let Some(name) = item["name"].as_str() {
                    let encoded = urlencoding::encode(name);
                    let _ = http.delete(format!("{}/b/{}/o/{}", GCS_BASE, bucket, encoded))
                        .bearer_auth(token)
                        .send().await;
                }
            }
        }
    }

    // Delete bucket
    let _ = http.delete(format!("{}/b/{}", GCS_BASE, bucket))
        .bearer_auth(token)
        .send().await;

    Ok(())
}

// --- Compute SDK helpers ---

async fn create_image(
    project: &str,
    image_name: &str,
    bucket: &str,
    disk_path: &Path,
    _config: &Config,
) -> Result<()> {
    let filename = disk_path.file_name()
        .context("No filename")?
        .to_string_lossy();

    info!(image_name, "Creating VM image...");

    let client = Images::builder().build().await
        .context("Failed to create Images client")?;

    // Delete existing image if present
    if let Ok(op) = client.delete()
        .set_project(project)
        .set_image(image_name)
        .send().await
    {
        let _ = wait_for_global_operation(project, &op).await;
    }

    // Build image resource
    let source_uri = format!("https://storage.googleapis.com/{}/{}", bucket, filename);
    let raw_disk = model::image::RawDisk::new()
        .set_source(&source_uri)
        .set_container_type(model::image::raw_disk::ContainerType::Tar);

    use model::guest_os_feature::Type as GofType;
    let features: Vec<model::GuestOsFeature> = [
        GofType::UefiCompatible,
        GofType::VirtioScsiMultiqueue,
        GofType::Gvnic,
        GofType::TdxCapable,
        GofType::SevSnpCapable,
    ].into_iter().map(|t| {
        model::GuestOsFeature::new().set_type(t)
    }).collect();

    let mut image = model::Image::new()
        .set_name(image_name)
        .set_raw_disk(raw_disk)
        .set_guest_os_features(features);

    // Secure boot certs
    let disk_dir = Config::disk_cache_dir()?;
    let cert_dir = disk_dir.join("secure_boot");
    if cert_dir.join("PK.crt").exists() {
        let pk = read_cert_as_file_content_buffer(&cert_dir.join("PK.crt"))?;
        let kek = read_cert_as_file_content_buffer(&cert_dir.join("KEK.crt"))?;
        let mut dbs = vec![read_cert_as_file_content_buffer(&cert_dir.join("db.crt"))?];
        if cert_dir.join("kernel.crt").exists() {
            dbs.push(read_cert_as_file_content_buffer(&cert_dir.join("kernel.crt"))?);
        }

        let initial_state = model::InitialStateConfig::new()
            .set_pk(pk)
            .set_keks(vec![kek])
            .set_dbs(dbs);

        image = image.set_shielded_instance_initial_state(initial_state);
    }

    let op = client.insert()
        .set_project(project)
        .set_body(image)
        .send().await
        .context("Failed to create VM image")?;

    wait_for_global_operation(project, &op).await?;
    info!("VM image created");
    Ok(())
}

async fn create_firewall(project: &str, fw_name: &str, config: &Config) -> Result<()> {
    if config.ports.is_empty() && config.operator_ports.is_empty() {
        return Ok(());
    }

    let mut all_ports: Vec<u16> = vec![8000];
    all_ports.extend(&config.ports);
    all_ports.extend(&config.operator_ports);
    all_ports.sort();
    all_ports.dedup();

    let port_strings: Vec<String> = all_ports.iter().map(|p| p.to_string()).collect();
    info!(fw_name, ports = %port_strings.join(","), "Creating firewall rules...");

    let client = Firewalls::builder().build().await
        .context("Failed to create Firewalls client")?;

    // Delete existing
    if let Ok(op) = client.delete()
        .set_project(project)
        .set_firewall(fw_name)
        .send().await
    {
        let _ = wait_for_global_operation(project, &op).await;
    }

    let tcp_allowed = model::firewall::Allowed::new()
        .set_ip_protocol("tcp")
        .set_ports(port_strings.clone());
    let udp_allowed = model::firewall::Allowed::new()
        .set_ip_protocol("udp")
        .set_ports(port_strings);

    let firewall = model::Firewall::new()
        .set_name(fw_name)
        .set_direction(model::firewall::Direction::Ingress)
        .set_source_ranges(vec!["0.0.0.0/0".to_string()])
        .set_target_tags(vec![config.vm_name.clone()])
        .set_allowed(vec![tcp_allowed, udp_allowed]);

    client.insert()
        .set_project(project)
        .set_body(firewall)
        .send().await
        .context("Failed to create firewall rule")?;

    Ok(())
}

async fn create_vm(
    config: &Config,
    project: &str,
    image_name: &str,
    state: &mut DeployState,
) -> Result<String> {
    let cc_type = config.confidential_compute_type();
    info!(vm = %config.vm_name, vm_type = %config.vm_type, cc_type, "Creating VM...");

    // Handle static IP
    if let Some(ref ip_name) = config.create_ip_name {
        let region = extract_region(&config.region);
        let addr_client = Addresses::builder().build().await?;

        let address = model::Address::new()
            .set_name(ip_name)
            .set_network_tier(model::address::NetworkTier::Premium);

        let _ = addr_client.insert()
            .set_project(project)
            .set_region(&region)
            .set_body(address)
            .send().await;
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;

        if let Ok(addr) = addr_client.get()
            .set_project(project)
            .set_region(&region)
            .set_address(ip_name)
            .send().await
        {
            if let Some(ip) = addr.address {
                state.ip = Some(ip);
                state.static_ip_name = Some(ip_name.clone());
            }
        }
    }

    // Boot disk
    let disk_type = if config.vm_type.starts_with("c3-") { "pd-ssd" } else { "pd-standard" };
    let mut init_params = model::AttachedDiskInitializeParams::new()
        .set_source_image(format!("projects/{}/global/images/{}", project, image_name))
        .set_disk_type(format!("zones/{}/diskTypes/{}", config.region, disk_type));
    if let Some(size) = config.boot_disk_size {
        init_params = init_params.set_disk_size_gb(size as i64);
    }
    let boot_disk = model::AttachedDisk::new()
        .set_auto_delete(true)
        .set_boot(true)
        .set_initialize_params(init_params);

    // Network interface
    let mut access_config = model::AccessConfig::new()
        .set_type(model::access_config::Type::OneToOneNat)
        .set_name("External NAT")
        .set_network_tier(model::access_config::NetworkTier::Premium);
    if let Some(ref ip) = state.ip {
        access_config = access_config.set_nat_ip(ip);
    }
    let net_iface = model::NetworkInterface::new()
        .set_access_configs(vec![access_config]);

    // Metadata
    let mut meta_items = vec![
        model::metadata::Items::new()
            .set_key("serial-port-logging-enable")
            .set_value("true"),
    ];
    if let Ok(Some(key)) = config.ssh_public_key() {
        meta_items.push(
            model::metadata::Items::new()
                .set_key("ssh-keys")
                .set_value(format!("automata:{}", key)),
        );
    }
    let metadata = model::Metadata::new().set_items(meta_items);

    // Confidential compute
    let cc_enum = match cc_type {
        "TDX" => model::confidential_instance_config::ConfidentialInstanceType::Tdx,
        _ => model::confidential_instance_config::ConfidentialInstanceType::SevSnp,
    };
    let cc_config = model::ConfidentialInstanceConfig::new()
        .set_enable_confidential_compute(true)
        .set_confidential_instance_type(cc_enum);

    // Scheduling
    let scheduling = model::Scheduling::new()
        .set_on_host_maintenance(model::scheduling::OnHostMaintenance::Terminate);

    // Shielded instance
    let shielded = model::ShieldedInstanceConfig::new()
        .set_enable_vtpm(true)
        .set_enable_secure_boot(true)
        .set_enable_integrity_monitoring(true);

    // Tags
    let tags = model::Tags::new()
        .set_items(vec![config.vm_name.clone()]);

    let instance = model::Instance::new()
        .set_name(&config.vm_name)
        .set_machine_type(format!("zones/{}/machineTypes/{}", config.region, config.vm_type))
        .set_disks(vec![boot_disk])
        .set_network_interfaces(vec![net_iface])
        .set_metadata(metadata)
        .set_confidential_instance_config(cc_config)
        .set_scheduling(scheduling)
        .set_shielded_instance_config(shielded)
        .set_tags(tags);

    let client = Instances::builder().build().await
        .context("Failed to create Instances client")?;

    let op = client.insert()
        .set_project(project)
        .set_zone(&config.region)
        .set_body(instance)
        .send().await
        .context("Failed to create VM instance")?;

    wait_for_zone_operation(project, &config.region, &op).await?;

    // Get public IP if we don't have a static one
    if state.ip.is_none() {
        let inst = client.get()
            .set_project(project)
            .set_zone(&config.region)
            .set_instance(&config.vm_name)
            .send().await
            .context("Failed to get VM instance details")?;

        if let Some(iface) = inst.network_interfaces.first() {
            if let Some(ac) = iface.access_configs.first() {
                state.ip.clone_from(&ac.nat_ip);
            }
        }
    }

    // Attach data disk if specified
    if let Some(ref disk_name) = config.attach_disk {
        attach_data_disk(&client, config, project, disk_name, state).await?;
    }

    let ip = state.ip.clone().unwrap_or_default();
    info!(vm = %config.vm_name, ip = %ip, "VM created");
    Ok(ip)
}

async fn attach_data_disk(
    instances_client: &Instances,
    config: &Config,
    project: &str,
    disk_name: &str,
    state: &mut DeployState,
) -> Result<()> {
    let disk_type = if config.vm_type.starts_with("c3-") { "pd-ssd" } else { "pd-standard" };

    let disks_client = Disks::builder().build().await?;

    // Check if disk exists
    let exists = disks_client.get()
        .set_project(project)
        .set_zone(&config.region)
        .set_disk(disk_name)
        .send().await
        .is_ok();

    if !exists {
        info!(disk_name, size = config.disk_size, "Creating data disk...");
        let disk = model::Disk::new()
            .set_name(disk_name)
            .set_size_gb(config.disk_size as i64)
            .set_type(format!("zones/{}/diskTypes/{}", config.region, disk_type));

        let op = disks_client.insert()
            .set_project(project)
            .set_zone(&config.region)
            .set_body(disk)
            .send().await
            .context("Failed to create data disk")?;

        wait_for_zone_operation(project, &config.region, &op).await?;
    }

    info!(disk_name, "Attaching data disk...");
    let attached = model::AttachedDisk::new()
        .set_source(format!("projects/{}/zones/{}/disks/{}", project, config.region, disk_name));

    instances_client.attach_disk()
        .set_project(project)
        .set_zone(&config.region)
        .set_instance(&config.vm_name)
        .set_body(attached)
        .send().await
        .context("Failed to attach data disk")?;

    state.disk_name = Some(disk_name.to_string());
    Ok(())
}

// --- Utility helpers ---

fn extract_region(zone: &str) -> String {
    let parts: Vec<&str> = zone.rsplitn(2, '-').collect();
    if parts.len() == 2 { parts[1].to_string() } else { zone.to_string() }
}

fn read_cert_as_file_content_buffer(path: &Path) -> Result<model::FileContentBuffer> {
    let bytes = fs::read(path)
        .with_context(|| format!("Failed to read cert: {}", path.display()))?;
    Ok(model::FileContentBuffer::new()
        .set_content(bytes::Bytes::from(bytes))
        .set_file_type(model::file_content_buffer::FileType::X509))
}

async fn wait_for_global_operation(project: &str, op: &model::Operation) -> Result<()> {
    let op_name = match op.name.as_deref() {
        Some(n) if !n.is_empty() => n,
        _ => return Ok(()),
    };

    let client = GlobalOperations::builder().build().await?;

    for _ in 0..60 {
        let result = client.get()
            .set_project(project)
            .set_operation(op_name)
            .send().await?;

        if result.status == Some(model::operation::Status::Done) {
            if let Some(ref error) = result.error {
                let msgs: Vec<String> = error.errors.iter()
                    .filter_map(|e| e.message.clone())
                    .collect();
                if !msgs.is_empty() {
                    bail!("Operation failed: {}", msgs.join(", "));
                }
            }
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
    bail!("Operation timed out: {}", op_name);
}

async fn wait_for_zone_operation(project: &str, zone: &str, op: &model::Operation) -> Result<()> {
    let op_name = match op.name.as_deref() {
        Some(n) if !n.is_empty() => n,
        _ => return Ok(()),
    };

    let client = ZoneOperations::builder().build().await?;

    for _ in 0..120 {
        let result = client.get()
            .set_project(project)
            .set_zone(zone)
            .set_operation(op_name)
            .send().await?;

        if result.status == Some(model::operation::Status::Done) {
            if let Some(ref error) = result.error {
                let msgs: Vec<String> = error.errors.iter()
                    .filter_map(|e| e.message.clone())
                    .collect();
                if !msgs.is_empty() {
                    bail!("Operation failed: {}", msgs.join(", "));
                }
            }
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
    bail!("Operation timed out: {}", op_name);
}
