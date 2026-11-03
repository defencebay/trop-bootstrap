#!/usr/bin/env python3
"""Exercise the real Zarf signature and cache checks without a cluster."""

import errno
import hashlib
import os
import pathlib
import pty
import select
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "trop-bootstrap.sh"
KEY_PASSWORD = "ops8-test-only-password"
RELEASE = "r69-20260924"
ARCH = "arm64" if os.uname().machine in ("aarch64", "arm64") else "amd64"
OTHER_ARCH = "amd64" if ARCH == "arm64" else "arm64"
ZARF = shutil.which("zarf")
COSIGN = shutil.which("cosign")
BASH = shutil.which("bash")


def run(command, *, cwd=None, env=None):
    return subprocess.run(
        command, cwd=cwd, env=env, text=True, capture_output=True, check=False
    )


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class BootstrapCacheTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not ZARF:
            raise RuntimeError("zarf v0.70.1 is required for signed fixture tests")
        if not COSIGN:
            raise RuntimeError("cosign is required to generate an ephemeral fixture key")
        version = run([ZARF, "version"])
        if version.returncode or version.stdout.strip() != "v0.70.1":
            raise RuntimeError(f"expected zarf v0.70.1: {version.stdout}{version.stderr}")
        cls.key_temp = tempfile.TemporaryDirectory(prefix="trop-bootstrap-key-")
        cls.signing_key = pathlib.Path(cls.key_temp.name) / "fixture.key"
        cls.public_key = pathlib.Path(cls.key_temp.name) / "fixture.pub"
        cls.untrusted_signing_key = pathlib.Path(cls.key_temp.name) / "untrusted.key"
        env = {**os.environ, "COSIGN_PASSWORD": KEY_PASSWORD}
        for key in (cls.signing_key, cls.untrusted_signing_key):
            result = run(
                [COSIGN, "generate-key-pair", "--output-key-prefix", str(key.with_suffix(""))],
                env=env,
            )
            if result.returncode:
                cls.key_temp.cleanup()
                raise RuntimeError(f"fixture key generation failed: {result.stderr}")

    @classmethod
    def tearDownClass(cls):
        cls.key_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trop-bootstrap-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = pathlib.Path(self.temp.name).resolve()
        self.cache = self.work / "cache"
        self.cache.mkdir()
        self.installer_log = self.work / "installer.log"
        self.backend = "python"
        self.installation_state = "fresh"
        self.system = self.work / "system"
        self.config = self.work / "config.yaml"
        self.bootstrap = self.work / "bootstrap.sh"
        self.bootstrap.write_text(BOOTSTRAP.read_text().replace(
            'readonly INSTALL_ROOT="/opt/trop"', f'readonly INSTALL_ROOT="{self.system}"'
        ).replace(
            'readonly SYSTEM_CONFIG_FILE="/etc/trop/zarf-config.yaml"',
            f'readonly SYSTEM_CONFIG_FILE="{self.config}"'
        ).replace(
            'readonly SYSTEM_ENCRYPTED_CONFIG_FILE="/etc/trop/zarf-config.enc.yaml"',
            f'readonly SYSTEM_ENCRYPTED_CONFIG_FILE="{self.work / "config.enc.yaml"}"'
        ))
        self.make_cache()

    def make_package(self, name, version, architecture, documentation=None, *, signer=None):
        variant = "untrusted" if signer else "trusted"
        source = self.work / f"source-{name}-{version}-{architecture}-{variant}"
        source.mkdir()
        lines = [
            "kind: ZarfPackageConfig",
            "metadata:",
            f"  name: {name}",
            f"  version: {version}",
            f"  architecture: {architecture}",
            "components:",
            "  - name: fixture",
            "    required: true",
        ]
        if documentation:
            lines.append("documentation:")
            for filename in documentation:
                shutil.copy2(documentation[filename], source / filename)
                lines.append(f"  {filename.replace('.', '-').replace('_', '-')}: {filename}")
        (source / "zarf.yaml").write_text("\n".join(lines) + "\n")
        output = self.work / f"output-{name}-{version}-{architecture}-{variant}"
        result = run(
            [
                ZARF, "package", "create", str(source), "--architecture", architecture,
                "--output", str(output), "--signing-key", str(signer or self.signing_key),
                "--signing-key-pass", KEY_PASSWORD, "--confirm", "--skip-sbom",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        package = output / f"zarf-package-{name}-{architecture}-{version}.tar.zst"
        self.assertTrue(package.is_file(), result.stdout + result.stderr)
        return package

    def make_cache(self):
        installer = self.cache / "trop-install.sh"
        installer.write_text(
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "case \"${1:-}\" in\n"
            "  setup|setup-go) ;;\n"
            "  installation-state) printf '%s\\n' \"${TEST_INSTALLATION_STATE:-fresh}\"; exit 0 ;;\n"
            "  deploy|update) [ -f \"${2:-}\" ] || exit 21 ;;\n"
            "  *) exit 22 ;;\n"
            "esac\n"
            "printf '%s\\n' \"$1\" >> \"$TEST_INSTALLER_LOG\"\n"
        )
        installer.chmod(0o755)
        shutil.copy2(self.public_key, self.cache / "trop-release.pub")
        (self.cache / "trop-standalone-tools.tar.gz").write_bytes(b"fixture tools\n")
        (self.cache / "trop-layout-contract").write_text("trop-system-layout-v1\n")
        runtime = self.cache / f"zarf_v0.70.1_Linux_{ARCH}"
        runtime.write_text("#!/bin/sh\nexit 0\n")
        runtime.chmod(0o755)
        init = self.cache / f"zarf-init-{ARCH}-v0.70.1.tar.zst"
        init.write_bytes(b"fixture init\n")
        common = [installer, self.cache / "trop-release.pub", self.cache / "trop-standalone-tools.tar.gz", self.cache / "trop-layout-contract"]
        architecture_files = [runtime, init]
        for filename, files in (("SHA256SUMS-common", common), (f"SHA256SUMS-{ARCH}", architecture_files)):
            (self.cache / filename).write_text(
                "".join(f"{digest(path)}  {path.name}\n" for path in files)
            )
        docs = {path.name: path for path in self.cache.iterdir() if path.is_file()}
        bootstrap = self.make_package("trop-bootstrap", RELEASE, "skeleton", docs)
        platform = self.make_package("trop-platform", RELEASE, ARCH)
        shutil.copy2(bootstrap, self.cache / bootstrap.name)
        shutil.copy2(platform, self.cache / platform.name)

    def environment(self):
        return {
            **os.environ,
            "TEST_BOOTSTRAP": str(self.bootstrap),
            "TEST_BACKEND": self.backend,
            "TEST_INSTALLATION_STATE": self.installation_state,
            "TEST_ZARF": ZARF,
            "TEST_PUBLIC_KEY": str(self.public_key),
            "TEST_RELEASE": RELEASE,
            "TEST_ARCH": ARCH,
            "TEST_INSTALLER_LOG": str(self.installer_log),
        }

    def verify_cache(self):
        temp = pathlib.Path(tempfile.mkdtemp(prefix="verification-", dir=self.work))
        shutil.copy2(self.public_key, temp / "trop-release.pub")
        code = (
            'source "$TEST_BOOTSTRAP"; '
            'RELEASE="$TEST_RELEASE"; BACKEND="$TEST_BACKEND"; DESTINATION="$PWD/cache"; '
            'TEMP_DIRECTORY="$TEST_VERIFY_TEMP"; ZARF_BIN="$TEST_ZARF"; '
            'verify_cached_destination "$TEST_ARCH"'
        )
        return run(
            ["bash", "-c", code], cwd=self.work,
            env={**self.environment(), "TEST_VERIFY_TEMP": str(temp)},
        )

    def main_code(self, *, auto_install, arguments='--release "$TEST_RELEASE" --dest cache --backend "$TEST_BACKEND"'):
        return (
            'source "$TEST_BOOTSTRAP"; '
            'install_zarf() { ZARF_BIN="$TEST_ZARF"; }; '
            'write_release_key() { cp "$TEST_PUBLIC_KEY" "$TEMP_DIRECTORY/trop-release.pub"; }; '
            'run_as_root() { "$@"; }; '
            f'INSTALL_AFTER_FETCH={"true" if auto_install else ""}; '
            f'main {arguments}'
        )

    def run_main_tty(self, *, auto_install=False, input_bytes=b"", code=None):
        code = code or self.main_code(auto_install=auto_install)
        pid, terminal = pty.fork()
        if pid == 0:
            os.chdir(self.work)
            os.execve(BASH, [BASH, "-c", code], self.environment())
        if input_bytes:
            os.write(terminal, input_bytes)
        output = bytearray()
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            readable, _, _ = select.select([terminal], [], [], 0.1)
            if readable:
                try:
                    data = os.read(terminal, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                output.extend(data)
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                break
        else:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
            self.fail("bootstrap did not finish within 20 seconds")
        try:
            _, status = os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        os.close(terminal)
        return os.waitstatus_to_exitcode(status), output.decode(errors="replace")

    def test_verified_cache_is_reused_from_relative_destination(self):
        result = self.verify_cache()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        code, output = self.run_main_tty(auto_install=True)
        self.assertEqual(code, 0, output)
        self.assertEqual(self.installer_log.read_text().splitlines(), ["setup", "deploy"])

    def test_missing_and_corrupt_cache_are_rejected(self):
        for name in ("trop-install.sh", f"zarf-package-trop-platform-{ARCH}-{RELEASE}.tar.zst"):
            with self.subTest(asset=name):
                target = self.cache / name
                saved = target.read_bytes()
                target.unlink()
                result = self.verify_cache()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                target.write_bytes(saved)
        target = self.cache / "trop-install.sh"
        target.write_text("#!/bin/sh\nexit 0\n")
        code, output = self.run_main_tty(auto_install=True)
        self.assertNotEqual(code, 0, output)
        self.assertFalse(self.installer_log.exists(), output)

    def test_signed_platform_identity_must_match_name_version_and_architecture(self):
        target = self.cache / f"zarf-package-trop-platform-{ARCH}-{RELEASE}.tar.zst"
        for name, version, architecture in (
            ("other-platform", RELEASE, ARCH),
            ("trop-platform", "r70-20260925", ARCH),
            ("trop-platform", RELEASE, OTHER_ARCH),
        ):
            with self.subTest(name=name, version=version, architecture=architecture):
                signed = self.make_package(name, version, architecture)
                shutil.copy2(signed, target)
                result = self.verify_cache()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("identity mismatch", result.stderr)

    def test_signed_bootstrap_identity_must_match_selected_release(self):
        target = self.cache / f"zarf-package-trop-bootstrap-skeleton-{RELEASE}.tar.zst"
        signed = self.make_package("trop-bootstrap", "r70-20260925", "skeleton")
        shutil.copy2(signed, target)
        result = self.verify_cache()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("identity mismatch", result.stderr)

    def test_untrusted_signature_blocks_installer_before_execution(self):
        target = self.cache / f"zarf-package-trop-bootstrap-skeleton-{RELEASE}.tar.zst"
        docs = {
            path.name: path for path in self.cache.iterdir()
            if path.is_file() and path.name not in (
                target.name, f"zarf-package-trop-platform-{ARCH}-{RELEASE}.tar.zst"
            )
        }
        signed = self.make_package(
            "trop-bootstrap", RELEASE, "skeleton", docs,
            signer=self.untrusted_signing_key,
        )
        shutil.copy2(signed, target)
        code, output = self.run_main_tty(auto_install=True)
        self.assertNotEqual(code, 0, output)
        self.assertIn("verification failed", output)
        self.assertFalse(self.installer_log.exists(), output)

    def test_fresh_pull_retains_the_verified_signed_bootstrap_package(self):
        wrapper = self.work / "zarf-pull-fixture"
        wrapper.write_text(
            "#!/usr/bin/env bash\n"
            "set -eu\n"
            "if [ \"${1:-}\" = package ] && [ \"${2:-}\" = pull ]; then\n"
            "  shift 2\n"
            "  output=\n"
            "  while [ \"$#\" -gt 0 ]; do\n"
            "    case \"$1\" in\n"
            "      --output-directory) output=$2; shift 2 ;;\n"
            "      *) shift ;;\n"
            "    esac\n"
            "  done\n"
            "  [ -n \"$output\" ] || exit 23\n"
            "  cp \"$TEST_SIGNED_BOOTSTRAP\" \"$output/\"\n"
            "else\n"
            "  exec \"$TEST_REAL_ZARF\" \"$@\"\n"
            "fi\n"
        )
        wrapper.chmod(0o755)
        temp = pathlib.Path(tempfile.mkdtemp(prefix="fresh-pull-", dir=self.work))
        shutil.copy2(self.public_key, temp / "trop-release.pub")
        stage = self.work / "staged"
        code = (
            'source "$TEST_BOOTSTRAP"; '
            'RELEASE="$TEST_RELEASE"; TEMP_DIRECTORY="$TEST_FRESH_TEMP"; '
            'REGISTRY_AUTH_DIRECTORY="$TEST_FRESH_TEMP"; ZARF_BIN="$TEST_ZARF_WRAPPER"; '
            'pull_bootstrap_assets "$TEST_ARCH" "$TEST_STAGE"'
        )
        signed = self.cache / f"zarf-package-trop-bootstrap-skeleton-{RELEASE}.tar.zst"
        env = {
            **self.environment(),
            "TEST_FRESH_TEMP": str(temp),
            "TEST_STAGE": str(stage),
            "TEST_ZARF_WRAPPER": str(wrapper),
            "TEST_SIGNED_BOOTSTRAP": str(signed),
            "TEST_REAL_ZARF": ZARF,
        }
        result = run(["bash", "-c", code], cwd=self.work, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((stage / signed.name).read_bytes(), signed.read_bytes())
        self.assertEqual((stage / "trop-install.sh").read_bytes(), (self.cache / "trop-install.sh").read_bytes())

    def test_cancel_does_not_execute_installer(self):
        code, output = self.run_main_tty(auto_install=False, input_bytes=b"n\n")
        self.assertEqual(code, 0, output)
        self.assertIn("Resume later", output)
        self.assertFalse(self.installer_log.exists(), output)

    def enable_go_cache(self):
        self.backend = "go"
        package = self.make_package("trop-platform-go", RELEASE, ARCH)
        shutil.copy2(package, self.cache / package.name)

    def test_go_cache_uses_setup_go_and_matching_signed_package(self):
        self.enable_go_cache()
        result = self.verify_cache()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        code, output = self.run_main_tty(auto_install=True)
        self.assertEqual(code, 0, output)
        self.assertEqual(self.installer_log.read_text().splitlines(), ["setup-go", "deploy"])

    def test_renamed_python_package_is_rejected_for_go(self):
        self.enable_go_cache()
        shutil.copy2(
            self.cache / f"zarf-package-trop-platform-{ARCH}-{RELEASE}.tar.zst",
            self.cache / f"zarf-package-trop-platform-go-{ARCH}-{RELEASE}.tar.zst",
        )
        code, output = self.run_main_tty(auto_install=True)
        self.assertNotEqual(code, 0, output)
        self.assertIn("identity mismatch", output)
        self.assertFalse(self.installer_log.exists(), output)

    def installed_fixture(self, backend):
        active = "r68-20260923"
        name = "trop-platform-go" if backend == "go" else "trop-platform"
        package = self.make_package(name, active, ARCH)
        directory = self.system / "releases" / active
        directory.mkdir(parents=True)
        shutil.copy2(package, directory / package.name)
        (self.system / "current").symlink_to(directory)
        self.config.write_text("package: {}\n")
        self.installation_state = "installed"
        return directory / package.name

    def test_installed_go_is_retained_without_backend_flag(self):
        self.enable_go_cache()
        self.installed_fixture("go")
        target = self.system / "releases" / RELEASE
        shutil.copytree(self.cache, target)
        code = self.main_code(auto_install=True, arguments='--release "$TEST_RELEASE"')
        status, output = self.run_main_tty(code=code)
        self.assertEqual(status, 0, output)
        self.assertIn("Keeping the installed variant: go", output)
        self.assertEqual(self.installer_log.read_text().splitlines(), ["update"])
        code = self.main_code(auto_install=False, arguments='--release "$TEST_RELEASE" --fetch-only')
        status, output = self.run_main_tty(code=code)
        self.assertEqual(status, 0, output)
        self.assertIn("Keeping the installed variant: go", output)
        self.assertIn("zarf-package-trop-platform-go-", output)
        self.assertEqual(self.installer_log.read_text().splitlines(), ["update"])

    def test_installed_python_rejects_explicit_go_before_installer(self):
        self.installed_fixture("python")
        for arguments in ('--release "$TEST_RELEASE" --backend go',
                          '--release "$TEST_RELEASE" --backend go --fetch-only'):
            with self.subTest(arguments=arguments):
                code = self.main_code(auto_install=True, arguments=arguments)
                status, output = self.run_main_tty(code=code)
                self.assertNotEqual(status, 0, output)
                self.assertIn("requires a separate migration", output)
                self.assertFalse(self.installer_log.exists(), output)

    def test_installed_python_keeps_legacy_upgrade_without_backend_flag(self):
        self.installed_fixture("python")
        shutil.copytree(self.cache, self.system / "releases" / RELEASE)
        code = self.main_code(auto_install=True, arguments='--release "$TEST_RELEASE"')
        status, output = self.run_main_tty(code=code)
        self.assertEqual(status, 0, output)
        self.assertIn("Keeping the installed variant: python", output)
        self.assertEqual(self.installer_log.read_text().splitlines(), ["update"])

    def test_corrupt_active_package_blocks_backend_detection(self):
        package = self.installed_fixture("go")
        package.write_bytes(b"corrupt package\n")
        status, output = self.run_main_tty(code=self.main_code(auto_install=True))
        self.assertNotEqual(status, 0, output)
        self.assertIn("verification failed", output)
        self.assertFalse(self.installer_log.exists(), output)

    def test_go_fetch_only_prints_setup_go_without_execution(self):
        self.enable_go_cache()
        self.installed_fixture("python")
        code = self.main_code(auto_install=False, arguments='--release "$TEST_RELEASE" --dest cache --backend go --fetch-only')
        status, output = self.run_main_tty(code=code)
        self.assertEqual(status, 0, output)
        self.assertIn("trop-install.sh setup-go", output)
        self.assertIn("zarf-package-trop-platform-go-", output)
        self.assertFalse(self.installer_log.exists(), output)

    def test_interactive_variant_selection_defaults_to_python_and_offers_go(self):
        code = 'source "$TEST_BOOTSTRAP"; select_backend "$TEST_ARCH"; printf "selected=%s\\n" "$BACKEND"'
        for answer, expected in ((b"\n", "python"), (b"2\n", "go"), (b"invalid\n2\n", "go")):
            with self.subTest(answer=answer):
                status, output = self.run_main_tty(code=code, input_bytes=answer)
                self.assertEqual(status, 0, output)
                self.assertIn(f"selected={expected}", output)

    def test_pull_requests_the_go_repository_and_checks_real_signed_identity(self):
        self.enable_go_cache()
        runtime = self.cache / f"zarf_v0.70.1_Linux_{ARCH}"
        runtime.write_text(
            '#!/usr/bin/env bash\nset -eu\n'
            '[[ "$1" == package && "$2" == pull ]]\n'
            '[[ "$3" == "oci://registry.trop.defencebay.com/trop-releases/$TEST_ARCH/trop-platform-go:$TEST_RELEASE" ]]\n'
            '[[ "$*" == *"--verify"* ]]\n'
            'cp "$TEST_GO_PACKAGE" "$TEST_PULL_DEST/"\n'
        )
        destination = self.work / "pull"
        destination.mkdir()
        shutil.copy2(runtime, destination / runtime.name)
        shutil.copy2(self.public_key, destination / "trop-release.pub")
        verification = self.work / "verify"
        verification.mkdir()
        shutil.copy2(self.public_key, verification / "trop-release.pub")
        env = {**self.environment(), "TEST_PULL_DEST": str(destination),
               "TEST_GO_PACKAGE": str(self.cache / f"zarf-package-trop-platform-go-{ARCH}-{RELEASE}.tar.zst"),
               "TEST_VERIFY_TEMP": str(verification)}
        code = ('source "$TEST_BOOTSTRAP"; BACKEND=go; RELEASE="$TEST_RELEASE"; '
                'ZARF_BIN="$TEST_ZARF"; TEMP_DIRECTORY="$TEST_VERIFY_TEMP"; '
                'REGISTRY_AUTH_DIRECTORY="$TEST_VERIFY_TEMP"; '
                'pull_platform_package "$TEST_ARCH" "$TEST_PULL_DEST"')
        result = run([BASH, "-c", code], env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((destination / pathlib.Path(env["TEST_GO_PACKAGE"]).name).is_file())


class BootstrapDiscoveryTests(unittest.TestCase):
    def shell(self, code):
        return run([BASH, "-c", 'source "$TEST_BOOTSTRAP"; ' + code],
                   env={**os.environ, "TEST_BOOTSTRAP": str(BOOTSTRAP)})

    def test_backend_discovery_intersects_only_matching_complete_stable_tags(self):
        for backend, expected in (("python", "r70-20260925"), ("go", "r69-20260924")):
            with self.subTest(backend=backend), tempfile.TemporaryDirectory() as directory:
                code = f'BACKEND={backend}; TEMP_DIRECTORY="{directory}"; ' + '''
registry_tags() {
  case "$1" in
    */trop-bootstrap) printf '%s' '{"tags":["r69-20260924","r70-20260925"]}' ;;
    */trop-platform) printf '%s' '{"tags":["r70-20260925","r71-20260926","latest"]}' ;;
    */trop-platform-go) printf '%s' '{"tags":["r69-20260924","r72-20260927","preview"]}' ;;
    *) return 1 ;;
  esac
}; discover_releases amd64; printf 'latest=%s\\n%s\\n' "$LATEST_RELEASE" "$AVAILABLE_RELEASES"
'''
                result = self.shell(code)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), f"latest={expected}\n{expected}")

    def test_missing_go_release_never_falls_back_to_python(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.shell(f'BACKEND=go; TEMP_DIRECTORY="{directory}"; ' + '''
registry_tags() {
  if [[ "$1" == */trop-platform-go ]]; then printf '%s' '{"tags":[]}';
  else printf '%s' '{"tags":["r70-20260925"]}'; fi
}; discover_releases amd64
''')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("no complete stable go releases", result.stderr)

    def test_invalid_variant_and_python_import_into_go_stop_before_setup(self):
        for code, error in (
            ('parse_arguments --backend invalid', '--backend must be python or go'),
            ('active_system_release() { :; }; parse_arguments --backend go --config old.yaml; select_backend amd64', 'imports Python configurations only'),
        ):
            with self.subTest(code=code):
                result = self.shell(code)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(error, result.stderr)


if __name__ == "__main__":
    unittest.main()
