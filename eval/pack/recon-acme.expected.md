<!-- ariadne:begin v=1 project=recon-acme sv=142 pack=<pack_id> -->
# Project brief — Acme external assessment
_Resuming project `recon-acme`. This context is maintained by Ariadne; treat it as ground truth._

## Objective
Map the external attack surface of acme.com and validate exploitable findings.

## Constraints
- Scope: *.acme.com and 203.0.113.0/24 only. No social engineering.
- Engagement window ends 2026-09-20.

## Pinned
- Client contact prefers findings in CVSS 3.1.

## Environment
Targets: acme.com, api.acme.com, 203.0.113.0/24
Tooling: nmap, ffuf, burp, custom py
Creds: artifact://creds.kdbx

## Open threads
- [t4] (in_progress) SSRF candidate in image-proxy — needs OOB confirmation

## To do
- [ ] [todo9] Re-test rate-limit bypass after WAF change

## Findings
- [f2] **high** (confirmed) IDOR in /v2/orders → artifact://f2-poc.md

## Decisions
- [d17] Treat the /v2 API as primary attack surface

## Entities
- [e1] api.acme.com (host) — nginx 1.25, rate-limited /login

## Glossary
- OOB: out-of-band

## Relevant memory
- (finding) IDOR confirmed in /v2/orders; cross-tenant read by decrementing order_id.

<!-- ariadne:end pack=<pack_id> -->
