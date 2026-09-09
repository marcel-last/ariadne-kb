# Open WebUI payload fixtures

These files pin down the **shapes** Ariadne's filter and tool server must handle: what an
`inlet` body looks like, what `__metadata__` and `__user__` carry, what the tool server receives
as an HTTP request, and what a status event looks like.

## ⚠️ Provenance — read this

**These fixtures are *reference shapes derived from the Open WebUI documentation and source code*
(verified 2026-09-09), NOT payloads captured from a live instance.** They are correct at the
structural level and good enough to build and unit-test against, but exact key presence, nesting,
and casing can differ by release and configuration. Two fields in particular are marked
`VERIFY:` inline because the docs don't fully pin them:

- where `folder_id` actually sits at `inlet` (top-level vs `metadata`);
- whether user identity headers reach an external tool server, or only chat/message id.

**Before the resolver and turn-normaliser are considered done, replace these with real captures**
using the recipe below, and drop the `VERIFY:` markers once confirmed. Contract tests should run
against the *captured* fixtures; treat these as scaffolding.

## Files

| File | What it represents |
|---|---|
| `inlet-body.json` | the `body` dict passed to `Filter.inlet` for a WebUI turn |
| `inlet-metadata.json` | the `__metadata__` dict at `inlet` (and the same object at `outlet`) |
| `inlet-user.json` | the `__user__` dict |
| `outlet-body.json` | the `body` dict passed to `Filter.outlet` after the response |
| `tool-request.http` | the raw HTTP request `ariadne-tools` receives for a `memory_recall` call |
| `status-event.json` | an `__event_emitter__` status payload |

## Capture recipe (get ground truth)

### 1. Filter payloads (`inlet` / `outlet` / `__metadata__` / `__user__`)

Install this tiny logging filter in Open WebUI (*Admin → Functions → Create*), enable it globally,
send one normal chat message **and** one message inside a folder-scoped chat, then read the files
it writes. It only records; it never modifies the turn.

```python
"""
title: Ariadne capture probe
description: Dumps inlet/outlet body, metadata and user to /tmp for fixture capture. Remove after use.
"""
import json, os, time
from typing import Optional

CAP_DIR = os.environ.get("ARIADNE_CAP_DIR", "/tmp/ariadne-cap")

def _dump(tag, obj):
    os.makedirs(CAP_DIR, exist_ok=True)
    path = os.path.join(CAP_DIR, f"{tag}-{int(time.time()*1000)}.json")
    # default=str so non-JSON objects (e.g. Request) don't crash the dump
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, default=str)

class Filter:
    def __init__(self):
        self.priority = 0   # run first, capture the body before other filters mutate it

    async def inlet(self, body: dict, __metadata__: dict = None,
                    __user__: dict = None, __model__: dict = None) -> dict:
        _dump("inlet-body", body)
        _dump("inlet-metadata", __metadata__ or {})
        _dump("inlet-user", __user__ or {})
        _dump("inlet-model", __model__ or {})
        return body

    async def outlet(self, body: dict, __metadata__: dict = None,
                     __user__: dict = None) -> dict:
        _dump("outlet-body", body)
        _dump("outlet-metadata", __metadata__ or {})
        return body
```

Then, in the Open WebUI container:

```bash
ls -t /tmp/ariadne-cap
# redact ids/emails, then copy the representative ones over these fixtures
```

Redact real user data before committing (replace emails/ids/names with the placeholders used
here). **Delete the probe filter afterward** — it writes request bodies to disk.

### 2. Tool-server request (`tool-request.http`)

Point Open WebUI at a throwaway echo server instead of Ariadne and read what arrives. With
`ENABLE_FORWARD_USER_INFO_HEADERS=True` set on Open WebUI:

```bash
# a one-liner echo server that logs method, path, headers and body
python3 - <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = self.rfile.read(n)
        print(self.command, self.path)
        print(self.headers)          # <-- the X-OpenWebUI-* headers you care about
        print(body.decode() or "<empty>")
        self.send_response(200); self.send_header("content-type","application/json")
        self.end_headers(); self.wfile.write(b'{"items":[]}')
HTTPServer(("0.0.0.0", 8099), H).serve_forever()
PY
```

Register `http://<host>:8099` as an OpenAPI tool server (you can point it at a copy of
`openapi/ariadne-tools.yaml`), ask the model something that triggers `memory_recall`, and copy the
logged request line + headers + body into `tool-request.http`. This is the definitive way to learn
**which** headers your specific release/config actually forwards.
