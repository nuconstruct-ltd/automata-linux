#!/bin/sh
# Generates promtail file_sd_configs targets with container name labels
# by reading podman container metadata.

# Load identity from toolkit-generated file
[ -f /etc/identity.env ] && . /etc/identity.env
export VM_NAME="${VM_NAME:-$(hostname)}"

TARGETS_FILE="/tmp/container-targets.json"
CONTAINERS_PATH="/data/user/lib/containers/storage/overlay-containers"
CONTAINERS_DB="${CONTAINERS_PATH}/containers.json"

# Build a name lookup from containers.json (c/storage database)
# Format: id|name pairs cached in a temp file
build_name_lookup() {
  LOOKUP_FILE="/tmp/container-names.txt"
  if [ -f "$CONTAINERS_DB" ]; then
    # Extract id and names from containers.json
    # Each entry has "id":"<hash>" and "names":["<name>"]
    sed 's/},/}\n/g' "$CONTAINERS_DB" | while IFS= read -r entry; do
      id=$(printf '%s' "$entry" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      name=$(printf '%s' "$entry" | sed -n 's/.*"names"[[:space:]]*:[[:space:]]*\["\([^"]*\)".*/\1/p')
      [ -n "$id" ] && [ -n "$name" ] && printf '%s|%s\n' "$id" "$name"
    done > "$LOOKUP_FILE"
  else
    echo "WARN: containers.json not found at $CONTAINERS_DB" >&2
    # Try alternative paths
    for alt in /data/user/share/containers/storage/overlay-containers/containers.json \
               /data/user/local/share/containers/storage/overlay-containers/containers.json; do
      if [ -f "$alt" ]; then
        echo "INFO: Found containers DB at $alt" >&2
        sed 's/},/}\n/g' "$alt" | while IFS= read -r entry; do
          id=$(printf '%s' "$entry" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
          name=$(printf '%s' "$entry" | sed -n 's/.*"names"[[:space:]]*:[[:space:]]*\["\([^"]*\)".*/\1/p')
          [ -n "$id" ] && [ -n "$name" ] && printf '%s|%s\n' "$id" "$name"
        done > "$LOOKUP_FILE"
        break
      fi
    done
  fi
  # Debug: log what we found
  if [ -f "$LOOKUP_FILE" ] && [ -s "$LOOKUP_FILE" ]; then
    echo "INFO: Container name lookup:" >&2
    cat "$LOOKUP_FILE" >&2
  else
    echo "WARN: No container name mappings found" >&2
    # List available files for debugging
    ls -la "$CONTAINERS_PATH"/*.json 2>&1 >&2 || true
  fi
}

lookup_name() {
  local container_id="$1"
  if [ -f "/tmp/container-names.txt" ]; then
    grep "^${container_id}" /tmp/container-names.txt | head -1 | cut -d'|' -f2
  fi
}

generate() {
  build_name_lookup

  echo '[' > "${TARGETS_FILE}.tmp"
  first=true

  for logfile in ${CONTAINERS_PATH}/*/userdata/ctr.log; do
    [ -f "$logfile" ] || continue

    # Extract container ID from path
    container_id=$(echo "$logfile" | sed 's|.*/overlay-containers/\([^/]*\)/userdata/ctr.log|\1|')

    # Look up name from containers.json
    name=$(lookup_name "$container_id")

    # Fallback: try OCI config.json annotations
    if [ -z "$name" ]; then
      config="$(dirname "$logfile")/config.json"
      if [ -f "$config" ]; then
        name=$(sed -n 's/.*"io\.podman\.annotations\.name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -1)
      fi
    fi

    # Fallback: use short container ID
    [ -z "$name" ] && name=$(echo "$container_id" | cut -c1-12)

    if [ "$first" = true ]; then
      first=false
    else
      printf ',\n' >> "${TARGETS_FILE}.tmp"
    fi

    printf '  {"targets":["localhost"],"labels":{"job":"cvm","vm_name":"%s","container":"%s","__path__":"%s"}}' \
      "${HOSTNAME}" "$name" "$logfile" >> "${TARGETS_FILE}.tmp"
  done

  printf '\n]\n' >> "${TARGETS_FILE}.tmp"
  mv "${TARGETS_FILE}.tmp" "$TARGETS_FILE"
}

# Initial generation
generate

# Watch for container changes and regenerate targets promptly.
# Checks containers.json mtime and overlay-containers directory every 10 seconds,
# but only runs the full generation when something has changed.
last_mtime=""
last_dir_listing=""
get_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo ""
}
(
  while true; do
    sleep 10
    cur_mtime=$(get_mtime "$CONTAINERS_DB")
    cur_dir_listing=$(ls -1 "$CONTAINERS_PATH" 2>/dev/null)
    if [ "$cur_mtime" != "$last_mtime" ] || [ "$cur_dir_listing" != "$last_dir_listing" ]; then
      last_mtime="$cur_mtime"
      last_dir_listing="$cur_dir_listing"
      generate
    fi
  done
) &

# Start promtail with passed arguments
exec /usr/bin/promtail "$@"
