# internet-public-api

A curated mirror of **official OpenAPI specifications** for well-known public APIs —
Stripe, Twilio, PayPal, Square, and more — published to the
[Spec0 public registry](https://spec0.io), where each one gets a browsable reference,
version history with machine-generated changelogs, a quality score, and anonymous
MCP access so AI agents can read the real contract instead of guessing.

**Not affiliated.** The companies whose APIs are mirrored here have no relationship
with Spec0. Every listing links to the official source and carries the owner's name,
license, and documentation link. Nothing here is authored by us — we only mirror what
the API owners themselves publish, verbatim.

## Inclusion policy

An API is listed only if **all four** hold:

1. **Official source** — the spec document is published by the API owner (their GitHub
   org or official docs site). Third-party reconstructions and scrapes don't qualify.
2. **Redistributable license** — the repo/file the spec lives in carries a license that
   permits redistribution (MIT, Apache-2.0, CC, …), verified per entry and recorded in
   `manifest.json`. No license = not listed, no exceptions. (This is why some famous
   APIs are absent: several publish official specs with no license at all.)
3. **≤ 7 MB** bundled — larger documents are excluded.
4. **Quality gate** — the spec scores **≥ 90** against [`ruleset/spec0-baseline.yaml`](ruleset/spec0-baseline.yaml),
   a deliberately relaxed ruleset that measures structural soundness, not style. The
   registry enforces this server-side on every publish; a version that regresses below
   the bar is rejected and the last passing version stays live.

## How it works

`.github/workflows/mirror.yml` runs weekly: fetch each manifest entry's official spec →
skip if unchanged (content hash) → publish to the registry, which lints it against the
baseline ruleset, records the score, and generates a changelog against the previous
version. `workflow_dispatch` also offers a **calibrate** mode that only reports scores
and publishes nothing.

Each publish also records the upstream commit the snapshot was taken from, so a reader
looking at a changelog can open the change that caused it. That matters most when a diff
looks alarming: a spec owner correcting a response schema that was wrong produces the same
shape of diff as one genuinely breaking their API, and only the commit tells them apart.
Entries whose spec URL is not a file in a public repository — a release asset, a vendor
CDN — publish without a commit rather than with a guessed one.

## Propose an API

Open a PR adding an entry to `manifest.json`. The PR must show:
- the official source (owner's repo/site),
- the license (link to the LICENSE file),
- the bundled size.

The calibration run on your PR will show whether it clears the score gate.

**Is it your own (or proprietary) API?** Then this repo is the wrong door — mirrors are
only for specs the owner already publishes under a redistributable license. Instead,
[create an organisation on Spec0](https://app.spec0.io) and publish with
`spec0 publish`: you get your own registry page (public or unlisted), version history
with changelogs, and the same quality scoring — no PR required.

## Removal

If you own one of these APIs and want your spec removed, open an issue — we'll remove
it promptly, no questions asked.
