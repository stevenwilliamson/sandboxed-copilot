FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# squid-openssl provides Squid compiled with OpenSSL ssl_bump support.
# openssl is needed for the security_file_certgen helper (ssl_db init).
RUN apt-get update && apt-get install -y \
    squid-openssl \
    openssl \
    && rm -rf /var/lib/apt/lists/*

COPY squid.conf /etc/squid/squid.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3128

ENTRYPOINT ["/entrypoint.sh"]
