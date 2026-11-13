## Tool installation

Prefer `mise` over `apt` for missing development tools and runtimes.

- `mise use <tool>`: latest, project-local (`mise.toml`).
- `mise use -g <tool>`: latest, global; use only when shared across projects.
- `mise install <tool>`: install a configured tool.
- `mise exec <tool> -- <command>`: one-off use.

Use `@<version>` only when pinning is required. Image tools are locked to the
image's build; for a newer release of one, use `mise use <tool>@latest` or
`mise upgrade <tool>`. Use `apt` only for system
packages mise cannot manage (you must check first). Image tools install lazily; do not bulk-install.
