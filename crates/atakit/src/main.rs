use anyhow::Result;
use clap::{Parser, Subcommand, ValueEnum};
use tracing_subscriber::EnvFilter;

mod commands;
mod config;
mod types;

pub use config::Config;

#[derive(Clone, Debug, ValueEnum)]
pub enum Csp {
    Aws,
    Gcp,
    Azure,
}

impl Csp {
    pub fn as_str(&self) -> &str {
        match self {
            Csp::Aws => "aws",
            Csp::Gcp => "gcp",
            Csp::Azure => "azure",
        }
    }

    pub fn disk_filename(&self) -> &str {
        match self {
            Csp::Aws => "aws_disk.vmdk",
            Csp::Gcp => "gcp_disk.tar.gz",
            Csp::Azure => "azure_disk.vhd",
        }
    }
}

impl std::fmt::Display for Csp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Parser)]
#[command(name = "atakit", about = "CVM base image deployment toolkit")]
struct Cli {
    #[command(subcommand)]
    command: AtaKit,
}

#[derive(Subcommand)]
enum AtaKit {
    /// Build workload packages from atakit.json
    BuildWorkload(commands::build_workload::BuildWorkload),

    /// Publish a built workload to the on-chain registry
    PublishWorkload(commands::publish_workload::PublishWorkload),

    /// Deploy workloads to cloud platforms using atakit.json
    Deploy(commands::deploy::Deploy),

    /// Start a simulated CVM agent for local development
    SimAgent(commands::sim_agent::SimAgent),

    /// Deploy a CVM to a cloud provider (raw disk image mode)
    #[command(subcommand)]
    DeployRaw(commands::deploy_raw::DeployRaw),

    /// Manage deployed CVMs and resources
    #[command(subcommand)]
    Manage(commands::manage::Manage),

    /// Security operations (provenance, signing, livepatch)
    #[command(subcommand)]
    Security(commands::security::Security),
}

impl AtaKit {
    fn run(self, config: &Config) -> Result<()> {
        match self {
            AtaKit::BuildWorkload(cmd) => cmd.run(config),
            AtaKit::PublishWorkload(cmd) => cmd.run(config),
            AtaKit::Deploy(cmd) => cmd.run(config),
            AtaKit::SimAgent(cmd) => cmd.run(),
            AtaKit::DeployRaw(cmd) => cmd.run(config),
            AtaKit::Manage(cmd) => cmd.run(config),
            AtaKit::Security(cmd) => cmd.run(config),
        }
    }
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .init();

    let cli = Cli::parse();
    let config = Config::detect()?;
    config.check_dependencies()?;
    cli.command.run(&config)
}
