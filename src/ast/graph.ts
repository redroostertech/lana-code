// Dependency graph builder — uses resolved imports from tree-sitter analysis
import { resolveImportPath } from './imports.js';
import type { FileAnalysis, DependencyNode } from './types.js';

/**
 * Build a dependency graph from analyzed files.
 * Resolves relative imports to actual file paths and builds forward + reverse edges.
 */
export function buildDependencyGraph(files: FileAnalysis[]): DependencyNode[] {
  // Build set of all file paths for resolution
  const allPaths = new Set(files.map(f => f.path));

  // Build forward dependencies (file -> files it imports)
  const nodes = new Map<string, DependencyNode>();

  for (const file of files) {
    const dependsOn: string[] = [];
    const importsRaw: string[] = file.imports.map(i => i.source);

    for (const imp of file.imports) {
      if (imp.isRelative) {
        // Resolve relative import to actual file
        const resolved = resolveImportPath(imp.source, file.path, allPaths);
        if (resolved && resolved !== file.path) {
          dependsOn.push(resolved);
        }
      } else {
        // Non-relative import — try basename matching against project files
        // This handles cases like `use crate::utils::auth` in Rust
        // or `import SummitLFE` in C headers
        const basename = imp.source.split(/[/.:]+/).pop() || '';
        if (basename.length >= 3) {
          for (const candidate of allPaths) {
            if (candidate === file.path) continue;
            const candidateBasename = candidate.split('/').pop()?.split('.')[0] || '';
            if (candidateBasename === basename) {
              dependsOn.push(candidate);
            }
          }
        }
      }
    }

    nodes.set(file.path, {
      file: file.path,
      importsRaw,
      dependsOn: [...new Set(dependsOn)],
      dependedBy: [], // filled in next pass
    });
  }

  // Build reverse dependencies
  for (const node of nodes.values()) {
    for (const dep of node.dependsOn) {
      const depNode = nodes.get(dep);
      if (depNode) {
        depNode.dependedBy.push(node.file);
      }
    }
  }

  // Deduplicate reverse deps
  for (const node of nodes.values()) {
    node.dependedBy = [...new Set(node.dependedBy)];
  }

  return Array.from(nodes.values());
}

/**
 * Serialize dependency graph to the format expected by deps.json
 * (backward compatible with the bash jq output).
 */
export function serializeDepsJson(graph: DependencyNode[]): any[] {
  return graph.map(node => ({
    file: node.file,
    imports_raw: node.importsRaw,
    depends_on: node.dependsOn,
    depended_by: node.dependedBy,
  }));
}
