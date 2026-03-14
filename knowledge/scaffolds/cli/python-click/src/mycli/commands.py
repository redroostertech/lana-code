"""Subcommand implementations."""

import click


@click.command()
@click.argument("name")
@click.option("--greeting", "-g", default="Hello", help="Greeting to use.")
@click.pass_context
def greet(ctx, name, greeting):
    """Greet someone by name."""
    msg = f"{greeting}, {name}!"
    if ctx.obj["verbose"]:
        click.echo(f"[verbose] greeting={greeting!r}, name={name!r}")
    click.echo(msg)


@click.command()
@click.pass_context
def info(ctx):
    """Show application information."""
    from mycli import __version__

    click.echo(f"mycli v{__version__}")
    click.echo(f"Verbose: {ctx.obj['verbose']}")
