package main

import (
	"fmt"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	exfilLogPath           = "/var/log/squid/exfil.log"
	releasesEnabledFlagFile = "/etc/squid/config/allow-github-releases"
)

// tokenRe matches all GitHub token prefix formats followed by at least 20
// alphanumeric or underscore characters. The minimum length (20) is well below
// the shortest real token (36 chars for ghp_/gho_/ghs_/ghu_) which keeps false
// positives negligible while catching all realistic exfiltration attempts.
var tokenRe = regexp.MustCompile(
	`(ghp_|gho_|ghs_|ghu_|github_pat_)[A-Za-z0-9_]{20,}`,
)

// githubInfraSuffixes lists the domain suffixes where GitHub tokens are
// legitimately used. Requests to these destinations are never blocked.
var githubInfraSuffixes = []string{
	".github.com",
	".githubusercontent.com",
	".githubcopilot.com",
}

// isGitHubInfra returns true if rawURL is destined for GitHub infrastructure.
func isGitHubInfra(rawURL string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}
	host := strings.ToLower(u.Hostname())
	for _, suffix := range githubInfraSuffixes {
		if host == strings.TrimPrefix(suffix, ".") || strings.HasSuffix(host, suffix) {
			return true
		}
	}
	return false
}

// scanForTokens inspects the encapsulated HTTP headers and body for GitHub
// token patterns. It returns the location ("header" or "body") where a token
// was found, and whether a token was detected.
//
// Requests going to GitHub infrastructure are always allowed regardless of
// whether they contain a token.
func scanForTokens(httpHeaders, body, targetURL string) (location string, found bool) {
	if isGitHubInfra(targetURL) {
		return "", false
	}
	if tokenRe.MatchString(httpHeaders) {
		return "header", true
	}
	if tokenRe.MatchString(body) {
		return "body", true
	}
	return "", false
}

// writeExfilLog appends a detection event to the exfil log via the channel
// owned by the single writer goroutine in main.go. This is safe to call from
// multiple goroutines concurrently.
//
// Format: ICAP <unix-ts> <client-ip> <method> <url> 403 detection:<location>
//
// The ICAP prefix allows the proxy monitor to distinguish body detections
// (logged here) from header/URL detections (logged by Squid's filtered
// access_log). The token value is intentionally NOT logged.
func writeExfilLog(clientIP, method, targetURL, location string) {
	ts := float64(time.Now().UnixNano()) / 1e9
	line := fmt.Sprintf("ICAP %.3f %s %s %s 403 detection:%s\n",
		ts, clientIP, method, targetURL, location)
	select {
	case exfilCh <- line:
	default:
		// Channel full (writer goroutine overwhelmed or shutting down); surface
		// the dropped entry to stderr so it is not silently lost.
		fmt.Fprintf(os.Stderr, "[icap-scanner] WARNING: exfil log channel full, dropping: %s", line)
	}
	// Also log to stdout so docker compose logs shows it.
	fmt.Printf("[icap-scanner] BLOCKED %s %s %s detection:%s\n",
		clientIP, method, targetURL, location)
}

// writeExfilWarning logs a truncation warning (body exceeded scan limit).
// We pass the request through but note it for visibility.
func writeExfilWarning(clientIP, method, targetURL string) {
	fmt.Printf("[icap-scanner] WARNING body truncated at %dMB, scan incomplete: %s %s %s\n",
		maxScanBytes/(1024*1024), clientIP, method, targetURL)
}

// ── GitHub API endpoint blocking (Shai-Hulud class protection) ───────────────

// endpointRule pairs an HTTP method with a compiled path regexp.
type endpointRule struct {
	method string
	pathRe *regexp.Regexp
}

