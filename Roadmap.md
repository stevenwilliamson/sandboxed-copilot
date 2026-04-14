# Sandboxed Copilot — Roadmap

Items are grouped by tier. Each tier targets a specific class of friction.
Check off items as they are completed.

---

## ✅ Security hardening (complete)

- [x] **CONNECT restricted to port 443** — prevents SSH and non-HTTPS tunnelling through allowed domains
- [x] **`no-new-privileges`** — blocks privilege escalation via setuid binaries inside the container
- [x] **`cap_drop: ALL`** — drops all Linux capabilities from the bounding set; running as UID 1000 with `no-new-privileges` needs none
- [x] **IPv6 disabled in copilot container** — eliminates potential IPv6 bypass of `HTTP_PROXY` interception
- [x] **`pids_limit: 512`** — prevents fork bombs and runaway process creation
- [x] **`mem_limit: 4g`** — contains memory exhaustion; prevents a misbehaving agent from thrashing the host
- [x] **`/tmp` mounted as `tmpfs` with `noexec,nosuid,nodev`** — prevents binaries dropped to `/tmp` from being executed (classic local exploit staging vector)
- [x] **Squid `forwarded_for off` + `via off`** — strips headers that would leak the copilot container's internal IP and Squid version to external servers
- [x] **Squid `Safe_ports` ACL** — blocks plain HTTP requests to non-standard ports across all proxy modes
- [x] **Security model documented** — README covers what is/isn't protected and known limitations

---

## ✅ Tier 0 — First impressions (complete)

> Goal: make the sandbox feel natural from day one for any developer.

- [x] **Per-project `.sandboxed-copilot` config** — `[allowlist]` and `[env]` sections; shareable with the team via source control
- [x] **Node.js LTS pre-installed** — `npm`/`npx` available without any setup
- [x] **Ruby latest + Python latest pre-installed** — via mise; gems and pip packages work out of the box
- [x] **Persistent shell history** — history survives container restarts via a named Docker volume
- [x] **Welcome banner** — shows auth status, tool versions, and workspace path on login
- [x] **`uninstall.sh`** — clean removal of containers, images, volumes, and the launcher binary
- [x] **Git identity forwarding** — mounts host `~/.gitconfig`; overrides credential helper to use the container's `gh` binary so `git push/pull` works without re-authenticating

---

## Tier 1 — Speed & onboarding friction

> Goal: remove the two most common reasons developers abandon a tool in the first 10 minutes.

- [ ] **T1-A: Pre-built images (GHCR)** — publish `ghcr.io/<org>/sandboxed-copilot` on every release tag via GitHub Actions so `install.sh` pulls a pre-built image instead of compiling Ruby from source (~5 min saved on first install)
- [x] **T1-B: Automatic `GITHUB_TOKEN` detection** — check `gh auth token` on the host and inject the token automatically; banner shows `✓ Authenticated as @username` or `⚠ Not authenticated`; removes the most-forgotten manual step
- [x] **T1-C: `sandboxed-copilot update` command** — pulls the latest images (or rebuilds if using local build); shows current vs available version

---

## ✅ Tier 1.5 — Supply chain exfiltration protection (complete)

> Goal: block GitHub-API-as-exfil attacks (Shai-Hulud class) without disrupting normal `git`, `gh pr/issue`, or Copilot operations.

- [x] **S-A: ICAP: block dangerous GitHub REST API endpoints** — extend the ICAP scanner to inspect requests to `api.github.com`; always block `POST /user/repos` and `POST /orgs/*/repos` (required for every known GitHub-API exfil attack); `git push/pull` unaffected (uses `github.com` Smart HTTP, not `api.github.com`)
- [x] **S-B: Block `uploads.github.com` by default** — `uploads.github.com` is exclusively used for release asset uploads; add deny rule in normal and lock proxy modes; stops TeamPCP's release-asset exfil fallback
- [x] **S-C: Configurable `gh release` support** — `POST /repos/*/releases` and `uploads.github.com` are blocked by default but can be unlocked via `sandboxed-copilot proxy releases [enable|disable|status]`; repo creation blocks remain even when releases are enabled

