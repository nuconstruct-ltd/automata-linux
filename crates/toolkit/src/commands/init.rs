use std::path::Path;

use anyhow::{Context, Result};
use tracing::info;

use crate::workload::templates;

pub fn run(csp: &str, output: &Path) -> Result<()> {
    let template = templates::config_template();

    // Replace CSP if needed
    let content = template.replace("csp: gcp", &format!("csp: {}", csp));

    std::fs::write(output, content)
        .with_context(|| format!("Failed to write config to {}", output.display()))?;

    info!(path = %output.display(), "Config template generated");
    println!("Config written to: {}", output.display());
    println!("Edit the file with your deployment parameters, then run:");
    println!("  toolkit deploy --config {}", output.display());

    Ok(())
}