// blockedGitHubAPIEndpoints lists api.github.com endpoints that are always
// blocked because they are required steps in every known GitHub-API data
// exfiltration attack (the "Shai-Hulud" class).
//
//   - POST /user/repos            — create a personal repository
//   - POST /orgs/{org}/repos      — create an organisation repository
//   - POST /gists                 — create a public or secret gist
//   - PATCH /gists/{id}           — edit an existing gist
//   - PUT /repos/*/contents/{p}   — write a file via Contents API (bypasses git)
//   - POST /repos/*/git/blobs     — raw git blob creation
//   - POST /repos/*/git/trees     — raw git tree creation
//   - POST /repos/*/git/commits   — raw git commit creation
//   - PATCH /repos/*/git/refs/*   — update a git reference
//
// git push/pull uses github.com Smart HTTP (/user/repo.git/...), not
// api.github.com, so normal git operations are unaffected.
// gh pr create, gh issue create, and gh pr comment use /repos/*/pulls,
// /repos/*/issues, and /repos/*/issues/comments respectively — those paths
// are intentionally NOT in this list so agentic Copilot workflows are preserved.
var blockedGitHubAPIEndpoints = []endpointRule{
	// Repository creation
	{method: "POST", pathRe: regexp.MustCompile(`^/user/repos$`)},
	{method: "POST", pathRe: regexp.MustCompile(`^/orgs/[^/]+/repos$`)},
	// Gist creation and editing
	{method: "POST", pathRe: regexp.MustCompile(`^/gists$`)},
	{method: "PATCH", pathRe: regexp.MustCompile(`^/gists/[^/]+$`)},
	// Contents API file write (bypasses git entirely)
	{method: "PUT", pathRe: regexp.MustCompile(`^/repos/[^/]+/[^/]+/contents/.+`)},
	// Raw git object API (bypasses git push; not used by gh CLI or normal git)
	{method: "POST", pathRe: regexp.MustCompile(`^/repos/[^/]+/[^/]+/git/blobs$`)},
	{method: "POST", pathRe: regexp.MustCompile(`^/repos/[^/]+/[^/]+/git/trees$`)},
	{method: "POST", pathRe: regexp.MustCompile(`^/repos/[^/]+/[^/]+/git/commits$`)},
	{method: "PATCH", pathRe: regexp.MustCompile(`^/repos/[^/]+/[^/]+/git/refs/.+`)},
}

// blockedReleasesEndpoints lists api.github.com endpoints that are blocked by
// default but can be unlocked via `sandboxed-copilot proxy releases enable`.
// This covers the release-asset exfil fallback used by TeamPCP and similar.
var blockedReleasesEndpoints = []endpointRule{
	{method: "POST", pathRe: regexp.MustCompile(`^/repos/[^/]+/[^/]+/releases$`)},
}

// isReleasesEnabled returns true when the operator has explicitly unlocked
// GitHub release creation (via `sandboxed-copilot proxy releases enable`).
func isReleasesEnabled() bool {
	_, err := os.Stat(releasesEnabledFlagFile)
	return err == nil
}

// isBlockedGitHubAPIEndpoint returns true if method+targetURL matches one of
// the dangerous api.github.com endpoints that should be denied.
func isBlockedGitHubAPIEndpoint(targetURL, method string) bool {
	u, err := url.Parse(targetURL)
	if err != nil {
		return false
	}
	if strings.ToLower(u.Hostname()) != "api.github.com" {
		return false
	}
	path := u.Path
	for _, rule := range blockedGitHubAPIEndpoints {
		if rule.method == method && rule.pathRe.MatchString(path) {
			return true
		}
	}
	if !isReleasesEnabled() {
		for _, rule := range blockedReleasesEndpoints {
			if rule.method == method && rule.pathRe.MatchString(path) {
				return true
			}
		}
	}
	return false
}

// writeGitHubAPIBlockLog appends a GitHub API endpoint block event to the
// exfil log. The GITHUB-API-BLOCK prefix distinguishes these entries from
// token exfiltration blocks (ICAP prefix) and Squid's own exfil_fmt log.
func writeGitHubAPIBlockLog(clientIP, method, targetURL string) {
	ts := float64(time.Now().UnixNano()) / 1e9
	line := fmt.Sprintf("GITHUB-API-BLOCK %.3f %s %s %s 403\n",
		ts, clientIP, method, targetURL)
	select {
	case exfilCh <- line:
	default:
		fmt.Fprintf(os.Stderr, "[icap-scanner] WARNING: exfil log channel full, dropping: %s", line)
	}
	fmt.Printf("[icap-scanner] BLOCKED %s %s %s github-api-endpoint\n",
		clientIP, method, targetURL)
}
