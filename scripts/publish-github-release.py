#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


def get_github_token() -> str:
    env_tok = os.environ.get("GITHUB_TOKEN", "").strip()
    if env_tok:
        return env_tok

    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    proc = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        text=True,
        capture_output=True,
        check=True,
        env=env,
    )
    for line in proc.stdout.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1].strip()
    raise RuntimeError("Fant ingen GitHub-pålogging i git credential helper.")


def api_request(method: str, url: str, token: str, data: bytes | None = None, content_type: str = "application/json"):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "FlowFile-Release-Publisher")
    if data is not None:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read()
        return json.loads(raw.decode("utf-8")) if raw else {}


def main() -> int:
    parser = argparse.ArgumentParser(description="Publiser FlowFile-utgivelse til GitHub Releases")
    parser.add_argument("--repo", required=True, help="owner/repo, f.eks. nordiccraft/FlowFile")
    parser.add_argument("--recreate", action="store_true", help="Slett eksisterende release og git-tag før opprettelse")
    parser.add_argument("--tag", required=True, help="Tag-navn, f.eks. v1.0.0")
    parser.add_argument("--title", required=True, help="Tittel på utgivelsen")
    parser.add_argument("--notes", required=True, help="Endringsnotater (Release notes)")
    parser.add_argument("files", nargs="+", help="Filer som skal lastes opp til utgivelsen")
    args = parser.parse_args()

    token = get_github_token()
    base_api = f"https://api.github.com/repos/{args.repo}"

    # Check if tag release already exists
    release = None
    try:
        existing = api_request("GET", f"{base_api}/releases/tags/{args.tag}", token)
        if args.recreate:
            api_request("DELETE", f"{base_api}/releases/{existing['id']}", token)
            try:
                api_request("DELETE", f"{base_api}/git/refs/tags/{args.tag}", token)
            except urllib.error.HTTPError:
                pass
        else:
            release = api_request(
                "PATCH",
                f"{base_api}/releases/{existing['id']}",
                token,
                json.dumps({"name": args.title, "body": args.notes, "draft": False, "prerelease": False}).encode("utf-8"),
            )
    except urllib.error.HTTPError as e:
        if e.code != 404:
            err_body = e.read().decode("utf-8", errors="replace")
            print(f"GitHub API-feil ({e.code}): {err_body}", file=sys.stderr)
            return 1

    if release is None:
        payload = {
            "tag_name": args.tag,
            "target_commitish": "main",
            "name": args.title,
            "body": args.notes,
            "draft": False,
            "prerelease": False,
        }
        try:
            release = api_request("POST", f"{base_api}/releases", token, json.dumps(payload).encode("utf-8"))
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            print(f"Kunne ikke opprette GitHub Release ({e.code}): {err_body}", file=sys.stderr)
            return 1

    release_id = release["id"]
    existing_assets = {a["name"]: a["id"] for a in release.get("assets", [])}

    for filepath in args.files:
        if not os.path.isfile(filepath):
            continue
        filename = os.path.basename(filepath)
        if filename in existing_assets:
            api_request("DELETE", f"{base_api}/releases/assets/{existing_assets[filename]}", token)

        print(f"[upload] Uploading {filename}...")
        with open(filepath, "rb") as f:
            blob = f.read()
        upload_url = f"https://uploads.github.com/repos/{args.repo}/releases/{release_id}/assets?name={urllib.parse.quote(filename)}"
        api_request("POST", upload_url, token, data=blob, content_type="application/octet-stream")

    print(f"[done] Published on GitHub Releases: {release['html_url']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
