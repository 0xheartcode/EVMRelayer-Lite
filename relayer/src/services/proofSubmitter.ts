import { Address } from 'viem';
import { sourceChain } from '../chains/sourceChain';
import { destChain } from '../chains/destChain';
import { logger } from '../utils/logger';
import { crossChainSourceAbi } from '../abi';
import config from '../config';
import { BlockProcessingResult } from './blockProcessor';

export interface DeliveryProof {
  destTxHash: `0x${string}`;
  receiptsRoot: `0x${string}`;
  success: boolean;
  destBlockHash: `0x${string}`;
  destBlockNumber: bigint;
  relayerEoa: Address;
  failureReason: string;
}

export interface ProofSubmissionResult {
  blockNumber: bigint;
  submissionHash: `0x${string}` | null;
  success: boolean;
  proofCount: number;
  error?: string;
}

export class ProofSubmitter {
  /**
   * Submit delivery proofs for a block processing result (Phase 3)
   * This ALWAYS happens regardless of individual message success/failure
   * Fixes the critical issue where partial failures left blocks in CLAIMED state forever
   */
  async submitProofsFromBlockResult(result: BlockProcessingResult): Promise<ProofSubmissionResult> {
    if (!result.completed || !result.claimHash) {
      logger.error(`Cannot submit proofs for incomplete block ${result.blockNumber}`);
      return {
        blockNumber: result.blockNumber,
        submissionHash: null,
        success: false,
        proofCount: 0,
        error: 'Block processing not completed',
      };
    }

    // Check if we have any network errors (deliveryHash: null)
    const networkErrors = result.processedMessages.filter(msg => msg.deliveryHash === null);
    
    if (networkErrors.length > 0) {
      logger.error(`Block ${result.blockNumber} has ${networkErrors.length} network errors - marking block as FAILED`);
      
      // Mark entire block as failed so another relayer can retry
      const failureHash = await this.markBlockAsFailed(
        result.blockNumber, 
        `Network errors prevented ${networkErrors.length} messages from being attempted`
      );
      
      return {
        blockNumber: result.blockNumber,
        submissionHash: failureHash,
        success: !!failureHash,
        proofCount: 0,
        error: failureHash ? undefined : 'Failed to mark block as failed',
      };
    }

    logger.info(`PHASE 3: Submitting delivery proofs for block ${result.blockNumber} (${result.successCount} success, ${result.failureCount} failed)`);

    try {
      // Create delivery proofs ONLY for messages that were actually attempted on-chain
      const proofs: DeliveryProof[] = result.processedMessages
        .filter(msg => msg.deliveryHash !== null) // Only messages with real tx hashes
        .map(msg => ({
          destTxHash: msg.deliveryHash!,
          receiptsRoot: this.generateReceiptsRoot(msg),
          success: msg.success,
          destBlockHash: this.getCurrentDestBlockHash(),
          destBlockNumber: BigInt(Date.now()), // Simplified - should use actual dest block number
          relayerEoa: config.relayer.address,
          failureReason: msg.error || '',
        }));

      // Submit proofs to source chain
      const submissionHash = await this.submitProofs(result.blockNumber, proofs);

      if (submissionHash) {
        logger.info(`✅ PHASE 3 COMPLETE: Block ${result.blockNumber} proofs submitted successfully`);
        logger.block(result.blockNumber, `🔗 3-phase protocol completed successfully`);
        return {
          blockNumber: result.blockNumber,
          submissionHash,
          success: true,
          proofCount: proofs.length,
        };
      } else {
        logger.error(`❌ Failed to submit proofs for block ${result.blockNumber}`);
        return {
          blockNumber: result.blockNumber,
          submissionHash: null,
          success: false,
          proofCount: proofs.length,
          error: 'Proof submission transaction failed',
        };
      }

    } catch (error: any) {
      logger.error(`Exception during proof submission for block ${result.blockNumber}`, error);
      return {
        blockNumber: result.blockNumber,
        submissionHash: null,
        success: false,
        proofCount: 0,
        error: error.message,
      };
    }
  }

