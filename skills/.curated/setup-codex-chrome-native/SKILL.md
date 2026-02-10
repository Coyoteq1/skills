---
name: setup-codex-chrome-native
description: Set up and repair Codex CLI connectivity to the codex-chrome extension by installing native messaging manifests and configuring the codex-extension MCP server entry in standalone mode only (retail Codex + installed extension). Use when users ask to connect Codex CLI to the extension, reinstall native host scripts, switch browser target for Chrome or Chromium, or troubleshoot disconnected native host or MCP wiring.
---

# Setup Codex Chrome Native

## Overview

Install, reconnect, verify, and uninstall the codex-chrome native host integration used by `codex-cli`.
The bundled script is standalone-only: no source repository checkout is required.

## Workflow

1. Collect required inputs:
   - Browser target (`chrome`, `chromium`, or `all`)
   - Optional extension id override (`--extension-id`)
   - Optional explicit schemas path (`--tool-schemas`) when auto-detection fails
2. Run `scripts/manage_codex_chrome_native.sh` with one of:
   - `setup` to install native host + configure MCP
   - `status` to check manifests, extension/schema detection, and MCP visibility
   - `uninstall` to remove manifests (and optionally MCP entry)
3. For `setup`, instruct the user to confirm Chrome extension loading:
   - Browser target (`chrome`, `chromium`, or `all`)
   - Open `chrome://extensions`
   - Ensure `codex-extension` is installed/enabled
   - Check extension Options and confirm native host status is connected
4. If setup fails, read `references/native-setup.md` and follow the matching troubleshooting path.
5. If Codex reports MCP startup/initialize handshake failures, run:
   - `./scripts/manage_codex_chrome_native.sh setup --skip-install`
   - then reload/reconnect the extension in `chrome://extensions`.

## Commands

Run from this skill directory or call with an absolute path:

```bash
# Setup using defaults
./scripts/manage_codex_chrome_native.sh setup

# Setup against Chromium and explicit extension id
./scripts/manage_codex_chrome_native.sh setup --browser chromium --extension-id <extension-id>

# Standalone setup with explicit schemas path
./scripts/manage_codex_chrome_native.sh setup --extension-id <extension-id> --tool-schemas <path/to/tool-schemas.json>

# Check setup state
./scripts/manage_codex_chrome_native.sh status

# Uninstall and remove codex-extension MCP entry
./scripts/manage_codex_chrome_native.sh uninstall --remove-mcp
```

## Resources

- `scripts/manage_codex_chrome_native.sh`: deterministic wrapper around extension setup/uninstall/status.
- `references/native-setup.md`: manual commands, manifest locations, and troubleshooting.

## Notes

- Prefer `setup` then `status` before deeper debugging.
- Keep changes scoped to native host setup and MCP registration only.
- Report exact failing command and stderr when escalation is needed.
