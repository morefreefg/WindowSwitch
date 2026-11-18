#!/usr/bin/env python3
"""Keep the current download and remove superseded WindowSwitch binary packages."""
import argparse
import json
import os
import re
import subprocess
import urllib.request
import xml.etree.ElementTree as ET

REPO = "morefreefg/WindowSwitch"
API = f"repos/{REPO}"
FEED = "https://morefreefg.github.io/WindowSwitch/appcast.xml"


def api(path, *, pages=False):
    command = ["gh", "api"]
    if pages:
        command += ["--paginate", "--slurp"]
    return json.loads(subprocess.check_output(command + [f"{API}/{path}"]))


def remove(path, apply):
    print(("Deleting " if apply else "Would delete ") + path, flush=True)
    if apply:
        subprocess.run(["gh", "api", "--method", "DELETE", f"{API}/{path}"], check=True)


def superseded_artifacts(completed, published_build):
    # Upload IDs reflect when a runner finished uploading. Parallel runs can finish out of order.
    successful = [(number, artifact_id) for number, artifact_id, success in completed
                  if success and number >= published_build]
    keep = max(successful, default=None)
    return [artifact_id for number, artifact_id, _ in completed
            if number < published_build or (keep is not None and number <= keep[0] and artifact_id != keep[1])]


def prune_artifacts(apply, published_build):
    pages = api("actions/artifacts?name=WindowSwitch-universal&per_page=100", pages=True)
    completed = []
    for page in pages:
        for artifact in page["artifacts"]:
            if artifact["name"] != "WindowSwitch-universal" or artifact["expired"] or not artifact.get("workflow_run"):
                continue
            run = api(f"actions/runs/{artifact['workflow_run']['id']}")
            if (run["path"] == ".github/workflows/build.yml" and run["status"] == "completed"
                    and run["event"] != "pull_request"):
                completed.append((run["run_number"], artifact["id"], run["conclusion"] == "success"))
    for artifact_id in superseded_artifacts(completed, published_build):
        remove(f"actions/artifacts/{artifact_id}", apply)


def version(tag):
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-rc[.-](\d+))?", tag)
    if not match:
        return None
    major, minor, patch, rc = match.groups()
    return int(major), int(minor), int(patch), rc is None, int(rc or 0)


def prune_releases(apply):
    latest = api("releases/latest")
    tag = latest["tag_name"]
    current = version(tag)
    if not current or not current[3] or latest["draft"] or latest["prerelease"]:
        raise RuntimeError("No current stable release")
    assets = {a["name"]: a for a in latest["assets"]}
    dmg = assets[f"WindowSwitch-{tag[1:]}-universal.dmg"]
    metadata = assets[f"WindowSwitch-{tag[1:]}-universal.update.json"]
    with urllib.request.urlopen(metadata["browser_download_url"], timeout=30) as response:
        update = json.load(response)
    if update["url"] != dmg["browser_download_url"] or int(update["length"]) != dmg["size"] or dmg["size"] <= 0:
        raise RuntimeError("Latest update manifest does not match the DMG")
    with urllib.request.urlopen(FEED, timeout=30) as response:
        enclosures = ET.parse(response).findall("./channel/item/enclosure")
    if not any(e.get("url") == update["url"] and
               e.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature") == update["edSignature"]
               for e in enclosures):
        raise RuntimeError("Latest release has not reached the public update feed")
    referenced = {e.get("url") for e in enclosures}
    for page in api("releases?per_page=100", pages=True):
        for release in page:
            old = version(release["tag_name"])
            if release["draft"] or not old or old >= current:
                continue
            if any(asset["browser_download_url"] in referenced for asset in release["assets"]):
                continue
            remove(f"releases/{release['id']}", apply)
    print(f"Retained {tag}")
    return int(update["buildVersion"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if os.environ.get("GITHUB_REPOSITORY", REPO) != REPO:
        raise SystemExit("Unexpected repository")
    published_build = prune_releases(args.apply)
    prune_artifacts(args.apply, published_build)
