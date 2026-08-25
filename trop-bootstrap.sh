#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

readonly TROP_BOOTSTRAP_VERSION="0.1.0"
# Bootstrap protocol v1 always uses this pinned client. The signed private
# package carries the release-specific Zarf runtime used for platform pulls.
readonly ZARF_VERSION="v0.70.1"
readonly REGISTRY_HOST="registry.trop.defencebay.com"
readonly HARBOR_PROJECT="trop-releases"

RELEASE=""
DESTINATION=""
TOKEN_STDIN="false"
FETCH_ONLY="false"
TEMP_DIRECTORY=""
STAGING_PARENT=""
STAGING_DIRECTORY=""
HARBOR_USERNAME=""
HARBOR_SECRET=""
ZARF_BIN=""

info() {
  printf '[trop-bootstrap] %s\n' "$*"
}

die() {
  printf '[trop-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  HARBOR_SECRET=""
  if [[ -n "$TEMP_DIRECTORY" && -d "$TEMP_DIRECTORY" ]]; then
    rm -rf -- "$TEMP_DIRECTORY"
  fi
  if [[ -n "$STAGING_PARENT" && -d "$STAGING_PARENT" ]]; then
    rm -rf -- "$STAGING_PARENT"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./trop-bootstrap.sh --release RELEASE [options]

Options:
  --release RELEASE  Immutable TROP release tag to retrieve
  --dest DIRECTORY   Output directory (default: $HOME/trop-RELEASE)
  --token-stdin      Read the TROP token from standard input
  --fetch-only       Retrieve and verify everything without running the installer
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

  [[ "$HARBOR_USERNAME" == "robot\$${HARBOR_PROJECT}+"* ]] ||
    die "token is not scoped to the expected Harbor project"
  [[ ${#HARBOR_SECRET} -ge 16 ]] || die "Harbor robot secret is unexpectedly short"
  [[ "$HARBOR_USERNAME" != *$'\n'* && "$HARBOR_SECRET" != *$'\n'* ]] || die "invalid credential"
}

install_zarf() {
  local architecture="$1" filename checksum expected_checksum download_url
  filename="zarf_${ZARF_VERSION}_Linux_${architecture}"
  case "$architecture" in
    amd64) expected_checksum="a409b568ab8120f5cc3ed0cbbaa819f031750bb320b8b8e26a345c3e2ddaad2a" ;;
    arm64) expected_checksum="ebaf0911749dbacf5280a88cf2a970717c3b6729819aadc9a25cc850eb04018e" ;;
  esac
  download_url="https://github.com/zarf-dev/zarf/releases/download/${ZARF_VERSION}/${filename}"

  info "Downloading open-source Zarf ${ZARF_VERSION}"
  ZARF_BIN="$TEMP_DIRECTORY/$filename"
  curl --fail --silent --show-error --location --output "$ZARF_BIN" "$download_url"
  checksum="$(sha256sum "$ZARF_BIN" | awk '{print $1}')"
  [[ "$checksum" == "$expected_checksum" ]] || die "Zarf checksum verification failed"
  chmod +x "$ZARF_BIN"
}

write_release_key() {
  cat >"$TEMP_DIRECTORY/trop-release.pub" <<'EOF'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEpgpOxlPdPuLlOxFfmJesihZ0VmPr
5UQTE+U6Y+ZT6QPUP1z7Kri3MsdEmK9WCakT11AcegVYGosnjzoYfEhmeA==
-----END PUBLIC KEY-----
EOF
}

verify_expected_checksum() {
  local manifest="$1" file="$2" expected actual
  expected="$(awk -v name="$(basename "$file")" '$2 == name || $2 == "*" name { print $1 }' "$manifest")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "missing checksum for $(basename "$file")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "checksum verification failed for $(basename "$file")"
}

verify_bootstrap_assets() {
  local directory="$1" architecture="$2" common_manifest arch_manifest name
  local zarf_files init_files
  common_manifest="$directory/SHA256SUMS-common"
  arch_manifest="$directory/SHA256SUMS-$architecture"
  [[ -f "$common_manifest" && -f "$arch_manifest" ]] || die "checksum manifests are missing"

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
  chmod +x "$directory/trop-install.sh" "${zarf_files[0]}"
}

prepare_staging() {
  local destination_parent
  destination_parent="$(dirname "$DESTINATION")"
  mkdir -p "$destination_parent"
  STAGING_PARENT="$(mktemp -d "$destination_parent/.trop-${RELEASE}.partial.XXXXXX")"
  STAGING_DIRECTORY="$STAGING_PARENT/payload"
}

pull_bootstrap_assets() {
  local architecture="$1" destination="$2" output staging reference auth_directory zarf_filename
  local release_zarf_files
  output="$TEMP_DIRECTORY/extracted"
  staging="$output/trop-bootstrap-documentation"
  reference="oci://${REGISTRY_HOST}/${HARBOR_PROJECT}/${architecture}/trop-bootstrap:${RELEASE}"
  auth_directory="$TEMP_DIRECTORY/registry-auth"
  zarf_filename="zarf_${ZARF_VERSION}_Linux_${architecture}"
  mkdir "$output" "$auth_directory"

  info "Downloading private installer assets for ${RELEASE} (${architecture})"
  printf '%s' "$HARBOR_SECRET" | DOCKER_CONFIG="$auth_directory" \
    "$ZARF_BIN" tools registry login \
    --username "$HARBOR_USERNAME" --password-stdin "$REGISTRY_HOST"
  DOCKER_CONFIG="$auth_directory" "$ZARF_BIN" package inspect documentation "$reference" \
    --architecture skeleton \
    --key "$TEMP_DIRECTORY/trop-release.pub" \
    --verify \
    --output "$output"
  [[ -d "$staging" ]] || die "Zarf did not extract the private installer assets"
  shopt -s nullglob
  release_zarf_files=("$staging"/zarf_*_Linux_"$architecture")
  shopt -u nullglob
  [[ ${#release_zarf_files[@]} -le 1 ]] || die "bootstrap package contains multiple Zarf runtimes"
  if [[ ${#release_zarf_files[@]} -eq 0 ]]; then
    cp "$ZARF_BIN" "$staging/$zarf_filename"
  fi
  verify_bootstrap_assets "$staging" "$architecture"
  mv "$staging" "$destination"
  info "Verified private installer assets"
}

pull_platform_package() {
  local architecture="$1" destination="$2" zarf_binary package_name package_ref auth_directory
  zarf_binary="$(find "$destination" -maxdepth 1 -type f -name "zarf_*_Linux_$architecture" -print -quit)"
  package_name="zarf-package-trop-platform-${architecture}-${RELEASE}.tar.zst"
  package_ref="oci://${REGISTRY_HOST}/${HARBOR_PROJECT}/${architecture}/trop-platform:${RELEASE}"
  auth_directory="$TEMP_DIRECTORY/zarf-auth"
  mkdir "$auth_directory"

  info "Pulling and verifying the signed TROP platform package"
  printf '%s' "$HARBOR_SECRET" | DOCKER_CONFIG="$auth_directory" \
    "$zarf_binary" tools registry login \
    --username "$HARBOR_USERNAME" --password-stdin "$REGISTRY_HOST"
  DOCKER_CONFIG="$auth_directory" "$zarf_binary" package pull "$package_ref" \
    --architecture "$architecture" \
    --output-directory "$destination" \
    --key "$destination/trop-release.pub" \
    --verify
  [[ -f "$destination/$package_name" ]] || die "Zarf pull did not create $package_name"
}

publish_destination() {
  [[ ! -e "$DESTINATION" ]] || die "destination appeared while downloading: $DESTINATION"
  mv -T -- "$STAGING_DIRECTORY" "$DESTINATION"
  rmdir "$STAGING_PARENT"
  STAGING_PARENT=""
  STAGING_DIRECTORY=""
  info "Verified installer and platform assets at $DESTINATION"
}

offer_install() {
  local architecture="$1" package init_package answer
  package="$DESTINATION/zarf-package-trop-platform-${architecture}-${RELEASE}.tar.zst"
  init_package="$(find "$DESTINATION" -maxdepth 1 -type f -name "zarf-init-${architecture}-*.tar.zst" -print -quit)"

  if [[ "$FETCH_ONLY" == "true" || ! -t 0 ]]; then
    info "Fetch-only checkpoint reached; installer was not executed"
    printf 'Next: cd %q && ./trop-install.sh setup\n' "$DESTINATION"
    return
  fi

  read -r -p 'Run the private TROP setup now? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || return
  (cd "$DESTINATION" && ./trop-install.sh setup)

  read -r -p 'Deploy TROP to this computer now? [y/N] ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || return
  (cd "$DESTINATION" && ./trop-install.sh deploy "$package" --init-package "$init_package")
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release) [[ $# -ge 2 ]] || die "--release requires a value"; RELEASE="$2"; shift 2 ;;
      --dest) [[ $# -ge 2 ]] || die "--dest requires a value"; DESTINATION="$2"; shift 2 ;;
      --token-stdin) TOKEN_STDIN="true"; shift ;;
      --fetch-only) FETCH_ONLY="true"; shift ;;
      --version) printf '%s\n' "$TROP_BOOTSTRAP_VERSION"; exit 0 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ "$RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "--release is required and must be a valid tag"
  DESTINATION="${DESTINATION:-$HOME/trop-$RELEASE}"
  [[ ! -e "$DESTINATION" ]] || die "destination already exists: $DESTINATION"
}

main() {
  local architecture command
  umask 077
  parse_arguments "$@"
  for command in awk base64 curl dirname find mktemp mv sha256sum; do
    require_command "$command"
  done
  architecture="$(detect_architecture)"
  read_credential
  TEMP_DIRECTORY="$(mktemp -d)"
  prepare_staging
  install_zarf "$architecture"
  write_release_key
  pull_bootstrap_assets "$architecture" "$STAGING_DIRECTORY"
  pull_platform_package "$architecture" "$STAGING_DIRECTORY"
  HARBOR_SECRET=""
  publish_destination
  offer_install "$architecture"
}

main "$@"
