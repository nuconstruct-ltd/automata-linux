#!/bin/sh
. /etc/discover-identity.sh
sed -e "s|\${VM_NAME}|$VM_NAME|g" \
    -e "s|\${CSP}|$CSP|g" \
    -e "s|\${PUBLIC_IP}|$PUBLIC_IP|g" \
    -e "s|\${REGION}|$REGION|g" \
    /etc/vmagent/vmagent.yml > /tmp/vmagent.yml
exec /vmagent-prod -promscrape.config=/tmp/vmagent.yml "$@"
