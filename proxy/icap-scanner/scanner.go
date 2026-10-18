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
	exfilLogPath            = "/var/log/squid/exfil.log"
	releasesEnabledFlagFile = "/etc/squid/config/allow-github-releases"
)

// credentialRule pairs a credential pattern with the destination domains where
// that credential is legitimately used. A credential is blocked when it appears
// in a request bound for anywhere else — so a GitHub token headed for Anthropic
// is caught, and an Anthropic key headed for GitHub is too.
type credentialRule struct {
	// name identifies the credential type in log entries.
	name string
	// re matches the credential's serialised form.
	re *regexp.Regexp
	// allowedDomains lists the domains where this credential belongs. A leading
	// dot is optional and ignored: matching always covers the domain itself and
	// any subdomain of it.
	allowedDomains []string
}

// credentialRules is the full set of credential types the scanner knows about.
//
// Minimum lengths (20) sit well below the shortest real credential of each kind
// (36 chars for ghp_/gho_/ghs_/ghu_), which keeps false positives negligible
// while catching all realistic exfiltration attempts.
var credentialRules = []credentialRule{
	{
		name: "github-token",
		re:   regexp.MustCompile(`(ghp_|gho_|ghs_|ghu_|github_pat_)[A-Za-z0-9_]{20,}`),
		allowedDomains: []string{
			".github.com",
			".githubusercontent.com",
			".githubcopilot.com",
		},
	},
	{
		// Covers Anthropic API keys (sk-ant-api…) and OAuth tokens (sk-ant-oat…).
		// Hyphens are included in the character class because both formats use
		// them as internal separators.
		name: "anthropic-key",
		re:   regexp.MustCompile(`sk-ant-[A-Za-z0-9_-]{20,}`),
		allowedDomains: []string{
			".anthropic.com",
			"claude.ai",
			"platform.claude.com",
		},
	},
}

// hostMatchesDomain reports whether host is domain or a subdomain of it.
// A leading dot on domain is accepted and ignored. Matching is always on a label
// boundary, so "notclaude.ai" does not match "claude.ai".
func hostMatchesDomain(host, domain string) bool {
	d := strings.TrimPrefix(domain, ".")
	return host == d || strings.HasSuffix(host, "."+d)
}

// isAllowedDestination returns true if rawURL is bound for one of the domains
// where the given credential is legitimately used.
func isAllowedDestination(rawURL string, allowedDomains []string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}
	host := strings.ToLower(u.Hostname())
	for _, domain := range allowedDomains {
		if hostMatchesDomain(host, domain) {
			return true
		}
	}
	return false
}

// scanForCredentials inspects the encapsulated HTTP headers and body for any
// known credential pattern. It returns the credential type, the location
// ("header" or "body") where it was found, and whether anything was detected.
//
// A credential bound for its own provider's infrastructure is always allowed —
// that is what the credential is for.
func scanForCredentials(httpHeaders, body, targetURL string) (credential, location string, found bool) {
	for _, rule := range credentialRules {
		if isAllowedDestination(targetURL, rule.allowedDomains) {
			continue
		}
		if rule.re.MatchString(httpHeaders) {
			return rule.name, "header", true
		}
		if rule.re.MatchString(body) {
			return rule.name, "body", true
		}
	}
	return "", "", false
}

// writeExfilLog appends a detection event to the exfil log via the channel
// owned by the single writer goroutine in main.go. This is safe to call from
// multiple goroutines concurrently.
//
// Format: ICAP <unix-ts> <client-ip> <method> <url> 403 detection:<location>:<credential>
//
// The ICAP prefix allows the proxy monitor to distinguish body detections
// (logged here) from header/URL detections (logged by Squid's filtered
// access_log). The credential value is intentionally NOT logged — only which
// kind of credential matched.
func writeExfilLog(clientIP, method, targetURL, location, credential string) {
	ts := float64(time.Now().UnixNano()) / 1e9
	line := fmt.Sprintf("ICAP %.3f %s %s %s 403 detection:%s:%s\n",
		ts, clientIP, method, targetURL, location, credential)
	select {
	case exfilCh <- line:
	default:
		// Channel full (writer goroutine overwhelmed or shutting down); surface
		// the dropped entry to stderr so it is not silently lost.
		fmt.Fprintf(os.Stderr, "[icap-scanner] WARNING: exfil log channel full, dropping: %s", line)
	}
	// Also log to stdout so docker compose logs shows it.
	fmt.Printf("[icap-scanner] BLOCKED %s %s %s detection:%s:%s\n",
		clientIP, method, targetURL, location, credential)
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
//   - POST /user/repos       — create a personal repository
//   - POST /orgs/{org}/repos — create an organisation repository
//   - POST /gists            — create a public or secret gist (one-command exfil path)
//
// git push/pull uses github.com Smart HTTP (/user/repo.git/...), not
// api.github.com, so normal git operations are unaffected.
var blockedGitHubAPIEndpoints = []endpointRule{
	{method: "POST", pathRe: regexp.MustCompile(`^/user/repos$`)},
	{method: "POST", pathRe: regexp.MustCompile(`^/orgs/[^/]+/repos$`)},
	{method: "POST", pathRe: regexp.MustCompile(`^/gists$`)},
}

// blockedReleasesEndpoints lists api.github.com endpoints that are blocked by
// default but can be unlocked via `sandbox proxy releases enable`.
// This covers the release-asset exfil fallback used by TeamPCP and similar.
var blockedReleasesEndpoints = []endpointRule{
	{method: "POST", pathRe: regexp.MustCompile(`^/repos/[^/]+/[^/]+/releases$`)},
}

// isReleasesEnabled returns true when the operator has explicitly unlocked
// GitHub release creation (via `sandbox proxy releases enable`).
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
