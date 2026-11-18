# Working rules

These rules apply to anyone, human or agent, changing this repository.

## Product constraints

- Work in English throughout this repository.
- No paid services: do not introduce paid services, paid tools, expiring paid trials, automatic overage billing or purchases. Verify free quotas and configure hard usage limits. The domain `zorja.app` is the one paid item (docs/decisions.md, 2026-11-11).
- The app ships on the App Store. No usage or adoption target is defined.
- Push notifications are deferred (see docs/decisions.md). Their backend code is kept outside this repository, in the tag `post-mvp-notifications` of the archived private repository. If alerts return: one selected location per device, no user accounts.
- Read README.md, docs/product.md, docs/forecast-model.md and docs/api.md before changing product behavior or API integration.
- Prioritize actual viewing conditions over geomagnetic activity alone.
- Account for daylight, twilight, polar night, midnight sun and seasonal variation.
- Never describe the experimental visibility assessment as a scientifically validated probability.
- Do not extrapolate short-term auroral data into future nights.
- Unknown, missing, stale and unfavorable conditions are different states.

## Ownership

Tomas owns the product experience, interaction and visual design, the design system, and every product, cost and account decision.

Claude implements: the SwiftUI app, the backend, external integrations, scientific processing, the API contract, tests, hosting configuration and documentation. Other reviewers take part only when Tomas asks.

No backend change may silently alter the meaning of a published field. Contract changes are documented in `docs/api.md` and `api/openapi.json` in the same change as the code.

## Workflow

- Commit completed, verified changes. Ask Tomas before pushing unless he has explicitly authorized the push in the current request.
- This repository is public. Never commit secrets, account or project IDs, personal data, or material meant to stay private; put the latter in the local `_private/` folder (excluded through `.git/info/exclude`, indexed in `_private/README.md`).
- The archived private repository `tomasminarik/zorja-private` is frozen history. All work happens here.
- Keep the contract, examples, documentation and implementation consistent in the same repository.
- The v1 API interface is frozen at 1.0.0 and live at `api.zorja.app`. Identify breaking changes explicitly and use a new major path for incompatible changes. The activity-coverage method is decided (docs/decisions.md); scientific calibration remains open and must not be claimed.
- Record product decisions, and technical choices that change behavior or cost, in `docs/decisions.md`, keeping the two separate. Do not create separate decision records, milestone or operations reports, review or response documents, or handoff files for routine work: the commit message and pull request description are the record. Keep README.md accurate when what the app does changes.
- Test scientific boundaries and provider failures, including source expiry, malformed payloads, timezone transitions, polar conditions and missing weather variables.
- Never commit APNs credentials, contact secrets, device tokens or personal location records.
- Use synthetic examples. Do not claim implementation, live validation, deployment or scientific calibration unless performed.
