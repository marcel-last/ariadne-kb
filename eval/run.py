#!/usr/bin/env python3
"""
Ariadne eval harness.

Usage:
    python eval/run.py [pack|extraction|resume|all] [--live BASE_URL]

Without --live it runs OFFLINE: it validates every fixture against the real schemas, recomputes
the golden pack's heuristic token count, checks the golden's structure, and checks each rubric /
scenario is well-formed. This is what CI runs (no model calls, deterministic).

With --live BASE_URL it additionally exercises the running system:
  * pack       -> POST {BASE_URL}/v1/context-pack, normalise the pack-id token, diff vs the golden.
  * extraction -> run the extractor on each case and score patch-validity + rubric pass rate.
  * resume     -> build a pack from the seed, ask the model the question, score surface/no-reask.
The live hooks are marked `TODO(live)` where they need the built system; the offline path is fully
implemented and is the gate for `make validate-kb`.

Exit code is non-zero if any offline check fails.
"""
import json, math, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root (parent of eval/)
EVAL = os.path.join(ROOT, "eval")

def _load_json(path):
    with open(path) as f:
        return json.load(f)

def _load_jsonl(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]

def _validators():
    """Compile the real schemas so fixtures are checked against the actual contracts."""
    import jsonschema
    state = _load_json(os.path.join(ROOT, "schemas", "state-doc.schema.json"))
    extr = _load_json(os.path.join(ROOT, "schemas", "extractor-output.schema.json"))
    return jsonschema.Draft202012Validator(state), jsonschema.Draft202012Validator(extr)

def _full_doc(excerpt):
    """Wrap a partial brief excerpt into a schema-complete document for validation."""
    base = {"schema": "ariadne.state/1", "project": {"slug": "eval-proj"},
            "objective": "placeholder objective", "meta": {"version": 1, "updated_seq": 1}}
    base.update(excerpt or {})
    return base

def heuristic_tokens(text: str) -> int:
    """Spec tokenizer 'heuristic': ceil(chars/4 * 1.1)."""
    return math.ceil(len(text) / 4 * 1.1)

# ----------------------------------------------------------------- pack suite
def run_pack(live=None):
    fails = []
    fx = _load_json(os.path.join(EVAL, "pack", "recon-acme.json"))
    state_v, _ = _validators()
    # 1. input state doc must be schema-valid
    errs = sorted(state_v.iter_errors(fx["state_doc"]), key=lambda e: e.path)
    if errs:
        fails.append(f"pack input state_doc invalid: {errs[0].message}")
    # 2. golden text: structure + budget under the declared tokenizer
    golden = open(os.path.join(EVAL, "pack", fx["expect"]["text_file"])).read()
    if not golden.startswith("<!-- ariadne:begin "):
        fails.append("golden missing begin sentinel")
    if "<!-- ariadne:end " not in golden:
        fails.append("golden missing end sentinel")
    order = re.findall(r'^## (.+)$', golden, re.M)
    fixed = ['Objective','Constraints','Pinned','Environment','Open threads','To do',
             'Findings','Decisions','Entities','Glossary','Relevant memory']
    # order must be a subsequence of the fixed order (sections may be absent, never reordered)
    it = iter(fixed)
    if not all(any(s == f for f in it) for s in order):
        fails.append(f"golden section order violates fixed order: {order}")
    for p0 in ("## Objective", "## Constraints", "## Pinned"):
        if p0 not in golden:
            fails.append(f"golden missing P0 section {p0}")
    budget = fx["request"]["budget_tokens"]
    tok = fx["request"]["tokenizer"]
    if tok == "heuristic":
        n = heuristic_tokens(golden)
        if n > budget and not fx["expect"]["truncated"]:
            fails.append(f"golden {n} tokens exceeds budget {budget} but truncated=false")
        print(f"  pack: golden {len(golden)} chars, heuristic tokens {n} <= budget {budget}")
    else:
        print(f"  pack: tokenizer '{tok}' not computable offline; skipping token count")
    if live:
        print("  pack: TODO(live) POST /v1/context-pack, normalise pack-id, diff vs golden")
    return fails

