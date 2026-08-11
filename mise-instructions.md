## Tool installation

Prefer `mise` over `apt` for missing development tools and runtimes.

- `mise use <tool>`: latest, project-local (`mise.toml`).
- `mise use -g <tool>`: latest, global; use only when shared across projects.
- `mise install <tool>`: install a configured tool.
- `mise exec <tool> -- <command>`: one-off use.

Use `@<version>` only when pinning is required. Use `apt` only for system
packages mise cannot manage. Image tools install lazily; do not bulk-install.
