#!/usr/bin/env bash
set -euo pipefail

readonly TROP_BOOTSTRAP_VERSION="0.1.0"
readonly DEFAULT_REGISTRY_HOST="registry.trop.defencebay.com"
readonly DEFAULT_REGISTRY_SCHEME="https"
readonly DEFAULT_PROJECT="trop-releases"
readonly DEFAULT_BOOTSTRAP_REPOSITORY="trop-bootstrap"
readonly EXPECTED_ARTIFACT_TYPE="application/vnd.defencebay.trop.bootstrap.bundle.v1"
readonly EXPECTED_LAYER_MEDIA_TYPE="application/vnd.defencebay.trop.bootstrap.layer.v1.tar+gzip"
readonly OCI_MANIFEST_MEDIA_TYPE="application/vnd.oci.image.manifest.v1+json"

REGISTRY_HOST="${TROP_REGISTRY_HOST:-$DEFAULT_REGISTRY_HOST}"
REGISTRY_SCHEME="${TROP_REGISTRY_SCHEME:-$DEFAULT_REGISTRY_SCHEME}"
PROJECT="${TROP_HARBOR_PROJECT:-$DEFAULT_PROJECT}"
BOOTSTRAP_REPOSITORY="${TROP_BOOTSTRAP_REPOSITORY:-$DEFAULT_BOOTSTRAP_REPOSITORY}"
RELEASE=""
DESTINATION=""
TOKEN_STDIN="false"
FETCH_ONLY="false"
BUNDLE_ONLY="false"
TEMP_DIRECTORY=""

info() {
  printf '[trop-bootstrap] %s\n' "$*"
}

die() {
  printf '[trop-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIRECTORY" && -d "$TEMP_DIRECTORY" ]]; then
    rm -rf -- "$TEMP_DIRECTORY"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./trop-bootstrap.sh --release RELEASE [options]

Options:
  --release RELEASE  Immutable TROP release tag to retrieve
  --dest DIRECTORY   Output directory (default: $HOME/trop-RELEASE)
  --token-stdin      Read the single TROP token from standard input
  --fetch-only       Retrieve and verify assets, but never run the installer
  --bundle-only      Retrieve only the private bootstrap bundle (diagnostics)
  --version          Print launcher version
  -h, --help         Show this help

The token is accepted only through a hidden prompt or standard input. It is
never accepted as a command argument or environment variable.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

detect_architecture() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64\n' ;;
    aarch64 | arm64) printf 'arm64\n' ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

