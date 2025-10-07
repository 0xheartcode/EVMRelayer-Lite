# Cross-Chain Messaging Protocol

A demo implementation of a cross-chain messaging protocol with 3-phase accountability and delivery tracking on origin chain.

## Overview

This project implements a trustless cross-chain messaging system where users submit messages on a source chain, and a relayer service observes, attests, and delivers them to a destination chain with full accountability. Unlike traditional "fire-and-forget" bridges, this protocol maintains audit trails and cryptographic delivery proofs, allowing users to check message states on the origin network.

### Key Innovation: 3-Phase Accountability Model

1. **Phase 1 - Message Observation:** Relayer claims entire blocks on source chain
2. **Phase 2 - Attested Delivery:** Relayer delivers messages to destination with EIP-712 attestations
3. **Phase 3 - Proof Submission:** Relayer submits cryptographic delivery proofs back to source chain

This creates an accountability loop where the source chain tracks the delivery status of every cross-chain message.

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌──────────────────┐
│   Source Chain  │    │     Relayer     │    │  Dest Chain      │
│                 │    │    Service      │    │                  │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌──────────────┐ │
│ │submitMessage│ │───▶│ │ Observes    │ │───▶│ │executeMessage│ │
│ │emit Event   │ │    │ │ Events      │ │    │ │+ EIP712      │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └──────────────┘ │
│        │        │    │        │        │    │        │         │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │        │         │
│ │confirmBlock │ │◀───│ │ Submits     │ │◀───│────────┘         │
│ │Delivery     │ │    │ │ Proofs      │ │    │                  │
│ └─────────────┘ │    │ └─────────────┘ │    │                  │
└─────────────────┘    └─────────────────┘    └──────────────────┘
    Phase 3 ◀──────────── Phase 1 ──────────▶ Phase 2
```

## Project Structure

```
evmrelayer-lite/
├── contracts/                 # Smart contracts (Solidity + Foundry)
│   ├── src/
│   │   ├── CrossChainSource.sol       # Source chain message acceptance
│   │   └── CrossChainDestination.sol  # Destination chain attestation verification
│   ├── test/                          # Comprehensive contract tests (52 tests)
│   ├── script/                        # Deployment and integration scripts
│   └── README.md                      # Smart contract documentation
├── relayer/                           # Off-chain relayer service (TypeScript)
│   ├── src/
│   │   ├── services/                  # Core relayer logic
│   │   ├── chains/                    # Blockchain clients
│   │   ├── state/                     # State persistence
│   │   └── utils/                     # EIP-712 signatures, logging
│   ├── utils/dockerfiles/             # Docker deployment
│   └── README.md                      # relayer documentation  
├── Makefile                           # Automated demo and development commands
├── DESIGN.md                          # Architectural decisions and reflection
└── README.md                          # We are here (x) 
```

## Quick Start

### Prerequisites
- [Foundry](https://getfoundry.sh/) - Smart contract development
- [Node.js 20+](https://nodejs.org/) - Relayer service
- [pnpm](https://pnpm.io/) - Package management
- [Docker](https://docker.com/) (optional) - Containerized deployment

### One-Command Setup
```bash
# Clone and install everything
git clone <repository-url>
cd evmrelayer-lite
make install  # Installs Foundry dependencies, pnpm packages, builds everything
```

## Automated Demos (Recommended)

The Makefile provides fully automated demos that handle the entire end-to-end flow:

### Option 1: Complete Docker Demo (Simplest)
```bash
make demo-docker
```

**What it does automatically:**
1. Clears relayer state for fresh start
2. Starts two Anvil instances (Chain 31337 & 31338)
3. Deploys contracts to both chains
4. Configures cross-chain contract references and permissions
5. Sends test message: "Hello today we are Thursday 09 October"
6. **Starts relayer in Docker container** with volume persistence
7. Monitors all 3 phases with automatic detection:
   - 🎉 PHASE 1: Block claimed and transaction picked up
   - 🎉 PHASE 2: Message executed on destination chain
   - 🎉 PHASE 3: Delivery proof submitted back to source
8. Shows comprehensive summary and gracefully stops everything

### Option 2: Local Node Demo
```bash
make demo
```

**Same as above but:**
- Runs relayer locally with Node.js (not in Docker)
- Shows TypeScript build process
- Direct access to relayer logs without Docker layers

### Option 3: Custom Message Demo
```bash
MESSAGE="Your custom cross-chain message" make demo-custom-message
```

**Customization:**
- Uses your custom message instead of default
- Otherwise identical to `make demo`
- Perfect for testing specific payloads

## What You'll See During Demo

### Phase 1 - Source Chain Processing
```
Web3 Call: claimBlock(
  blockNumber: 9,
  expectedMessageCount: 1
)
[Tx 0x6c2e25a641777e59...] Block 9 claim transaction sent
PHASE 1 DETECTED: Block claimed!
```

### Phase 2 - Destination Chain Execution  
```
Web3 Call: executeMessage(
  sourceChainId: 31337,
  sourceBlockNumber: 9,
  messageId: 0,
  sender: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
  payload: 0x2f049bf3000000000000000000000000000000000000000000000000000000...,
  destContract: 0x8464135c8F25Da09e49BC8782676a84730C318bC,
  nonce: 0,
  deadline: 1759797595,
  signature: { v: 28, r: 0xc42f27aa3c82b3f3c25cf51ea0d307..., s: 0x19f95b2b71572f5b9b397... }
)
[Tx 0x07bdef10cf2d4d97...] Message 0 execution transaction sent
PHASE 2 DETECTED: Message executed on destination!
```

### Phase 3 - Proof Submission Back to Source
```
Web3 Call: confirmBlockDelivery(
  blockNumber: 9,
  proofs: [
    1. { destTxHash: 0x07bdef10cf2d4d9752ee6fb2d8cfd6dfe2ef1ba4db026a5c8b66bb0288ab9b04, success: true, receiptsRoot: 0x00000000... }
  ]
)
[Tx 0xb30137aa28e7ecf4...] Delivery proof submission for block 9
PHASE 3 DETECTED: Delivery proof submitted!

