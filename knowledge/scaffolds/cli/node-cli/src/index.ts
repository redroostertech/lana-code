#!/usr/bin/env node

import { Command } from "commander";
import { initCommand } from "./commands/init.js";

const program = new Command();

program
  .name("mycli")
  .description("A command-line tool")
  .version("0.1.0");

program
  .command("init")
  .description("Initialize a new project")
  .argument("[name]", "project name", "my-project")
  .option("-t, --template <template>", "template to use", "default")
  .option("--dry-run", "show what would be created without writing files")
  .action((name: string, options: { template: string; dryRun: boolean }) => {
    initCommand(name, options);
  });

program
  .command("info")
  .description("Show environment information")
  .action(() => {
    console.log(`mycli v${program.version()}`);
    console.log(`Node.js ${process.version}`);
    console.log(`Platform: ${process.platform} ${process.arch}`);
  });

program.parse();
