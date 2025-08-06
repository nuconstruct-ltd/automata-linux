
DIR="secure_boot"
LIVEPATCH_KEY_NAME="$DIR/livepatch"

set -e

if [ -f "$LIVEPATCH_KEY_NAME.key" ] && [ -f "$LIVEPATCH_KEY_NAME.crt" ]; then
  echo "Livepatch keys already exist. Skipping generation."
else
  echo "Generating livepatch keys..."
  openssl req -newkey rsa:2048 -nodes -keyout "$LIVEPATCH_KEY_NAME.key" -new -x509 -sha256 -days 20000 -subj "/CN=Livepatch Key/" -out "$LIVEPATCH_KEY_NAME.pem"
  openssl x509 -outform DER -in "$LIVEPATCH_KEY_NAME.pem" -out "$LIVEPATCH_KEY_NAME.crt"
  echo "Livepatch keys generated successfully."
fi