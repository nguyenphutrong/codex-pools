mod analytics;
mod cache;
mod codex;
mod pricing;

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};
use uuid::Uuid;

#[derive(Parser)]
#[command(name = "codex-pools")]
#[command(about = "Codex Pools local analytics CLI")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    Analytics {
        #[command(subcommand)]
        command: AnalyticsCommand,
    },
}

#[derive(Subcommand)]
enum AnalyticsCommand {
    Scan {
        #[arg(long)]
        instance_id: Uuid,
        #[arg(long)]
        instance_name: String,
        #[arg(long)]
        codex_home: PathBuf,
        #[arg(long)]
        json: bool,
        #[arg(long)]
        cache_db: Option<PathBuf>,
    },
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Analytics { command } => match command {
            AnalyticsCommand::Scan {
                instance_id,
                instance_name,
                codex_home,
                json,
                cache_db,
            } => {
                let result =
                    codex::scan_instance(instance_id, instance_name, codex_home, cache_db)?;
                if json {
                    println!("{}", serde_json::to_string(&result)?);
                } else {
                    println!(
                        "Loaded {} Codex analytics session(s), skipped {} file(s).",
                        result.snapshot.sessions.len(),
                        result.skipped_file_count
                    );
                }
            }
        },
    }
    Ok(())
}
