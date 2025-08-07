#!/bin/bash

# quit when any error occurs
set -Eeuo pipefail

# 1. Convert all the certs to PEM format, then create ESL files
openssl x509 -in secure_boot/PK.crt -inform DER -out secure_boot/PK.pem -outform PEM
openssl x509 -in secure_boot/KEK.crt -inform DER -out secure_boot/KEK.pem -outform PEM
openssl x509 -in secure_boot/db.crt -inform DER -out secure_boot/db.pem -outform PEM
openssl x509 -in secure_boot/kernel.crt -inform DER -out secure_boot/kernel.pem -outform PEM

cert-to-efi-sig-list secure_boot/PK.pem secure_boot/PK.esl
cert-to-efi-sig-list secure_boot/KEK.pem secure_boot/KEK.esl
cert-to-efi-sig-list secure_boot/db.pem secure_boot/db.esl
cert-to-efi-sig-list secure_boot/kernel.pem secure_boot/kernel.esl

if [ -f secure_boot/livepatch.crt ]; then
  openssl x509 -in secure_boot/livepatch.crt -inform DER -out secure_boot/livepatch.pem -outform PEM
  cert-to-efi-sig-list secure_boot/livepatch.pem secure_boot/livepatch.esl
  cat secure_boot/db.esl secure_boot/kernel.esl secure_boot/livepatch.esl > secure_boot/db_combined.esl
else
  cat secure_boot/db.esl secure_boot/kernel.esl > secure_boot/db_combined.esl
fi

# 2. Create the UEFI blob
UEFI_BLOB="secure_boot/aws-uefi-blob.bin"
./tools/python-uefivars/uefivars -i none -o aws -O $UEFI_BLOB -P secure_boot/PK.esl -K secure_boot/KEK.esl -b secure_boot/db_combined.esl

# 3. Remove temporary files
rm secure_boot/*.pem secure_boot/*.esl

set +e