#!/usr/bin/env bash
set -euo pipefail
ports=$(mktemp)
./tls_server.exe > "$ports" &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; rm -f "$ports"' EXIT
for attempt in {1..100}; do
  test -s "$ports" && break
  sleep 0.1
done
read -r http1_port h2_port stall_port < "$ports"
cert="$PWD/fixtures/server.pem"
SSL_CERT_FILE="$cert" ./tls_probe.exe lwt "https://localhost:$http1_port/ok" ok
SSL_CERT_FILE="$cert" ./tls_probe.exe async "https://localhost:$h2_port/ok" ok
for client in lwt async; do
  port=$http1_port
  test "$client" = async && port=$h2_port
  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt ./tls_probe.exe "$client" "https://localhost:$port/ok" error
  SSL_CERT_FILE="$cert" ./tls_probe.exe "$client" "https://127.0.0.1:$port/ok" error
  SSL_CERT_FILE="$cert" ./tls_probe.exe "$client" "https://localhost:$stall_port/ok" timeout
done
SSL_CERT_FILE="$cert" ./tls_probe.exe async "https://localhost:$http1_port/ok" error
SSL_CERT_FILE="$cert" ./tls_probe.exe lwt "https://localhost:$http1_port/downgrade" error
echo 'Native TLS tests passed (trust roots, hostname, ALPN and handshake timeout)'
