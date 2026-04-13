package main

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
)

// handleConn handles a persistent ICAP connection from Squid.
// Squid reuses connections (keep-alive), so we loop until the connection closes.
func handleConn(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	for {
		if err := dispatchRequest(conn, r); err != nil {
			if err != io.EOF && !isClosedErr(err) {
				// log parse errors at debug level; connection resets are normal
			}
			return
		}
	}
}

// dispatchRequest reads one ICAP request and writes the response.
func dispatchRequest(conn net.Conn, r *bufio.Reader) error {
	// ── Request line ────────────────────────────────────────────────────────
	line, err := r.ReadString('\n')
	if err != nil {
		return err
	}
	parts := strings.Fields(strings.TrimRight(line, "\r\n"))
	if len(parts) < 2 {
		return fmt.Errorf("invalid ICAP request line: %q", line)
	}
	method := parts[0]

	// ── ICAP headers ────────────────────────────────────────────────────────
	icapHdrs := make(map[string]string)
	for {
		hline, err := r.ReadString('\n')
		if err != nil {
			return err
		}
		hline = strings.TrimRight(hline, "\r\n")
		if hline == "" {
			break
		}
		if idx := strings.IndexByte(hline, ':'); idx > 0 {
			key := strings.ToLower(strings.TrimSpace(hline[:idx]))
			val := strings.TrimSpace(hline[idx+1:])
			icapHdrs[key] = val
		}
	}

	switch method {
	case "OPTIONS":
		return sendOptions(conn)
	case "REQMOD":
		return handleREQMOD(conn, r, icapHdrs)
	default:
		return sendICAPStatus(conn, 405, "Method Not Allowed")
	}
}

// sendOptions responds to an ICAP OPTIONS request with our capabilities.
func sendOptions(conn net.Conn) error {
	resp := "ICAP/1.0 200 OK\r\n" +
		"Methods: REQMOD\r\n" +
		"Service: sandboxed-copilot token scanner 1.0\r\n" +
		"ISTag: \"token-scanner-v1\"\r\n" +
		"Allow: 204\r\n" +
		"Preview: 0\r\n" +
		"Transfer-Complete: *\r\n" +
		"\r\n"
	_, err := conn.Write([]byte(resp))
	return err
}

// handleREQMOD processes an ICAP REQMOD request. It reads the encapsulated
// HTTP request headers and body, scans for GitHub tokens, then either allows
// (204) or denies (200 + synthetic HTTP 403) the request.
func handleREQMOD(conn net.Conn, r *bufio.Reader, icapHdrs map[string]string) error {
	// ── Parse Encapsulated offsets ───────────────────────────────────────────
	// e.g. "req-hdr=0, req-body=256" or "req-hdr=0, null-body=256"
	reqHdrOff, reqBodyOff, nullBodyOff := parseEncapsulated(icapHdrs["encapsulated"])
	if reqHdrOff < 0 {
		return sendAllow(conn)
	}

	// How many bytes are the HTTP request headers?
	var httpHdrLen int
	hasBody := false
	if reqBodyOff >= 0 {
		httpHdrLen = reqBodyOff - reqHdrOff
		hasBody = true
	} else if nullBodyOff >= 0 {
		httpHdrLen = nullBodyOff - reqHdrOff
	}

	// ── Read HTTP request headers ────────────────────────────────────────────
	var httpHeaders []byte
	if httpHdrLen > 0 {
		httpHeaders = make([]byte, httpHdrLen)
		if _, err := io.ReadFull(r, httpHeaders); err != nil {
			return err
		}
	}

	// ── Read HTTP request body (chunked ICAP encoding) ───────────────────────
	var body []byte
	bodyTruncated := false
	if hasBody {
		var err error
		body, bodyTruncated, err = readChunkedBody(r, maxScanBytes)
		if err != nil {
			return err
		}
	}

	// ── Scan ─────────────────────────────────────────────────────────────────
	targetURL := extractURL(string(httpHeaders))
	method := extractMethod(string(httpHeaders))
	clientIP := icapHdrs["x-client-ip"]
	if clientIP == "" {
		if host, _, err := net.SplitHostPort(conn.RemoteAddr().String()); err == nil {
			clientIP = host
		}
	}

	location, found := scanForTokens(string(httpHeaders), string(body), targetURL)
	if found {
		writeExfilLog(clientIP, method, targetURL, location)
		return sendDeny(conn)
	}

	if bodyTruncated {
		// Log a warning but don't block: we can't prove a token exists in the
		// unseen portion, and blocking large legitimate uploads would be noisy.
		writeExfilWarning(clientIP, method, targetURL)
	}

	return sendAllow(conn)
}

// sendAllow writes an ICAP 204 No Content response (pass request through).
func sendAllow(conn net.Conn) error {
	_, err := fmt.Fprint(conn, "ICAP/1.0 204 No Content\r\n\r\n")
	return err
}

