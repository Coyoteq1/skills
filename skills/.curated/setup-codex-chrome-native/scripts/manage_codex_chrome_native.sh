#!/usr/bin/env bash
set -euo pipefail

HOST_NAME="com.openai.codex_experimental_extension"
WRAPPER_DIR="$HOME/Library/Application Support/CodexExtension"
STANDALONE_DIR="$WRAPPER_DIR/standalone-mcp-shim"
STANDALONE_WRAPPER="$WRAPPER_DIR/codex-native-host-shim-standalone.sh"

usage() {
  cat <<'USAGE'
Usage:
  manage_codex_chrome_native.sh <setup|status|uninstall> [options]

Options:
  --browser <target>      chrome | chromium | all (default: chrome)
  --extension-id <id>     Extension id override
  --tool-schemas <path>   Explicit tool-schemas.json path
  --skip-install          Skip npm install during setup
  --remove-mcp            Remove codex-extension MCP entry on uninstall
  -h, --help              Show this message
USAGE
}

fail() {
  echo "[setup-codex-chrome-native] $*" >&2
  exit 1
}

info() {
  echo "[setup-codex-chrome-native] $*"
}

ensure_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing required command: $cmd"
}

manifest_paths() {
  local browser="$1"
  if [[ "$browser" == "chrome" || "$browser" == "all" ]]; then
    printf '%s\n' "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$HOST_NAME.json"
  fi
  if [[ "$browser" == "chromium" || "$browser" == "all" ]]; then
    printf '%s\n' "$HOME/Library/Application Support/Chromium/NativeMessagingHosts/$HOST_NAME.json"
  fi
}

extension_roots() {
  local browser="$1"
  if [[ "$browser" == "chrome" || "$browser" == "all" ]]; then
    printf '%s\n' "$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
  fi
  if [[ "$browser" == "chromium" || "$browser" == "all" ]]; then
    printf '%s\n' "$HOME/Library/Application Support/Chromium/Default/Extensions"
  fi
}

show_port_status() {
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi

  local listeners
  listeners="$(lsof -nP -iTCP:8787 -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$listeners" ]]; then
    info "Port 8787 listener(s):"
    echo "$listeners"
  else
    info "No listener currently bound to TCP 8787."
  fi
}

cleanup_stale_shim() {
  local patterns
  patterns=(
    'mcp-shim/dist/index.js'
    'standalone-mcp-shim/index.mjs'
    'codex-native-host-shim-standalone.sh'
  )

  local pattern
  for pattern in "${patterns[@]}"; do
    if pgrep -f "$pattern" >/dev/null 2>&1; then
      info "Stopping existing process(es) matching: $pattern"
      pkill -f "$pattern" 2>/dev/null || true
    fi
  done
  sleep 1
}

latest_version_dir() {
  local base_dir="$1"
  [[ -d "$base_dir" ]] || return 1

  local latest=""
  latest="$(find "$base_dir" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -V | tail -n 1 || true)"
  [[ -n "$latest" ]] || return 1
  printf '%s\n' "$latest"
}

detect_extension_id() {
  local browser="$1"
  local override_id="$2"

  if [[ -n "$override_id" ]]; then
    printf '%s\n' "$override_id"
    return 0
  fi

  local root
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    local id_dir
    while IFS= read -r id_dir; do
      [[ -d "$id_dir" ]] || continue
      local manifest_dir
      manifest_dir="$(latest_version_dir "$id_dir" || true)"
      [[ -n "$manifest_dir" ]] || continue
      local manifest_path="$manifest_dir/manifest.json"
      [[ -f "$manifest_path" ]] || continue
      if grep -q '"name"[[:space:]]*:[[:space:]]*"codex-extension"' "$manifest_path"; then
        basename "$id_dir"
        return 0
      fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort)
  done < <(extension_roots "$browser")

  return 1
}

resolve_tool_schemas_path() {
  local browser="$1"
  local extension_id="$2"
  local override_path="$3"

  if [[ -n "$override_path" ]]; then
    [[ -f "$override_path" ]] || fail "--tool-schemas path does not exist: $override_path"
    printf '%s\n' "$override_path"
    return 0
  fi

  local root
  while IFS= read -r root; do
    local id_root="$root/$extension_id"
    [[ -d "$id_root" ]] || continue
    local ver_dir
    ver_dir="$(latest_version_dir "$id_root" || true)"
    [[ -n "$ver_dir" ]] || continue
    local schemas="$ver_dir/tool-schemas.json"
    if [[ -f "$schemas" ]]; then
      printf '%s\n' "$schemas"
      return 0
    fi
  done < <(extension_roots "$browser")

  return 1
}

