#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIRECTORY="$(mktemp -d)"
SERVER_PID=""
USERNAME="robot\$trop-releases+test-device"
SECRET='test-secret-0123456789abcdef'
RELEASE='test-release-1'

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_DIRECTORY"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

create_fixture() {
  local fixture="$TEST_DIRECTORY/fixture"
  mkdir -p "$fixture" "$TEST_DIRECTORY/bin"
  printf '#!/usr/bin/env bash\nprintf "x86_64\\n"\n' >"$TEST_DIRECTORY/bin/uname"
  chmod +x "$TEST_DIRECTORY/bin/uname"
  printf '#!/usr/bin/env bash\necho private installer\n' >"$fixture/trop-install.sh"
  printf 'test-public-key\n' >"$fixture/trop-release.pub"
  printf 'test-tools\n' >"$fixture/trop-standalone-tools.tar.gz"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/zarf_v0.70.1_Linux_amd64"
  printf 'test-init\n' >"$fixture/zarf-init-amd64-v0.70.1.tar.zst"
  chmod +x "$fixture/trop-install.sh" "$fixture/zarf_v0.70.1_Linux_amd64"
  (
    cd "$fixture"
    sha256sum trop-install.sh trop-release.pub trop-standalone-tools.tar.gz >SHA256SUMS-common
    sha256sum zarf_v0.70.1_Linux_amd64 zarf-init-amd64-v0.70.1.tar.zst >SHA256SUMS-amd64
  )
  printf '{"schema_version":1,"release":"%s","architecture":"amd64"}\n' "$RELEASE" >"$fixture/trop-bootstrap.json"
  (cd "$fixture" && COPYFILE_DISABLE=1 tar -czf "$TEST_DIRECTORY/bundle.tar.gz" -- *)
}

start_server() {
  local mode="$1" port_file="$TEST_DIRECTORY/port"
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f -- "$port_file"
  python3 "$REPO_ROOT/tests/fake_registry.py" \
    "$TEST_DIRECTORY/bundle.tar.gz" "$USERNAME" "$SECRET" "$mode" "$port_file" &
  SERVER_PID=$!
  for _ in {1..50}; do
    [[ -s "$port_file" ]] && break
    sleep 0.05
  done
  [[ -s "$port_file" ]] || fail "fake registry did not start"
  REGISTRY_PORT="$(cat "$port_file")"
}

create_token() {
  printf '%s\n' "$1" | "$REPO_ROOT/tools/create-token.sh" "$USERNAME" --secret-stdin
}

run_bootstrap() {
  local token="$1" destination="$2"
  printf '%s\n' "$token" |
    PATH="$TEST_DIRECTORY/bin:$PATH" \
    TROP_REGISTRY_HOST="127.0.0.1:$REGISTRY_PORT" \
    TROP_REGISTRY_SCHEME=http \
    "$REPO_ROOT/trop-bootstrap.sh" \
      --release "$RELEASE" \
      --dest "$destination" \
      --token-stdin \
      --bundle-only
}

create_fixture
start_server normal
token="$(create_token "$SECRET")"
run_bootstrap "$token" "$TEST_DIRECTORY/success"
[[ -x "$TEST_DIRECTORY/success/trop-install.sh" ]] || fail "private installer was not retrieved"
[[ -f "$TEST_DIRECTORY/success/trop-release.pub" ]] || fail "verification key was not retrieved"

if printf 'malformed\n' | "$REPO_ROOT/trop-bootstrap.sh" --release "$RELEASE" --dest "$TEST_DIRECTORY/malformed" --token-stdin --bundle-only >/dev/null 2>&1; then
  fail "malformed token was accepted"
fi

wrong_token="$(create_token 'wrong-secret-0123456789abcdef')"
if run_bootstrap "$wrong_token" "$TEST_DIRECTORY/wrong-secret" >/dev/null 2>&1; then
  fail "invalid Harbor secret was accepted"
fi

start_server bad-digest
if run_bootstrap "$token" "$TEST_DIRECTORY/bad-digest" >/dev/null 2>&1; then
  fail "corrupted OCI layer was accepted"
fi

echo "All bootstrap integration tests passed"