base64url_decode() {
  local encoded="$1" remainder
  [[ "$encoded" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  remainder=$(( ${#encoded} % 4 ))
  case "$remainder" in
    0) ;;
    2) encoded="${encoded}==" ;;
    3) encoded="${encoded}=" ;;
    *) return 1 ;;
  esac
  printf '%s' "$encoded" | tr '_-' '/+' | base64 --decode 2>/dev/null
}

read_credential() {
  local token prefix encoded_username encoded_secret extra
  if [[ "$TOKEN_STDIN" == "true" ]]; then
    IFS= read -r token || die "unable to read TROP token from standard input"
  else
    [[ -t 0 ]] || die "standard input is not a terminal; use --token-stdin"
    read -r -s -p 'TROP token: ' token
    printf '\n' >&2
  fi

  IFS='.' read -r prefix encoded_username encoded_secret extra <<<"$token"
  token=""
  [[ "$prefix" == "trop1" && -n "$encoded_username" && -n "$encoded_secret" && -z "${extra:-}" ]] ||
    die "malformed TROP token"

  HARBOR_USERNAME="$(base64url_decode "$encoded_username")" || die "malformed username segment"
  HARBOR_SECRET="$(base64url_decode "$encoded_secret")" || die "malformed secret segment"
  encoded_username=""
  encoded_secret=""

  [[ "$HARBOR_USERNAME" == "robot\$${PROJECT}+"* ]] ||
    die "token is not scoped to the expected Harbor project"
  [[ ${#HARBOR_SECRET} -ge 16 ]] || die "Harbor robot secret is unexpectedly short"
  [[ "$HARBOR_USERNAME" != *$'\n'* && "$HARBOR_USERNAME" != *$'\r'* ]] || die "invalid Harbor username"
  [[ "$HARBOR_SECRET" != *$'\n'* && "$HARBOR_SECRET" != *$'\r'* ]] || die "invalid Harbor secret"
}

curl_config_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

registry_bearer_token() {
  local repository="$1" credentials response
  credentials="$(curl_config_escape "${HARBOR_USERNAME}:${HARBOR_SECRET}")"
  response="$(
    printf 'user = "%s"\n' "$credentials" |
      curl --config - --fail --silent --show-error --location --get \
        "${REGISTRY_SCHEME}://${REGISTRY_HOST}/service/token" \
        --data-urlencode 'service=harbor-registry' \
        --data-urlencode "scope=repository:${repository}:pull"
  )" || die "Harbor authentication failed"
  credentials=""
  printf '%s' "$response" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
token = payload.get("token") or payload.get("access_token")
if not isinstance(token, str) or not token:
    raise SystemExit("registry response did not contain a bearer token")
print(token)
'
}

curl_with_bearer() {
  local bearer="$1" url="$2" output="$3" accept="${4:-}" escaped
  escaped="$(curl_config_escape "Authorization: Bearer $bearer")"
  if [[ -n "$accept" ]]; then
    printf 'header = "%s"\n' "$escaped" |
      curl --config - --fail --silent --show-error --location \
        --header "Accept: $accept" --output "$output" "$url"
  else
    printf 'header = "%s"\n' "$escaped" |
      curl --config - --fail --silent --show-error --location \
        --output "$output" "$url"
  fi
}

parse_manifest() {
  local manifest="$1"
  python3 - "$manifest" "$EXPECTED_ARTIFACT_TYPE" "$EXPECTED_LAYER_MEDIA_TYPE" <<'PY'
import json
import re
import sys

path, expected_artifact, expected_layer = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
if manifest.get("schemaVersion") != 2:
    raise SystemExit("unexpected OCI schema version")
if manifest.get("artifactType") != expected_artifact:
    raise SystemExit("unexpected OCI artifact type")
layers = manifest.get("layers")
if not isinstance(layers, list) or len(layers) != 1:
    raise SystemExit("bootstrap manifest must contain exactly one layer")
layer = layers[0]
if layer.get("mediaType") != expected_layer:
    raise SystemExit("unexpected bootstrap layer media type")
digest = layer.get("digest", "")
size = layer.get("size")
if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    raise SystemExit("invalid bootstrap layer digest")
if not isinstance(size, int) or size <= 0:
    raise SystemExit("invalid bootstrap layer size")
print(digest, size)
PY
}

extract_bundle_safely() {
  local bundle="$1" target="$2"
  python3 - "$bundle" "$target" <<'PY'
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile

bundle = Path(sys.argv[1])
target = Path(sys.argv[2])
target.mkdir(mode=0o700)
with tarfile.open(bundle, "r:gz") as archive:
    members = archive.getmembers()
    names = [member.name for member in members]
    if len(names) != len(set(names)):
        raise SystemExit("duplicate path in bootstrap bundle")
    for member in members:
        if not member.isfile() or member.name != Path(member.name).name:
            raise SystemExit(f"unsafe bootstrap bundle entry: {member.name}")
        source = archive.extractfile(member)
        if source is None:
            raise SystemExit(f"unable to read bootstrap bundle entry: {member.name}")
        destination = target / member.name
        with destination.open("xb") as output:
            shutil.copyfileobj(source, output)
        os.chmod(destination, 0o755 if member.name == "trop-install.sh" or member.name.startswith("zarf_") else 0o600)

metadata_path = target / "trop-bootstrap.json"
with metadata_path.open(encoding="utf-8") as handle:
    metadata = json.load(handle)
if metadata.get("schema_version") != 1:
    raise SystemExit("unsupported bootstrap metadata schema")
PY
}

verify_expected_checksum() {
  local manifest="$1" file="$2" expected actual
  expected="$(awk -v name="$(basename "$file")" '$2 == name || $2 == "*" name { print $1 }' "$manifest")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "missing checksum for $(basename "$file")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "checksum verification failed for $(basename "$file")"
}

verify_extracted_bundle() {
  local directory="$1" architecture="$2" release="$3"
  local common_manifest="$directory/SHA256SUMS-common"
  local arch_manifest="$directory/SHA256SUMS-$architecture"
  local zarf_files init_files name

  [[ -f "$common_manifest" && -f "$arch_manifest" ]] || die "bootstrap checksum manifests are missing"
  for name in trop-install.sh trop-release.pub trop-standalone-tools.tar.gz; do
    [[ -f "$directory/$name" ]] || die "bootstrap asset is missing: $name"
    verify_expected_checksum "$common_manifest" "$directory/$name"
  done

  shopt -s nullglob
  zarf_files=("$directory"/zarf_*_Linux_"$architecture")
  init_files=("$directory"/zarf-init-"$architecture"-*.tar.zst)
  shopt -u nullglob
  [[ ${#zarf_files[@]} -eq 1 ]] || die "expected exactly one Zarf binary"
  [[ ${#init_files[@]} -eq 1 ]] || die "expected exactly one Zarf init package"
  verify_expected_checksum "$arch_manifest" "${zarf_files[0]}"
  verify_expected_checksum "$arch_manifest" "${init_files[0]}"

  python3 - "$directory/trop-bootstrap.json" "$architecture" "$release" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    metadata = json.load(handle)
if metadata.get("architecture") != sys.argv[2] or metadata.get("release") != sys.argv[3]:
    raise SystemExit("bootstrap metadata does not match requested architecture/release")
PY
}

pull_platform_package() {
  local directory="$1" architecture="$2" release="$3"
  local zarf_binary package_name package_ref auth_directory
  zarf_binary="$(find "$directory" -maxdepth 1 -type f -name "zarf_*_Linux_$architecture" -print -quit)"
  package_name="zarf-package-trop-platform-${architecture}-${release}.tar.zst"
  package_ref="oci://${REGISTRY_HOST}/${PROJECT}/${architecture}/trop-platform:${release}"
  auth_directory="$(mktemp -d "$TEMP_DIRECTORY/registry-auth.XXXXXX")"
  chmod +x "$zarf_binary"

  info "Pulling and verifying signed TROP platform package"
  (
    export DOCKER_CONFIG="$auth_directory"
    printf '%s' "$HARBOR_SECRET" | "$zarf_binary" tools registry login \
      --username "$HARBOR_USERNAME" --password-stdin "$REGISTRY_HOST"
    "$zarf_binary" package pull "$package_ref" \
      --architecture "$architecture" \
      --output-directory "$directory" \
      --key "$directory/trop-release.pub" \
      --verify
  )
  [[ -f "$directory/$package_name" ]] || die "Zarf pull did not create $package_name"
  verify_expected_checksum "$directory/SHA256SUMS-$architecture" "$directory/$package_name"
}

retrieve_release() {
  local architecture="$1" repository bearer manifest bundle layer_digest layer_size actual_digest actual_size staging
  repository="${PROJECT}/${architecture}/${BOOTSTRAP_REPOSITORY}"
  bearer="$(registry_bearer_token "$repository")" || die "unable to obtain Harbor registry token"
  manifest="$TEMP_DIRECTORY/manifest.json"
  bundle="$TEMP_DIRECTORY/bootstrap.tar.gz"
  staging="$TEMP_DIRECTORY/extracted"

  info "Retrieving private bootstrap manifest for $RELEASE ($architecture)"
  curl_with_bearer "$bearer" \
    "${REGISTRY_SCHEME}://${REGISTRY_HOST}/v2/${repository}/manifests/${RELEASE}" \
    "$manifest" "$OCI_MANIFEST_MEDIA_TYPE" || die "unable to retrieve private bootstrap manifest"
  read -r layer_digest layer_size < <(parse_manifest "$manifest") || die "invalid private bootstrap manifest"

  info "Downloading private installer bundle"
  curl_with_bearer "$bearer" \
    "${REGISTRY_SCHEME}://${REGISTRY_HOST}/v2/${repository}/blobs/${layer_digest}" \
    "$bundle" || die "unable to retrieve private bootstrap bundle"
  bearer=""
  actual_size="$(wc -c <"$bundle" | tr -d ' ')"
  [[ "$actual_size" == "$layer_size" ]] || die "bootstrap bundle size mismatch"
  actual_digest="sha256:$(sha256sum "$bundle" | awk '{print $1}')"
  [[ "$actual_digest" == "$layer_digest" ]] || die "bootstrap bundle digest mismatch"

  extract_bundle_safely "$bundle" "$staging"
  verify_extracted_bundle "$staging" "$architecture" "$RELEASE"
  mkdir -p "$(dirname "$DESTINATION")"
  mv "$staging" "$DESTINATION"
  info "Verified private installer bundle at $DESTINATION"
}

offer_install() {
  local architecture="$1" package init_package answer
  package="$DESTINATION/zarf-package-trop-platform-${architecture}-${RELEASE}.tar.zst"
  init_package="$(find "$DESTINATION" -maxdepth 1 -type f -name "zarf-init-${architecture}-*.tar.zst" -print -quit)"

  if [[ "$FETCH_ONLY" == "true" || ! -t 0 ]]; then
    info "Fetch-only checkpoint reached; installer was not executed"
    printf 'Next: cd %q && ./trop-install.sh setup\n' "$DESTINATION"
    return 0
  fi

  read -r -p 'Run the private TROP setup now? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    info "Installer was not executed"
    return 0
  }
  (cd "$DESTINATION" && ./trop-install.sh setup)

  read -r -p 'Deploy TROP to this computer now? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    info "Configuration created; deployment was not executed"
    return 0
  }
  (cd "$DESTINATION" && ./trop-install.sh deploy "$package" --init-package "$init_package")
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release)
        [[ $# -ge 2 ]] || die "--release requires a value"
        RELEASE="$2"
        shift 2
        ;;
      --dest)
        [[ $# -ge 2 ]] || die "--dest requires a value"
        DESTINATION="$2"
        shift 2
        ;;
      --token-stdin) TOKEN_STDIN="true"; shift ;;
      --fetch-only) FETCH_ONLY="true"; shift ;;
      --bundle-only) BUNDLE_ONLY="true"; FETCH_ONLY="true"; shift ;;
      --version) printf '%s\n' "$TROP_BOOTSTRAP_VERSION"; exit 0 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ "$RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "--release is required and must be a valid immutable tag"
  DESTINATION="${DESTINATION:-$HOME/trop-$RELEASE}"
  [[ ! -e "$DESTINATION" ]] || die "destination already exists: $DESTINATION"
}

main() {
  local architecture command
  umask 077
  parse_arguments "$@"
  for command in base64 curl find python3 sed sha256sum tar; do
    require_command "$command"
  done
  architecture="$(detect_architecture)"
  read_credential
  TEMP_DIRECTORY="$(mktemp -d)"
  retrieve_release "$architecture"
  if [[ "$BUNDLE_ONLY" != "true" ]]; then
    pull_platform_package "$DESTINATION" "$architecture" "$RELEASE"
  fi
  HARBOR_SECRET=""
  offer_install "$architecture"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
