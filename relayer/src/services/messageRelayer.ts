import { sourceChain } from '../chains/sourceChain';
import { destChain } from '../chains/destChain';
import { BlockProcessor } from './blockProcessor';
import { ProofSubmitter } from './proofSubmitter';
import { RelayerState } from '../state/relayerState';
import { logger } from '../utils/logger';
import { crossChainSourceAbi } from '../abi';
import config from '../config';

export class MessageRelayer {
  private state: RelayerState;
  private blockProcessor: BlockProcessor;
  private proofSubmitter: ProofSubmitter;
  private isRunning: boolean = false;
  private stopWatcher?: () => void;

  constructor() {
    this.state = new RelayerState();
    this.blockProcessor = new BlockProcessor(this.state);
    this.proofSubmitter = new ProofSubmitter();
  }

  /**
   * Initialize the relayer service
   */
  async initialize(): Promise<void> {
    logger.info('Initializing Cross-Chain Message Relayer...');

    // Initialize state
    await this.state.initialize();

    // Verify relayer has required permissions
    await this.verifyPermissions();

    // Clean up old failed transactions
    await this.state.cleanupOldFailedTransactions();

    logger.info('✅ Relayer initialized successfully');
  }

  /**
   * Start the relayer service
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      logger.warn('Relayer is already running');
      return;
    }

    logger.info('🚀 Starting Cross-Chain Message Relayer');
    this.isRunning = true;

    try {
      // Check for blocks that might be stuck in CLAIMED state (Phase 2 completed but Phase 3 failed)
      await this.checkStuckBlocks();

      // Retry failed transactions from previous runs
      await this.retryFailedTransactions();

      // Start watching for new blocks
      await this.startBlockWatcher();

      logger.info('✅ Relayer started successfully');
    } catch (error) {
      logger.error('Failed to start relayer', error);
      this.isRunning = false;
      throw error;
    }
  }

  /**
   * Stop the relayer service
   */
  async stop(): Promise<void> {
    if (!this.isRunning) {
      return;
    }

    logger.info('🛑 Stopping Cross-Chain Message Relayer');
    this.isRunning = false;

    // Stop block watcher
    if (this.stopWatcher) {
      this.stopWatcher();
    }

    logger.info('✅ Relayer stopped successfully');
  }

  /**
   * Verify relayer has required permissions on both chains
   */
  private async verifyPermissions(): Promise<void> {
    logger.info('Verifying relayer permissions...');

    // Check source chain permissions  
    const relayerRole = await sourceChain.publicClient.readContract({
      address: config.sourceChain.contractAddress,
      abi: crossChainSourceAbi,
      functionName: 'RELAYER_ROLE',
    }) as `0x${string}`;

    const sourceHasRole = await sourceChain.publicClient.readContract({
      address: config.sourceChain.contractAddress,
      abi: crossChainSourceAbi,
      functionName: 'hasRole',
      args: [relayerRole, config.relayer.address],
    });

    if (!sourceHasRole) {
      throw new Error('Relayer does not have RELAYER_ROLE on source chain');
    }

    // Check destination chain permissions
    const destHasRole = await destChain.hasRelayerRole(config.relayer.address);
    if (!destHasRole) {
      throw new Error('Relayer does not have RELAYER_ROLE on destination chain');
    }

    // Check balances
    const sourceBalance = await sourceChain.publicClient.getBalance({
      address: config.relayer.address,
    });
    const destBalance = await destChain.getBalance();

    logger.info(`Source chain balance: ${sourceBalance} wei`);
    logger.info(`Destination chain balance: ${destBalance} wei`);

    if (sourceBalance === 0n || destBalance === 0n) {
      logger.warn('⚠️  Low balance detected - ensure relayer has sufficient funds');
    }

    logger.info('✅ Permissions verified successfully');
  }

