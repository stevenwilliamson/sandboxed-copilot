package main

import (
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const exfilLogPath = "/var/log/squid/exfil.log"

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

// writeExfilLog appends a detection event to the exfil log.
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
	exfilLog.WriteString(line)
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
