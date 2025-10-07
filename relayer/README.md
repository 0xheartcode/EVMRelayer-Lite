# Cross-Chain Message Relayer

A POC TypeScript implementation of a cross-chain message relayer that implements the 3-phase accountability protocol with complete delivery tracking and proof submission.

## Overview

This Node.js service monitors the source chain for cross-chain messages, executes them on the destination chain, and submits cryptographic delivery proofs back to maintain complete accountability. Built with TypeScript, Viem, and Express.

### Key Features
- **3-Phase Protocol Implementation** - Block claiming, message delivery, and proof submission
- **Complete Logging Visibility** - Full web3 call parameter logging for all phases 
- **Robust State Management** - Persistent state with automatic recovery and retry logic
- **Health Monitoring** - HTTP endpoints for service health and metrics
- **Docker Support** - Containerized deployment with volume persistence
- **EIP-712 Signatures** - Cryptographically secure message authentication

## Architecture

### Core Components

#### `MessageRelayer` - Main Orchestrator
The primary service class that coordinates all cross-chain operations:

```typescript
class MessageRelayer {
  private state: RelayerState;
  private blockProcessor: BlockProcessor;
  private proofSubmitter: ProofSubmitter;
  
  async initialize(): Promise<void>    // Setup and permission verification
  async start(): Promise<void>         // Begin monitoring and processing
  async stop(): Promise<void>          // Graceful shutdown
  async getHealth(): Promise<Health>   // Health check status
}
```

**Key Responsibilities:**
- Initializes and coordinates all service components
- Manages relayer permissions and wallet connectivity  
- Provides health monitoring and graceful shutdown
- Handles service lifecycle and error recovery

#### `BlockProcessor` - Phase 1 & 2 Implementation  
Handles block claiming and message delivery:

```typescript
class BlockProcessor {
  async processBlock(blockNumber: bigint): Promise<BlockProcessingResult>
  async claimBlock(blockNumber: bigint, messageCount: bigint): Promise<string>
  async processMessages(messages: Message[]): Promise<ProcessedMessage[]>
}
```

**3-Phase Operations:**
- **Phase 1:** Claims entire blocks with `claimBlock()` and monitors for `MessageSubmitted` events
- **Phase 2:** Executes each message via `executeMessage()` on destination chain with EIP-712 signatures
- **Logging:** Comprehensive web3 call parameter logging for visibility

#### `ProofSubmitter` - Phase 3 Implementation
Submits delivery proofs back to source chain:

```typescript  
class ProofSubmitter {
  async submitProofs(blockNumber: bigint, proofs: DeliveryProof[]): Promise<string>
  async collectDeliveryProofs(processedMessages: ProcessedMessage[]): Promise<DeliveryProof[]>
}
```

**Key Functions:**
- Collects transaction receipts and creates cryptographic proofs
- Submits proof arrays via `confirmBlockDelivery()`
- **Logging:** Full proof details including transaction hashes and success status

#### `SourceChain` & `DestChain` - Blockchain Clients
Chain-specific clients built with Viem for web3 interactions:

**SourceChain Functions:**
```typescript
async claimBlock(blockNumber: bigint, expectedMessageCount: bigint): Promise<string>
async getMessage(messageId: bigint): Promise<Message>  
async getLogs(fromBlock: bigint, toBlock: bigint): Promise<MessageSubmittedEvent[]>
async confirmBlockDelivery(blockNumber: bigint, proofs: DeliveryProof[]): Promise<string>
```

**DestChain Functions:**  
```typescript
async executeMessage(
  sourceChainId: bigint,
  sourceBlockNumber: bigint, 
  messageId: bigint,
  sender: Address,
  payload: `0x${string}`,
  destContract: Address,
  nonce: bigint,
  deadline: bigint,
  signature: { v: number; r: `0x${string}`; s: `0x${string}` }
): Promise<{ hash: string; success: boolean }>
```

#### `RelayerState` - State Persistence
Manages persistent state with automatic recovery:

```typescript
interface RelayerStateData {
  lastProcessedBlock: bigint;      // Simple recovery point
  failedTransactions: FailedTransaction[];  // Retry queue
  startupTime: number;
  version: string;
}
```

