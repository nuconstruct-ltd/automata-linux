echo "==============================================================="
TOKEN=$(cat token)
echo "API Token: ${TOKEN}"
echo "API token has been saved to ./token."
echo "This API token can be used with \`./cvm-cli update-workload\` to update the workload securely."