  /**
   * Check for blocks that might be stuck in CLAIMED state 
   * This handles the case where Phase 2 completed but Phase 3 failed
   */
  private async checkStuckBlocks(): Promise<void> {
    const lastProcessedBlock = this.state.getLastProcessedBlock();
    
    logger.info(`Checking for stuck blocks around ${lastProcessedBlock}...`);

    // Check a few blocks around our last processed block for stuck claims and partial deliveries
    const startCheck = lastProcessedBlock > 10n ? lastProcessedBlock - 10n : 0n;
    const endCheck = lastProcessedBlock + 5n;

    for (let blockNum = startCheck; blockNum <= endCheck; blockNum++) {
      try {
        const proofStatus = await this.proofSubmitter.getProofStatus(blockNum);
        
        if (proofStatus.needsProofs && proofStatus.isOwner) {
          logger.warn(`Found stuck block ${blockNum} - attempting to complete Phase 3`);
          
          // Try to get the block processing result and submit proofs
          // This is a simplified recovery - in practice you might want more sophisticated logic
          const blockStatus = await this.blockProcessor.getBlockStatus(blockNum);
          if (blockStatus.messageCount > 0) {
            logger.info(`Attempting to complete Phase 3 for block ${blockNum}`);
            // Note: This is a simplified recovery. A full implementation might 
            // reconstruct the processing result or mark the block as failed.
            await this.proofSubmitter.markBlockAsFailed(blockNum, 'Recovery: Phase 3 failed during previous run');
          }
        }

        // Also check for PARTIALLY_DELIVERED blocks that might have retryable failures
        await this.checkPartiallyDeliveredBlock(blockNum);
        
      } catch (error) {
        // Ignore errors for individual blocks during stuck block check
        logger.debug(`Error checking block ${blockNum}:`, error);
      }
    }
  }

  /**
   * Check a PARTIALLY_DELIVERED block and log status
   * Note: PARTIALLY_DELIVERED blocks are final - we don't retry their failed messages
   * Users can resubmit failed messages as new transactions if needed
   */
  private async checkPartiallyDeliveredBlock(blockNumber: bigint): Promise<void> {
    try {
      // Use the new enhanced function to get block status
      const status = await sourceChain.getBlockDeliveryStatus(blockNumber);
      
      if (!status || status.state !== 3) { // 3 = PARTIALLY_DELIVERED
        return;
      }

      if (status.failureCount > 0) {
        logger.info(`Block ${blockNumber}: PARTIALLY_DELIVERED - ${status.successCount} succeeded, ${status.failureCount} failed (final)`);
        
        // Just log for visibility - don't retry since block state is final
        const failedMessages = await sourceChain.getFailedMessagesForBlock(blockNumber);
        if (failedMessages.length > 0) {
          logger.debug(`Block ${blockNumber} failed message IDs: [${failedMessages.join(', ')}]`);
        }
      }
    } catch (error) {
      logger.debug(`Error checking partially delivered block ${blockNumber}:`, error);
    }
  }

  /**
   * Retry failed transactions from previous runs
   */
  private async retryFailedTransactions(): Promise<void> {
    const retryableTransactions = this.state.getRetryableFailedTransactions(config.relayer.maxRetries);
    
    if (retryableTransactions.length === 0) {
      logger.info('No failed transactions to retry');
      return;
    }

    logger.info(`Retrying ${retryableTransactions.length} failed transactions...`);

    let successCount = 0;
    for (const failedTx of retryableTransactions) {
      try {
        const success = await this.blockProcessor.retryFailedMessage(failedTx);
        if (success) {
          await this.state.removeFailedTransaction(failedTx.blockNumber, failedTx.messageId);
          successCount++;
        }
      } catch (error) {
        logger.error(`Failed to retry transaction ${failedTx.messageId}`, error);
      }

      // Small delay between retries
      await new Promise(resolve => setTimeout(resolve, 1000));
    }

    logger.info(`Retry completed: ${successCount}/${retryableTransactions.length} successful`);
  }

  /**
   * Start watching for new blocks to process
   */
  private async startBlockWatcher(): Promise<void> {
    const startBlock = this.state.getLastProcessedBlock() + 1n;
    
    logger.info(`Starting block watcher from block ${startBlock}`);

    this.stopWatcher = await sourceChain.watchBlocks(
      startBlock,
      async (blockNumber: bigint, messageCount: bigint) => {
        if (!this.isRunning) {
          return;
        }

        try {
          await this.processBlock(blockNumber, messageCount);
        } catch (error) {
          logger.error(`Failed to process block ${blockNumber}`, error);
        }
      }
    );
  }

  /**
   * Process a single block
   */
  private async processBlock(blockNumber: bigint, messageCount: bigint): Promise<void> {
    logger.block(blockNumber, `Processing block with ${messageCount} messages`);

    try {
      // Check if block is ready for processing
      const isReady = await this.blockProcessor.isBlockReadyForProcessing(blockNumber);
      if (!isReady) {
        logger.warn(`Block ${blockNumber} not ready for processing`);
        return;
      }

      // Process the block
      const result = await this.blockProcessor.processBlock(blockNumber, messageCount);

      if (result.completed) {
        logger.block(
          blockNumber,
          `✅ Phase 2 completed: ${result.successCount} success, ${result.failureCount} failed`
        );

        // PHASE 3: Submit delivery proofs
        const proofResult = await this.proofSubmitter.submitProofsFromBlockResult(result);
        
        if (proofResult.success) {
          // ONLY update state after BOTH Phase 2 AND Phase 3 complete successfully
          await this.state.setLastProcessedBlock(blockNumber);
          logger.block(blockNumber, `✅ 3-phase protocol completed successfully`);
        } else {
          logger.error(`Failed to submit proofs for block ${blockNumber}: ${proofResult.error}`);
          logger.warn(`Block ${blockNumber} will be retried on next restart`);
        }
      } else {
        logger.block(
          blockNumber,
          `⚠️  Phase 2 partial completion: ${result.successCount} success, ${result.failureCount} failed`
        );
      }

      // Log processing metrics
      this.logMetrics(result);

    } catch (error) {
      logger.error(`Block ${blockNumber} processing failed`, error);
    }
  }

