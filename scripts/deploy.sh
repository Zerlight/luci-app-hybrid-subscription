#!/bin/sh
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
HOST=${1:?Usage: scripts/deploy.sh root@router}
# Uses the caller's normal SSH configuration and authentication, never stored credentials.
ARCHIVE=$(mktemp -t hybrid-subscription.XXXXXX)
trap 'rm -f "$ARCHIVE"' EXIT HUP INT TERM
(cd "$HERE" && COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" root htdocs po LICENSE NOTICE scripts/install-router.sh)
ssh "$HOST" 'umask 077; mkdir -p /tmp/hybrid-subscription-install; cat > /tmp/hybrid-subscription-install/package.tgz' < "$ARCHIVE"
ssh "$HOST" 'tar -xzf /tmp/hybrid-subscription-install/package.tgz -C /tmp/hybrid-subscription-install; /bin/sh /tmp/hybrid-subscription-install/scripts/install-router.sh'
