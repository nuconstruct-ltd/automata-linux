# On-chain Workflows

This document will host several diagrams that explain different parts of the on-chain attestation workflow at a high level.

## Uploading Golden Measurements
For the following example given below, we make the following assumptions:
- The workload uses the [sample application contract](https://github.com/automata-network/automata-tee-workload-measurement/blob/main/src/mock/MockCVMExample.sol) without any modifications to the function `addGoldenMeasurement`.

```mermaid
sequenceDiagram
    participant WO as Workload Owner
    participant AA as Attestation Agent
    participant AC as Application Contract

    WO->>AA: GET /onchain/golden-measurement
    AA-->>WO: base64(measurement)
    WO->>WO: base64-decode measurement <br/> calldata = abiEncode("addGoldenMeasurement", measurement)
    WO->>AC: submitTX(calldata)
```

## CVM Registration

### Verification of TEE Collaterals
The registration process involves verifying all TEE collaterals on the CVM Registry Contract. We support two types of TEE attestation report verification - direct verification of signatures and certs on-chain (which we will call "Solidity verification"), or via a Groth-16 zkProof using either of the remote prover networks, Succinct SP1 or Risc0 Bonsai.

Below, we show the workflow of using direct Solidity Verification vs using zkProofs:

#### Solidity Verification

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant RC as Registry Contract

    CVM->>AA: POST /onchain/registration-collaterals <br/> (report_type: 1, chain_id: 11155111)
    AA-->>CVM: base64(calldata)
    CVM->>CVM: base64-decode calldata
    CVM->>RC: submitTX(calldata)
```

In the above scenario, `calldata = abiEncode("registerCvm", cloudType, teeType, teeTTL, teeReportType, teeAttestationReport, cvmIdentity, cvmCertification, workloadCollaterals)`.

#### Groth-16 zkProof Verification
- When report_type = 2, Succinct SP1 zkProver network is used.
- When report_type = 3, Risc0 Bonsai zkProver network is used.

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant PP as Remote ZkProver
    participant RC as Registry Contract

    CVM->>AA: POST /onchain/registration-collaterals <br/> (report_type: 2/3, chain_id: 11155111, image_id=XXX, api_key=XXX, version=XXX)
    AA->>PP: (TEE report, certs)
    PP-->>AA: Groth-16 zkProof
    AA-->>CVM: base64(calldata)
    CVM->>CVM: base64-decode calldata
    CVM->>RC: submitTX(calldata)
```

In the above scenario, `calldata = abiEncode("registerCvm", cloudType, teeType, teeTTL, teeReportType, teeAttestationReport, cvmIdentity, cvmCertification, workloadCollaterals)`.

### Registration of CVM Identity
Once all TEE collaterals are verified, a VM-unique public key, which is sent together with the calldata, will be registered on the CVM Registry contract. This key will represent the CVM onchain. This registered public key will also thus be known as the "CVM Identity". After successful registration, any message signed by this CVM's registered VM Identity Key can be considered trusted for a fixed TTL. 

Once the TTL has expired, the CVM must reattest its TEE collaterals with the Registry contract again. To reattest, please check the next section for the workflow.

## Refreshing CVM Registration

When a CVM's TEE attestation TTL expires, or if the workload wants to renew attestation without changing the CVM identity, the `refreshCvm` contract method can be used. This is similar to registration but does not rotate the CVM identity key. Note that you must perform a registration ONCE before you can successfully run this refreshing workflow.

### Solidity Verification

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant RC as Registry Contract

    CVM->>AA: POST /onchain/refresh-cvm <br/> (report_type: 1, chain_id: 11155111)
    AA-->>CVM: base64(calldata)
    CVM->>CVM: base64-decode calldata
    CVM->>RC: submitTX(calldata)
```

### Groth-16 zkProof Verification
- When report_type = 2, Succinct SP1 zkProver network is used.
- When report_type = 3, Risc0 Bonsai zkProver network is used.

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant PP as Remote ZkProver
    participant RC as Registry Contract

    CVM->>AA: POST /onchain/refresh-cvm <br/> (report_type: 2/3, chain_id: 11155111, tee_ttl: 0, zk_config: {...})
    AA->>PP: (TEE report, certs)
    PP-->>AA: Groth-16 zkProof
    AA-->>CVM: base64(calldata)
    CVM->>CVM: base64-decode calldata
    CVM->>RC: submitTX(calldata)
```

In the above scenarios, `calldata = abiEncode("refreshCvm", cvmIdentityHash, teeTTL, teeReportType, teeAttestationReport, workloadCollaterals)`.

**Note**: The `tee_ttl` parameter is optional. Setting it to 0 or omitting it means the contract will use its default TTL value.

## CVM Verification

For the following example workflow that we will showcase, we make the following assumptions:
- That the Verifier and Attester are both workloads running in the CVM (ie, they are performing mutual verification). Note that this does not have to be the case, and depends on your workload architecture.
- The workload uses the [sample application contract](https://github.com/automata-network/cvm-onchain-verifier/blob/main/contracts/src/mock/MockCVMExample.sol) without any modifications to the function `checkCVMSignature`.

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
    V->>V: base64-decode <br/> calldata = abiEncode("checkCVMSignature", cvmIdentityHash, message, signature)
    V->>AC: submitTX(calldata)
```

## Rotating CVM Identity

There are instances where the workload might want to rotate the key used for signing messages. Note that for this workflow to work, the TEE TTL on the CVMRegistry contract must still be valid. This is a high level workflow of the steps that need to be taken to rotate the CVM's message signing key:

```mermaid
sequenceDiagram
    participant CVM as CVM Workload
    participant AA as Attestation Agent
    participant RC as Registry Contract

    rect rgb(229,255,204)
        Note over CVM,RC: 1. Request new cvm-identity
        CVM->>AA: GET /onchain/new-cvm-identity
        AA-->>CVM: base64(calldata)
    end

    rect rgb(255,226,226)
        Note over CVM,RC: 2. Register new identity on-chain
        CVM->>CVM: base64-decode calldata
        CVM->>RC: submitTX(calldata)
        RC-->>CVM: Success
    end

    rect rgb(229,255,204)
        Note over CVM, RC: 3. Sign message with new key
        CVM->>AA: POST /sign-message <br/>(message, purge_old_keys=true)
        AA-->>CVM: {base64(cvmIdentityHash), base64(signature)}
    end

```

In the above diagram, for Step 3, `calldata = abiEncode("rotateCvmIdentityKey", cvmIdentityHash, newCvmIdentity, newCvmCertification)`.
