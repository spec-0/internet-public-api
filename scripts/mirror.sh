#!/usr/bin/env bash
# Mirror pipeline: fetch each manifest entry's official OpenAPI spec, gate it, and
# (in publish mode) publish it to the Spec0 public registry.
#
# Each listing is published under its vendor's own slug, so it is served at
# /registry/{vendorSlug}/{slug} — the URL names whose API it is. The token in SPEC0_TOKEN has to
# be one authorised to publish mirrors; an ordinary publishing token is refused with 403.
#
# Modes (env MODE):
#   calibrate — fetch + local lint only. Publishes NOTHING. Reports every score.
#   publish   — fetch + publish; the registry server is the authoritative gate
#               (it lints with the org's synced baseline ruleset and rejects < min score).
#
# Env: SPEC0_API_URL (required), SPEC0_TOKEN (required in publish mode),
#      MODE (calibrate|publish, default calibrate), MIN_SCORE (default 90).
set -euo pipefail

MODE="${MODE:-calibrate}"
MIN_SCORE="${MIN_SCORE:-90}"

# Publishing pace.
#
# A publish is not a cheap write. The registry parses the document, lints it, and does further
# work per version — including diffing the new version against the previous one, which holds two
# parsed specifications in memory at once. That work is queued, and the queue fills faster than
# it drains. Run flat out over a few dozen specifications and it is the queue, not any single
# document, that exhausts the server.
#
# So publish in small batches and pause between them. A batch is capped by BOTH count and total
# bytes, whichever fills first: five specifications is a very different amount of work depending
# on which five, and the byte cap is what actually tracks the cost.
#
# Re-publishing an unchanged document short-circuits on the server and costs almost nothing, so
# a steady-state weekly run rarely pauses. This matters on the first run over a batch of new
# listings — the run that has caused trouble before.
BATCH_SIZE="${BATCH_SIZE:-5}"
BATCH_MAX_BYTES="${BATCH_MAX_BYTES:-$((8 * 1024 * 1024))}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-20}"

batch_count=0
batch_bytes=0

# Called with the size of the spec about to be published, and pauses BEFORE adding it when it
# would overflow. Checking afterwards would let one large document carry a batch well past the
# cap — the first three specs in this manifest are 10 MB between them.
cool_down_before() {
  next_bytes="$1"
  [ "$batch_count" -eq 0 ] && return 0
  if [ "$batch_count" -ge "$BATCH_SIZE" ] || [ $((batch_bytes + next_bytes)) -gt "$BATCH_MAX_BYTES" ]; then
    echo "Batch complete ($batch_count specs, $batch_bytes bytes) — pausing ${COOLDOWN_SECONDS}s."
    sleep "$COOLDOWN_SECONDS"
    batch_count=0
    batch_bytes=0
  fi
  return 0
}
RULESET="ruleset/spec0-baseline.yaml"
MANIFEST="manifest.json"
MAX_BYTES=$((7 * 1024 * 1024))
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

fail_count=0
reject_count=0

echo "## Mirror run — mode: \`$MODE\`, min score: $MIN_SCORE" >> "$SUMMARY"
echo "" >> "$SUMMARY"
echo "| API | Fetched | Size | Score | Result |" >> "$SUMMARY"
echo "|---|---|---|---|---|" >> "$SUMMARY"

row() { echo "| $1 | $2 | $3 | $4 | $5 |" >> "$SUMMARY"; }

