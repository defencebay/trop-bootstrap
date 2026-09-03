#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

readonly TROP_BOOTSTRAP_VERSION="0.4.1"
# Bootstrap protocol v3 always uses this pinned client. The signed private
# package carries the release-specific Zarf runtime used for platform pulls.
readonly ZARF_VERSION="v0.70.1"
readonly REGISTRY_HOST="registry.trop.defencebay.com"
readonly HARBOR_PROJECT="trop-releases"
readonly INSTALL_ROOT="/opt/trop"
readonly SYSTEM_CONFIG_FILE="/etc/trop/zarf-config.yaml"
readonly SYSTEM_ENCRYPTED_CONFIG_FILE="/etc/trop/zarf-config.enc.yaml"
readonly BOOTSTRAP_LATEST_URL="https://github.com/defencebay/trop-bootstrap/releases/latest"

RELEASE=""
DESTINATION=""
TOKEN_STDIN="false"
FETCH_ONLY="false"
LIST_RELEASES="false"
INSTALL_AFTER_FETCH=""
EXISTING_CONFIG=""
TEMP_DIRECTORY=""
STAGING_PARENT=""
STAGING_DIRECTORY=""
PUBLISH_PARTIAL_DIRECTORY=""
HARBOR_USERNAME=""
HARBOR_SECRET=""
ZARF_BIN=""
REGISTRY_AUTH_DIRECTORY=""
INSTALLATION_STATE=""
AVAILABLE_RELEASES=""
LATEST_RELEASE=""
ACTIVE_RELEASE=""

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
  if [[ -n "$PUBLISH_PARTIAL_DIRECTORY" ]]; then
    run_as_root rm -rf -- "$PUBLISH_PARTIAL_DIRECTORY" >/dev/null 2>&1 || true
  fi
}

