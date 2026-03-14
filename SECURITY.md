# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in LANA CODE, please report it responsibly.

**Do not open a public issue.** Instead, email the maintainers or use [GitHub's private vulnerability reporting](https://github.com/redroostertech/lana-code/security/advisories/new).

We will acknowledge your report within 48 hours and aim to provide a fix or mitigation within 7 days for critical issues.

## Scope

LANA CODE runs entirely locally — there are no cloud services, user accounts, or remote data storage. However, security considerations include:

- **Shell command execution** — LANA executes shell commands on behalf of the user. The permission mode system (`confirm`, `auto-edit`, `yolo`) controls this.
- **File system access** — LANA reads and writes files in the working directory and `.lana/` project directories.
- **Local network** — LANA communicates with llama.cpp over `localhost`. In proxy mode, it connects to lana-proxy on a local port.
- **Model files** — GGUF model files are loaded by llama.cpp. Only use models from trusted sources.

## Supported Versions

| Version | Supported |
|---------|-----------|
| 0.4.x   | Yes       |
| < 0.4   | No        |
