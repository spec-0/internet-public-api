# Baseline calibration record

The `spec0-baseline` ruleset is calibrated against this corpus using the **same lint
engine the registry runs server-side** (the CLI's local linter is a different engine
and was not used). Method: score every manifest entry, inspect what drags scores,
turn off rules that punish deliberate API-design choices rather than structural
soundness, repeat. Three iterations, 2026-07-27:

| API | v1 (raw) | v2 | v3 (shipped) | Remaining errors (v3) |
|---|---|---|---|---|
| stripe-api | 70 | 82 | **99** | — |
| paypal-orders-api | 82 | 97 | **99** | — |
| square-api | 29 | 97 | **97** | 2 schema |
| adyen-checkout-api | 77 | 96 | **97** | 2 schema |
| twilio-api | 73 | 88 | **99** | — |
| sendgrid-mail-api | 95 | 98 | **98** | 1 schema |
| mailgun-api | 77 | 90 | **99** | — |
| intercom-api | 63 | 85 | **97** | 2 path-params |
| ups-shipping-api | 15 | 78 | **94** | 4 schema, 2 path-params |
| discord-api | 79 | 90 | **99** | — |
| amazon-selling-partner-orders | 72 | 100 | **100** | — |
| okta-management-api | 65 | 98 | **98** | 1 schema |
| google-maps-platform | 70 | 97 | **97** | — |
| openai-api *(excluded)* | 33 | 46 | 56 | 107+ schema |

## What the iterations removed (and why)

- **v1 → v2**: engine-specific style rules that punish deliberate design choices —
  `camel-case-properties` (flagged Stripe's intentional snake_case 8,242 times),
  `description-duplication`, `oas3-missing-example`, `no-$ref-siblings`.
- **v2 → v3**: the remaining style opinions — `paths-kebab-case`, `no-request-body`,
  `no-unnecessary-combinator` — plus demotions to non-blocking for
  pedantic-but-harmless findings (`oas-schema-check`, e.g. a `minimum` constraint on
  a string type: sloppy authoring, invisible to tooling).

What stayed **on** is structural: unresolvable `$ref`s, duplicate operationIds,
undeclared path parameters, schema validity. The scores still differentiate —
Square and UPS carry real errors that keep them below the high 90s.

## The gate's first catch

**OpenAI** is excluded rather than listed: its official spec declares OpenAPI
3.1.0 while using the 3.0-only `nullable` keyword 107+ times, and honestly fails
the ≥90 bar at 56/100. Recorded in `manifest.json` under `excluded`; it returns
when upstream fixes the document.