configure_codex_mcp() {
  if ! command -v codex >/dev/null 2>&1; then
    info "codex CLI not found on PATH; skipping MCP entry configuration."
    return 0
  fi

  codex mcp remove codex-extension >/dev/null 2>&1 || true
  codex mcp add codex-extension --url http://127.0.0.1:8787/mcp
}

install_native_manifest() {
  local browser="$1"
  local extension_id="$2"
  local host_path="$3"

  while IFS= read -r manifest; do
    mkdir -p "$(dirname "$manifest")"
    cat > "$manifest" <<JSON
{
  "name": "$HOST_NAME",
  "description": "Codex Experimental Extension Native Host",
  "path": "$host_path",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$extension_id/"
  ]
}
JSON
    info "Installed native host manifest: $manifest"
  done < <(manifest_paths "$browser")
}

remove_native_manifests() {
  local browser="$1"
  while IFS= read -r manifest; do
    if [[ -f "$manifest" ]]; then
      rm -f "$manifest"
      info "Removed manifest: $manifest"
    else
      info "Manifest not found (skipped): $manifest"
    fi
  done < <(manifest_paths "$browser")
}

setup_standalone_mode() {
  local browser="$1"
  local extension_id="$2"
  local tool_schemas="$3"
  local skip_install="$4"
  local script_dir="$5"

  ensure_cmd node
  ensure_cmd npm

  cleanup_stale_shim

  mkdir -p "$STANDALONE_DIR"
  cp "$script_dir/standalone-mcp-shim.mjs" "$STANDALONE_DIR/index.mjs"

  cat > "$STANDALONE_DIR/package.json" <<'JSON'
{
  "name": "codex-extension-standalone-shim",
  "private": true,
  "type": "module",
  "version": "0.1.0",
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0"
  }
}
JSON

  if [[ "$skip_install" -eq 0 ]]; then
    info "Installing standalone shim dependencies..."
    npm --prefix "$STANDALONE_DIR" install
  else
    info "Skipping npm install (--skip-install)."
  fi

  [[ -d "$STANDALONE_DIR/node_modules/@modelcontextprotocol/sdk" ]] || \
    fail "Standalone dependencies missing. Re-run setup without --skip-install."

  local node_bin
  node_bin="$(command -v node || true)"
  [[ -n "$node_bin" ]] || fail "Unable to locate node on PATH"

  mkdir -p "$WRAPPER_DIR"
  cat > "$STANDALONE_WRAPPER" <<WRAP
#!/bin/bash
export CODEX_TOOL_SCHEMAS_PATH="$tool_schemas"
exec "$node_bin" "$STANDALONE_DIR/index.mjs" "\$@"
WRAP
  chmod +x "$STANDALONE_WRAPPER"
  info "Installed standalone host wrapper: $STANDALONE_WRAPPER"

  install_native_manifest "$browser" "$extension_id" "$STANDALONE_WRAPPER"

  configure_codex_mcp
}

status_report() {
  local browser="$1"
  local extension_id="$2"
  local tool_schemas="$3"

  local found=0
  while IFS= read -r manifest; do
    if [[ -f "$manifest" ]]; then
      info "Manifest found: $manifest"
      found=1
    else
      info "Manifest not found: $manifest"
    fi
  done < <(manifest_paths "$browser")
  if [[ "$found" -eq 0 ]]; then
    info "No manifests found for target=$browser."
  fi

  if [[ -n "$extension_id" ]]; then
    info "Detected extension id: $extension_id"
  else
    info "Could not auto-detect extension id from installed browser extensions."
  fi

  if [[ -n "$tool_schemas" ]]; then
    info "Tool schemas path: $tool_schemas"
  else
    info "Tool schemas file not detected."
  fi

  if [[ -f "$STANDALONE_WRAPPER" ]]; then
    info "Standalone wrapper present: $STANDALONE_WRAPPER"
  fi

  if command -v codex >/dev/null 2>&1; then
    info "Codex MCP entries:"
    codex mcp list || true
  else
    info "codex CLI not found on PATH; skipping MCP listing."
  fi

  show_port_status
}

