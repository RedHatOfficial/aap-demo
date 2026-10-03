#!/usr/bin/env bash

# Read small JSON values without requiring a full Python installation on Windows.
# Git for Windows may expose the Microsoft Store's python.exe alias even when
# Python is not installed, so jq is preferred and Python is only used when it
# can actually start.

aap_demo_json_value() {
  local key="$1" json="${2:-}"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg key "$key" '.[$key] // empty'
    return
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
    return
  fi
  if command -v python >/dev/null 2>&1 && python -c 'import json' >/dev/null 2>&1; then
    printf '%s' "$json" | python -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$key"
    return
  fi
  # CRC status fields are top-level scalar values. Keep a POSIX fallback for
  # locked-down Windows installations where WinGet binaries are inaccessible.
  printf '%s' "$json" | sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"?([^",}]+)"?.*/\1/p' | head -n 1
}

aap_demo_json_disk_percent() {
  local json="${1:-}"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r 'if (.diskSize // 0) > 0 then (((.diskUse // 0) / .diskSize * 100) | floor) else 0 end'
    return
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int((d.get("diskUse",0) / (d.get("diskSize",1) or 1)) * 100))'
    return
  fi
  if command -v python >/dev/null 2>&1 && python -c 'import json' >/dev/null 2>&1; then
    printf '%s' "$json" | python -c 'import json,sys; d=json.load(sys.stdin); print(int((d.get("diskUse",0) / (d.get("diskSize",1) or 1)) * 100))'
    return
  fi
  local disk_use disk_size
  disk_use=$(aap_demo_json_value diskUse "$json")
  disk_size=$(aap_demo_json_value diskSize "$json")
  awk -v used="$disk_use" -v total="$disk_size" 'BEGIN { if (total > 0) print int((used / total) * 100); else print 0 }'
}

aap_demo_json_clear_namespace_finalizers() {
  if command -v jq >/dev/null 2>&1; then
    jq '.spec.finalizers = []'
    return
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.load(sys.stdin); d.setdefault("spec", {})["finalizers"]=[]; print(json.dumps(d))'
    return
  fi
  if command -v python >/dev/null 2>&1 && python -c 'import json' >/dev/null 2>&1; then
    python -c 'import json,sys; d=json.load(sys.stdin); d.setdefault("spec", {})["finalizers"]=[]; print(json.dumps(d))'
    return
  fi
  echo 'jq or a working Python 3 interpreter is required to rewrite namespace JSON' >&2
  return 1
}
