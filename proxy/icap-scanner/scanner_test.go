package main

import (
	"strings"
	"testing"
)

// Fake credentials in each provider's serialised format. Built at runtime from
// a prefix and filler so no token-shaped literal appears in the source, which
// keeps secret scanners quiet. They will never authenticate anywhere.
var (
	fakeGitHubToken    = "ghp_" + strings.Repeat("A", 36)
	fakeGitHubPAT      = "github_pat_" + strings.Repeat("B", 40)
	fakeAnthropicKey   = "sk-ant-api03-" + strings.Repeat("c", 40)
	fakeAnthropicOAuth = "sk-ant-oat01-" + strings.Repeat("d", 40)
)

func TestHostMatchesDomain(t *testing.T) {
	tests := []struct {
		host, domain string
		want         bool
	}{
		{"claude.ai", "claude.ai", true},
		{"claude.ai", ".claude.ai", true},
		{"api.claude.ai", "claude.ai", true},
		{"api.github.com", ".github.com", true},
		{"github.com", ".github.com", true},
		// Matching must be on a label boundary.
		{"notclaude.ai", "claude.ai", false},
		{"evilgithub.com", ".github.com", false},
		{"github.com.evil.example", ".github.com", false},
		{"example.com", "claude.ai", false},
	}
	for _, tt := range tests {
		if got := hostMatchesDomain(tt.host, tt.domain); got != tt.want {
			t.Errorf("hostMatchesDomain(%q, %q) = %v, want %v", tt.host, tt.domain, got, tt.want)
		}
	}
}

func TestScanForCredentials(t *testing.T) {
	tests := []struct {
		name           string
		headers, body  string
		url            string
		wantCredential string
		wantLocation   string
		wantFound      bool
	}{
		// Each credential is allowed to reach its own provider.
		{
			name:    "github token to github",
			headers: "Authorization: Bearer " + fakeGitHubToken + "\r\n",
			url:     "https://api.github.com/user",
		},
		{
			name: "github token to copilot",
			body: `{"token":"` + fakeGitHubToken + `"}`,
			url:  "https://api.githubcopilot.com/chat/completions",
		},
		{
			name:    "anthropic key to anthropic",
			headers: "x-api-key: " + fakeAnthropicKey + "\r\n",
			url:     "https://api.anthropic.com/v1/messages",
		},
		{
			name: "anthropic oauth token to platform.claude.com",
			body: `{"refresh_token":"` + fakeAnthropicOAuth + `"}`,
			url:  "https://platform.claude.com/v1/oauth/token",
		},
		{
			name: "no credential to third party",
			body: `{"hello":"world"}`,
			url:  "https://example.com/upload",
		},

		// Credentials bound for a third party are blocked.
		{
			name:           "github token in header to third party",
			headers:        "Authorization: token " + fakeGitHubToken + "\r\n",
			url:            "https://example.com/collect",
			wantCredential: "github-token",
			wantLocation:   "header",
			wantFound:      true,
		},
		{
			name:           "github fine-grained PAT in body to third party",
			body:           "data=" + fakeGitHubPAT,
			url:            "https://example.com/collect",
			wantCredential: "github-token",
			wantLocation:   "body",
			wantFound:      true,
		},
		{
			name:           "anthropic key in body to third party",
			body:           `{"k":"` + fakeAnthropicKey + `"}`,
			url:            "https://example.com/collect",
			wantCredential: "anthropic-key",
			wantLocation:   "body",
			wantFound:      true,
		},

		// Cross-provider: each credential only belongs to its own provider.
		// (In production squid.conf exempts agent API bodies from ICAP, so
		// the first case is enforced by the header ACLs there; the scanner's
		// own logic still classifies it correctly.)
		{
			name:           "github token to anthropic",
			body:           `{"prompt":"` + fakeGitHubToken + `"}`,
			url:            "https://api.anthropic.com/v1/messages",
			wantCredential: "github-token",
			wantLocation:   "body",
			wantFound:      true,
		},
		{
			name:           "anthropic key to github",
			body:           `{"body":"` + fakeAnthropicKey + `"}`,
			url:            "https://api.github.com/repos/o/r/issues",
			wantCredential: "anthropic-key",
			wantLocation:   "body",
			wantFound:      true,
		},

		// Lookalike hosts are not the provider.
		{
			name:           "anthropic key to lookalike host",
			headers:        "x-api-key: " + fakeAnthropicKey + "\r\n",
			url:            "https://notclaude.ai/v1/messages",
			wantCredential: "anthropic-key",
			wantLocation:   "header",
			wantFound:      true,
		},

		// Too short to be a real credential.
		{
			name: "short prefix only",
			body: "ghp_short sk-ant-short",
			url:  "https://example.com/",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			credential, location, found := scanForCredentials(tt.headers, tt.body, tt.url)
			if found != tt.wantFound || credential != tt.wantCredential || location != tt.wantLocation {
				t.Errorf("scanForCredentials() = (%q, %q, %v), want (%q, %q, %v)",
					credential, location, found, tt.wantCredential, tt.wantLocation, tt.wantFound)
			}
		})
	}
}

func TestIsBlockedGitHubAPIEndpoint(t *testing.T) {
	tests := []struct {
		method, url string
		want        bool
	}{
		{"POST", "https://api.github.com/user/repos", true},
		{"POST", "https://api.github.com/orgs/acme/repos", true},
		{"POST", "https://api.github.com/gists", true},
		{"GET", "https://api.github.com/user/repos", false},
		{"POST", "https://api.github.com/repos/o/r/pulls", false},
		// Only api.github.com is in scope.
		{"POST", "https://github.com/user/repos", false},
	}
	for _, tt := range tests {
		if got := isBlockedGitHubAPIEndpoint(tt.url, tt.method); got != tt.want {
			t.Errorf("isBlockedGitHubAPIEndpoint(%q, %q) = %v, want %v", tt.url, tt.method, got, tt.want)
		}
	}
}