uninstall_all() {
  local browser="$1"
  local remove_mcp="$2"

  remove_native_manifests "$browser"

  local wrappers=(
    "$WRAPPER_DIR/codex-native-host.sh"
    "$WRAPPER_DIR/codex-native-host-shim.sh"
    "$WRAPPER_DIR/codex-native-host-fake.sh"
    "$STANDALONE_WRAPPER"
  )
  local wrapper
  for wrapper in "${wrappers[@]}"; do
    if [[ -f "$wrapper" ]]; then
      rm -f "$wrapper"
      info "Removed wrapper: $wrapper"
    fi
  done

  if [[ -d "$STANDALONE_DIR" ]]; then
    rm -rf "$STANDALONE_DIR"
    info "Removed standalone shim directory: $STANDALONE_DIR"
  fi

  if [[ "$remove_mcp" -eq 1 ]]; then
    if command -v codex >/dev/null 2>&1; then
      if codex mcp remove codex-extension >/dev/null 2>&1; then
        info "Removed Codex MCP entry: codex-extension"
      else
        info "Codex MCP entry not removed (may not exist): codex-extension"
      fi
    else
      info "codex CLI not found; skipping MCP removal"
    fi
  fi
}

MODE="${1:-}"
if [[ -z "$MODE" || "$MODE" == "--help" || "$MODE" == "-h" ]]; then
  usage
  exit 0
fi
shift || true

BROWSER="chrome"
EXTENSION_ID=""
TOOL_SCHEMAS=""
SKIP_INSTALL=0
REMOVE_MCP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser)
      [[ $# -ge 2 ]] || fail "--browser requires a value"
      BROWSER="$2"
      shift 2
      ;;
    --extension-id)
      [[ $# -ge 2 ]] || fail "--extension-id requires a value"
      EXTENSION_ID="$2"
      shift 2
      ;;
    --tool-schemas)
      [[ $# -ge 2 ]] || fail "--tool-schemas requires a value"
      TOOL_SCHEMAS="$2"
      shift 2
      ;;
    --skip-install)
      SKIP_INSTALL=1
      shift
      ;;
    --remove-mcp)
      REMOVE_MCP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

case "$MODE" in
  setup|status|uninstall) ;;
  *) fail "Unknown mode: $MODE" ;;
esac

case "$BROWSER" in
  chrome|chromium|all) ;;
  *) fail "Invalid browser target: $BROWSER (expected chrome|chromium|all)" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

info "Mode: $MODE"
info "Implementation: standalone"
info "Browser target: $BROWSER"

if [[ "$MODE" == "setup" ]]; then
  resolved_extension_id="$(detect_extension_id "$BROWSER" "$EXTENSION_ID" || true)"
  [[ -n "$resolved_extension_id" ]] || fail "Could not detect Codex extension id. Pass --extension-id <id>."
  resolved_tool_schemas="$(resolve_tool_schemas_path "$BROWSER" "$resolved_extension_id" "$TOOL_SCHEMAS" || true)"
  [[ -n "$resolved_tool_schemas" ]] || fail "Could not locate tool-schemas.json. Pass --tool-schemas <path>."

  setup_standalone_mode "$BROWSER" "$resolved_extension_id" "$resolved_tool_schemas" "$SKIP_INSTALL" "$SCRIPT_DIR"

  info "Setup complete."
  info "Next: open chrome://extensions, reload the codex-extension, then verify in extension options."
  status_report "$BROWSER" "${resolved_extension_id:-$EXTENSION_ID}" "${resolved_tool_schemas:-$TOOL_SCHEMAS}"
  exit 0
fi

if [[ "$MODE" == "status" ]]; then
  resolved_extension_id="$(detect_extension_id "$BROWSER" "$EXTENSION_ID" || true)"
  resolved_tool_schemas=""
  if [[ -n "$resolved_extension_id" ]]; then
    resolved_tool_schemas="$(resolve_tool_schemas_path "$BROWSER" "$resolved_extension_id" "$TOOL_SCHEMAS" || true)"
  fi
  status_report "$BROWSER" "$resolved_extension_id" "$resolved_tool_schemas"
  exit 0
fi

if [[ "$MODE" == "uninstall" ]]; then
  uninstall_all "$BROWSER" "$REMOVE_MCP"
  info "Uninstall complete."
fi
