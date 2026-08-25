#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: create-token.sh HARBOR_ROBOT_USERNAME --secret-stdin" >&2
}

base64url_encode() {
  base64 | tr -d '\n=' | tr '/+' '_-'
}

[[ $# -eq 2 && "$2" == "--secret-stdin" ]] || {
  usage
  exit 1
}
username="$1"
[[ "$username" == "robot\$trop-releases+"* ]] || {
  echo "ERROR: username must be a trop-releases project robot" >&2
  exit 1
}
IFS= read -r secret || {
  echo "ERROR: unable to read Harbor robot secret from standard input" >&2
  exit 1
}
[[ ${#secret} -ge 16 ]] || {
  echo "ERROR: Harbor robot secret is unexpectedly short" >&2
  exit 1
}

printf 'trop1.%s.%s\n' \
  "$(printf '%s' "$username" | base64url_encode)" \
  "$(printf '%s' "$secret" | base64url_encode)"
