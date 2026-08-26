#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

readonly TROP_BOOTSTRAP_VERSION="0.2.0"
# Bootstrap protocol v2 always uses this pinned client. The signed private
# package carries the release-specific Zarf runtime used for platform pulls.
readonly ZARF_VERSION="v0.70.1"
readonly REGISTRY_HOST="registry.trop.defencebay.com"
readonly HARBOR_PROJECT="trop-releases"

RELEASE=""
DESTINATION=""
TOKEN_STDIN="false"
FETCH_ONLY="false"
INSTALL_AFTER_FETCH=""
TEMP_DIRECTORY=""
STAGING_PARENT=""
STAGING_DIRECTORY=""
HARBOR_USERNAME=""
HARBOR_SECRET=""
ZARF_BIN=""
REGISTRY_AUTH_DIRECTORY=""

info() {
  printf '[trop-bootstrap] %s\n' "$*"
}

die() {
  printf '[trop-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  HARBOR_SECRET=""
  HARBOR_USERNAME=""
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
Usage: ./trop-bootstrap [--release RELEASE] [options]

Run without arguments in a terminal to open the guided installer.

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

prompt_value() {
  local prompt="$1" default="$2" variable="$3" value
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$prompt" "$default"
  else
    printf '%s: ' "$prompt"
  fi
  IFS= read -r value || die "input was interrupted"
  printf -v "$variable" '%s' "${value:-$default}"
}

confirm_default_yes() {
  local prompt="$1" answer
  while true; do
    prompt_value "$prompt (Y/n)" "Y" answer
    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) printf 'Please enter y or n.\n' ;;
    esac
  done
}

guided_setup() {
  local architecture="$1" action
  cat <<'EOF'

=== TROP Standalone Guided Installer ===

This wizard downloads a signed TROP release and can install it on this computer.
Press Enter to accept a recommended value. No token or password is shown in the
review screen or written to shell history.

EOF

  printf 'The release tag is supplied with your TROP token (for example, r47-20260826).\n'
  while true; do
    prompt_value "TROP release tag" "" RELEASE
    if [[ "$RELEASE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
      break
    fi
    printf 'Enter the release tag supplied by your TROP administrator.\n'
  done

  prompt_value "Download directory" "${DESTINATION:-$HOME/trop-$RELEASE}" DESTINATION

  if [[ "$FETCH_ONLY" == "true" ]]; then
    INSTALL_AFTER_FETCH="false"
  else
    while true; do
      cat <<'EOF'

What should this wizard do?
  1. Download, verify, configure, and install TROP (recommended)
  2. Download and verify the release only
  0. Exit without making changes
EOF
      prompt_value "Choose an option" "1" action
      case "$action" in
        1) INSTALL_AFTER_FETCH="true"; FETCH_ONLY="false"; break ;;
        2) INSTALL_AFTER_FETCH="false"; FETCH_ONLY="true"; break ;;
        0) info "No changes were made"; exit 0 ;;
        *) printf 'Please choose 1, 2, or 0.\n' ;;
      esac
    done
  fi

  cat <<EOF

Review
  Release:       $RELEASE
  Architecture:  $architecture
  Destination:   $DESTINATION
  Action:        $(if [[ "$INSTALL_AFTER_FETCH" == "true" ]]; then printf 'download and install'; else printf 'download only'; fi)

The release and its signatures will be verified before any installation starts.
EOF
  confirm_default_yes "Continue?" || { info "No changes were made"; exit 0; }
}

