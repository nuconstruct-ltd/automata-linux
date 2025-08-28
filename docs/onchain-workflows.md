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
    note over WO: Base64-decode measurement
    WO->>AC: submit(addGoldenMeasurement)
```

## CVM Registration

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant RC as Registry Contract

    CVM->>AA: POST /onchain/registration-collaterals
    AA-->>CVM: base64(calldata)
    note over CVM: Base64-decode calldata
    CVM->>RC: submit(attestCvm)
```

## CVM Verification

```mermaid
sequenceDiagram
    participant V as Verifier
    participant AT as Attester
    participant AA as Attestation Agent
    participant AC as Application Contract

    V->>AT: message
    AT->>AA: POST /sign-message (message)
    AA-->>AT: {base64(cvmIdentityHash), base64(signature)}
    AT-->>V: {base64(cvmIdentityHash), base64(signature)}
    note over V: Base64-decode<br/>Construct on-chain calldata
    V->>AC: checkCVMSignature(cvmIdentityHash, message, signature)
```

## Rotating CVM Identity

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant RC as Registry Contract

    CVM->>AA: GET /current-cvm-identity-hash
    AA-->>CVM: base64(cvmIdentityHash)
    note over CVM: Base64-decode & build calldata
    CVM->>RC: nonces(cvmIdentityHash)
    RC-->>CVM: nonce
    CVM->>AA: POST /onchain/new-cvm-identity<br/>(nonce, chainId, contractAddress)
    AA-->>CVM: base64(calldata)
    note over CVM: Base64-decode calldata
    CVM->>RC: submit(reattestCvmWithTpm)
```