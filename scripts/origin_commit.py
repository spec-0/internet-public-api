#!/usr/bin/env python3
"""Print the upstream commit a spec URL currently resolves to, or nothing.

    <sha><TAB><commit web url>

Used by mirror.sh so each published snapshot records the commit it was taken from.
Without it the registry has only a hash of the spec file's bytes, which tells a
reader that something changed but not what — and a diff against the previous
snapshot cannot tell a real breaking change from the owner correcting a spec that
was wrong. The commit is what makes the difference checkable in one click.

Handles the raw.githubusercontent.com form, which is how a spec that actually
moves is published:

    https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path...>

Anything else — a release asset pinned to a tag, a vendor's own CDN — prints
nothing, and the entry publishes without a commit. That is deliberate: a link we
had to guess at is worse than no link.

Reads GITHUB_TOKEN when present, purely for the API rate limit.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"


def resolve(spec_url):
    parts = urllib.parse.urlparse(spec_url)
    if parts.netloc != "raw.githubusercontent.com":
        return None

    # /<owner>/<repo>/<ref>/<path...>
    segments = [s for s in parts.path.split("/") if s]
    if len(segments) < 4:
        return None
    owner, repo, ref = segments[0], segments[1], segments[2]
    path = "/".join(segments[3:])

    query = urllib.parse.urlencode({"path": path, "sha": ref, "per_page": 1})
    request = urllib.request.Request(
        f"{API}/repos/{owner}/{repo}/commits?{query}",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "spec0-mirror",
        },
    )
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(request, timeout=30) as response:
        commits = json.load(response)

    if not commits:
        return None
    sha = commits[0].get("sha")
    if not sha:
        return None
    return sha, f"https://github.com/{owner}/{repo}/commit/{sha}"


if __name__ == "__main__":
    try:
        found = resolve(sys.argv[1])
    except (urllib.error.URLError, ValueError, KeyError, IndexError, TimeoutError):
        # Never fail the run over provenance: the snapshot is still worth publishing.
        found = None
    if found:
        print(f"{found[0]}\t{found[1]}")
