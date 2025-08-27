# CVM-Agent API Reference

The server will broadcast on 2 ports:
- HTTPS: 0.0.0.0:8000 (for queries from outside of the TEE environment) 
- HTTP: 127.0.0.1:7999 (for internal workload use).

## Generic APIs
- `/platform` [GET]
    - Port Availability: 7999
    - Returns information about the platform's TEE and cloud type
    - Response:
    ```json
    {
        "tee_type": <uint8>,
        "tee_name": <string>,
        "cloud_type": <uint8>,
        "cloud_name": <string>
    }
    ```

- `/sign-message` [POST]
    - Port Availability: 7999
    - Sign a message using a p256 key (that lives in the CVM's vTPM) that uniquely identifies the CVM.
    - **NOTE**: Set "purge-old-keys" to true in the request if you wish to use the new key generated in the API `/onchain/new-cvm-identity`. Make sure you have previously registered the new identity on-chain, if you're using the signed message with an on-chain contract.
    - Request Body:
    ```json
    {
        "message": <string>,
        "purge-old-keys": true/false
    }
    ```
    - Response:
    ```json
    {
        "cvm_identity_hash": <base64-encoded string>, // keccak256 hash
        "signature": <base64-encoded string> // p256 signature
    }
    ```

- `/current-cvm-identity-hash` [GET]
    - Port Availability: 7999
    - Get the current CVM's identity as a keccak256 hash.
    - Response:
    ```json
    {
        "cvm_identity_hash": <base64-encoded string> // keccak256 hash
    }
    ```

## Attestation APIs

### On-chain APIS
- `/onchain/golden-measurement` [POST]
    - Port Availability: 8000
    - Generates onchain golden measurements for the current CVM. Returns a hash that can be uploaded to a user application contract.
    - Example Request: `curl -X POST -k https://<vm-ip>:8000/onchain/golden-measurement -H "Content-Type: application/json" -d '{"report_type":1}'`
    - **Note: In the current version, we only support Solidity verification for TDX and Risc0 zkProof for SEV-SNP.**
    - Request Body:
    ```json
    {
        "report_type": <integer>, // 1: Solidity verification, 2: SP1 zkProof, 3: Risc0 zkProof
        "zk_config": {
            // Optional ZK proof configuration, omit if using Solidity verification
            "image_id": <string>,
            "url": <string>,
            "api_key": <string>,
            "version": <string>
        }
    }
    ```
    - Response:
    ```json
    {
        "golden_measurement": <base64-encoded string>
    }
    ```

- `/onchain/registration-collaterals` [POST]
    - Port Availability: 7999
    - Retrieve collaterals required for cvm registration on-chain.
    - Example Request: `curl -X POST http://127.0.0.1:7999/onchain/registration-collaterals -H "Content-Type: application/json" -d '{"report_type":1}'`
    - **Note: In the current version, we only support Solidity verification for TDX and Risc0 zkProof for SEV-SNP.**
    - Request Body:
    ```json
    {
        "report_type": <integer>, // 1: Solidity verification, 2: SP1 zkProof, 3: Risc0 zkProof
        "zk_config": {
            // Optional ZK proof configuration, omit if using Solidity verification
            "image_id": <string>,
            "url": <string>,
            "api_key": <string>,
            "version": <string>
        }
    }
    ```
    - Response:
    ```json
    {
        // abi-encoded data for:
        // attestCvm(CloudType cloudType, TEEType teeType, TeeReportType teeReportType, bytes calldata teeAttestationReport, WorkloadCollaterals calldata wc)
        // can be placed directly into tx.data after base64-decoding
        "calldata": <base64 encoded string>
    }
    ```

- `/onchain/new-cvm-identity` [POST]
    - Port Availability: 7999
    - Generate a new p256 keypair for the CVM.
    - **Note**: The key is not immediately rotated on the CVM. CVM-Agent will continue to sign messages using the old key until users explicitly specify that they would like to sign a message using the new key (using `/sign-message` API). Afterwhich, the old key will be purged, and only the new key can be used.
    - **Note**: Nonce should be queried from the Registry Contract by the workload. 
    - Content-Type: application/json
    - Example Request: `curl -X POST http://127.0.0.1:7999/onchain/new-cvm-identity -H "Content-Type: application/json" -d '{"nonce": "0", "chain_id": 31337, "contract_address": "0x3cd4E8a3644ddc8b16954A9f50Fd0Dc0185161aC"}'`
    - Request Body:
    ```json
    {
        "nonce": "0", "chain_id": 31337, "contract_address": "0x3cd4E8a3644ddc8b16954A9f50Fd0Dc0185161aC"
    }
    ```
    - Response:
    ```json
    {
        // abi-encoded data for:
        // reattestCvmWithTpm(bytes32 cvmIdentityHash, bytes calldata signature, WorkloadCollaterals calldata wc)
        // can be placed directly into tx.data after base64-decoding
        "calldata": <base64 encoded bytes>
    }
    ```


### Off-Chain APIs

- `/offchain/verify` [POST]
    - Port Availability: 7999
    - Verifies CVM collaterals against golden measurements
    - Request Body:
    ```json
    {
        "collaterals_path": <string>,
        "golden_measurement_path": <string>,
        // Or provide the data directly:
        "collaterals": <string>,
        "golden_measurement": <string>
    }
    ```
    - Response:
    ```json
    {
        "success": <boolean>,
        "error": <string, optional>
    }
    ```

- `/offchain/collaterals/{nonce}`: [GET]
    - Port Availability: 7999, 8000
    - The nonce is used as it is for the TPM quote.
    - report_data field in the attestation report should contain the following:
      - On GCP/AWS: 0 * 64
      - On Azure: sha256sum(HclVarData) || 0*32
    - extra_data field in the TPM Quote should contain the following:
      - On Azure/AWS/GCP: magic || nonce
    - magic = "External/collaterals" or "Internal/collaterals"
    - Response:
    ```json
    {
        // Only sev_snp or tdx will be returned, not both at the same time.
        "sev_snp":
        {
            "attestation_report": <base64 encoded bytes>,
            "vek_cert": <base64 encoded bytes of X509 DER-encoded cert>
        },
        // Only sev_snp or tdx will be returned, not both at the same time.
        "tdx":
        {
            "attestation_report": <base64 encoded bytes>
        },
        "tpm":
        {
            "quote": <base64 encoded bytes>,
            "raw_sig": <base64 encoded bytes>,
            "pcrs":
            {
                "hash": <int, hash algorithm used for the values in the PCR>,
                // PCR number -> base64 encoded value of the value in the PCR
                "pcrs": <map<uint32><base64 encoded bytes>>
            },
            // Only used when ak_cert exists
            "ak_cert": <base64 encoded bytes of X509 DER-encoded cert>,
            // Only used if ak_pub is needed
            "ak_pub": <base64 encoded bytes of X509 DER-encoded SubjectPublicKeyInfo>,
            // Only used in Azure
            "var_data": <base64 encoded bytes>
        },
        "magic": <base64 encoded bytes>,
        "nonce": <base64 encoded bytes>,
        // 16-byte UUID, only used in GCP TDX.
        "uuid": <base64 encoded bytes>,
        "boot_log_tpm": <base64 encoded bytes>,
        // Only used in GCP TDX.
        "boot_log_ccel": <base64 encoded bytes>
    }
    ```

- `/offchain/golden-measurement` [GET]
    - Port Availability: 8000
    - Generates offchain golden measurements for the current CVM
    - **Important Note**: Generated golden measurements are specific to:
        - The CVM type (SEV-SNP, TDX)
        - The cloud provider (Azure, GCP, AWS)
        - The VM size/configuration
    - Image/Workload creators must generate separate golden measurements for each unique combination of VM type, size, and cloud provider
    - Response:
    ```json
    {
        "golden_measurement": <json object>,
        "error": <string, optional>
    }
    ```

## Management APIs
- `/update-workload`: [POST]
    - Port Availability: 8000
    - Used to update the current workload on the server by uploading a .zip file containing a `workload/` folder.
    - It requires the following folder structure:
      ```
      workload/
          config/
              - all config files go here
          secrets/
              - all secrets go here
          docker-compose.yml
      ```
    - Requires authentication via a Bearer token.
    - Headers: `Authorization: Bearer <token>` (Required. Used for authenticating the request.)
    - Content-Type: multipart/form-data
    - Body: file (required): A .zip file uploaded via form-data.
    - Example: `curl -X POST -F "file=@output.zip" -H "Authorization: Bearer abcde12345" -k "https://<ip>:8000/update-workload"`
    - Returns a successful response after the new workload is successfully measured and running.

- `/container-logs?name=ContainerA&name=ContainerB`: [GET]
  - Port Availability: 8000
  - Retrieve specified containers' logs. If no container names are provided, it will retrieve the logs from all containers.
  - Requires authentication via a Bearer token.
  - Headers: `Authorization: Bearer <token>` (Required. Used for authenticating the request.)
  - Example: Retrieve all container logs `curl -H "Authorization: Bearer abcde12345" -k "https://<ip>:8000/container-logs"`
  - Response:
    ```json
    [
        {
            // Container Name
            "name": <string>,
            // Raw container logs
            "log": <string>
        },
        ...
    ]
    ```

- `/maintenance-mode` [POST]
    - Port Availability: 8000
    - Purpose: Toggle the CVM into or out of maintenance mode by enabling / disabling SSH access to the operator container.
    - Authentication: same as `/update-workload` endpoint
    - Example Requests:
    ```bash
        # Immediately disable SSH
        curl -H "Authorization: Bearer abcde12345" \
            -X POST -k https://<ip>:8000/maintenance-mode \
            -H "Content-Type: application/json" \
            -d '{"action":"disable"}'

        # Enable SSH again after 30 s
        curl -H "Authorization: Bearer abcde12345" \
            -X POST -k https://<ip>:8000/maintenance-mode \
            -H "Content-Type: application/json" \
            -d '{"action":"enable","delay_seconds":30}'
    ```
    - Success Response
    ```json
    {
        "status": "maintenance mode triggered",
        "maintenance_action": "enable",
        "port": "2222",
        "delay_seconds": 0,
        "results": {
            "operator": "operator\n"
        },
        "timestamp": "2025-07-01T01:34:32Z"
    }
    ```

- `/livepatch` [POST]
    - Port Availability: 8000
    - Purpose: Upload a kernel livepatch, which will be loaded onto the CVM. Note that livepatch must be built with `REPLACE=1`.
    - Requires authentication via a Bearer token.
    - Headers: `Authorization: Bearer <token>` (Required. Used for authenticating the request.)
    - Content-Type: multipart/form-data
    - Body: file (required): A <livepatch>.ko file uploaded via form-data.
    - Example Request:
    ```bash
    curl -H "Authorization: Bearer abcde12345" \
        -X POST -F "file=@livepatch.ko" \
        -k "https://<ip>:8000/livepatch"
    ```
    - Success Response
    ```
    Livepatch successfully applied and measured into PCR 16.
    ```