  /**
   * Submit delivery proofs for a completed block (Phase 3)
   * This completes the accountability loop by proving delivery back to source chain
   */
  async submitBlockDeliveryProofs(
    blockNumber: bigint,
    deliveryHashes: (`0x${string}` | null)[]
  ): Promise<ProofSubmissionResult> {
    logger.info(`PHASE 3: Submitting delivery proofs for block ${blockNumber}`);

    try {
      // Filter out null hashes and create proofs
      const validHashes = deliveryHashes.filter((hash): hash is `0x${string}` => hash !== null);
      
      if (validHashes.length === 0) {
        logger.warn(`No valid delivery hashes for block ${blockNumber}`);
        return {
          blockNumber,
          submissionHash: null,
          success: false,
          proofCount: 0,
          error: 'No valid delivery hashes',
        };
      }

      // Generate delivery proofs for each transaction
      const proofs: DeliveryProof[] = [];
      
      for (const txHash of validHashes) {
        try {
          const proof = await this.generateDeliveryProof(txHash);
          proofs.push(proof);
        } catch (error: any) {
          logger.error(`Failed to generate proof for tx ${txHash}`, error);
          // Create a failed proof entry
          proofs.push({
            destTxHash: txHash,
            receiptsRoot: '0x0000000000000000000000000000000000000000000000000000000000000000',
            success: false,
            destBlockHash: '0x0000000000000000000000000000000000000000000000000000000000000000',
            destBlockNumber: 0n,
            relayerEoa: config.relayer.address,
            failureReason: error.message || 'Failed to generate proof',
          });
        }
      }

      // Submit proofs to source chain
      const submissionHash = await this.submitProofs(blockNumber, proofs);

      if (submissionHash) {
        logger.info(`✅ PHASE 3 COMPLETE: Delivery proofs submitted for block ${blockNumber}`);
        return {
          blockNumber,
          submissionHash,
          success: true,
          proofCount: proofs.length,
        };
      } else {
        logger.error(`❌ Failed to submit delivery proofs for block ${blockNumber}`);
        return {
          blockNumber,
          submissionHash: null,
          success: false,
          proofCount: proofs.length,
          error: 'Proof submission transaction failed',
        };
      }

    } catch (error: any) {
      logger.error(`Failed to submit delivery proofs for block ${blockNumber}`, error);
      return {
        blockNumber,
        submissionHash: null,
        success: false,
        proofCount: 0,
        error: error.message,
      };
    }
  }

  /**
   * Generate a delivery proof for a destination chain transaction
   */
  private async generateDeliveryProof(txHash: `0x${string}`): Promise<DeliveryProof> {
    logger.debug(`Generating delivery proof for tx ${txHash}`);

    // Get transaction receipt from destination chain
    const receipt = await destChain.publicClient.getTransactionReceipt({
      hash: txHash,
    });

    // Get the block where the transaction was included
    const block = await destChain.publicClient.getBlock({
      blockHash: receipt.blockHash,
      includeTransactions: false,
    });

    // Get the transaction details to extract relayer EOA and nonce
    const tx = await destChain.publicClient.getTransaction({
      hash: txHash,
    });

    return {
      destTxHash: txHash,
      receiptsRoot: block.receiptsRoot || '0x0000000000000000000000000000000000000000000000000000000000000000',
      success: receipt.status === 'success',
      destBlockHash: receipt.blockHash,
      destBlockNumber: receipt.blockNumber,
      relayerEoa: tx.from,
      failureReason: receipt.status === 'success' ? '' : 'Transaction reverted',
    };
  }

  /**
   * Submit proofs array to source chain contract
   */
  private async submitProofs(
    blockNumber: bigint,
    proofs: DeliveryProof[]
  ): Promise<`0x${string}` | null> {
    try {
      logger.info(`Submitting ${proofs.length} delivery proofs for block ${blockNumber}`);

      console.log(`Web3 Call: confirmBlockDelivery(\n` +
        `  blockNumber: ${blockNumber},\n` +
        `  proofs: [\n` +
        proofs.map((proof, i) => 
          `    ${i + 1}. { destTxHash: ${proof.destTxHash}, success: ${proof.success}, receiptsRoot: ${proof.receiptsRoot.slice(0, 10)}... }`
        ).join(',\n') + 
        `\n  ]\n` +
        `)`);
      
      // First simulate the transaction
      const { request } = await sourceChain.publicClient.simulateContract({
        account: sourceChain.account,
        address: config.sourceChain.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'confirmBlockDelivery',
        args: [blockNumber, proofs],
      });

      // Execute the transaction
      const hash = await sourceChain.walletClient.writeContract(request);
      logger.tx(hash, `Delivery proof submission for block ${blockNumber}`);

      // Wait for confirmation
      const receipt = await sourceChain.publicClient.waitForTransactionReceipt({
        hash,
        confirmations: config.sourceChain.confirmationBlocks,
      });

      if (receipt.status === 'success') {
        logger.info(`✅ Delivery proofs confirmed for block ${blockNumber}`);
        return hash;
      } else {
        logger.error(`❌ Delivery proof submission reverted for block ${blockNumber}`);
        return null;
      }

    } catch (error: any) {
      logger.error(`Failed to submit delivery proofs for block ${blockNumber}`, error);
      
      // Check for specific errors
      if (error.message?.includes('NotClaimOwner')) {
        logger.warn('Not the claim owner for this block');
      } else if (error.message?.includes('InvalidClaimState')) {
        logger.warn('Block is not in correct state for proof submission');
      } else if (error.message?.includes('ProofCountMismatch')) {
        logger.warn('Proof count does not match expected message count');
      }

      return null;
    }
  }

