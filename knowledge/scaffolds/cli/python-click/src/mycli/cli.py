"""CLI entry point and command group."""

import click

from mycli import __version__
from mycli.commands import greet, info


@click.group()
@click.version_option(version=__version__)
@click.option("--verbose", "-v", is_flag=True, help="Enable verbose output.")
@click.pass_context
def main(ctx, verbose):
    """mycli - A command-line tool."""
    ctx.ensure_object(dict)
    ctx.obj["verbose"] = verbose


main.add_command(greet)
main.add_command(info)
