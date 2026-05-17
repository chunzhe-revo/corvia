#!/usr/bin/env bash
# install.sh — Corvia installer for macOS (Revolab internal)
# Idempotent: safe to re-run at any time.
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
REPO="chunzhe-revo/corvia"
BIN_NAME="corvia"
INSTALL_DIR="/usr/local/bin"
WORKSPACE="${HOME}/revolab"
SETTINGS_JSON="${HOME}/.claude/settings.json"
TMP_DIR="/tmp/corvia-install"

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1: Detect architecture
# ---------------------------------------------------------------------------
RAW_ARCH="$(uname -m)"
case "${RAW_ARCH}" in
  arm64)   ARCH="aarch64" ;;
  x86_64)  ARCH="x86_64"  ;;
  *)
    echo "ERROR: Unsupported architecture: ${RAW_ARCH}" >&2
    exit 1
    ;;
esac
ASSET_PATTERN="${BIN_NAME}-${ARCH}-apple-darwin.tar.gz"
echo "==> Architecture: ${RAW_ARCH} → ${ARCH}"

# ---------------------------------------------------------------------------
# Step 2: Version check — skip download if already current
# ---------------------------------------------------------------------------
LATEST_TAG="$(gh release view --repo "${REPO}" --json tagName --jq '.tagName')"
echo "==> Latest release: ${LATEST_TAG}"

CURRENT_VERSION=""
if command -v "${BIN_NAME}" &>/dev/null; then
  CURRENT_VERSION="$("${BIN_NAME}" --version 2>/dev/null | awk '{print $NF}' || true)"
  echo "==> Installed version: ${CURRENT_VERSION}"
fi

NEED_DOWNLOAD=true
if [[ -n "${CURRENT_VERSION}" && "v${CURRENT_VERSION}" == "${LATEST_TAG}" ]] \
   || [[ "${CURRENT_VERSION}" == "${LATEST_TAG}" ]]; then
  echo "==> Already on latest version (${LATEST_TAG}), skipping download."
  NEED_DOWNLOAD=false
fi

# ---------------------------------------------------------------------------
# Step 3 & 4: Download and install binary
# ---------------------------------------------------------------------------
if [[ "${NEED_DOWNLOAD}" == "true" ]]; then
  echo "==> Downloading ${ASSET_PATTERN} from release ${LATEST_TAG} …"
  mkdir -p "${TMP_DIR}"
  gh release download "${LATEST_TAG}" \
    --repo "${REPO}" \
    --pattern "${ASSET_PATTERN}" \
    --clobber \
    --dir "${TMP_DIR}"

  echo "==> Extracting archive …"
  tar -xzf "${TMP_DIR}/${ASSET_PATTERN}" -C "${TMP_DIR}"

  # The extracted binary should be named 'corvia' in the archive root.
  EXTRACTED_BIN="${TMP_DIR}/${BIN_NAME}"
  if [[ ! -f "${EXTRACTED_BIN}" ]]; then
    # Some archives nest the binary one level deep; search for it.
    EXTRACTED_BIN="$(find "${TMP_DIR}" -maxdepth 2 -type f -name "${BIN_NAME}" | head -1)"
    if [[ -z "${EXTRACTED_BIN}" ]]; then
      echo "ERROR: Could not find '${BIN_NAME}' binary in extracted archive." >&2
      exit 1
    fi
  fi

  echo "==> Installing binary to ${INSTALL_DIR}/${BIN_NAME} …"
  if install -m755 "${EXTRACTED_BIN}" "${INSTALL_DIR}/${BIN_NAME}" 2>/dev/null; then
    echo "==> Installed successfully."
  else
    echo "==> Permission denied — retrying with sudo …"
    sudo install -m755 "${EXTRACTED_BIN}" "${INSTALL_DIR}/${BIN_NAME}"
    echo "==> Installed successfully (via sudo)."
  fi
fi

# Verify binary is functional
INSTALLED_VERSION="$("${BIN_NAME}" --version 2>/dev/null | awk '{print $NF}' || true)"
echo "==> corvia version after install: ${INSTALLED_VERSION}"

# ---------------------------------------------------------------------------
# Step 5: Init workspace store
# ---------------------------------------------------------------------------
mkdir -p "${WORKSPACE}"
CORVIA_STORE="${WORKSPACE}/.corvia"
if [[ -d "${CORVIA_STORE}" ]]; then
  echo "==> Workspace store already exists at ${CORVIA_STORE}, skipping init."
else
  echo "==> Initialising corvia workspace store at ${WORKSPACE} …"
  (cd "${WORKSPACE}" && "${BIN_NAME}" init --yes)
  echo "==> Init complete."
fi

# ---------------------------------------------------------------------------
# Step 6: Write corvia.toml
# ---------------------------------------------------------------------------
TOML_PATH="${WORKSPACE}/corvia.toml"
if [[ -f "${TOML_PATH}" ]]; then
  echo "==> ${TOML_PATH} already present, skipping."
else
  echo "==> Writing ${TOML_PATH} …"
  cat > "${TOML_PATH}" <<'EOF'
data_dir = ".corvia"
EOF
  echo "==> corvia.toml written."
fi

# ---------------------------------------------------------------------------
# Step 7: Merge MCP entry into ~/.claude/settings.json
# ---------------------------------------------------------------------------
if [[ ! -f "${SETTINGS_JSON}" ]]; then
  echo "WARNING: ${SETTINGS_JSON} not found — skipping MCP registration." >&2
else
  echo "==> Merging corvia MCP entry into ${SETTINGS_JSON} …"
  python3 - "${SETTINGS_JSON}" "${WORKSPACE}" <<'PYEOF'
import json
import os
import sys

settings_path = sys.argv[1]
workspace_path = os.path.expanduser(sys.argv[2])

with open(settings_path, "r") as f:
    settings = json.load(f)

mcp_entry = {
    "type": "stdio",
    "command": "corvia",
    "args": ["--base-dir", workspace_path, "mcp"],
}

if "mcpServers" not in settings:
    settings["mcpServers"] = {}

settings["mcpServers"]["corvia"] = mcp_entry

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"  MCP entry written: corvia → {workspace_path}")
PYEOF
fi

# ---------------------------------------------------------------------------
# Step 8: Bootstrap ingest
# ---------------------------------------------------------------------------
echo "==> Running bootstrap ingest from ${WORKSPACE} …"
INGEST_COUNT=0

# Find all decisions/, operations/, learnings/ dirs under WORKSPACE,
# excluding .corvia/ and corvia-fork/ subtrees.
while IFS= read -r -d '' dir; do
  echo "    ingesting ${dir} …"
  (cd "${WORKSPACE}" && "${BIN_NAME}" ingest "${dir}")
  INGEST_COUNT=$((INGEST_COUNT + 1))
done < <(find "${WORKSPACE}" \
  -path "${WORKSPACE}/.corvia" -prune -o \
  -path "${WORKSPACE}/corvia-fork" -prune -o \
  \( -type d \( -name "decisions" -o -name "operations" -o -name "learnings" \) \) \
  -print0)

if [[ ${INGEST_COUNT} -eq 0 ]]; then
  echo "    No decisions/operations/learnings directories found — nothing to ingest."
fi

# ---------------------------------------------------------------------------
# Step 9: Print summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Corvia install complete"
echo "============================================================"
echo "  Version  : ${INSTALLED_VERSION}"
echo "  Store    : ${CORVIA_STORE}"
echo ""
echo "  corvia status:"
(cd "${WORKSPACE}" && "${BIN_NAME}" status 2>/dev/null) || true
echo "============================================================"
