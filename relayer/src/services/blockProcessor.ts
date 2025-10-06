import { Address } from 'viem';
import { sourceChain, Message } from '../chains/sourceChain';
import { destChain } from '../chains/destChain';
import { logger } from '../utils/logger';
import { RelayerState } from '../state/relayerState';
import config from '../config';

export interface ProcessedMessage {
  messageId: bigint;
  message: Message;
  deliveryHash: `0x${string}` | null;
  success: boolean;
  error?: string;
}

export interface BlockProcessingResult {
  blockNumber: bigint;
  messageCount: bigint;
  claimHash: `0x${string}` | null;
  processedMessages: ProcessedMessage[];
  successCount: number;
  failureCount: number;
  completed: boolean;
}

export class BlockProcessor {
  private state: RelayerState;

  constructor(state: RelayerState) {
    this.state = state;
  }

  /**
   * Process a single block through the 3-phase protocol
   * Phase 1: Claim the block
   * Phase 2: Process all messages in the block
   * Phase 3: Submit delivery proofs (handled by ProofSubmitter)
   */
  async processBlock(blockNumber: bigint, expectedMessageCount: bigint): Promise<BlockProcessingResult> {
    logger.block(blockNumber, `Starting 3-phase processing (${expectedMessageCount} messages)`);

    const result: BlockProcessingResult = {
      blockNumber,
      messageCount: expectedMessageCount,
      claimHash: null,
      processedMessages: [],
      successCount: 0,
      failureCount: 0,
      completed: false,
    };

    try {
      // PHASE 1: Claim the block
      logger.info(`PHASE 1: Claiming block ${blockNumber}`);
      const claimHash = await sourceChain.claimBlock(blockNumber, expectedMessageCount);
      
      if (!claimHash) {
        logger.error(`Failed to claim block ${blockNumber}`);
        return result;
      }

      result.claimHash = claimHash;
      logger.info(`PHASE 1 COMPLETE: Block ${blockNumber} claimed successfully`);

      // PHASE 2: Process all messages in the block
      logger.info(`PHASE 2: Processing ${expectedMessageCount} messages in block ${blockNumber}`);
      
      const messageIds = await sourceChain.getBlockMessages(blockNumber);
      if (messageIds.length !== Number(expectedMessageCount)) {
        logger.error(`Message count mismatch: expected ${expectedMessageCount}, got ${messageIds.length}`);
        return result;
      }

      // Process messages in order (maintaining transaction sequence)
      for (const messageId of messageIds) {
        const processedMessage = await this.processMessage(messageId, blockNumber);
        result.processedMessages.push(processedMessage);
        
        if (processedMessage.success) {
          result.successCount++;
        } else {
          result.failureCount++;
          // Add to failed transactions for retry later
          await this.state.addFailedTransaction({
            blockNumber,
            messageId,
            error: processedMessage.error || 'Unknown error',
            timestamp: Date.now(),
          });
        }
      }

      logger.info(`PHASE 2 COMPLETE: Block ${blockNumber} processed - ${result.successCount} success, ${result.failureCount} failed`);

      // Always mark as completed if we processed all messages (regardless of success/failure)
      result.completed = result.processedMessages.length === Number(expectedMessageCount);

      if (result.completed) {
        // DO NOT update state here - only update after Phase 3 (proof submission) completes
        // This ensures we retry blocks that crashed between Phase 2 and Phase 3
        logger.block(blockNumber, `✅ Phase 2 completed - ready for proof submission`);
      }

      return result;

    } catch (error) {
      logger.error(`Failed to process block ${blockNumber}`, error);
      return result;
    }
  }

