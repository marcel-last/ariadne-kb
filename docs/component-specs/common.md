# Component: ariadne_common

**Path:** `packages/ariadne_common/` · **Kind:** shared library (imported by every service)

## Responsibility
The single home for cross-cutting concerns so they can't drift between services: config, DB
access with tenant scoping, Redis access, auth (mint/verify identity claims), and loading +
validating the JSON Schemas. If two services need the same rule, it lives here.

## Provides
- **config** — typed settings from env (`docs/config-reference.md`, Tier 6). One `Settings`
  object; no service reads `os.environ` directly.
- **db** — an `asyncpg` pool wrapper that, on every acquired connection used for a request,
  issues `SET LOCAL ariadne.tenant = $tenant` inside the transaction. Exposes a
  `tenant_scoped(tenant_id)` context manager; there is no un-scoped query helper for
  tenant-scoped tables.
- **redis** — client + helpers for streams (`XADD`/`XREADGROUP`/`XACK`/`XAUTOCLAIM`), the
  seq/pack/bind key builders (`specs/queue-messages.md` §7), and the single-instance lock.
- **auth** — `mint_identity(claims, ttl<=300s)` and `verify_identity(jwt) -> Principal`
  (HS256, shared secret); `tenant_from_service_key(key)`. Rejects expired/!sig/!iss.
- **schemas** — compiled validators for `schemas/state-doc.schema.json` and
  `schemas/extractor-output.schema.json`, loaded once; `apply_state_patch(doc, patch)` that
  applies RFC 6902 then validates the result.
- **models** — pydantic models generated from / checked against `openapi/ariadne-api.yaml`.

## Consumes
Env; the two JSON Schema files; the OpenAPI schemas (for model generation in CI).

## Failure behaviour
Pure library: raises typed errors (`AuthError`, `SchemaError`, `VersionConflict`) that callers
map to responses. Never catches broadly; never logs and swallows.

## Definition of done
- Every tenant-scoped query path sets `ariadne.tenant` from a **verified** principal, never from
  request input — proves INV-11, INV-12. Test: a connection without the GUC set sees zero rows.
- `verify_identity` rejects expired (>300 s), wrong-secret, and wrong-issuer tokens — INV-12.
- `apply_state_patch` rejects a patch whose *result* fails `schemas/state-doc.schema.json`, and refuses
  paths under `/pins`,`/meta`,`/schema` for non-user authors — INV-4.
- Schema validators are loaded from the files in `schemas/`, not re-declared in code (single
  source). Test: mutating the schema file changes validation behaviour.
