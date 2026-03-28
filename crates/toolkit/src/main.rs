use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

mod agent;
mod cloud;
mod commands;
mod config;
mod disk;
mod state;
mod types;
mod workload;

pub use config::Config;
pub use state::DeployState;

#[derive(Parser)]
#[command(
    name = "toolkit",
    about = "CVM deployment toolkit — deploy confidential VMs with a single config file",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Deploy a new CVM to the cloud
    Deploy {
        /// Path to cvm.yaml config file
        #[arg(long, short)]
        config: PathBuf,
    },

    /// Update workload on a running CVM
    Update {
        /// Path to cvm.yaml config file
        #[arg(long, short)]
        config: PathBuf,
    },

    /// Destroy a deployed CVM and all its resources
    Destroy {
        /// Path to cvm.yaml config file
        #[arg(long, short)]
        config: PathBuf,
    },

    /// Fetch container logs from a running CVM
    Logs {
        /// Path to cvm.yaml config file
        #[arg(long, short)]
        config: PathBuf,

        /// Container names to fetch logs for (all if omitted)
        containers: Vec<String>,
    },

    /// Fetch golden measurements from a running CVM
    Measurements {
        /// Path to cvm.yaml config file
        #[arg(long, short)]
        config: PathBuf,
    },

    /// Generate a config file template
    Init {
        /// Cloud service provider
        #[arg(long, default_value = "gcp")]
        csp: String,

        /// Output file path
        #[arg(long, short, default_value = "cvm.yaml")]
        output: PathBuf,
    },

    /// Start a simulated CVM agent for local development
    SimAgent {
        /// Port to listen on
        #[arg(long, default_value = "7999")]
        port: u16,
    },
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::from_default_env()
                .add_directive(tracing::Level::INFO.into()),
        )
        .init();

    let cli = Cli::parse();

    match cli.command {
        Commands::Deploy { config } => {
            let cfg = Config::load(&config)?;
            commands::deploy::run(cfg)
        }
        Commands::Update { config } => {
            let cfg = Config::load(&config)?;
            commands::update::run(cfg)
        }
        Commands::Destroy { config } => {
            let cfg = Config::load(&config)?;
            commands::destroy::run(cfg)
        }
        Commands::Logs { config, containers } => {
            let cfg = Config::load(&config)?;
            commands::logs::run(cfg, containers)
        }
        Commands::Measurements { config } => {
            let cfg = Config::load(&config)?;
            commands::measurements::run(cfg)
        }
        Commands::Init { csp, output } => {
            commands::init::run(&csp, &output)
        }
        Commands::SimAgent { port } => {
            commands::sim_agent::run(port)
        }
    }
}
