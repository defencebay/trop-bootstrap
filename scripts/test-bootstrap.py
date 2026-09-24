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
        self.work = pathlib.Path(self.temp.name)
        self.cache = self.work / "cache"
        self.cache.mkdir()
        self.installer_log = self.work / "installer.log"
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
            "  setup) ;;\n"
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
            "TEST_BOOTSTRAP": str(BOOTSTRAP),
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
            'RELEASE="$TEST_RELEASE"; DESTINATION="$PWD/cache"; '
            'TEMP_DIRECTORY="$TEST_VERIFY_TEMP"; ZARF_BIN="$TEST_ZARF"; '
            'verify_cached_destination "$TEST_ARCH"'
        )
        return run(
            ["bash", "-c", code], cwd=self.work,
            env={**self.environment(), "TEST_VERIFY_TEMP": str(temp)},
        )

    def main_code(self, *, auto_install):
        return (
            'source "$TEST_BOOTSTRAP"; '
            'install_zarf() { ZARF_BIN="$TEST_ZARF"; }; '
            'write_release_key() { cp "$TEST_PUBLIC_KEY" "$TEMP_DIRECTORY/trop-release.pub"; }; '
            f'INSTALL_AFTER_FETCH={"true" if auto_install else ""}; '
            'main --release "$TEST_RELEASE" --dest cache'
        )

    def run_main_tty(self, *, auto_install, input_bytes=b""):
        code = self.main_code(auto_install=auto_install)
        pid, terminal = pty.fork()
        if pid == 0:
            os.chdir(self.work)
            os.execve("/bin/bash", ["bash", "-c", code], self.environment())
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


if __name__ == "__main__":
    unittest.main()