**State Management:**
- **Simple Recovery:** Resume from `lastProcessedBlock + 1`
- **Failed Transaction Queue:** Retry failed messages on startup
- **Automatic Cleanup:** Remove old failed transactions
- **File-based Persistence:** JSON state file with atomic writes

#### `EIP712Utils` - Signature Generation
Handles EIP-712 structured data signing:

```typescript
const MESSAGE_TYPE = {
  CrossChainMessage: [
    { name: 'sourceChainId', type: 'uint256' },
    { name: 'sourceBlockNumber', type: 'uint256' },
    { name: 'messageId', type: 'uint256' },
    { name: 'sender', type: 'address' },
    { name: 'payload', type: 'bytes' },
    { name: 'destContract', type: 'address' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' }
  ]
};
```

## Installation

### Prerequisites
- Node.js 20+
- pnpm (recommended) or npm
- Access to source and destination chain RPC endpoints

### Setup
```bash
# Install dependencies
pnpm install

# Build TypeScript
pnpm build

# Copy environment configuration
cp .env.example .env
```

### Configuration

Create a `.env` file with your chain configuration:

```env
# Chain Configuration
RPC_URL_ONE=http://localhost:8545          # Source chain RPC
RPC_URL_TWO=http://localhost:8546          # Destination chain RPC
CHAIN_ID_ONE=31337                         # Source chain ID
CHAIN_ID_TWO=31338                         # Destination chain ID

# Contract Addresses (set after deployment)
SOURCE_CONTRACT=0x8464135c8F25Da09e49BC8782676a84730C318bC
DEST_CONTRACT=0x8464135c8F25Da09e49BC8782676a84730C318bC

# Relayer Configuration
PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
RELAYER_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

# Processing Configuration
START_BLOCK=0                              # Block to start processing from
CONFIRMATION_BLOCKS=2                      # Blocks to wait for finality
MAX_RETRIES=3                              # Maximum retry attempts
RETRY_DELAY=5000                           # Delay between retries (ms)

# State Management  
STATE_FILE=./relayer-state.json            # Persistent state file location, delete this for a fresh state

# Health Monitoring
HEALTH_CHECK_PORT=8080                     # HTTP server port for health checks
```

**Note:** Example uses Anvil default test accounts - replace with secure keys for production.

## Usage

### Basic Commands

```bash
# Start the relayer
pnpm start

# Development mode with hot reload
pnpm dev

# Run build 
pnpm build 

# Clean build files
pnpm clean
```

### Docker Deployment

```bash
# Build and start with Docker Compose
docker compose up --build

# Run in detached mode
docker compose up -d

# View logs
docker compose logs -f relayer

# Stop containers
docker compose down

# Clean everything (containers, volumes, images)
docker compose down -v --rmi all
```

**Docker Features:**
- **Volume Persistence:** Relayer state persists across container restarts
- **Health Checks:** Built-in container health monitoring
- **Configuration:** Environment variables passed through compose file
- **Networking:** Connects to host machine for Anvil chains via `host.docker.internal`

## API Endpoints

The relayer exposes HTTP endpoints for monitoring and health checks:

### Health Check
```bash
GET http://localhost:8080/health
```

**Response:**
```json
{
  "status": "healthy",
  "checks": {
    "sourceChainConnected": true,
    "destChainConnected": true,
    "relayerPermissions": true,
    "sufficientBalance": true
  }
}```

### Status Information  
```bash
GET http://localhost:status
```

**Response:**
```json
{
  "isRunning": true,
  "state": {
    "lastProcessedBlock": "160",
    "failedTransactionCount": 0,
    "uptimeMs": 315547,
    "version": "1.0.0"
  },
  "config": {
    "sourceChain": "31337 @ http://localhost:8545",
    "destChain": "31338 @ http://localhost:8546",
    "startBlock": "0"
  }
}```

### Metrics Endpoint
```bash
GET http://localhost:8080/metrics
```

Returns metrics for monitoring.

## Logging Output

The relayer provides comprehensive logging for all 3 phases:

### Phase 1 - Source Chain (Block Claiming & Transaction Pickup)
```
Web3 Call: claimBlock(
  blockNumber: 9,
  expectedMessageCount: 1
)
[Tx 0x6c2e25a641777e59804a86fa7f8a135eeda2b2b5dbbe50f3ab0c67035e99cbe7] Block 9 claim transaction sent

Web3 Call: getMessage(
  messageId: 0
)
```

