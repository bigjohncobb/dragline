#!/usr/bin/env bash
# Dragline deployment script
#
# Usage: deploy.sh <instance>
#   instance — the systemd instance identifier, e.g. "1" or "prod"
#
# This script must be run as a user with sudo rights for systemctl,
# or as root on the deployment host.
#
# Adjust INSTALL_DIR if Dragline is not installed at /opt/dragline.

set -euo pipefail

INSTALL_DIR="/opt/dragline"

# ------------------------------------------------------------------ validation
if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "Usage: $0 <instance>" >&2
    echo "  Example: $0 1" >&2
    echo "  Example: $0 prod" >&2
    exit 1
fi

INSTANCE="$1"

# Sanity check: instance identifier must be alphanumeric/dash/underscore only
if ! [[ "$INSTANCE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: instance identifier must be alphanumeric (got: '$INSTANCE')" >&2
    exit 1
fi

ENV_FILE="/etc/dragline/${INSTANCE}.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    echo "Create it with at minimum: DRAGLINE_SECRET, DRAGLINE_DB, DRAGLINE_PORT" >&2
    exit 1
fi

echo "==> Deploying Dragline instance '$INSTANCE'"

# ------------------------------------------------------------------ update code
cd "$INSTALL_DIR"

echo "==> Pulling latest code"
git pull origin main --rebase

echo "==> Resetting to remote HEAD"
git reset --hard origin/main

# ------------------------------------------------------------------ dependencies
echo "==> Installing CPAN dependencies"
cpanm --installdeps --local-lib local .

# ------------------------------------------------------------------ syntax check
echo "==> Checking syntax"
perl -Ilocal/lib/perl5 -c dragline.pl || {
    echo "Error: syntax check failed. Aborting deploy." >&2
    exit 1
}

# ------------------------------------------------------------------ restart services
echo "==> Restarting dragline@${INSTANCE}"
systemctl restart "dragline@${INSTANCE}"

echo "==> Restarting dragline-worker@${INSTANCE}"
systemctl restart "dragline-worker@${INSTANCE}"

# ------------------------------------------------------------------ done
echo ""
echo "Deployed successfully to instance '${INSTANCE}'."
echo "Web:    systemctl status dragline@${INSTANCE}"
echo "Worker: systemctl status dragline-worker@${INSTANCE}"
