use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use tracing::info;

use crate::config::Config;

// Embed all template files at compile time
const DOCKER_COMPOSE: &str = include_str!("../templates/docker-compose.yml");
const CVM_AGENT_POLICY: &str = include_str!("../templates/config/cvm_agent/cvm_agent_policy.json");
const PROMTAIL_CONFIG: &str = include_str!("../templates/config/promtail/promtail.yml");
const VMAGENT_CONFIG: &str = include_str!("../templates/config/vmagent/vmagent.yml");
const CADDY_ENTRYPOINT: &str = include_str!("../templates/config/scripts/caddy-entrypoint.sh");
const PROMTAIL_ENTRYPOINT: &str = include_str!("../templates/config/scripts/promtail-entrypoint.sh");
const VMAGENT_ENTRYPOINT: &str = include_str!("../templates/config/scripts/vmagent-entrypoint.sh");
const CVM_YAML_TEMPLATE: &str = include_str!("../templates/cvm.yaml.template");

/// Template file entry.
struct TemplateFile {
    path: &'static str,
    content: &'static str,
    /// Whether to apply {{...}} substitution (images, operator ports, etc.)
    needs_subst: bool,
}

const TEMPLATE_FILES: &[TemplateFile] = &[
    TemplateFile { path: "docker-compose.yml", content: DOCKER_COMPOSE, needs_subst: true },
    TemplateFile { path: "config/cvm_agent/cvm_agent_policy.json", content: CVM_AGENT_POLICY, needs_subst: false },
    TemplateFile { path: "config/promtail/promtail.yml", content: PROMTAIL_CONFIG, needs_subst: false },
    TemplateFile { path: "config/vmagent/vmagent.yml", content: VMAGENT_CONFIG, needs_subst: false },
    TemplateFile { path: "config/scripts/caddy-entrypoint.sh", content: CADDY_ENTRYPOINT, needs_subst: false },
    TemplateFile { path: "config/scripts/promtail-entrypoint.sh", content: PROMTAIL_ENTRYPOINT, needs_subst: false },
    TemplateFile { path: "config/scripts/vmagent-entrypoint.sh", content: VMAGENT_ENTRYPOINT, needs_subst: false },
];

/// Write all template files to the given directory.
/// Image placeholders in docker-compose.yml are resolved from config.
pub fn write_all(dir: &Path, config: &Config) -> Result<()> {
    for template in TEMPLATE_FILES {
        let target = dir.join(template.path);

        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
        }

        let content = if template.needs_subst {
            config.apply_to_template(template.content)
        } else {
            template.content.to_string()
        };

        fs::write(&target, content)
            .with_context(|| format!("Failed to write template: {}", target.display()))?;
    }

    // Create empty secrets directory (populated by secret_files config)
    fs::create_dir_all(dir.join("secrets"))?;

    info!(count = TEMPLATE_FILES.len(), "Wrote workload template files");
    Ok(())
}

/// Get the cvm.yaml template content.
pub fn config_template() -> &'static str {
    CVM_YAML_TEMPLATE
}
