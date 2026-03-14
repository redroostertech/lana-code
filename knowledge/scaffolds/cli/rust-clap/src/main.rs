use clap::Parser;

mod commands;

/// A command-line tool
#[derive(Parser)]
#[command(name = "mycli", version, about)]
struct Cli {
    /// Enable verbose output
    #[arg(short, long, global = true)]
    verbose: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(clap::Subcommand)]
enum Commands {
    /// Greet someone by name
    Greet {
        /// Name to greet
        name: String,

        /// Custom greeting
        #[arg(short, long, default_value = "Hello")]
        greeting: String,
    },
    /// Show application information
    Info,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Greet { name, greeting } => {
            commands::greet(&name, &greeting, cli.verbose)
        }
        Commands::Info => commands::info(cli.verbose),
    }
}
