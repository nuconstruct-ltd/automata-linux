#!/bin/sh
set -e

IDENTITY_FILE="/etc/identity.env"

if [ -f "$IDENTITY_FILE" ]; then
  set -a
  . "$IDENTITY_FILE"
  set +a
fi

envsubst < /etc/vmagent/vmagent.yml > /tmp/vmagent.yml

exec /vmagent-prod \
  -promscrape.config=/tmp/vmagent.yml \
  "$@"