\o.o/ You have arrived at the end of this script!
🎉 3-Phase Cross-Chain Protocol completed successfully!
```

## Manual Setup (Step-by-Step)

For developers who want granular control or to understand each step:

### 1. Infrastructure Setup
```bash
# Start two local blockchain networks
make start-anvil
# This runs:
# - anvil --port 8545 --chain-id 31337 (Source chain)  
# - anvil --port 8546 --chain-id 31338 (Destination chain)
# - Both use default Anvil test accounts with 10,000 ETH each
```

### 2. Smart Contract Deployment
```bash
# Deploy and configure everything in one command
make setup
```

**This runs sequentially:**
```bash
make deploy-source      # Deploy CrossChainSource to chain 31337
make deploy-dest        # Deploy CrossChainDestination to chain 31338  
make configure-source   # Grant RELAYER_ROLE permissions on source
make configure-dest     # Configure cross-chain references on destination
make verify-source      # Verify source chain deployment and config
make verify-dest        # Verify destination chain deployment and config
```

**What each deploy step does:**
- **Source Chain:** Deploys `CrossChainSource.sol` with domain separator for EIP-712
- **Destination Chain:** Deploys `CrossChainDestination.sol` with source chain references
- **Configuration:** Sets up cross-chain contract addresses and relayer permissions
- **Verification:** Comprehensive checks of deployment state and configuration

### 3. Send Cross-Chain Message
```bash
# Send a test message (customizable)
make demo-send-message

# Or with custom message:
MESSAGE="Hello Cross-Chain World" make demo-send-message  
```

**What happens:**
```bash
forge script script/integration/SendMessageScript.s.sol \
  --rpc-url http://localhost:8545 --broadcast
