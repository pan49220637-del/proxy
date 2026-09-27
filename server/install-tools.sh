#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash server/install-tools.sh" >&2
  exit 1
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y mtr-tiny jq netcat-openbsd dnsutils tcpdump traceroute curl
install -o root -g root -m 0755 "$repo_dir/proxy-diag" /usr/local/sbin/proxy-diag
install -o root -g root -m 0755 "$repo_dir/proxy-capture" /usr/local/sbin/proxy-capture

echo "Installed: /usr/local/sbin/proxy-diag and /usr/local/sbin/proxy-capture"
echo "Smoke test: sudo /usr/local/sbin/proxy-diag"
