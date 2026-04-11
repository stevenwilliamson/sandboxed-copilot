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
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
)

const (
	listenAddr   = "127.0.0.1:1344"
	maxScanBytes = 1 * 1024 * 1024 // 1 MB body scan limit
)

// exfilLog is the file handle for /var/log/squid/exfil.log.
// ICAP detections are appended here in the format:
//
//	ICAP <timestamp> <client-ip> <method> <url> <http-status> detection:<location>
var exfilLog *os.File

func main() {
	log.SetPrefix("[icap-scanner] ")
	log.SetFlags(log.LstdFlags)

	// Open exfil log for appending. If unavailable fall back to stdout so
	// the process still runs (entrypoint creates the file before us, but
	// handle the edge case gracefully).
	var err error
	exfilLog, err = os.OpenFile(exfilLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		log.Printf("warning: cannot open exfil log %s: %v — logging to stdout", exfilLogPath, err)
		exfilLog = os.Stdout
	}

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
			break
		}
		go handleConn(conn)
	}

	log.Println("stopped")
}