```

- User submits message with EIP-712 signature
- `submitMessage()` function called on source chain
- `MessageSubmitted` event emitted for relayer observation
- Returns message ID and block number for tracking

### 4. Start Relayer Service

**Option A: Local TypeScript**
```bash
make relayer-build      # Compile TypeScript to dist/
make relayer-start      # Start with: node dist/index.js
```

**Option B: Development Mode** 
```bash
make relayer-dev        # Hot reload with: tsx watch src/index.ts
```

**Option C: Docker Container**
```bash
make dockercompose-up   # Starts with volume persistence
make dockercompose-logs # Follow real-time logs
```

### 5. Monitor Progress

**Relayer exposes HTTP endpoints:**
```bash
curl http://localhost:8080/health    # Service health status
curl http://localhost:8080/status    # Current processing state  
curl http://localhost:8080/metrics   # Prometheus metrics
```

**Health Response:**
```json
{
  "status": "healthy",
  "lastProcessedBlock": "9",
  "sourceChainConnected": true,
  "destChainConnected": true,
  "relayerBalance": {
    "source": "9999.5 ETH", 
    "dest": "9998.2 ETH"
  }
}
```

### 6. Cleanup
```bash
make stop-anvil            # Stop blockchain networks
make demo-cleanup          # Kill any running relayer processes
make dockercompose-down    # Stop Docker containers
```

## Understanding the Flow

### 1. User Message Submission
```solidity
// User calls submitMessage() on source chain
CrossChainSource.submitMessage(
    destChainId: 31338,
    destContract: 0x8464135c8F25Da09e49BC8782676a84730C318bC,
    payload: "Hello Cross-Chain World",
    nonce: userNonce,
    deadline: block.timestamp + 1 hours,
    signature: userEIP712Signature
);

// Contract emits event for relayer observation
emit MessageSubmitted(messageId, sender, destChainId, destContract, payload);
```

### 2. Relayer Observation (Phase 1)  
```typescript
// Relayer monitors source chain for events
const logs = await sourceChain.getLogs(fromBlock, toBlock);

// When messages found, relayer claims the entire block
await sourceChain.claimBlock(blockNumber, expectedMessageCount);
```

### 3. Message Delivery (Phase 2)
```typescript
// Relayer creates EIP-712 attestation  
const signature = await relayer.signMessage({
    sourceChainId: 31337,
    sourceBlockNumber: blockNumber,
    messageId: messageId, 
    sender: originalSender,
    payload: messagePayload,
    destContract: targetContract,
    nonce: relayerNonce,
    deadline: deadline
});

// Submits to destination chain with attestation
await destChain.executeMessage(...messageParams, signature);
```

### 4. Proof Submission (Phase 3)
```typescript
// Relayer collects delivery receipts
const deliveryProof = {
    destTxHash: executionTransaction.hash,
    receiptsRoot: block.receiptsRoot, 
    destBlockHash: block.hash,
    relayerEOA: relayer.address,
    relayerNonce: transaction.nonce,
    success: transaction.status === 'success'
};