### Phase 2 - Destination Chain (Message Execution)
```
Web3 Call: executeMessage(
  sourceChainId: 31337,
  sourceBlockNumber: 9,
  messageId: 0,
  sender: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
  payload: 0x2f049bf30000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000002648656c6c6f20746f64617920776520617265205468757273646179203039204f63746f6265720000000000000000000000000000000000000000000000000000,
  destContract: 0x8464135c8F25Da09e49BC8782676a84730C318bC,
  nonce: 0,
  deadline: 1759797595,
  signature: { v: 28, r: 0xc42f27aa3c82b3f3c25cf51ea0d307783c59f22ae5928a32b55f9a099b3d6352, s: 0x19f95b2b71572f5b9b397ea6799930fb3ada58ec0ef1d3b06db67a045d31c5c3 }
)
[Tx 0x07bdef10cf2d4d9752ee6fb2d8cfd6dfe2ef1ba4db026a5c8b66bb0288ab9b04] Message 0 execution transaction sent
```

### Phase 3 - Source Chain (Proof Submission)
```
Web3 Call: confirmBlockDelivery(
  blockNumber: 9,
  proofs: [
    1. { destTxHash: 0x07bdef10cf2d4d9752ee6fb2d8cfd6dfe2ef1ba4db026a5c8b66bb0288ab9b04, success: true, receiptsRoot: 0x00000000... }
  ]
)
[Tx 0xb30137aa28e7ecf4a3f3f4e06b2eee06f04c8c2ce946856169521cfea18bbc7c] Delivery proof submission for block 9
 PHASE 3 COMPLETE: Block 9 proofs submitted successfully
```

## State Management & Recovery

### Simple Recovery Model
The relayer uses a single number (`lastProcessedBlock`) for recovery:

```json
{
  "lastProcessedBlock": "42",
  "failedTransactions": [],
  "startupTime": 1701944200000,
  "version": "1.0.0"
}
```

### Recovery Process
1. **On Startup:** Load state from `relayer-state.json`
2. **Resume Processing:** Start from `lastProcessedBlock + 1`  
3. **Retry Failed Transactions:** Attempt each failed transaction once
4. **Continue:** Begin normal block monitoring

### Failure Handling
```typescript
interface FailedTransaction {
  blockNumber: bigint;
  messageId: bigint;
  error: string;
  timestamp: number;
  retryCount?: number;
}
```

**Failure Process:**
- Failed messages added to retry queue with error details
- On startup, retry each failed transaction once
- If retry succeeds: remove from queue
- If retry fails: log permanent failure and continue
- No infinite retry loops

## Development

### Project Structure
```
src/
   index.ts                    # Main application entry point
   config.ts                   # Configuration management
   chains/
      sourceChain.ts          # Source chain web3 client
      destChain.ts            # Destination chain web3 client  
   services/
      messageRelayer.ts       # Main relayer orchestrator
      blockProcessor.ts       # Phase 1 & 2 implementation
      proofSubmitter.ts       # Phase 3 implementation
   state/
      relayerState.ts         # State persistence management
   utils/
      eip712.ts               # EIP-712 signature utilities
      logger.ts               # Logging configuration
   abi/
       CrossChainSource.json   # Source contract ABI
       CrossChainDestination.json # Destination contract ABI
       index.ts                # ABI exports
```

## Dependencies

### Core Dependencies
- **viem** - Ethereum client library with TypeScript support
- **express** - HTTP server for health endpoints
- **dotenv** - Environment variable management

## Production Deployment

### Environment Setup
1. **Secure Private Keys:** Replace test keys with production keys
2. **RPC Endpoints:** Configure production RPC endpoints
3. **State Persistence:** Ensure state file has persistent storage
4. **Monitoring:** Set up log aggregation and alerting
5. **Health Checks:** Configure container orchestration health checks

### Monitoring
- **Health Endpoint:** Monitor `/health` for service status
- **Log Analysis:** Parse structured logs for phase completion
- **Metrics Collection:** Use `/metrics` endpoint for Prometheus
- **State File Monitoring:** Track state file for recovery information

### Security Considerations
- **Private Key Management:** Use secure key management systems
- **RPC Security:** Use authenticated RPC endpoints when possible
- **Access Control:** Restrict health endpoint access in production
- **State File Security:** Ensure state file has appropriate file permissions

