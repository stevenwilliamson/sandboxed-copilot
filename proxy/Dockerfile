# ── Stage 1: build the ICAP token scanner ───────────────────────────────────
# Uses the same ubuntu:24.04 base as the final image so Docker reuses the
# cached layer — no additional registry pull is required.
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y golang-go && rm -rf /var/lib/apt/lists/*

COPY icap-scanner/ /src/
WORKDIR /src
# CGO_ENABLED=0 produces a fully static binary with no libc dependency.
RUN CGO_ENABLED=0 go build -o /icap-scanner .

# ── Stage 2: proxy image ─────────────────────────────────────────────────────
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# squid-openssl provides Squid compiled with OpenSSL ssl_bump support.
# openssl is needed for the security_file_certgen helper (ssl_db init).
RUN apt-get update && apt-get install -y \
    squid-openssl \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# ICAP token scanner binary (compiled in builder stage; no Go toolchain needed).
COPY --from=builder /icap-scanner /usr/local/bin/icap-scanner

COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3128

ENTRYPOINT ["/entrypoint.sh"]
