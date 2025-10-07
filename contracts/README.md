# Cross-Chain Messaging Contracts

A proof of concect 3-phase cross-chain messaging protocol with complete accountability and block-based batch processing.

## Overview

This Foundry project implements a trustless cross-chain messaging system where relayers claim entire blocks on the source chain, deliver all messages to the destination chain in transaction order, and submit cryptographic delivery proofs back to the source chain.

### Key Innovation
Unlike traditional bridges that "fire and forget", this protocol creates a complete accountability loop where the source chain tracks delivery status of every cross-chain message.

## Getting Started

### Prerequisites
- [Foundry](https://getfoundry.sh/)

### Installation
```bash
forge install
forge build
```

### Testing
```bash
forge test
```

To run tests with detailed output:
```bash
forge test -vvv
```

For test coverage:
```bash
forge coverage
```

## Smart Contracts

### Core Contracts (`src/`)

#### `CrossChainSource.sol`
The source chain contract that manages message submission and block processing accountability.

**State Management:**
- `nextMessageId` - Auto-incrementing message identifier
- `blockProcessing` - Mapping of block numbers to processing state and metadata
- `deliveryProofs` - Cryptographic proofs of message delivery on destination chain
- `messages` - Complete record of all cross-chain messages

**Key Functions:**

##### Message Submission
```solidity
function submitMessage(
    uint256 destChainId,
    address destContract, 
    bytes calldata payload,
    uint256 nonce,
    uint256 deadline,
    bytes calldata signature
) external returns (uint256 messageId)
```
- **Purpose:** Submit a cross-chain message with EIP-712 signature verification
- **Access:** Public (with valid signature)
- **Emits:** `MessageSubmitted(messageId, sender, destChainId, destContract, payload)`
- **Returns:** Unique message ID for tracking

##### Block Processing
```solidity
function claimBlock(uint256 blockNumber, uint256 expectedMessageCount) external
```
- **Purpose:** Relayer claims an entire block for cross-chain processing
- **Access:** RELAYER_ROLE only
- **Validation:** Block must be finalized and contain expected message count
- **State Change:** Block status moves from AVAILABLE → CLAIMED
- **Emits:** `BlockClaimed(blockNumber, relayer, messageCount, claimTime)`

```solidity
function confirmBlockDelivery(
    uint256 blockNumber,
    DeliveryProof[] calldata proofs
) external
```
- **Purpose:** Submit cryptographic delivery proofs for all messages in a block
- **Access:** RELAYER_ROLE only (must be the claiming relayer)
- **Validation:** Verifies receipt roots and transaction hashes
- **State Change:** Block status moves from CLAIMED → COMPLETED/FAILED
- **Emits:** `BlockDeliveryConfirmed(blockNumber, successCount, failureCount)`

##### Query Functions
```solidity
function getMessage(uint256 messageId) external view returns (Message memory)
function getBlockProcessing(uint256 blockNumber) external view returns (BlockProcessing memory)
function isBlockClaimable(uint256 blockNumber) public view returns (bool)
function getMessagesInBlock(uint256 blockNumber) external view returns (uint256[] memory)
```

**Data Structures:**
```solidity
struct Message {
    uint256 id;
    address sender;
    uint256 sourceBlockNumber;
    uint256 destChainId;
    address destContract;
    bytes payload;
    uint256 timestamp;
    uint256 blockIndex;
}

struct BlockProcessing {
    uint256 blockNumber;
    bytes32 blockHash;
    address relayer;
    uint256 messageCount;
    uint256 claimTime;
    BlockState state; // AVAILABLE, CLAIMED, COMPLETED, FAILED
}

struct DeliveryProof {
    bytes32 destTxHash;      // Transaction hash on destination chain
    bytes32 receiptsRoot;    // Cryptographic commitment to execution
    bytes32 destBlockHash;   // Block containing the transaction  
    address relayerEOA;      // Address that sent the transaction
    uint256 relayerNonce;    // Nonce used for transaction
    bool success;            // Whether execution succeeded
}
```

#### `CrossChainDestination.sol`  
The destination chain contract that receives and executes cross-chain messages.

**State Management:**
- `sourceChainId` - ID of the source chain this contract accepts messages from
- `sourceContract` - Address of the CrossChainSource contract
- `sourceDomainSeparator` - EIP-712 domain separator for signature verification
- `relayerNonces` - Prevents replay attacks for each relayer

**Key Functions:**

##### Message Execution
```solidity
function executeMessage(
    uint256 sourceChainId,
    uint256 sourceBlockNumber,
    uint256 messageId,
    address sender,
    bytes calldata payload,
    address destContract,
    uint256 nonce,
    uint256 deadline,
    uint8 v, bytes32 r, bytes32 s
) external returns (bool success)
```
- **Purpose:** Execute a cross-chain message with full signature verification
- **Access:** RELAYER_ROLE only
- **Validation:** 
  - Verifies EIP-712 signature against source chain domain
  - Checks message hasn't expired (deadline)
  - Prevents nonce reuse for replay protection
- **Execution:** Calls `destContract` with the provided payload
- **Emits:** `MessageExecuted(messageId, sender, destContract, success)`
- **Returns:** Whether the destination call succeeded

##### Configuration
```solidity
function initialize(
    uint256 _sourceChainId,
    address _sourceContract, 
    bytes32 _sourceDomainSeparator
) external
```
- **Purpose:** Set up cross-chain configuration (one-time setup)
- **Access:** Owner only
- **Validation:** Can only be called once during deployment

##### Query Functions
```solidity
function verifyMessageSignature(...) public view returns (bool)
function getRelayerNonce(address relayer) external view returns (uint256)
function hashMessage(...) public view returns (bytes32)
```

**EIP-712 Domain Separation:**
The contract uses EIP-712 structured data signing to prevent signature replay attacks across chains:
```solidity
bytes32 public constant MESSAGE_TYPEHASH = keccak256(
    "CrossChainMessage(uint256 sourceChainId,uint256 sourceBlockNumber,uint256 messageId,address sender,bytes payload,address destContract,uint256 nonce,uint256 deadline)"
);
```

## Test Coverage

```
╭---------------------------------+------------------+------------------+----------------+-----------------╮
| File                            | % Lines          | % Statements     | % Branches     | % Funcs         |
+==========================================================================================================+
| src/CrossChainDestination.sol   | 75.56% (34/45)   | 80.43% (37/46)   | 87.50% (7/8)   | 66.67% (6/9)    |
| src/CrossChainSource.sol        | 84.14% (122/145) | 78.95% (135/171) | 80.65% (25/31) | 100.00% (19/19) |
╰---------------------------------+------------------+------------------+----------------+-----------------╯
```

## Tests (`test/`)

**4 test suites • 52 total tests • 18.45ms runtime**

- **`CrossChainSource.t.sol`** - Core source chain functionality, message submission, block claiming
- **`CrossChainDestination.t.sol`** - Message execution, signature verification, access control  
- **`CrossChainIntegration.t.sol`** - Complete end-to-end cross-chain message flow
- **`CrossChainPartialDelivery.t.sol`** - Partial block delivery, retry scenarios, failure handling

### Test Utilities
- **`mocks/MockTarget.sol`** - Mock contract for testing message execution outcomes
- **`utils/SignatureUtils.sol`** - EIP-712 signature generation and verification helpers
- **`utils/TestHelpers.sol`** - Common assertions, setup utilities, and test data

## Scripts (`script/`)

### Two-Chain Setup

First, start two Anvil instances for local testing:

```bash
# Terminal 1: Source chain (Chain ID 31337)
anvil --port 8545 --chain-id 31337

# Terminal 2: Destination chain (Chain ID 31338)  
anvil --port 8546 --chain-id 31338
```

### Setup Scripts (`script/setup/`)

#### Deploy Contracts

Deploy to **Source Chain** (31337):
```bash
forge script script/setup/Deploy.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Deploy to **Destination Chain** (31338):
```bash
forge script script/setup/Deploy.s.sol \
  --rpc-url http://localhost:8546 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

#### Configure Contracts  

Configure **Source Chain** contracts:
```bash
forge script script/setup/Configure.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Configure **Destination Chain** contracts:
```bash
forge script script/setup/Configure.s.sol \
  --rpc-url http://localhost:8546 \
  --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### Integration Scripts (`script/integration/`)

#### Send Test Message
```bash
# Send message on source chain
forge script script/integration/SendMessageScript.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
```

This script:
- Submits a test message using `submitMessage()`
- Uses EIP-712 signature for authentication
- Emits a `MessageSubmitted` event
- Returns the message ID for tracking

#### System Verification

Verify **Source Chain** setup:
```bash
forge script script/integration/Verify.s.sol \
  --rpc-url http://localhost:8545
```

Verify **Destination Chain** setup:
```bash
forge script script/integration/Verify.s.sol \
  --rpc-url http://localhost:8546
```

The verification script checks:
- Contract deployment addresses
- Relayer role permissions  
- EIP-712 domain separator setup
- Cross-chain configuration consistency
- Message processing capabilities

## Configuration

The project includes a pre-configured `.env` file with test values for easy setup:

```env
# Chain Configuration
CHAIN_ID_ONE=31337          # Source chain (Anvil default)
CHAIN_ID_TWO=31338          # Destination chain  
RPC_URL_ONE=http://localhost:8545
RPC_URL_TWO=http://localhost:8546

# Test Accounts (Anvil defaults)
PRIVATE_KEY_DEPLOYER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PRIVATE_KEY_RELAYER=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d  
PRIVATE_KEY_USER=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

# Contract Addresses (same addresses on foundry local, change these after deployment if needed)
SOURCE_CONTRACT=0x8464135c8F25Da09e49BC8782676a84730C318bC
DEST_CONTRACT=0x8464135c8F25Da09e49BC8782676a84730C318bC
```

**Note:** No sensitive data - all values are for local development and testing.

## Architecture

### 3-Phase Protocol Flow

1. **Phase 1 - Block Claiming:** 
   - Relayer monitors source chain for finalized blocks containing messages
   - Calls `claimBlock()` to reserve exclusive processing rights
   - Block state transitions: `AVAILABLE` → `CLAIMED`

2. **Phase 2 - Message Delivery:**
   - Relayer processes all messages in claimed block sequentially  
   - Calls `executeMessage()` on destination chain for each message
   - Maintains transaction ordering from source block

3. **Phase 3 - Proof Submission:**
   - Relayer collects transaction receipts from destination chain
   - Submits `DeliveryProof[]` via `confirmBlockDelivery()`
   - Block state transitions: `CLAIMED` → `COMPLETED`/`FAILED`

### Security Model

- **Cryptographic Proofs:** Receipt roots provide tamper-proof delivery evidence  
- **External Verification:** Anyone can verify delivery claims against destination chain
- **Complete Audit Trail:** Source chain maintains permanent record of all cross-chain activity
- **Replay Protection:** EIP-712 signatures with nonces prevent message replay
- **Access Control:** Role-based permissions restrict critical functions

## Development

Built with Foundry for fast, reliable smart contract development.

```bash
# Run all tests
forge test

# Run tests with gas reporting
forge test --gas-report

# Run test coverage
forge coverage --ir-minimum

# Build contracts  
forge build

# Format code
forge fmt

```
