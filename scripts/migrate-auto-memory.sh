#!/usr/bin/env bash
# Migrate Claude Code auto-memory entries to .corvia/user/docs/
# Run once after Phase 2 install to move personal knowledge into corvia.
set -euo pipefail

WORKSPACE="${HOME}/revolab"
USER_DOCS="${WORKSPACE}/.corvia/user/docs"

# Find the auto-memory directory (may vary by project path hash)
MEMORY_DIR=""
for candidate in ~/.claude/projects/*/memory; do
  if [[ -d "${candidate}" ]]; then
    MEMORY_DIR="${candidate}"
    break
  fi
done

if [[ -z "${MEMORY_DIR}" ]]; then
  echo "No auto-memory directory found at ~/.claude/projects/*/memory — nothing to migrate."
  exit 0
fi

if [[ ! -d "${USER_DOCS}" ]]; then
  echo "ERROR: ${USER_DOCS} not found. Run the Phase 2 installer first." >&2
  exit 1
fi

echo "==> Migrating from ${MEMORY_DIR} to ${USER_DOCS} …"

COUNT=0
while IFS= read -r -d '' f; do
  FILENAME="$(basename "${f}")"
  # Skip the index file — it's not an entry
  [[ "${FILENAME}" == "MEMORY.md" ]] && continue
  DEST="${USER_DOCS}/migrated-${FILENAME}"
  cp "${f}" "${DEST}"
  COUNT=$((COUNT + 1))
  echo "  Migrated: ${FILENAME}"
done < <(find "${MEMORY_DIR}" -maxdepth 1 -name "*.md" -print0)

if [[ ${COUNT} -eq 0 ]]; then
  echo "No .md entries found to migrate."
else
  echo ""
  echo "Migrated ${COUNT} file(s)."
  echo "Re-index with: cd ${WORKSPACE} && corvia ingest ${USER_DOCS}"
fi