  /**
   * Process a single message from source to destination chain
   */
  private async processMessage(messageId: bigint, blockNumber: bigint): Promise<ProcessedMessage> {
    try {
      logger.info(`Processing message ${messageId} from block ${blockNumber}`);

      // Get message details from source chain
      const message = await sourceChain.getMessage(messageId);
      if (!message) {
        return {
          messageId,
          message: {} as Message,
          deliveryHash: null,
          success: false,
          error: 'Message not found on source chain',
        };
      }

      // Get current relayer nonce
      const nonce = await destChain.getRelayerNonce(config.relayer.address);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour from now

      // Generate EIP-712 message digest for signing
      const digest = await sourceChain.getMessageDigest(
        message.destChainId,
        messageId,
        message.sender,
        message.payload,
        message.destContract,
        nonce,
        deadline
      );

      // Sign the digest using the wallet client
      const signature = await sourceChain.walletClient.signMessage({
        account: sourceChain.account,
        message: { raw: digest },
      });

      // Parse signature components
      const r = signature.slice(0, 66) as `0x${string}`;
      const s = `0x${signature.slice(66, 130)}` as `0x${string}`;
      const v = parseInt(signature.slice(130, 132), 16);

      // Execute message on destination chain
      const execution = await destChain.executeMessage(
        BigInt(config.sourceChain.chainId),
        messageId,
        message.sender,
        message.payload,
        message.destContract,
        nonce,
        deadline,
        v,
        r,
        s
      );

      if (execution.success && execution.hash) {
        logger.info(`✅ Message ${messageId} executed successfully`);
        return {
          messageId,
          message,
          deliveryHash: execution.hash,
          success: true,
        };
      } else {
        logger.warn(`❌ Message ${messageId} execution failed`);
        return {
          messageId,
          message,
          deliveryHash: execution.hash,
          success: false,
          error: 'Execution failed on destination chain',
        };
      }

    } catch (error: any) {
      logger.error(`Failed to process message ${messageId}`, error);
      return {
        messageId,
        message: {} as Message,
        deliveryHash: null,
        success: false,
        error: error.message || 'Unknown processing error',
      };
    }
  }

  /**
   * Retry a failed transaction
   */
  async retryFailedMessage(failedTx: any): Promise<boolean> {
    try {
      logger.info(`Retrying failed message ${failedTx.messageId} from block ${failedTx.blockNumber}`);
      
      const processed = await this.processMessage(failedTx.messageId, failedTx.blockNumber);
      
      if (processed.success) {
        logger.info(`✅ Retry successful for message ${failedTx.messageId}`);
        return true;
      } else {
        logger.warn(`❌ Retry failed for message ${failedTx.messageId}: ${processed.error}`);
        return false;
      }
    } catch (error) {
      logger.error(`Exception during retry of message ${failedTx.messageId}`, error);
      return false;
    }
  }

  /**
   * Check if a block is ready for processing
   */
  async isBlockReadyForProcessing(blockNumber: bigint): Promise<boolean> {
    try {
      // Check if block is claimable
      const isClaimable = await sourceChain.isBlockClaimable(blockNumber);
      if (!isClaimable) {
        return false;
      }

      // Check if block has messages
      const messageCount = await sourceChain.getBlockMessageCount(blockNumber);
      return messageCount > 0n;
    } catch (error) {
      logger.error(`Failed to check if block ${blockNumber} is ready`, error);
      return false;
    }
  }

  /**
   * Get processing status for a block
   */
  async getBlockStatus(blockNumber: bigint): Promise<{
    exists: boolean;
    claimed: boolean;
    relayer: Address | null;
    state: number;
    messageCount: bigint;
  }> {
    try {
      const claim = await sourceChain.getBlockClaim(blockNumber);
      const messageCount = await sourceChain.getBlockMessageCount(blockNumber);

      if (!claim) {
        return {
          exists: false,
          claimed: false,
          relayer: null,
          state: 0,
          messageCount,
        };
      }

      return {
        exists: true,
        claimed: claim.state >= 1, // CLAIMED or higher
        relayer: claim.relayer,
        state: claim.state,
        messageCount,
      };
    } catch (error) {
      logger.error(`Failed to get status for block ${blockNumber}`, error);
      return {
        exists: false,
        claimed: false,
        relayer: null,
        state: 0,
        messageCount: 0n,
      };
    }
  }
}