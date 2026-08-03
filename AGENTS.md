# AGENTS.md

## Project

This repository contains a CC:Tweaked wired-inventory storage terminal for one or more Colossal Chests.

## Safety

- Runtime code must be Lua compatible with the target CC:Tweaked version.
- Never execute ComputerCraft startup programs or turtle actions from the host.
- Treat live Minecraft computer directories as production. Verify numeric ID, label, role, exact target, and shutdown state before writing.
- Never deploy tests, documentation, Git files, planning files, or host helpers to ComputerCraft computers.
- Preserve live runtime data unless the user explicitly authorizes a fresh install.
- Keep temporary host helpers outside the repository and remove them after use.

## Development

- Develop in an isolated Git worktree.
- Use test-first development for behavior changes.
- Keep the controller responsive: inventory scans, transfers, monitor rendering, and metadata enrichment must not block input indefinitely.
- The scanned inventory index is derived state. Never persist it as authoritative stock truth.
- Treat actual quantities returned by inventory transfer methods as authoritative.
- Keep modules focused and dependency-injected so inventory, UI, and failure behavior can be tested without Minecraft.