  /**
   * Log processing metrics
   */
  private logMetrics(result: any): void {
    const summary = this.state.getSummary();
    
    if (Number(result.blockNumber) % 10 === 0) { // Log every 10 blocks
      logger.info('📊 Relayer Metrics:');
      logger.info(`  Last processed block: ${summary.lastProcessedBlock}`);
      logger.info(`  Failed transactions: ${summary.failedTransactionCount}`);
      logger.info(`  Uptime: ${Math.floor(summary.uptimeMs / 1000)}s`);
    }
  }

  /**
   * Get current relayer status
   */
  getStatus(): {
    isRunning: boolean;
    state: ReturnType<RelayerState['getSummary']>;
    config: {
      sourceChain: string;
      destChain: string;
      startBlock: bigint;
    };
  } {
    return {
      isRunning: this.isRunning,
      state: this.state.getSummary(),
      config: {
        sourceChain: `${config.sourceChain.chainId} @ ${config.sourceChain.rpcUrl}`,
        destChain: `${config.destChain.chainId} @ ${config.destChain.rpcUrl}`,
        startBlock: config.sourceChain.startBlock,
      },
    };
  }

  /**
   * Manual block processing (for testing or recovery)
   */
  async processBlockManual(blockNumber: bigint): Promise<void> {
    logger.info(`Manual processing requested for block ${blockNumber}`);

    const messageCount = await sourceChain.getBlockMessageCount(blockNumber);
    if (messageCount === 0n) {
      logger.warn(`Block ${blockNumber} has no messages`);
      return;
    }

    await this.processBlock(blockNumber, messageCount);
  }

  /**
   * Force retry of a specific failed transaction
   */
  async retryTransaction(blockNumber: bigint, messageId: bigint): Promise<boolean> {
    const failedTxs = this.state.getFailedTransactions();
    const failedTx = failedTxs.find(
      tx => tx.blockNumber === blockNumber && tx.messageId === messageId
    );

    if (!failedTx) {
      logger.warn(`Failed transaction not found: block ${blockNumber}, message ${messageId}`);
      return false;
    }

    const success = await this.blockProcessor.retryFailedMessage(failedTx);
    if (success) {
      await this.state.removeFailedTransaction(blockNumber, messageId);
    }

    return success;
  }

  /**
   * Get health status
   */
  async getHealth(): Promise<{
    status: 'healthy' | 'degraded' | 'unhealthy';
    checks: Record<string, boolean>;
    lastError?: string;
  }> {
    const checks = {
      sourceChainConnected: false,
      destChainConnected: false,
      relayerPermissions: false,
      sufficientBalance: false,
    };

    let lastError: string | undefined;

    try {
      // Check source chain connection
      await sourceChain.getCurrentBlock();
      checks.sourceChainConnected = true;
    } catch (error: any) {
      lastError = `Source chain: ${error.message}`;
    }

    try {
      // Check destination chain connection
      await destChain.getBalance();
      checks.destChainConnected = true;
    } catch (error: any) {
      lastError = `Destination chain: ${error.message}`;
    }

    try {
      // Check permissions
      const hasRole = await destChain.hasRelayerRole(config.relayer.address);
      checks.relayerPermissions = hasRole;
    } catch (error: any) {
      lastError = `Permissions: ${error.message}`;
    }

    try {
      // Check balances
      const balance = await destChain.getBalance();
      checks.sufficientBalance = balance > 0n;
    } catch (error: any) {
      lastError = `Balance check: ${error.message}`;
    }

    const healthyChecks = Object.values(checks).filter(Boolean).length;
    const totalChecks = Object.keys(checks).length;

    let status: 'healthy' | 'degraded' | 'unhealthy';
    if (healthyChecks === totalChecks) {
      status = 'healthy';
    } else if (healthyChecks >= totalChecks / 2) {
      status = 'degraded';
    } else {
      status = 'unhealthy';
    }

    return { status, checks, lastError };
  }
}