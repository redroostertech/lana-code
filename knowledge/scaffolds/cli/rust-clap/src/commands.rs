use anyhow::Result;

pub fn greet(name: &str, greeting: &str, verbose: bool) -> Result<()> {
    if verbose {
        eprintln!("[verbose] greeting={greeting:?}, name={name:?}");
    }
    println!("{greeting}, {name}!");
    Ok(())
}

pub fn info(verbose: bool) -> Result<()> {
    let version = env!("CARGO_PKG_VERSION");
    println!("mycli v{version}");
    println!("Verbose: {verbose}");
    Ok(())
}
