#!/bin/sh
# Load identity from toolkit-generated file
[ -f /etc/identity.env ] && . /etc/identity.env
export VM_NAME="${VM_NAME:-$(hostname)}" CSP="${CSP:-unknown}" PUBLIC_IP="${PUBLIC_IP:-unknown}" REGION="${REGION:-unknown}"

sed -e "s|\${VM_NAME}|$VM_NAME|g" \
    -e "s|\${CSP}|$CSP|g" \
    -e "s|\${PUBLIC_IP}|$PUBLIC_IP|g" \
    -e "s|\${REGION}|$REGION|g" \
    /etc/vmagent/vmagent.yml > /tmp/vmagent.yml
exec /vmagent-prod -promscrape.config=/tmp/vmagent.yml "$@"
