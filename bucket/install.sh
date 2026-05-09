#!/usr/bin/env bash
# Bucket install — run once as root (or with sudo) on the server
set -euo pipefail

BUCKET_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Creating virtual environment"
python3 -m venv "$BUCKET_DIR/venv"

echo "==> Installing Python dependencies"
"$BUCKET_DIR/venv/bin/pip" install --upgrade pip
"$BUCKET_DIR/venv/bin/pip" install -r "$BUCKET_DIR/requirements.txt"

echo "==> Installing Chromium via Playwright"
"$BUCKET_DIR/venv/bin/playwright" install chromium
"$BUCKET_DIR/venv/bin/playwright" install-deps chromium

echo "==> Installing systemd unit"
cp "$BUCKET_DIR/bucket.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now bucket

echo ""
echo "Bucket is running. Test with:"
echo "  curl -s http://localhost:3002/health"
