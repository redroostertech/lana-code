import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

interface InitOptions {
  template: string;
  dryRun: boolean;
}

export function initCommand(name: string, options: InitOptions): void {
  const projectDir = join(process.cwd(), name);

  if (existsSync(projectDir)) {
    console.error(`Error: directory "${name}" already exists.`);
    process.exit(1);
  }

  const files: Record<string, string> = {
    "package.json": JSON.stringify(
      {
        name,
        version: "0.1.0",
        description: "",
        license: "MIT",
      },
      null,
      2
    ),
    "README.md": `# ${name}\n\nCreated with mycli using template: ${options.template}\n`,
  };

  if (options.dryRun) {
    console.log(`Would create project "${name}" with template "${options.template}":`);
    for (const file of Object.keys(files)) {
      console.log(`  ${name}/${file}`);
    }
    return;
  }

  mkdirSync(projectDir, { recursive: true });
  for (const [file, content] of Object.entries(files)) {
    writeFileSync(join(projectDir, file), content);
  }

  console.log(`Created project "${name}" with template "${options.template}".`);
}
