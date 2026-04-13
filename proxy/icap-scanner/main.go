// ICAP token exfiltration scanner for sandboxed-copilot.
//
// Listens on 127.0.0.1:1344 and handles Squid REQMOD requests.
// Scans request bodies for GitHub token patterns and blocks requests
// that contain a token destined for non-GitHub infrastructure.
//
// Detection is complementary to the Squid ACL rules in squid.conf which
// cover Authorization headers and URLs; this service adds body scanning
// for POST/PUT/PATCH requests.
package main

import (
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

const (
	listenAddr   = "127.0.0.1:1344"
	maxScanBytes = 1 * 1024 * 1024 // 1 MB body scan limit
)

// exfilCh is the channel used to pass detection log lines to the single
// writer goroutine that owns the exfil.log file handle. All goroutines
// must send here rather than writing to the file directly, to avoid
// concurrent-write races. Buffered to absorb bursts without blocking callers.
var exfilCh chan string

func main() {
	log.SetPrefix("[icap-scanner] ")
	log.SetFlags(log.LstdFlags)

	// Open exfil log for appending. If unavailable fall back to stdout so
	// the process still runs (entrypoint creates the file before us, but
	// handle the edge case gracefully).
	f, err := os.OpenFile(exfilLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("warning: cannot open exfil log %s: %v — logging to stdout", exfilLogPath, err)
		f = os.Stdout
	}

	// Start the single log-writer goroutine. It is the only owner of f.
	exfilCh = make(chan string, 256)
	var writerDone sync.WaitGroup
	writerDone.Add(1)
	go func() {
		defer writerDone.Done()
		for line := range exfilCh {
			if _, werr := f.WriteString(line); werr != nil {
				fmt.Fprintf(os.Stderr, "[icap-scanner] ERROR: failed to write exfil log: %v\n", werr)
			}
		}
	}()

	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", listenAddr, err)
	}
	log.Printf("listening on %s", listenAddr)

	// Shut down cleanly on SIGTERM/SIGINT.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sig
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			// Listener closed means we're shutting down cleanly.
			if errors.Is(err, net.ErrClosed) {
				break
			}
			// Log transient errors (e.g. EMFILE, ECONNABORTED) and keep accepting.
			log.Printf("accept error: %v", err)
			continue
		}
		go handleConn(conn)
	}

	// Drain the log channel before exiting so no detection events are lost.
	close(exfilCh)
	writerDone.Wait()
	log.Println("stopped")
}