// sendDeny writes an ICAP 200 response containing a synthetic HTTP 403 Forbidden.
func sendDeny(conn net.Conn) error {
	bodyText := "Request blocked: GitHub token exfiltration attempt detected by sandboxed-copilot.\n"

	httpRespHdrs := fmt.Sprintf(
		"HTTP/1.1 403 Forbidden\r\n"+
			"Content-Type: text/plain\r\n"+
			"Content-Length: %d\r\n"+
			"X-ICAP-Block-Reason: github-token-exfiltration\r\n"+
			"\r\n",
		len(bodyText),
	)

	// Body section uses ICAP chunked encoding.
	chunkedBody := fmt.Sprintf("%x\r\n%s\r\n0\r\n\r\n", len(bodyText), bodyText)

	icapResp := fmt.Sprintf(
		"ICAP/1.0 200 OK\r\n"+
			"ISTag: \"token-scanner-v1\"\r\n"+
			"Encapsulated: res-hdr=0, res-body=%d\r\n"+
			"\r\n",
		len(httpRespHdrs),
	)

	_, err := fmt.Fprint(conn, icapResp+httpRespHdrs+chunkedBody)
	return err
}

// sendICAPStatus writes a bare ICAP error status line (for unsupported methods).
func sendICAPStatus(conn net.Conn, code int, msg string) error {
	_, err := fmt.Fprintf(conn, "ICAP/1.0 %d %s\r\n\r\n", code, msg)
	return err
}

// parseEncapsulated parses the Encapsulated ICAP header into byte offsets.
// Returns -1 for values that are not present.
func parseEncapsulated(v string) (reqHdr, reqBody, nullBody int) {
	reqHdr, reqBody, nullBody = -1, -1, -1
	for _, part := range strings.Split(v, ",") {
		kv := strings.TrimSpace(part)
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			continue
		}
		name := strings.TrimSpace(kv[:eq])
		val, err := strconv.Atoi(strings.TrimSpace(kv[eq+1:]))
		if err != nil {
			continue
		}
		switch name {
		case "req-hdr":
			reqHdr = val
		case "req-body":
			reqBody = val
		case "null-body":
			nullBody = val
		}
	}
	return
}

// readChunkedBody reads an HTTP/1.1 chunked body from an ICAP body section.
// It reads up to maxBytes of content; any excess is drained (not stored) so
// the connection state remains valid for the next request.
// Returns the bytes read, whether the content was truncated, and any error.
func readChunkedBody(r *bufio.Reader, maxBytes int) ([]byte, bool, error) {
	var body []byte
	truncated := false

	for {
		// Read chunk size line (may have extensions, e.g. "; ieof").
		line, err := r.ReadString('\n')
		if err != nil {
			return body, truncated, err
		}
		line = strings.TrimRight(line, "\r\n")
		if idx := strings.IndexByte(line, ';'); idx >= 0 {
			line = line[:idx]
		}

		size64, err := strconv.ParseInt(strings.TrimSpace(line), 16, 64)
		if err != nil {
			return body, truncated, fmt.Errorf("invalid chunk size %q: %v", line, err)
		}

		if size64 == 0 {
			// Terminating chunk — consume trailing CRLF.
			r.ReadString('\n')
			break
		}
		if size64 < 0 || size64 > int64(^uint(0)>>1) {
			return body, truncated, fmt.Errorf("invalid chunk size %q: out of range", line)
		}
		size := int(size64)

		if truncated {
			// Already over budget: drain and discard this chunk.
			if _, err := io.CopyN(io.Discard, r, int64(size)); err != nil {
				return body, truncated, err
			}
		} else {
			canStore := maxBytes - len(body)
			if size <= canStore {
				chunk := make([]byte, size)
				if _, err := io.ReadFull(r, chunk); err != nil {
					return body, truncated, err
				}
				body = append(body, chunk...)
			} else {
				// Partial read up to budget, drain remainder.
				partial := make([]byte, canStore)
				if _, err := io.ReadFull(r, partial); err != nil {
					return body, truncated, err
				}
				body = append(body, partial...)
				if _, err := io.CopyN(io.Discard, r, int64(size-canStore)); err != nil {
					return body, truncated, err
				}
				truncated = true
			}
		}

		// Consume trailing CRLF after chunk data.
		r.ReadString('\n')
	}

	return body, truncated, nil
}

// extractURL returns the URL from an HTTP request line (first line of httpHeaders).
func extractURL(httpHeaders string) string {
	line, _, _ := strings.Cut(httpHeaders, "\n")
	parts := strings.Fields(strings.TrimRight(line, "\r"))
	if len(parts) >= 2 {
		return parts[1]
	}
	return ""
}

// extractMethod returns the HTTP method from an HTTP request line.
func extractMethod(httpHeaders string) string {
	line, _, _ := strings.Cut(httpHeaders, "\n")
	parts := strings.Fields(strings.TrimRight(line, "\r"))
	if len(parts) >= 1 {
		return parts[0]
	}
	return ""
}

// isClosedErr returns true for "use of closed network connection" errors that
// occur when the listener is shut down gracefully.
func isClosedErr(err error) bool {
	return strings.Contains(err.Error(), "use of closed network connection")
}