# ------------------------------------------------------------ extraction suite
RUBRIC_KEYS = {"expect_empty_patch","patch_must_touch","patch_must_not_touch","state_result",
               "new_array_item","memories_must_mention","memories_may_be_empty",
               "memories_must_be_empty","must_not_appear_anywhere","notes_for_reviewer_expected",
               "note"}
ALWAYS_FORBIDDEN = ("/pins", "/meta", "/schema")

def run_extraction(live=None):
    fails = []
    cases = _load_jsonl(os.path.join(EVAL, "extraction", "cases.jsonl"))
    state_v, extr_v = _validators()
    ids = set()
    for c in cases:
        cid = c.get("id", "<no id>")
        if cid in ids: fails.append(f"duplicate case id {cid}")
        ids.add(cid)
        # the case's starting brief must be a valid (completed) document
        errs = list(state_v.iter_errors(_full_doc(c.get("current_doc"))))
        if errs: fails.append(f"{cid}: current_doc not schema-valid: {errs[0].message}")
        # rubric must be well-formed
        rub = c.get("rubric", {})
        unknown = set(rub) - RUBRIC_KEYS
        if unknown: fails.append(f"{cid}: unknown rubric keys {unknown}")
        # patch_must_touch paths must be under mutable roots (never forbidden ones)
        for p in rub.get("patch_must_touch", []):
            if p.startswith(ALWAYS_FORBIDDEN):
                fails.append(f"{cid}: rubric asks to touch forbidden path {p}")
        # a secret-exclusion case must actually name the fake secret it forbids
        for s in rub.get("must_not_appear_anywhere", []):
            if not s: fails.append(f"{cid}: empty must_not_appear_anywhere entry")
    print(f"  extraction: {len(cases)} cases well-formed, ids unique, rubrics valid")
    if live:
        print("  extraction: TODO(live) run extractor per case, validate against extractor-output"
              " schema (patch-validity), apply patch, re-validate brief, score rubric")
        # Sketch of the scoring contract the live runner must implement:
        #   valid   = envelope matches extractor-output.schema AND applied doc matches state schema
        #   rubric  = patch touched patch_must_touch, never touched ALWAYS_FORBIDDEN, state_result
        #             holds, required memory substrings present, secrets absent everywhere
        #   gate: patch-validity >= 0.98, rubric >= 0.90
    return fails

# ---------------------------------------------------------------- resume suite
def run_resume(live=None):
    fails = []
    scen = _load_jsonl(os.path.join(EVAL, "resume", "scenarios.jsonl"))
    state_v, _ = _validators()
    for s in scen:
        sid = s.get("id", "<no id>")
        errs = list(state_v.iter_errors(s["seed_state"]))
        if errs: fails.append(f"{sid}: seed_state not schema-valid: {errs[0].message}")
        if not s.get("must_surface"): fails.append(f"{sid}: no must_surface facts")
        if not s.get("fresh_question"): fails.append(f"{sid}: no fresh_question")
    print(f"  resume: {len(scen)} scenarios well-formed, seed states schema-valid")
    if live:
        print("  resume: TODO(live) build pack from seed_state, ask fresh_question, score:"
              " surfaced must_surface facts / did NOT re-ask must_not_reask -> resume-success rate")
    return fails

SUITES = {"pack": run_pack, "extraction": run_extraction, "resume": run_resume}

def main(argv):
    which = argv[1] if len(argv) > 1 and not argv[1].startswith("-") else "all"
    live = None
    if "--live" in argv:
        i = argv.index("--live"); live = argv[i+1] if i+1 < len(argv) else True
    suites = SUITES if which == "all" else {which: SUITES[which]}
    all_fails = []
    for name, fn in suites.items():
        print(f"[{name}]")
        all_fails += fn(live=live)
    if all_fails:
        print("\nFAILURES:")
        for f in all_fails: print("  -", f)
        return 1
    print("\nALL EVAL FIXTURES VALID" + (" (offline)" if not live else ""))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
