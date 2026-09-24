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

An API is listed only if **all three** hold:

1. **Official source** — the spec document is published by the API owner (their GitHub
   org or official docs site). Third-party reconstructions and scrapes don't qualify.
2. **Redistributable license** — the repo/file the spec lives in carries a license that
   permits redistribution (MIT, Apache-2.0, CC, …), verified per entry and recorded in
   `manifest.json`. No license = not listed, no exceptions. (This is why some famous
   APIs are absent: several publish official specs with no license at all.)
3. **≤ 7 MB** bundled — larger documents are excluded.
4. **Scored, not gated** — every spec is linted against
   [`ruleset/spec0-baseline.yaml`](ruleset/spec0-baseline.yaml) on publish and the score is
   shown on the listing, along with how many findings are structural (a broken reference, an
   invalid schema) versus style (a missing description). A low score does not keep an API out.
   Showing what a published specification actually looks like is the point, and hiding the ones
   that score badly would make this a worse record of the real world, not a better one.

## Where a listing lives

Each entry is served at `/registry/{vendorSlug}/{slug}` — `/registry/stripe/api`,
`/registry/ups/shipping-api`, `/registry/google/maps-platform`. The URL names whose API it
is, and `/registry/stripe` is a page about the APIs Stripe publishes rather than a path
through a bucket of ours.

Two fields per entry decide it:

| Field | What it is |
|---|---|
| `vendorSlug` | The vendor's own slug — `stripe`, `google`, `ups`. Shared by every listing from the same company. |
| `slug` | The API, without repeating the vendor — `orders-api`, not `paypal-orders-api`. Plain `api` when the vendor publishes one API and calls it that. |

The pair has to be unique, and the publish run refuses to start if two entries claim the
same path or if any entry is missing a slug, a vendor, or a license.

Vendor organisations on the registry have no members and are never shown as verified —
domain verification is a claim about a publisher, and we are not the publisher. Each page
names the real owner and states that it is not affiliated.

## How it works

`.github/workflows/mirror.yml` runs weekly: fetch each manifest entry's official spec →
skip if unchanged (content hash) → publish to the registry, which lints it against the
baseline ruleset, records the score, and generates a changelog against the previous
version. `workflow_dispatch` also offers a **calibrate** mode that only reports scores
and publishes nothing.

## Propose an API

Open a PR adding an entry to `manifest.json`. The PR must show:
- the official source (owner's repo/site),
- the license (link to the LICENSE file),
- the bundled size,
- the `vendorSlug` and `slug` it should be served at.

The calibration run on your PR will report its score and findings.

**Is it your own (or proprietary) API?** Then this repo is the wrong door — mirrors are
only for specs the owner already publishes under a redistributable license. Instead,
[create an organisation on Spec0](https://app.spec0.io) and publish with
`spec0 publish`: you get your own registry page (public or unlisted), version history
with changelogs, and the same quality scoring — no PR required.

## Removal

If you own one of these APIs and want your spec removed, open an issue — we'll remove
it promptly, no questions asked.