// Submits proof back to source chain
await sourceChain.confirmBlockDelivery(blockNumber, [deliveryProof]);
```

## Makefile Command Reference

### Demo Commands (Automated)
```bash
make demo              # Complete end-to-end local demo
make demo-docker       # Complete end-to-end Docker demo  
make demo-custom-message MESSAGE="text"  # Custom message demo
```

### Smart Contract Commands
```bash
make install           # Install all dependencies and build everything
make build             # Build contracts only
make test              # Run contract tests (52 tests)
make setup             # Deploy + configure + verify contracts
make deploy-source     # Deploy to source chain (31337)
make deploy-dest       # Deploy to destination chain (31338)
```

### Relayer Commands  
```bash
make relayer-build     # Build TypeScript relayer
make relayer-start     # Start built relayer
make relayer-dev       # Development mode with hot reload
make dockercompose-up  # Start relayer in Docker
make dockercompose-down # Stop Docker relayer
```

### Infrastructure Commands
```bash
make start-anvil       # Start both Anvil instances
make stop-anvil        # Stop all Anvil instances
make demo-cleanup      # Clean up demo processes
```

## Key Features

### Smart Contracts

**CrossChainSource.sol** - Source chain contract:
- ✅ **Message Acceptance:** `submitMessage()` with EIP-712 signature verification
- ✅ **Event Emission:** Emits `MessageSubmitted` events for relayer observation
- ✅ **Block-based Processing:** Relayers claim entire blocks for batch processing
- ✅ **Delivery Tracking:** Maintains complete audit trail of all cross-chain messages
- ✅ **Proof Verification:** Accepts and verifies cryptographic delivery proofs

**CrossChainDestination.sol** - Destination chain contract:
- ✅ **Attestation Verification:** Verifies EIP-712 signatures before message execution
- ✅ **Replay Protection:** Nonce-based protection against message replay attacks
- ✅ **Access Control:** Role-based permissions for authorized relayers only
- ✅ **Message Execution:** Safe execution of cross-chain payloads

### Off-Chain Relayer Service

**Core Architecture:**
- ✅ **TypeScript Implementation:** Built with Viem for type-safe blockchain interactions
- ✅ **3-Phase Processing:** Implements complete accountability protocol
- ✅ **State Persistence:** JSON-based state with automatic recovery
- ✅ **Comprehensive Logging:** Full web3 call parameter visibility
- ✅ **Health Monitoring:** HTTP endpoints for service health and metrics
- ✅ **Docker Support:** Containerized deployment with volume persistence

## Testing

### Test Coverage
```
╭---------------------------------+------------------+------------------+----------------+-----------------╮
| File                            | % Lines          | % Statements     | % Branches     | % Funcs         |
+==========================================================================================================+
| src/CrossChainDestination.sol   | 75.56% (34/45)   | 80.43% (37/46)   | 87.50% (7/8)   | 66.67% (6/9)    |
| src/CrossChainSource.sol        | 84.14% (122/145) | 78.95% (135/171) | 80.65% (25/31) | 100.00% (19/19) |
╰---------------------------------+------------------+------------------+----------------+-----------------╯
```

### Running Tests
```bash
# Smart contract tests
cd contracts && forge test              # 52 tests across 4 suites
cd contracts && forge test -vvv         # Verbose output
cd contracts && forge coverage          # Coverage report

# Relayer tests  
cd relayer && pnpm test                 # TypeScript service tests

# Integration tests
make demo                               # Full end-to-end testing
```

## Trust Model & Security

### EIP-712 Signature Attestation
```solidity
struct CrossChainMessage {
    uint256 sourceChainId;
    uint256 sourceBlockNumber; 
    uint256 messageId;
    address sender;
    bytes payload;
    address destContract;
    uint256 nonce;
    uint256 deadline;
}
```

### Security Features
- **Domain Separation:** EIP-712 prevents signature replay across chains
- **Nonce Protection:** Prevents message replay attacks
- **Deadline Enforcement:** Time-bounded message validity
- **Role-Based Access:** Only authorized relayers can execute messages
- **Cryptographic Proofs:** Receipt roots provide tamper-proof delivery evidence
- **Complete Audit Trail:** Source chain maintains record of all activity

## Configuration

The project uses a shared `.env` file with sensible defaults:

```env
# Chain Configuration
CHAIN_ID_ONE=31337          # Source chain (Anvil default)
CHAIN_ID_TWO=31338          # Destination chain
RPC_URL_ONE=http://localhost:8545
RPC_URL_TWO=http://localhost:8546

# Test Accounts (Anvil defaults)
PRIVATE_KEY_DEPLOYER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PRIVATE_KEY_RELAYER=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

# Contract Addresses (consistent across Foundry local deployments)
SOURCE_CONTRACT=0x8464135c8F25Da09e49BC8782676a84730C318bC
DEST_CONTRACT=0x8464135c8F25Da09e49BC8782676a84730C318bC
```

**Note:** All values are for local development - no sensitive data included.

## Considerations 

### ✅ Testing
- **Unit Tests:** Comprehensive contract testing with Foundry (52 tests)
- **Integration:** Automated end-to-end demos with real blockchain interaction
- **Documentation:** Every component documented

### ✅ Setup & Documentation
- **Self-Contained:** Everything runs locally with Anvil
- **Minimal Setup:** Single `make install` command followed by `make demo`

## Production Considerations

For production deployment, consider checking everything. This code was written in a rush. It does what it should but you never know.

