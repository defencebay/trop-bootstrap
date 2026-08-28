#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup_test_root() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup_test_root EXIT

# shellcheck source=trop-bootstrap.sh
source "$SCRIPT_DIR/trop-bootstrap.sh"

TEMP_DIRECTORY="$TEST_ROOT"

FAKE_BIN="$TEST_ROOT/bin"
CURL_ARGV_LOG="$TEST_ROOT/curl.argv"
CURL_STDIN_LOG="$TEST_ROOT/curl.stdin"
mkdir "$FAKE_BIN"
cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TROP_TEST_CURL_ARGV_LOG"
input="$(cat)"
printf '%s\n' "$input" >>"$TROP_TEST_CURL_STDIN_LOG"
case "$*" in
  *service/token*) printf '%s\n' '{"token":"short-lived-bearer"}' ;;
  *) printf '%s\n' '{"name":"test","tags":["r52-20260828"]}' ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"

export TROP_TEST_CURL_ARGV_LOG="$CURL_ARGV_LOG"
export TROP_TEST_CURL_STDIN_LOG="$CURL_STDIN_LOG"
PATH="$FAKE_BIN:$PATH"
HARBOR_USERNAME="robot\$trop-releases+external-test"
HARBOR_SECRET='secret-that-must-not-reach-argv'
[[ "$(registry_bearer_token 'trop-releases/amd64/trop-bootstrap')" == "short-lived-bearer" ]]
registry_tags 'trop-releases/amd64/trop-bootstrap' >/dev/null
if grep -q "$HARBOR_SECRET" "$CURL_ARGV_LOG"; then
  echo "ERROR: Harbor credential reached curl arguments" >&2
  exit 1
fi
grep -q "$HARBOR_SECRET" "$CURL_STDIN_LOG"
grep -q 'Authorization: Bearer short-lived-bearer' "$CURL_STDIN_LOG"

registry_tags() {
  case "$1" in
    trop-releases/amd64/trop-bootstrap)
      printf '%s\n' '{"name":"bootstrap","tags":["r9-20260101","r52-20260828","n75-20260828","r51-20260827","broken","r53-20260829"]}'
      ;;
    trop-releases/amd64/trop-platform)
      printf '%s\n' '{"name":"platform","tags":["r9-20260101","r52-20260828","r51-20260827","n75-20260828"]}'
      ;;
    *) return 1 ;;
  esac
}

discover_releases amd64
diff -u - <(printf '%s\n' "$AVAILABLE_RELEASES") <<'EOF'
r52-20260828
r51-20260827
r9-20260101
EOF
[[ "$LATEST_RELEASE" == "r52-20260828" ]]
release_is_available r51-20260827
if release_is_available r53-20260829; then
  echo "ERROR: incomplete release was offered" >&2
  exit 1
fi
if release_is_available n75-20260828; then
  echo "ERROR: nightly release was offered" >&2
  exit 1
fi

# shellcheck disable=SC2030 # main is intentionally isolated in a subshell
main_output="$(
  (
    RELEASE=""
    DESTINATION=""
    TOKEN_STDIN="false"
    FETCH_ONLY="false"
    LIST_RELEASES="false"
    EXISTING_CONFIG=""
    TEMP_DIRECTORY=""
    AVAILABLE_RELEASES=""
    LATEST_RELEASE=""
    ACTIVE_RELEASE=""
    require_command() { :; }
    detect_architecture() { printf '%s\n' amd64; }
    ensure_credential() { HARBOR_USERNAME="test"; HARBOR_SECRET="test-secret"; }
    prepare_staging() { :; }
    install_zarf() { :; }
    write_release_key() { :; }
    registry_login() { :; }
    pull_bootstrap_assets() { :; }
    pull_platform_package() { :; }
    publish_destination() { :; }
    offer_install() { :; }
    main --release latest --token-stdin --dest "$TEST_ROOT/latest-release"
  )
)"
grep -q 'Resolved latest stable release to r52-20260828' <<<"$main_output"
grep -q 'Selected immutable release: r52-20260828' <<<"$main_output"

list_output="$(
  (
    RELEASE=""
    LIST_RELEASES="false"
    TOKEN_STDIN="false"
    TEMP_DIRECTORY=""
    AVAILABLE_RELEASES=""
    LATEST_RELEASE=""
    require_command() { :; }
    detect_architecture() { printf '%s\n' amd64; }
    ensure_credential() { HARBOR_USERNAME="test"; HARBOR_SECRET="test-secret"; }
    main --list-releases --token-stdin
  )
)"
grep -q 'Available stable TROP releases for amd64' <<<"$list_output"
grep -q 'r52-20260828' <<<"$list_output"

active_system_release() {
  printf '%s\n' 'r52-20260828'
}

RELEASE="r52-20260828"
DESTINATION="/opt/trop/releases/$RELEASE"
if same_output="$(validate_release_transition 2>&1)"; then
  echo "ERROR: same-version transition was accepted" >&2
  exit 1
fi
grep -q 'already active' <<<"$same_output"

RELEASE="r51-20260827"
DESTINATION="/opt/trop/releases/$RELEASE"
if downgrade_output="$(validate_release_transition 2>&1)"; then
  echo "ERROR: downgrade transition was accepted" >&2
  exit 1
fi
grep -q 'automatic rollback is not supported' <<<"$downgrade_output"

RELEASE="r53-20260829"
DESTINATION="/opt/trop/releases/$RELEASE"
validate_release_transition
# shellcheck disable=SC2031 # this assertion is outside the isolated main test above
[[ "$ACTIVE_RELEASE" == "r52-20260828" ]]

RELEASE="r51-20260827"
DESTINATION="$TEST_ROOT/custom-release"
if custom_output="$(validate_release_transition 2>&1)"; then
  echo "ERROR: custom destination bypassed the system upgrade guard" >&2
  exit 1
fi
grep -q 'must be upgraded in /opt/trop/releases/r51-20260827' <<<"$custom_output"

echo "TROP-BOOTSTRAP-TEST: OK"