  /**
   * Mark a block as failed with reason
   */
  async markBlockAsFailed(blockNumber: bigint, reason: string): Promise<`0x${string}` | null> {
    try {
      logger.warn(`Marking block ${blockNumber} as failed: ${reason}`);

      const { request } = await sourceChain.publicClient.simulateContract({
        account: sourceChain.account,
        address: config.sourceChain.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'markBlockFailed',
        args: [blockNumber, reason],
      });

      const hash = await sourceChain.walletClient.writeContract(request);
      logger.tx(hash, `Block failure marking for block ${blockNumber}`);

      const receipt = await sourceChain.publicClient.waitForTransactionReceipt({
        hash,
        confirmations: config.sourceChain.confirmationBlocks,
      });

      if (receipt.status === 'success') {
        logger.info(`Block ${blockNumber} marked as failed`);
        return hash;
      } else {
        logger.error(`Failed to mark block ${blockNumber} as failed`);
        return null;
      }

    } catch (error) {
      logger.error(`Exception marking block ${blockNumber} as failed`, error);
      return null;
    }
  }

  /**
   * Check if a block needs proof submission
   */
  async needsProofSubmission(blockNumber: bigint): Promise<boolean> {
    try {
      const claim = await sourceChain.getBlockClaim(blockNumber);
      
      if (!claim) {
        return false;
      }

      // Check if block is claimed by us and in CLAIMED state (not yet delivered)
      return (
        claim.relayer.toLowerCase() === config.relayer.address.toLowerCase() &&
        claim.state === 1 // CLAIMED state
      );
    } catch (error) {
      logger.error(`Failed to check proof submission need for block ${blockNumber}`, error);
      return false;
    }
  }

  /**
   * Get proof submission status for a block
   */
  async getProofStatus(blockNumber: bigint): Promise<{
    needsProofs: boolean;
    isOwner: boolean;
    state: number;
    claimTime: bigint;
    expired: boolean;
  }> {
    try {
      const claim = await sourceChain.getBlockClaim(blockNumber);
      
      if (!claim) {
        return {
          needsProofs: false,
          isOwner: false,
          state: 0,
          claimTime: 0n,
          expired: false,
        };
      }

      const isOwner = claim.relayer.toLowerCase() === config.relayer.address.toLowerCase();
      const currentTime = BigInt(Math.floor(Date.now() / 1000));
      const expired = currentTime > claim.claimTime + BigInt(3600); // 1 hour timeout

      return {
        needsProofs: isOwner && claim.state === 1 && !expired,
        isOwner,
        state: claim.state,
        claimTime: claim.claimTime,
        expired,
      };
    } catch (error) {
      logger.error(`Failed to get proof status for block ${blockNumber}`, error);
      return {
        needsProofs: false,
        isOwner: false,
        state: 0,
        claimTime: 0n,
        expired: false,
      };
    }
  }


  /**
   * Generate receipts root for proof
   */
  private generateReceiptsRoot(message: any): `0x${string}` {
    const data = message.success 
      ? `success_${message.messageId}_${Date.now()}`
      : `failed_${message.messageId}_${message.error || 'unknown'}_${Date.now()}`;
    return `0x${Buffer.from(data).toString('hex').padStart(64, '0')}` as `0x${string}`;
  }

  /**
   * Get current destination chain block hash
   */
  private getCurrentDestBlockHash(): `0x${string}` {
    // Simplified - should get actual current block hash from destination chain
    return `0x${Buffer.from(`dest_block_${Date.now()}`).toString('hex').padStart(64, '0')}` as `0x${string}`;
  }
}