---

## Tier 1.6 — Exfiltration gap remediation

> Goal: close the highest-priority gaps identified in the threat-model analysis. Scoring is 1–5 (5 = known observed tactic in the wild).

- [ ] **E1: Block `POST /gists`** *(score 5)* — `gh gist create` is a one-command path to a public or secret URL containing anything the agent can read; add `/gists` to `blockedGitHubAPIEndpoints` in the ICAP scanner
- [ ] **E2: Block repo write paths on existing repos** *(score 4)* — `PUT /repos/*/contents/*` (file write), `POST /repos/*/issues` (issue body), `POST /repos/*/issues/comments`, `POST /repos/*/git/blobs` and related refs; add path rules to `blockedGitHubAPIEndpoints`
- [ ] **E3: Extend header scanning to GET requests** *(score 3)* — ICAP currently only fires on POST/PUT/PATCH; a `GET /anything` with `X-Api-Key: ghp_...` to an allowlisted domain is invisible; extend Squid or ICAP to scan all request headers, not just `Authorization`
- [ ] **E4: DNS exfiltration firewall** *(score 4)* — Docker's internal resolver (`127.0.0.11`) is a loopback address not routed through Squid; a 40-char token fits in 1–2 DNS subdomain queries; route container DNS through a filtering resolver (e.g. restrict to Squid's `CONNECT` tunnel or use a dnsproxy sidecar)
- [ ] **E5: ICAP encoded-token detection** *(score 4)* — current regex only matches the raw `ghp_` prefix; base64 or hex encoding completely bypasses it; add a base64/hex decode step in the ICAP scanner before the regex match

---

## Tier 2 — Polish & portability

> Goal: broaden the audience and reduce "it doesn't work on my machine" reports.

- [ ] **T2-A: Linux host support** — validate on Ubuntu 24.04; fix any macOS-specific path assumptions in `install.sh` and the launcher; add Linux to CI test matrix
- [ ] **T2-B: `sandboxed-copilot logs` command** — surface container and proxy logs without needing to know Docker commands; `--proxy` flag shows Squid access log; `--follow` streams live
- [x] **T2-C: `sandboxed-copilot proxy denied`** — parse the Squid access log and list domains that have been blocked in the current or recent sessions; output is one domain per line so it can be piped
- [x] **T2-D: `sandboxed-copilot proxy allowlist [domain]`** — add a domain to the allowlist interactively; when called without arguments (or piped the output of `proxy denied`) it prompts for which entries to add and whether each should go into the **user** allowlist (`~/.sandboxed-copilot/config/allowlist.txt`) or the **project** allowlist (`.sandboxed-copilot` in the current directory); single-domain usage (`proxy allowlist api.example.com`) skips the menu and goes straight to the scope prompt
- [x] **T2-E: Shell completion** — `sandboxed-copilot completion bash|zsh|fish`; `install.sh` offers to add it to the shell profile
- [x] **T2-F: `sandboxed-copilot proxy monitor`** — live terminal UI showing real-time proxy traffic across **all active sandbox sessions**; colour-coded output (🟢 green = allowed, 🔴 red = denied); columns: timestamp · project · method · domain · status; auto-discovers all running proxy containers by image label so it works with concurrent sessions; streams until Ctrl-C
- [ ] **T2-H: Workspace read-only mode** — `sandboxed-copilot --read-only` mounts `/workspace` as `:ro`; useful for review/audit tasks where Copilot should observe and suggest without writing files; pairs naturally with `proxy lock`
- [ ] **T2-I: Proxy bandwidth rate limiting** — configure Squid delay pools to cap outbound bandwidth per connection; limits exfiltration throughput even through allowed domains; configurable via a `[proxy]` section in `.sandboxed-copilot`

---

## ❌ Docker-in-Docker — not viable in current architecture

> **Status: deferred — requires VM-level network isolation to implement safely.**

