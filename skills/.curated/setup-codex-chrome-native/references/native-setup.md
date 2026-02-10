# Native Setup Reference

## Inputs

- `browser`: `chrome`, `chromium`, or `all`
- `extension_id`: optional override when extension auto-detection fails
- `tool_schemas`: optional explicit `tool-schemas.json` path

## Preferred command paths

Use the bundled script first:

```bash
./scripts/manage_codex_chrome_native.sh setup
./scripts/manage_codex_chrome_native.sh status
./scripts/manage_codex_chrome_native.sh uninstall --remove-mcp
```

## Verification checklist

1. Native host manifest exists:
   - `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.openai.codex_experimental_extension.json`
   - `~/Library/Application Support/Chromium/NativeMessagingHosts/com.openai.codex_experimental_extension.json` (if using Chromium)
2. `codex mcp list` includes entry `codex-extension` with URL `http://127.0.0.1:8787/mcp`.
3. Extension is installed in Chrome and options show native status connected.
4. `status` output reports standalone wrapper at `~/Library/Application Support/CodexExtension/codex-native-host-shim-standalone.sh`.

## Troubleshooting

### Missing extension id

Symptoms:
- setup script fails with message about missing extension id.

Fix:
- pass `--extension-id <id>` to the bundled script.

### Node or npm not available

Symptoms:
- `Missing required command: node` or `npm`.

Fix:
- install Node.js and rerun setup.

### MCP entry missing

Symptoms:
- native host manifest exists but `codex mcp list` does not show `codex-extension`.

Fix:
- rerun setup.
- if still missing, run:
  - `codex mcp add codex-extension --url http://127.0.0.1:8787/mcp`
  - `codex mcp list`

### Extension still disconnected

Symptoms:
- extension options show disconnected after setup.

Fix:
1. Open `chrome://extensions`, enable Developer Mode, reload extension.
2. Ensure `codex-extension` is installed/enabled.
3. Run `./scripts/manage_codex_chrome_native.sh status` and verify manifest presence.

### Tool schemas path not found (standalone mode)

Symptoms:
- setup fails with `Could not locate tool-schemas.json`.

Fix:
1. Confirm extension is installed in the selected browser profile.
2. Provide explicit schemas path:
   - `./scripts/manage_codex_chrome_native.sh setup --extension-id <id> --tool-schemas <path/to/tool-schemas.json>`

### MCP startup handshake fails after idle

Symptoms:
- Codex shows errors similar to:
  - `MCP startup failed: handshaking with MCP server failed`
  - `error decoding response body`

Cause:
- A long-lived `mcp-shim` process can keep stale session state and reject a fresh initialize request.

Fix:
1. Run:
   - `./scripts/manage_codex_chrome_native.sh setup --skip-install`
2. Reload the extension from `chrome://extensions` (or click reconnect in extension options).
3. Re-run the command in Codex.
