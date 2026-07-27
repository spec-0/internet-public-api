#!/usr/bin/env bash
# Mirror pipeline: fetch each manifest entry's official OpenAPI spec, gate it, and
# (in publish mode) publish it to the Spec0 public registry.
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
  title=$(jq -r '.title' <<<"$entry")
  company=$(jq -r '.company' <<<"$entry")
  spec_url=$(jq -r '.specUrl' <<<"$entry")
  license=$(jq -r '.license' <<<"$entry")
  docs_url=$(jq -r '.docsUrl' <<<"$entry")
  description=$(jq -r '.description' <<<"$entry")
  spec_file="$WORKDIR/$slug.spec"

  if ! curl -sSL --fail --max-time 120 "$spec_url" -o "$spec_file"; then
    row "$slug" "❌ fetch failed" "-" "-" "error"
    fail_count=$((fail_count + 1))
    continue
  fi

  size_bytes=$(wc -c < "$spec_file" | tr -d ' ')
  size_mb=$(awk "BEGIN {printf \"%.2f\", $size_bytes / 1048576}")
  if [ "$size_bytes" -gt "$MAX_BYTES" ]; then
    row "$slug" "✅" "${size_mb} MB" "-" "skipped — exceeds 7 MB cap"
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
    row "$slug" "✅" "${size_mb} MB" "$score" "$verdict"
    continue
  fi

  # publish mode — the server is the authoritative gate
  git_sha=$(shasum -a 256 "$spec_file" 2>/dev/null | cut -c1-64 || sha256sum "$spec_file" | cut -c1-64)
  body=$(jq -n \
    --arg slug "$slug" --arg title "$title" --arg desc "$description" \
    --arg sha "$git_sha" --arg owner "$company" --arg url "$spec_url" \
    --arg lic "$license" --arg docs "$docs_url" \
    --rawfile spec "$spec_file" \
    --arg notes "Mirrored from the official $company OpenAPI specification." \
    '{apiSlug: $slug, title: $title, description: $desc, visibility: "PUBLISHED",
      semver: true, openapiSpec: $spec, gitSha: $sha, releaseNotes: $notes,
      source: "MIRRORED", originUrl: $url, originOwner: $owner,
      originLicense: $lic, originDocsUrl: $docs}')

  http_status=$(curl -sS -o "$WORKDIR/$slug.resp.json" -w "%{http_code}" --max-time 300 \
    -X POST "$SPEC0_API_URL/api/v1/public/apis" \
    -H "Authorization: Bearer $SPEC0_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "@/dev/stdin" <<<"$body")

  case "$http_status" in
    200)
      version=$(jq -r '.version // "-"' "$WORKDIR/$slug.resp.json")
      score=$(jq -r '.lintScore // "-"' "$WORKDIR/$slug.resp.json")
      created=$(jq -r '.versionCreated' "$WORKDIR/$slug.resp.json")
      result="published v$version"
      [ "$created" = "false" ] && result="unchanged (v$version)"
      row "$slug" "✅" "${size_mb} MB" "$score" "$result ✅"
      ;;
    422)
      detail=$(jq -r '.detail // .message // .title // "rejected"' "$WORKDIR/$slug.resp.json" | head -c 160)
      row "$slug" "✅" "${size_mb} MB" "-" "rejected by gate: $detail ❌"
      reject_count=$((reject_count + 1))
      ;;
    *)
      detail=$(head -c 160 "$WORKDIR/$slug.resp.json" | tr -d '\n|')
      row "$slug" "✅" "${size_mb} MB" "-" "HTTP $http_status: $detail ❌"
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