- [ ] **T3-C: Docker-in-Docker via VM-boundary proxy enforcement** — allow Copilot to spawn Docker containers (databases, test services, etc.) for dev setups while keeping the proxy firewall effective

  **Why the socket-mount approach is not safe:**

  Mounting the Docker socket (`~/.rd/docker.sock` or `/var/run/docker.sock`) into the copilot container breaks every security guarantee this project provides:
  - Child containers can join `bridge` or `host` networks that have a direct internet route, bypassing Squid entirely
  - The Docker API can be used to mount `~/.sandboxed-copilot/config/` with write access, defeating the read-only allowlist protection
  - Docker socket access is root-equivalent on the host — the agent can mount `/` into a container and escape all controls
  - No wrapper script or network injection reliably closes these gaps; the agent has the full API and can call it directly

  **The architecture required to do this safely:**

  Enforcement must move from the container network level to the VM network interface level:

  ```
  Internet ←→ Proxy VM (Squid, two NICs) ←→ host-only network ←→ Copilot VM
                                                                      └── Docker daemon
                                                                           ├── copilot container
                                                                           └── child containers  ← spawned by agent
  ```

  Because the Copilot VM has no direct internet route at the hypervisor level, every container it spawns — regardless of what Docker network they join — must exit through the VM's single NIC, which routes to the Proxy VM. The agent cannot bypass this by manipulating Docker networking because it only controls the inside of the VM, not the VM boundary itself.

  **Why this is complex:**
  - Requires provisioning and wiring two VMs together with a host-only network
  - Rancher Desktop and Docker Desktop manage their own internal VMs (Lima / HyperKit); injecting a second VM requires replacing or wrapping that abstraction
  - Allowlist changes must cross a VM boundary; management UX becomes more involved
  - macOS, Linux, and Windows each have different VM networking primitives
  - Significantly more moving parts to install, maintain, and debug

  This remains a valid and worthwhile goal but is a larger architectural project than the current Docker Compose approach.

---

## Tier 3 — Team & enterprise features

> Goal: make the tool viable as a shared, team-wide standard.

- [ ] **T3-A: Shared team allowlist via URL** — support `@include https://...` directives in `allowlist.txt` so teams can maintain one canonical domain list in a gist or internal URL; proxy fetches and caches remote includes on startup
- [ ] **T3-B: `sandboxed-copilot init` from devcontainer** — read an existing `.devcontainer/devcontainer.json` and generate a `.sandboxed-copilot` config with matching `[allowlist]` and `[env]` entries; reduces friction for teams already using devcontainers

---

## Implementation order

```
T1-B  →  pure shell change in launcher, 10 minutes, highest adoption impact
T1-A  →  requires GitHub Actions workflow; biggest first-impression win
T1-C  →  depends on T1-A (needs registry to pull from)
S-A   →  ICAP endpoint blocking; extends existing ICAP scanner; medium effort; high security value
S-B   →  Squid deny for uploads.github.com; small entrypoint change; trivial effort
S-C   →  proxy releases subcommand; depends on S-A + S-B; medium effort
E1    →  add /gists to blockedGitHubAPIEndpoints; trivial effort; highest residual risk
E2    →  add repo write paths to ICAP block list; small effort; high value
E3    →  extend ICAP/Squid header scanning to GET; medium effort
E5    →  ICAP encoded-token detection; medium effort; depends on E3 for GET coverage
E4    →  DNS firewall; larger architectural change; standalone effort
T2-A  →  CI matrix change + minor path fixes
T2-B  →  small shell addition to the launcher
T2-C  →  depends on T2-B (reads from proxy access log); pure shell, high UX value
T2-D  →  depends on T2-C (can consume its output); interactive prompt; also useful standalone
T2-E  →  standalone, low effort
T2-F  →  multi-container log fan-in + ANSI UI; standalone, high observability value
T2-H  →  workspace read-only mode; small launcher + compose change
T2-I  →  Squid delay pools; proxy-side change, medium effort
T3-A  →  proxy-side change, medium effort
T3-B  →  most complex; high value for enterprise adoption
T3-C  →  Docker-in-Docker; requires VM-level network architecture; large project
```