usage() {
  cat <<'EOF'
Usage: ./trop-bootstrap [--release RELEASE] [options]

Run without arguments in a terminal to open the guided installer.

Options:
  --release RELEASE  Immutable release tag, or 'latest'
  --list-releases    List stable releases available to this token and exit
  --dest DIRECTORY   Verified release-assets directory (default: /opt/trop/releases/RELEASE)
  --config FILE      Import plaintext config from an earlier home-directory install
  --token-stdin      Read the TROP token from standard input
  --fetch-only       Retrieve and verify everything without running the installer
  --version          Print launcher version
  -h, --help         Show this help

The token is accepted only through a hidden prompt or standard input. It is
never accepted as a command argument or environment variable.

The destination stores one complete, verified release bundle: the installer,
Zarf tools, signed application package, and checksums. It is persistent release
storage, not a temporary download folder and not the Kubernetes data directory.
The active bundle supplies management and safe-uninstall tools and must remain
intact. With the recommended /opt/trop/releases/RELEASE destination, configuration
and secrets live separately under /etc/trop. A custom destination is an
operator-owned download/checkpoint directory and keeps its config locally.
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

version_is_newer() {
  local candidate="${1#v}" current="${2#v}"
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch
  [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
  IFS=. read -r current_major current_minor current_patch <<<"$current"
  (( 10#$candidate_major > 10#$current_major )) && return 0
  (( 10#$candidate_major < 10#$current_major )) && return 1
  (( 10#$candidate_minor > 10#$current_minor )) && return 0
  (( 10#$candidate_minor < 10#$current_minor )) && return 1
  (( 10#$candidate_patch > 10#$current_patch ))
}

check_for_bootstrap_update() {
  local resolved_url latest_tag
  resolved_url="$(curl --proto '=https' --tlsv1.2 --fail --silent --location \
    --head --output /dev/null --write-out '%{url_effective}' \
    "$BOOTSTRAP_LATEST_URL" 2>/dev/null || true)"
  latest_tag="${resolved_url##*/}"
  if ! version_is_newer "$latest_tag" "$TROP_BOOTSTRAP_VERSION"; then
    return 0
  fi

  cat <<EOF
Update available for this launcher: v$TROP_BOOTSTRAP_VERSION -> $latest_tag
It is recommended to restart with the current public launcher before downloading
a private TROP release:

  curl --proto '=https' --tlsv1.2 -fL \
    https://github.com/defencebay/trop-bootstrap/releases/latest/download/trop-bootstrap \
    -o trop-bootstrap.new
  chmod +x trop-bootstrap.new
  ./trop-bootstrap.new

Continuing now still uses the immutable, signed release selected below.

EOF
}

guided_intro() {
  cat <<'EOF'

=== TROP Standalone Guided Installer ===

This wizard downloads a signed TROP release and can install it on this computer.
Press Enter to accept a recommended value. No token or password is shown in the
review screen or written to shell history.

EOF
}

guided_setup() {
  local architecture="$1" action release

  printf 'Available stable releases for %s:\n' "$architecture"
  print_available_releases 10
  printf '\n'

  while true; do
    prompt_value "TROP release tag" "$LATEST_RELEASE" release
    if release_is_available "$release"; then
      RELEASE="$release"
      break
    fi
    printf 'Choose a complete stable release available to this token.\n'
  done

  cat <<EOF
=== Where TROP files are stored ===

Recommended system layout:
  Release bundle:     $INSTALL_ROOT/releases/$RELEASE
  Configuration:      /etc/trop
  Application data:   managed separately by k3s

The release bundle contains the installer, management tools, signed application
package, and checksums. It stays on disk after installation; it is not a temporary
download folder. After a healthy deploy it becomes the active bundle, so do not
delete it or individual files inside it.

An upgrade creates a new release directory and changes $INSTALL_ROOT/current only
after the upgrade passes its health check. Older release directories are retained
and are not currently removed automatically.

Choosing another path creates an operator-owned download/checkpoint directory
with its configuration kept locally.
EOF
  prompt_value "Verified release-assets directory" "${DESTINATION:-$INSTALL_ROOT/releases/$RELEASE}" DESTINATION

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
  Current:       ${ACTIVE_RELEASE:-not installed}
  Architecture:  $architecture
  Release assets: $DESTINATION
  Configuration: $(if [[ -n "$EXISTING_CONFIG" ]]; then printf 'import %s' "$EXISTING_CONFIG"; elif is_system_destination; then printf '%s' "$SYSTEM_CONFIG_FILE"; else printf '%s/zarf-config.yaml' "$DESTINATION"; fi)
  Action:        $(if [[ "$INSTALL_AFTER_FETCH" == "true" ]]; then printf 'download and install'; else printf 'download only'; fi)

The release and its signatures will be verified before any installation starts.
EOF
  confirm_default_yes "Continue?" || { info "No changes were made"; exit 0; }
}

is_system_destination() {
  [[ "$DESTINATION" == "$INSTALL_ROOT/releases/$RELEASE" ]]
}

system_config_exists() {
  [[ -f "$SYSTEM_CONFIG_FILE" || -f "$SYSTEM_ENCRYPTED_CONFIG_FILE" ]]
}

active_system_release() {
  local target
  [[ -L "$INSTALL_ROOT/current" ]] || return 0
  target="$(readlink -f "$INSTALL_ROOT/current" 2>/dev/null || true)"
  case "$target" in
    "$INSTALL_ROOT"/releases/*) basename "$target" ;;
  esac
}

release_sequence() {
  local release="$1"
  [[ "$release" =~ ^r([0-9]+)-[0-9]{8}$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

validate_release_transition() {
  local current_sequence target_sequence
  ACTIVE_RELEASE="$(active_system_release)"
  [[ -n "$ACTIVE_RELEASE" ]] || return 0
  is_system_destination || die "an existing system installation must be upgraded in $INSTALL_ROOT/releases/$RELEASE"
  [[ "$RELEASE" != "$ACTIVE_RELEASE" ]] || die "release $RELEASE is already active"

  current_sequence="$(release_sequence "$ACTIVE_RELEASE" || true)"
  target_sequence="$(release_sequence "$RELEASE" || true)"
  if [[ -n "$current_sequence" && -n "$target_sequence" ]] \
    && (( 10#$target_sequence < 10#$current_sequence )); then
    die "refusing downgrade from $ACTIVE_RELEASE to $RELEASE; automatic rollback is not supported"
  fi
}

detect_installation_state() {
  local detected="" state_args=()
  [[ -z "$INSTALLATION_STATE" ]] || return 0
  if ! is_system_destination; then
    INSTALLATION_STATE="fresh"
    return 0
  fi
  if [[ -n "$EXISTING_CONFIG" ]]; then
    state_args+=(--legacy-config "$EXISTING_CONFIG")
  fi
  detected="$(run_as_root "$DESTINATION/trop-install.sh" installation-state "${state_args[@]}" 2>/dev/null || true)"
  case "$detected" in
    fresh|installed|ambiguous) INSTALLATION_STATE="$detected" ;;
    *) INSTALLATION_STATE="ambiguous" ;;
  esac
}

existing_install_detected() {
  detect_installation_state
  [[ "$INSTALLATION_STATE" == "installed" ]]
}

print_ambiguous_state() {
  cat <<EOF
The release was verified at $DESTINATION, but this host contains a partial or
degraded installation state. No setup, deploy, or update command was selected
automatically, and existing secrets were not changed.

Inspect the host before continuing. For a known incomplete first install, resume
the verified release with 'deploy'. For a previously working installation,
restore its k3s/Zarf state and run the bootstrap again so it can select 'update'.
EOF
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  command -v sudo >/dev/null 2>&1 || die "sudo is required for the default system installation"
  if [[ "$TOKEN_STDIN" != "true" && -t 0 ]]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
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

ensure_credential() {
  [[ -n "$HARBOR_USERNAME" && -n "$HARBOR_SECRET" ]] || read_credential
}

curl_config_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

registry_bearer_token() {
  local repository="$1" response token username secret
  username="$(curl_config_escape "$HARBOR_USERNAME")"
  secret="$(curl_config_escape "$HARBOR_SECRET")"
  response="$(
    printf 'user = "%s:%s"\n' "$username" "$secret" \
      | curl --config - --fail --silent --show-error --get \
          --proto '=https' --tlsv1.2 \
          --data-urlencode 'service=harbor-registry' \
          --data-urlencode "scope=repository:${repository}:pull" \
          "https://${REGISTRY_HOST}/service/token"
  )" || die "TROP token was rejected while discovering releases"
  username=""
  secret=""
  token="$(printf '%s' "$response" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  response=""
  [[ -n "$token" ]] || die "Harbor did not return a registry access token"
  printf '%s\n' "$token"
}

registry_tags() {
  local repository="$1" token response escaped_token
  token="$(registry_bearer_token "$repository")"
  escaped_token="$(curl_config_escape "$token")"
  response="$(
    printf 'header = "Authorization: Bearer %s"\n' "$escaped_token" \
      | curl --config - --fail --silent --show-error \
          --proto '=https' --tlsv1.2 \
          "https://${REGISTRY_HOST}/v2/${repository}/tags/list?n=1000"
  )" || die "could not list releases in $repository"
  token=""
  escaped_token=""
  printf '%s\n' "$response"
}

stable_tags_from_json() {
  grep -oE '"r[0-9]+-[0-9]{8}"' | tr -d '"' | sort -Vu || true
}

discover_releases() {
  local architecture="$1" bootstrap_tags platform_tags bootstrap_file platform_file
  bootstrap_tags="$(registry_tags "${HARBOR_PROJECT}/${architecture}/trop-bootstrap" | stable_tags_from_json)"
  platform_tags="$(registry_tags "${HARBOR_PROJECT}/${architecture}/trop-platform" | stable_tags_from_json)"
  [[ -n "$bootstrap_tags" && -n "$platform_tags" ]] || die "no complete stable releases are available for $architecture"

  bootstrap_file="$TEMP_DIRECTORY/bootstrap-tags"
  platform_file="$TEMP_DIRECTORY/platform-tags"
  printf '%s\n' "$bootstrap_tags" >"$bootstrap_file"
  printf '%s\n' "$platform_tags" >"$platform_file"
  AVAILABLE_RELEASES="$(
    awk 'NR == FNR { available[$0] = 1; next } available[$0] { print }' \
      "$bootstrap_file" "$platform_file" | LC_ALL=C sort -Vr
  )"
  [[ -n "$AVAILABLE_RELEASES" ]] || die "no complete stable releases are available for $architecture"
  LATEST_RELEASE="${AVAILABLE_RELEASES%%$'\n'*}"
}

release_is_available() {
  local requested="$1" release
  while IFS= read -r release; do
    [[ "$release" == "$requested" ]] && return 0
  done <<<"$AVAILABLE_RELEASES"
  return 1
}

print_available_releases() {
  local limit="${1:-20}"
  printf '%s\n' "$AVAILABLE_RELEASES" | awk -v limit="$limit" 'NR <= limit { print "  " $0 }'
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

  for name in trop-install.sh trop-release.pub trop-standalone-tools.tar.gz trop-layout-contract; do
    [[ -f "$directory/$name" ]] || die "bootstrap asset is missing: $name"
    verify_expected_checksum "$common_manifest" "$directory/$name"
  done
  [[ "$(cat "$directory/trop-layout-contract")" == "trop-system-layout-v1" ]] ||
    die "release $RELEASE does not support the system installation layout; use bootstrap 0.2 for that immutable release"

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
  if is_system_destination; then
    DESTINATION="$INSTALL_ROOT/releases/$RELEASE"
    STAGING_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/trop-${RELEASE}.partial.XXXXXX")"
  else
    mkdir -p "$destination_parent"
    destination_parent="$(cd "$destination_parent" && pwd)"
    DESTINATION="$destination_parent/$(basename "$DESTINATION")"
    STAGING_PARENT="$(mktemp -d "$destination_parent/.trop-${RELEASE}.partial.XXXXXX")"
  fi
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
  local partial_destination
  [[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || die "destination appeared while downloading: $DESTINATION"
  if is_system_destination; then
    run_as_root install -d -o root -g root -m 0755 "$INSTALL_ROOT" "$INSTALL_ROOT/releases"
    partial_destination="$(run_as_root mktemp -d "$INSTALL_ROOT/releases/.${RELEASE}.partial.XXXXXX")"
    PUBLISH_PARTIAL_DIRECTORY="$partial_destination"
    if ! run_as_root cp -a "$STAGING_DIRECTORY/." "$partial_destination/"; then
      run_as_root rm -rf -- "$partial_destination"
      die "could not copy the verified release into $INSTALL_ROOT/releases"
    fi
    run_as_root chown -R root:root "$partial_destination"
    run_as_root chmod -R a+rX,go-w "$partial_destination"
    if ! run_as_root mv -T -- "$partial_destination" "$DESTINATION"; then
      run_as_root rm -rf -- "$partial_destination"
      die "could not publish the verified release at $DESTINATION"
    fi
    PUBLISH_PARTIAL_DIRECTORY=""
    rm -rf -- "$STAGING_DIRECTORY"
  else
    mv -T -- "$STAGING_DIRECTORY" "$DESTINATION"
  fi
  rmdir "$STAGING_PARENT"
  STAGING_PARENT=""
  STAGING_DIRECTORY=""
  info "Verified installer and platform assets at $DESTINATION"
}

print_resume_commands() {
  local package="$1" init_package="$2"
  printf '  cd %q\n' "$DESTINATION"
  if is_system_destination; then
    if [[ -n "$EXISTING_CONFIG" ]]; then
      printf '  sudo ./trop-install.sh setup --import-config %q\n' "$EXISTING_CONFIG"
    elif system_config_exists; then
      printf '  # Reusing the existing configuration in /etc/trop\n'
    else
      printf '  sudo ./trop-install.sh setup\n'
    fi
  else
    printf '  ./trop-install.sh setup\n'
  fi
  print_deploy_command "$package" "$init_package"
}

print_deploy_command() {
  local package="$1" init_package="$2"
  if existing_install_detected; then
    printf '  sudo ./trop-install.sh update %q\n' "$(basename "$package")"
  elif is_system_destination; then
    printf '  sudo ./trop-install.sh deploy %q --init-package %q\n' \
      "$(basename "$package")" "$(basename "$init_package")"
  else
    printf '  ./trop-install.sh deploy %q --init-package %q\n' \
      "$(basename "$package")" "$(basename "$init_package")"
  fi
}

offer_install() {
  local architecture="$1" package init_package answer run_setup="true" apply_mode="deploy"
  package="$DESTINATION/zarf-package-trop-platform-${architecture}-${RELEASE}.tar.zst"
  init_package="$(find "$DESTINATION" -maxdepth 1 -type f -name "zarf-init-${architecture}-*.tar.zst" -print -quit)"
  detect_installation_state

  if [[ "$FETCH_ONLY" == "true" || "$INSTALL_AFTER_FETCH" == "false" || ! -t 0 ]]; then
    info "Fetch-only checkpoint reached; installer was not executed"
    if [[ "$INSTALLATION_STATE" == "ambiguous" ]]; then
      print_ambiguous_state
      return
    fi
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

  if [[ "$INSTALLATION_STATE" == "ambiguous" ]]; then
    print_ambiguous_state >&2
    return 1
  fi

  if is_system_destination && [[ -z "$EXISTING_CONFIG" ]] && system_config_exists; then
    info "Reusing existing configuration in /etc/trop"
    run_setup="false"
  fi

  local setup_command=(./trop-install.sh setup)
  if [[ -n "$EXISTING_CONFIG" ]]; then
    setup_command+=(--import-config "$EXISTING_CONFIG")
  fi
  if [[ "$run_setup" == "true" ]]; then
    if is_system_destination; then
      (cd "$DESTINATION" && run_as_root "${setup_command[@]}") || {
        printf 'Setup failed. Resume with:\n'
        print_resume_commands "$package" "$init_package"
        return 1
      }
    elif ! (cd "$DESTINATION" && "${setup_command[@]}"); then
      printf 'Setup failed. Resume with:\n'
      print_resume_commands "$package" "$init_package"
      return 1
    fi
  fi
  local deploy_command=(./trop-install.sh deploy "$package" --init-package "$init_package")
  if existing_install_detected; then
    apply_mode="update"
    deploy_command=(./trop-install.sh update "$package")
    info "Updating the existing TROP installation"
  fi
  if is_system_destination; then
    (cd "$DESTINATION" && run_as_root "${deploy_command[@]}") || {
      printf '%s failed. Keep the existing config and resume with:\n  cd %q\n' "${apply_mode^}" "$DESTINATION"
      print_deploy_command "$package" "$init_package"
      return 1
    }
  elif ! (cd "$DESTINATION" && "${deploy_command[@]}"); then
    printf '%s failed. Keep the existing config and resume with:\n  cd %q\n' "${apply_mode^}" "$DESTINATION"
    print_deploy_command "$package" "$init_package"
    return 1
  fi
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release) [[ $# -ge 2 ]] || die "--release requires a value"; RELEASE="$2"; shift 2 ;;
      --list-releases) LIST_RELEASES="true"; shift ;;
      --dest) [[ $# -ge 2 ]] || die "--dest requires a value"; DESTINATION="$2"; shift 2 ;;
      --config) [[ $# -ge 2 ]] || die "--config requires a value"; EXISTING_CONFIG="$2"; shift 2 ;;
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
  DESTINATION="${DESTINATION:-$INSTALL_ROOT/releases/$RELEASE}"
  validate_release_transition
  if [[ -n "$EXISTING_CONFIG" ]]; then
    [[ -f "$EXISTING_CONFIG" && -r "$EXISTING_CONFIG" ]] || die "configuration file is not readable: $EXISTING_CONFIG"
    EXISTING_CONFIG="$(cd "$(dirname "$EXISTING_CONFIG")" && pwd)/$(basename "$EXISTING_CONFIG")"
  fi
  [[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || die "destination already exists: $DESTINATION"
}

main() {
  local architecture command discovery_required="false" guided="false"
  umask 077
  trap cleanup EXIT
  parse_arguments "$@"
  [[ "$LIST_RELEASES" != "true" || -z "$RELEASE" ]] || die "--list-releases cannot be combined with --release"
  for command in awk base64 cat cp curl dirname find grep install mktemp mv readlink sed sha256sum sort tr; do
    require_command "$command"
  done
  architecture="$(detect_architecture)"
  if [[ -z "$RELEASE" && "$LIST_RELEASES" != "true" ]]; then
    [[ -t 0 ]] || die "--release is required when standard input is not a terminal"
    guided="true"
    guided_intro
    check_for_bootstrap_update
  fi
  if [[ -z "$RELEASE" || "$RELEASE" == "latest" || "$LIST_RELEASES" == "true" ]]; then
    discovery_required="true"
    TEMP_DIRECTORY="$(mktemp -d)"
    ensure_credential
    discover_releases "$architecture"
  fi
  if [[ "$LIST_RELEASES" == "true" ]]; then
    printf 'Available stable TROP releases for %s:\n' "$architecture"
    print_available_releases 20
    clear_registry_credentials
    return 0
  fi
  if [[ "$RELEASE" == "latest" ]]; then
    RELEASE="$LATEST_RELEASE"
    info "Resolved latest stable release to $RELEASE"
  elif [[ "$guided" == "true" ]]; then
    ACTIVE_RELEASE="$(active_system_release)"
    if [[ -n "$ACTIVE_RELEASE" && "$ACTIVE_RELEASE" == "$LATEST_RELEASE" ]]; then
      info "TROP is already running the latest stable release: $ACTIVE_RELEASE"
      clear_registry_credentials
      return 0
    fi
    guided_setup "$architecture"
  fi
  finalize_options
  if [[ -n "$ACTIVE_RELEASE" ]]; then
    info "Upgrade: $ACTIVE_RELEASE -> $RELEASE"
  else
    info "Selected immutable release: $RELEASE"
  fi
  if is_system_destination; then
    info "Checking permission to use $INSTALL_ROOT"
    run_as_root true || die "sudo authorization is required; run 'sudo -v' first"
  fi
  if [[ "$discovery_required" != "true" ]]; then
    TEMP_DIRECTORY="$(mktemp -d)"
  fi
  prepare_staging
  install_zarf "$architecture"
  write_release_key
  ensure_credential
  registry_login
  pull_bootstrap_assets "$architecture" "$STAGING_DIRECTORY"
  pull_platform_package "$architecture" "$STAGING_DIRECTORY"
  clear_registry_credentials
  publish_destination
  rm -rf -- "$TEMP_DIRECTORY"
  TEMP_DIRECTORY=""
  offer_install "$architecture"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
