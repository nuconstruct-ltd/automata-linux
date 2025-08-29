# On-chain Workflows

This document will host several diagrams that explain different parts of the on-chain attestation workflow at a high level.

## Uploading Golden Measurements

```mermaid
sequenceDiagram
    participant WO as Workload Owner
    participant AA as Attestation Agent
    participant AC as Application Contract

    WO->>AA: GET /onchain/golden-measurement
    AA-->>WO: base64(measurement)
    note over WO: base64-decode measurement <br/> calldata = abiEncode("addGoldenMeasurement", measurement)
    WO->>AC: submitTX(calldata)
```

## CVM Registration

The registration process involves verifying all TEE collaterals and registering a VM-unique public key to represent the VM on the Registry contract. This registered public key will also thus be known as the "VM Identity". Once successful registration has happened, any message signed by this CVM's registered VM Identity Key can be considered trusted for a fixed TTL. Once the TTL has expired, the CVM must reattest its TEE collaterals with the Registry contract again. To reattest, simply perform the registration steps again.

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant RC as Registry Contract

    CVM->>AA: POST /onchain/registration-collaterals
    AA-->>CVM: base64(calldata)
    note over CVM: base64-decode calldata
    CVM->>RC: submitTX(calldata)
```

In the above scenario, `calldata = abiEncode("attestCvm", cloudType, teeType, teeReportType, teeAttestationReport, workloadCollaterals)`.

## CVM Verification

In this workflow, we can assume that the Verifier and Attester are both workloads running in the CVM. (ie, they are performing mutual verification)

```mermaid
sequenceDiagram
    participant V as Verifier
    participant AT as Attester
    participant AA as Attestation Agent
    participant AC as Application Contract

    V->>AT: message
    AT->>AA: POST /sign-message <br/> (message)
    AA-->>AT: {base64(cvmIdentityHash), base64(signature)}
    AT-->>V: {base64(cvmIdentityHash), base64(signature)}
    note over V: base64-decode <br/> calldata = abiEncode("checkCVMSignature", cvmIdentityHash, message, signature)
    V->>AC: submitTX(calldata)
```

## Rotating CVM Identity

There are instances where the workload might want to rotate the key used for signing messages. This is a high level workflow of the steps that need to be taken to rotate the CVM's message signing key:

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant RC as Registry Contract

    rect rgb(255,226,226)
        Note over CVM,RC: 1. Get nonce
        CVM->>AA: GET /current-cvm-identity-hash
        AA-->>CVM: base64(cvmIdentityHash)
        note over CVM: base64-decode <br/> calldata = abiEncode("nonces", cvmIdentityHash)
        CVM->>RC: submitTX(calldata)
        RC-->>CVM: abiEncode(nonce)
        note over CVM: nonce = abiDecode(abiEncode(nonce))
    end

    rect rgb(229,255,204)
        Note over CVM,RC: 2. Request new cvm-identity
        CVM->>AA: POST /onchain/new-cvm-identity<br/>(nonce, chainId, contractAddress)
        AA-->>CVM: base64(calldata)
    end

    rect rgb(255,226,226)
        Note over CVM,RC: 3. Register new identity on-chain
        note over CVM: base64-decode calldata
        CVM->>RC: submitTX(calldata)
        RC-->>CVM: Success
    end

    rect rgb(229,255,204)
        Note over CVM, RC: 4. Sign message with new key
        CVM->>AA: POST /sign-message <br/>(message, purge_old_keys=true)
        AA-->>CVM: {base64(cvmIdentityHash), base64(signature)}
    end

```

In the above diagram, for Step 3, `calldata = abiEncode("reattestCvmWithTpm", cvmIdentityHash, calldata signature, workloadCollaterals)`.