clear_registry_credentials() {
  HARBOR_SECRET=""
  HARBOR_USERNAME=""
  if [[ -n "$REGISTRY_AUTH_DIRECTORY" && -d "$REGISTRY_AUTH_DIRECTORY" ]]; then
    rm -rf -- "$REGISTRY_AUTH_DIRECTORY"
  fi
  REGISTRY_AUTH_DIRECTORY=""
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
  [[ ${#zarf_files[@]} -eq 1 ]] || die "release $RELEASE uses an unsupported legacy bootstrap format; select a qualified release that carries exactly one Zarf runtime"
  [[ ${#init_files[@]} -eq 1 ]] || die "expected exactly one Zarf init package"
  verify_expected_checksum "$arch_manifest" "${zarf_files[0]}"
  verify_expected_checksum "$arch_manifest" "${init_files[0]}"
  chmod +x "$directory/trop-install.sh" "${zarf_files[0]}"
}

prepare_staging() {
  local destination_parent
  destination_parent="$(dirname "$DESTINATION")"
  mkdir -p "$destination_parent"
  destination_parent="$(cd "$destination_parent" && pwd)"
  DESTINATION="$destination_parent/$(basename "$DESTINATION")"
  STAGING_PARENT="$(mktemp -d "$destination_parent/.trop-${RELEASE}.partial.XXXXXX")"
  STAGING_DIRECTORY="$STAGING_PARENT/payload"
}

registry_login() {
  REGISTRY_AUTH_DIRECTORY="$TEMP_DIRECTORY/registry-auth"
  mkdir "$REGISTRY_AUTH_DIRECTORY"
  printf '%s' "$HARBOR_SECRET" | DOCKER_CONFIG="$REGISTRY_AUTH_DIRECTORY" \
    "$ZARF_BIN" tools registry login \
    --username "$HARBOR_USERNAME" --password-stdin "$REGISTRY_HOST"
}

pull_bootstrap_assets() {
  local architecture="$1" destination="$2" output staging reference
  output="$TEMP_DIRECTORY/extracted"
  staging="$output/trop-bootstrap-documentation"
  reference="oci://${REGISTRY_HOST}/${HARBOR_PROJECT}/${architecture}/trop-bootstrap:${RELEASE}"
  mkdir "$output"

  info "Downloading private installer assets for ${RELEASE} (${architecture})"
  DOCKER_CONFIG="$REGISTRY_AUTH_DIRECTORY" "$ZARF_BIN" package inspect documentation "$reference" \
    --architecture skeleton \
    --key "$TEMP_DIRECTORY/trop-release.pub" \
    --verify \
    --output "$output"
  [[ -d "$staging" ]] || die "Zarf did not extract the private installer assets"
  verify_bootstrap_assets "$staging" "$architecture"
  mv "$staging" "$destination"
  info "Verified private installer assets"
}

pull_platform_package() {
  local architecture="$1" destination="$2" zarf_binary package_name package_ref
  zarf_binary="$(find "$destination" -maxdepth 1 -type f -name "zarf_*_Linux_$architecture" -print -quit)"
  package_name="zarf-package-trop-platform-${architecture}-${RELEASE}.tar.zst"
  package_ref="oci://${REGISTRY_HOST}/${HARBOR_PROJECT}/${architecture}/trop-platform:${RELEASE}"
  info "Pulling and verifying the signed TROP platform package"
  DOCKER_CONFIG="$REGISTRY_AUTH_DIRECTORY" "$zarf_binary" package pull "$package_ref" \
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

print_resume_commands() {
  local package="$1" init_package="$2"
  printf '  cd %q\n  ./trop-install.sh setup\n' "$DESTINATION"
  print_deploy_command "$package" "$init_package"
}

print_deploy_command() {
  local package="$1" init_package="$2"
  printf '  ./trop-install.sh deploy %q --init-package %q\n' \
    "$(basename "$package")" "$(basename "$init_package")"
}

offer_install() {
  local architecture="$1" package init_package answer
  package="$DESTINATION/zarf-package-trop-platform-${architecture}-${RELEASE}.tar.zst"
  init_package="$(find "$DESTINATION" -maxdepth 1 -type f -name "zarf-init-${architecture}-*.tar.zst" -print -quit)"

  if [[ "$FETCH_ONLY" == "true" || "$INSTALL_AFTER_FETCH" == "false" || ! -t 0 ]]; then
    info "Fetch-only checkpoint reached; installer was not executed"
    printf 'Next:\n'
    print_resume_commands "$package" "$init_package"
    return
  fi

  if [[ "$INSTALL_AFTER_FETCH" != "true" ]]; then
    read -r -p 'Configure and deploy TROP on this computer now? [y/N] ' answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      printf 'Resume later:\n'
      print_resume_commands "$package" "$init_package"
      return
    fi
  fi
  if ! (cd "$DESTINATION" && ./trop-install.sh setup); then
    printf 'Setup failed. Resume with:\n'
    print_resume_commands "$package" "$init_package"
    return 1
  fi
  if ! (cd "$DESTINATION" && ./trop-install.sh deploy "$package" --init-package "$init_package"); then
    printf 'Deploy failed. Keep the existing config and resume with:\n  cd %q\n' "$DESTINATION"
    print_deploy_command "$package" "$init_package"
    return 1
  fi
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
}

finalize_options() {
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
  if [[ -z "$RELEASE" ]]; then
    [[ -t 0 ]] || die "--release is required when standard input is not a terminal"
    guided_setup "$architecture"
  fi
  finalize_options
  TEMP_DIRECTORY="$(mktemp -d)"
  prepare_staging
  install_zarf "$architecture"
  write_release_key
  read_credential
  registry_login
  pull_bootstrap_assets "$architecture" "$STAGING_DIRECTORY"
  pull_platform_package "$architecture" "$STAGING_DIRECTORY"
  clear_registry_credentials
  publish_destination
  rm -rf -- "$TEMP_DIRECTORY"
  TEMP_DIRECTORY=""
  offer_install "$architecture"
}

main "$@"