# Publish mode: sync the baseline ruleset to the org first, so the server's gate
# scores with the exact ruleset in this repo.
if [ "$MODE" = "publish" ]; then
  : "${SPEC0_TOKEN:?SPEC0_TOKEN is required in publish mode}"

  # Nothing is published without a licence and a vendor. The licence is the reason we are
  # allowed to republish the document at all; the vendor slug is the first half of the URL the
  # listing is served at, and a missing one would quietly publish into the wrong place.
  missing=$(jq -r '.apis[]
      | select((.license // "") == "" or (.vendorSlug // "") == "" or (.slug // "") == "")
      | .title' "$MANIFEST")
  if [ -n "$missing" ]; then
    echo "Manifest entries missing license, vendorSlug or slug:" >&2
    echo "$missing" >&2
    exit 1
  fi

  dupes=$(jq -r '[.apis[] | "\(.vendorSlug)/\(.slug)"] | group_by(.) | map(select(length > 1))
      | flatten | unique | .[]' "$MANIFEST")
  if [ -n "$dupes" ]; then
    echo "Two manifest entries claim the same registry path:" >&2
    echo "$dupes" >&2
    exit 1
  fi
  sync_status=$(curl -sS -o "$WORKDIR/ruleset-resp.json" -w "%{http_code}" \
    -X PUT "$SPEC0_API_URL/api/v1/public/spectral/ruleset" \
    -H "Authorization: Bearer $SPEC0_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$(jq -n --rawfile y "$RULESET" '{rulesetYaml: $y}')")
  if [ "$sync_status" != "200" ]; then
    echo "Ruleset sync failed (HTTP $sync_status): $(cat "$WORKDIR/ruleset-resp.json")" >&2
    echo "" >> "$SUMMARY"
    echo "**Ruleset sync failed (HTTP $sync_status)** — aborting before any publish." >> "$SUMMARY"
    exit 1
  fi
  echo "Ruleset synced to org."
fi

count=$(jq '.apis | length' "$MANIFEST")
for i in $(seq 0 $((count - 1))); do
  entry="$(jq -c ".apis[$i]" "$MANIFEST")"
  slug=$(jq -r '.slug' <<<"$entry")
  vendor_slug=$(jq -r '.vendorSlug' <<<"$entry")
  vendor_name=$(jq -r '.vendorName // .company' <<<"$entry")
  vendor_website=$(jq -r '.vendorWebsite // empty' <<<"$entry")
  title=$(jq -r '.title' <<<"$entry")
  company=$(jq -r '.company' <<<"$entry")
  spec_url=$(jq -r '.specUrl' <<<"$entry")
  license=$(jq -r '.license' <<<"$entry")
  docs_url=$(jq -r '.docsUrl' <<<"$entry")
  description=$(jq -r '.description' <<<"$entry")
  # `slug` is unique per vendor, not globally ("api" is several vendors' slug), so the
  # working files are keyed on the pair.
  entry_key="$vendor_slug-$slug"
  spec_file="$WORKDIR/$entry_key.spec"

  if ! curl -sSL --fail --max-time 120 "$spec_url" -o "$spec_file"; then
    row "$vendor_slug/$slug" "❌ fetch failed" "-" "-" "error"
    fail_count=$((fail_count + 1))
    continue
  fi

  size_bytes=$(wc -c < "$spec_file" | tr -d ' ')
  size_mb=$(awk "BEGIN {printf \"%.2f\", $size_bytes / 1048576}")
  if [ "$size_bytes" -gt "$MAX_BYTES" ]; then
    row "$vendor_slug/$slug" "✅" "${size_mb} MB" "-" "skipped — exceeds 7 MB cap"
    continue
  fi

  if [ "$MODE" = "calibrate" ]; then
    set +e
    lint_json=$(spec0 lint "$spec_file" --ruleset "$RULESET" --format json 2>/dev/null)
    lint_exit=$?
    set -e
    score=$(jq -r '.score // .summary.score // empty' <<<"$lint_json" 2>/dev/null || true)
    [ -n "$score" ] || score="? (exit $lint_exit)"
    verdict="below $MIN_SCORE ❌"
    if [ -n "${score%%[!0-9]*}" ] && [ "${score%%.*}" -ge "$MIN_SCORE" ] 2>/dev/null; then
      verdict="clears $MIN_SCORE ✅"
    fi
    row "$vendor_slug/$slug" "✅" "${size_mb} MB" "$score" "$verdict"
    continue
  fi

  # publish mode — the server is the authoritative gate
  git_sha=$(shasum -a 256 "$spec_file" 2>/dev/null | cut -c1-64 || sha256sum "$spec_file" | cut -c1-64)

  # Version tag = the producer's own info.version (Stripe's date tags, Adyen's service
  # majors, ...), falling back to today's date when the spec doesn't carry one. If the
  # producer changed content without bumping their version, the tag collides (409) and
  # we retry once with a content-hash suffix so the new snapshot still lands.
  tag=$(python3 scripts/spec_version.py "$spec_file" || true)
  [ -n "$tag" ] || tag=$(date -u +%Y-%m-%d)

  publish_attempt() {
    local attempt_tag="$1"
    body=$(jq -n \
      --arg slug "$slug" --arg title "$title" --arg desc "$description" \
      --arg sha "$git_sha" --arg owner "$company" --arg url "$spec_url" \
      --arg lic "$license" --arg docs "$docs_url" --arg tag "$attempt_tag" \
      --arg vslug "$vendor_slug" --arg vname "$vendor_name" --arg vsite "$vendor_website" \
      --rawfile spec "$spec_file" \
      --arg notes "Mirrored from the official $company OpenAPI specification (their version: $attempt_tag)." \
      '{apiSlug: $slug, title: $title, description: $desc, visibility: "PUBLISHED",
        version: $tag, openapiSpec: $spec, gitSha: $sha, releaseNotes: $notes,
        source: "MIRRORED", originUrl: $url, originOwner: $owner,
        originLicense: $lic, originDocsUrl: $docs,
        vendorSlug: $vslug, vendorName: $vname}
       + (if $vsite == "" then {} else {vendorWebsiteUrl: $vsite} end)')
    curl -sS -o "$WORKDIR/$entry_key.resp.json" -w "%{http_code}" --max-time 300 \
      -X POST "$SPEC0_API_URL/api/v1/public/apis" \
      -H "Authorization: Bearer $SPEC0_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary "@/dev/stdin" <<<"$body"
  }

  cool_down_before "$size_bytes"
  batch_count=$((batch_count + 1))
  batch_bytes=$((batch_bytes + size_bytes))

  http_status=$(publish_attempt "$tag")
  if [ "$http_status" = "409" ]; then
    tag="$tag-${git_sha:0:7}"
    http_status=$(publish_attempt "$tag")
  fi

  case "$http_status" in
    200)
      version=$(jq -r '.version // "-"' "$WORKDIR/$entry_key.resp.json")
      score=$(jq -r '.lintScore // "-"' "$WORKDIR/$entry_key.resp.json")
      created=$(jq -r '.versionCreated' "$WORKDIR/$entry_key.resp.json")
      result="published v$version"
      [ "$created" = "false" ] && result="unchanged (v$version)"
      row "$vendor_slug/$slug" "✅" "${size_mb} MB" "$score" "$result ✅"
      ;;
    422)
      detail=$(jq -r '.detail // .message // .title // "rejected"' "$WORKDIR/$entry_key.resp.json" | head -c 160)
      row "$vendor_slug/$slug" "✅" "${size_mb} MB" "-" "rejected by gate: $detail ❌"
      reject_count=$((reject_count + 1))
      ;;
    *)
      detail=$(head -c 160 "$WORKDIR/$entry_key.resp.json" | tr -d '\n|')
      row "$vendor_slug/$slug" "✅" "${size_mb} MB" "-" "HTTP $http_status: $detail ❌"
      fail_count=$((fail_count + 1))
      ;;
  esac
done

echo "" >> "$SUMMARY"
echo "Errors: $fail_count · Gate rejections: $reject_count" >> "$SUMMARY"

# Calibrate mode never fails on scores — measuring them is the point.
# Publish mode fails loudly on any error or rejection so the schedule alerts.
if [ "$MODE" = "publish" ] && [ $((fail_count + reject_count)) -gt 0 ]; then
  exit 1
fi
[ "$fail_count" -gt 0 ] && exit 1
exit 0
