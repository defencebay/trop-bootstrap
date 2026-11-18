#!/usr/bin/env python3
"""Validate launcher versions and publish their tested files as one release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ("trop-bootstrap", "trop-bootstrap-go")
VERSION_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def version():
    versions = [
        subprocess.check_output(["bash", ROOT / f"{name}.sh", "--version"], text=True)
        for name in ASSETS
    ]
    tag = "v" + versions[0].removesuffix("\n")
    if versions != [f"{tag[1:]}\n"] * len(ASSETS) or not VERSION_TAG.fullmatch(tag):
        raise ValueError(f"Expected matching stable launcher versions, got {versions!r}")
    return tag


def api(endpoint, *args):
    output = subprocess.check_output(["gh", "api", endpoint, *args])
    return json.loads(output) if output else None


def upload(url, name, data):
    request = Request(
        f"{url}?name={name}",
        data=data,
        headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Content-Type": "application/octet-stream",
        },
    )
    with urlopen(request, timeout=60) as response:
        if response.status != 201:
            raise ValueError(f"Unexpected upload response for {name}: {response.status}")


def version_key(tag):
    return tuple(map(int, tag[1:].split(".")))


def tag_ref(repo, tag):
    refs = api(f"repos/{repo}/git/matching-refs/tags/{tag}")
    return next((ref for ref in refs if ref["ref"] == f"refs/tags/{tag}"), None)


def publish(repo, sha, tag):
    if subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() != sha:
        raise ValueError("Checkout does not match the tested commit")
    if version() != tag:
        raise ValueError("Checkout version does not match the tested version")

    releases_url = f"repos/{repo}/releases"
    releases = [
        release
        for page in api(f"{releases_url}?per_page=100", "--paginate", "--slurp")
        for release in page
    ]
    if any(
        not release["draft"]
        and VERSION_TAG.fullmatch(release["tag_name"])
        and version_key(release["tag_name"]) >= version_key(tag)
        for release in releases
    ):
        print(f"{tag} is already published or superseded")
        return

    marker = f"<!-- bootstrap-ci: {sha} -->"
    notes = f"Standalone launchers for the Python and Go backends.\n\n{marker}"
    drafts = [release for release in releases if release["tag_name"] == tag]
    if len(drafts) > 1 or any(
        draft["target_commitish"] != sha or draft["body"] != notes for draft in drafts
    ):
        raise ValueError(f"Conflicting release for {tag}")

    ref = tag_ref(repo, tag)
    if ref and ref["object"]["sha"] != sha:
        raise ValueError(f"Conflicting existing tag {tag}")
    if not ref:
        try:
            api(
                f"repos/{repo}/git/refs", "-X", "POST", "-f", f"ref=refs/tags/{tag}",
                "-f", f"sha={sha}",
            )
        except subprocess.CalledProcessError:
            head = api(f"repos/{repo}/git/ref/heads/main")["object"]["sha"]
            if head == sha:
                raise

            def launcher_blobs(commit):
                tree = api(f"repos/{repo}/git/trees/{commit}")["tree"]
                return {entry["path"]: entry["sha"] for entry in tree
                        if entry["path"] in {f"{name}.sh" for name in ASSETS}}

            tested = launcher_blobs(sha)
            if len(tested) != len(ASSETS) or tested != launcher_blobs(head):
                raise
            comparison = api(f"repos/{repo}/compare/{sha}...{head}")
            if comparison["status"] != "ahead":
                raise
            print(f"{tag}: main advanced with identical launchers; the newer run can publish")
            return
        ref = tag_ref(repo, tag)
        if not ref or ref["object"]["sha"] != sha:
            raise ValueError(f"{tag} does not point to the tested commit")

    draft = drafts[0] if drafts else api(
        releases_url, "-X", "POST", "-f", f"tag_name={tag}",
        "-f", f"target_commitish={sha}", "-f", f"name=TROP Bootstrap {tag}",
        "-f", f"body={notes}", "-F", "draft=true",
    )
    release_url = f"{releases_url}/{draft['id']}"
    upload_url = draft["upload_url"].split("{", 1)[0]
    contents = {name: (ROOT / f"{name}.sh").read_bytes() for name in ASSETS}
    expected = {
        name: f"sha256:{hashlib.sha256(data).hexdigest()}" for name, data in contents.items()
    }

    def verified_assets(*, repair=False):
        release = api(release_url)
        if (
            not release["draft"] or release["tag_name"] != tag
            or release["target_commitish"] != sha or release["body"] != notes
        ):
            raise ValueError(f"Release {tag} changed during publication")
        seen = set()
        verified = set()
        for asset in release["assets"]:
            name = asset["name"]
            if name not in expected or name in seen:
                raise ValueError(f"Unexpected asset in {tag}: {name}")
            seen.add(name)
            state = asset["state"]
            if state == "uploaded" and asset["digest"] == expected[name]:
                verified.add(name)
            elif repair and state in {"open", "starter", "uploaded"}:
                api(f"{releases_url}/assets/{asset['id']}", "-X", "DELETE")
            else:
                raise ValueError(f"Unexpected asset in {tag}: {name}")
        return verified

    existing = verified_assets(repair=True)
    for name in ASSETS:
        if name not in existing:
            upload(upload_url, name, contents[name])

    if verified_assets() != set(ASSETS):
        raise ValueError(f"Both launcher assets must be verified before publishing {tag}")

    ref = tag_ref(repo, tag)
    if not ref or ref["object"]["sha"] != sha:
        raise ValueError(f"{tag} does not point to the tested commit")

    release = api(release_url, "-X", "PATCH", "-F", "draft=false")
    print(release["html_url"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", metavar="TAG")
    args = parser.parse_args()
    if args.publish:
        publish(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"], args.publish)
    else:
        print(version())


if __name__ == "__main__":
    main()
