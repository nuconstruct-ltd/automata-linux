use std::path::Path;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use tracing::info;

/// CVM agent client for communicating with a deployed CVM.
pub struct AgentClient {
    ip: String,
    token: String,
    client: reqwest::blocking::Client,
}

impl AgentClient {
    pub fn new(ip: &str, token: &str) -> Result<Self> {
        let client = reqwest::blocking::Client::builder()
            .danger_accept_invalid_certs(true)
            .timeout(Duration::from_secs(120))
            .build()
            .context("Failed to create HTTP client")?;

        Ok(Self {
            ip: ip.to_string(),
            token: token.to_string(),
            client,
        })
    }

    fn base_url(&self) -> String {
        format!("https://{}:8000", self.ip)
    }

    /// Update workload on the running CVM.
    pub fn update_workload(&self, workload_dir: &Path) -> Result<()> {
        info!("Zipping workload directory...");

        // Create a zip of the workload directory
        let zip_data = create_workload_zip(workload_dir)?;

        info!(size = zip_data.len(), "Uploading workload to CVM...");

        let part = reqwest::blocking::multipart::Part::bytes(zip_data)
            .file_name("workload.zip")
            .mime_str("application/zip")?;
        let form = reqwest::blocking::multipart::Form::new()
            .part("file", part);

        let resp = self.client
            .post(format!("{}/update-workload", self.base_url()))
            .header("Authorization", format!("Bearer {}", self.token))
            .multipart(form)
            .send()
            .context("Failed to send update-workload request")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().unwrap_or_default();
            bail!("update-workload failed ({}): {}", status, body);
        }

        info!("Workload updated successfully");
        Ok(())
    }

    /// Fetch container logs.
    pub fn get_logs(&self, containers: &[String]) -> Result<String> {
        let mut url = format!("{}/container-logs", self.base_url());

        if !containers.is_empty() {
            let params: Vec<String> = containers.iter()
                .map(|c| format!("name={}", c))
                .collect();
            url = format!("{}?{}", url, params.join("&"));
        }

        let resp = self.client
            .get(&url)
            .header("Authorization", format!("Bearer {}", self.token))
            .send()
            .context("Failed to fetch logs")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().unwrap_or_default();
            bail!("get-logs failed ({}): {}", status, body);
        }

        resp.text().context("Failed to read log response")
    }

    /// Fetch golden measurements with retry.
    pub fn get_measurements(&self) -> Result<(serde_json::Value, serde_json::Value)> {
        info!("Waiting for CVM to be ready...");
        std::thread::sleep(Duration::from_secs(20));

        let max_retries = 10;
        let retry_delay = Duration::from_secs(30);

        for attempt in 1..=max_retries {
            info!(attempt, max_retries, "Fetching golden measurements...");

            match self.try_get_measurements() {
                Ok(result) => return Ok(result),
                Err(e) => {
                    if attempt == max_retries {
                        return Err(e).context("Failed to fetch measurements after all retries");
                    }
                    info!(error = %e, "Retrying in 30s...");
                    std::thread::sleep(retry_delay);
                }
            }
        }

        unreachable!()
    }

    fn try_get_measurements(&self) -> Result<(serde_json::Value, serde_json::Value)> {
        let offchain = self.client
            .get(format!("{}/offchain/golden-measurement", self.base_url()))
            .header("Authorization", format!("Bearer {}", self.token))
            .send()
            .context("Failed to fetch offchain measurement")?
            .json::<serde_json::Value>()
            .context("Failed to parse offchain measurement")?;

        let onchain = self.client
            .get(format!("{}/onchain/golden-measurement", self.base_url()))
            .header("Authorization", format!("Bearer {}", self.token))
            .send()
            .context("Failed to fetch onchain measurement")?
            .json::<serde_json::Value>()
            .context("Failed to parse onchain measurement")?;

        Ok((offchain, onchain))
    }

    /// Deploy a livepatch.
    #[allow(dead_code)]
    pub fn deploy_livepatch(&self, livepatch_path: &Path) -> Result<()> {
        let data = std::fs::read(livepatch_path)
            .with_context(|| format!("Failed to read livepatch: {}", livepatch_path.display()))?;

        let resp = self.client
            .post(format!("{}/livepatch", self.base_url()))
            .header("Authorization", format!("Bearer {}", self.token))
            .header("Content-Type", "application/octet-stream")
            .body(data)
            .send()
            .context("Failed to send livepatch")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().unwrap_or_default();
            bail!("livepatch failed ({}): {}", status, body);
        }

        info!("Livepatch deployed successfully");
        Ok(())
    }
}

/// Create a zip archive of the workload directory.
fn create_workload_zip(workload_dir: &Path) -> Result<Vec<u8>> {
    use std::io::Write;
    use walkdir::WalkDir;
    use zip::write::SimpleFileOptions;

    let mut buf = Vec::new();
    {
        let mut zip = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
        let options = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        for entry in WalkDir::new(workload_dir) {
            let entry = entry?;
            let path = entry.path();
            let relative = path.strip_prefix(workload_dir)?;

            if relative.as_os_str().is_empty() {
                continue;
            }

            // Skip directories — zip creates them implicitly from file paths
            if path.is_dir() {
                continue;
            }

            // CVM agent expects paths prefixed with "workload/"
            let name = format!("workload/{}", relative.to_string_lossy());
            zip.start_file(&name, options)?;
            let data = std::fs::read(path)?;
            zip.write_all(&data)?;
        }

        zip.finish()?;
    }

    Ok(buf)
}
