import { createPublicClient, createWalletClient, http, PublicClient, WalletClient, Address, parseEventLogs } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { crossChainDestinationAbi } from '../abi';
import config from '../config';
import { logger } from '../utils/logger';

export interface MessageExecutedEvent {
  messageId: bigint;
  success: boolean;
  returnData: `0x${string}`;
}

export class DestinationChainClient {
  public publicClient: PublicClient;
  public walletClient: WalletClient;
  public account: ReturnType<typeof privateKeyToAccount>;
  private contractAddress: Address;

  constructor() {
    this.contractAddress = config.destChain.contractAddress;
    
    // Create account from private key
    this.account = privateKeyToAccount(config.relayer.privateKey);

    // Create clients
    this.publicClient = createPublicClient({
      transport: http(config.destChain.rpcUrl),
    });

    this.walletClient = createWalletClient({
      account: this.account,
      transport: http(config.destChain.rpcUrl),
    });

    logger.info(`Destination chain client initialized for chain ${config.destChain.chainId}`);
  }

  /**
   * Get the current relayer nonce
   */
  async getRelayerNonce(relayer: Address): Promise<bigint> {
    try {
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainDestinationAbi,
        functionName: 'getRelayerNonce',
        args: [relayer],
      });
      return result as bigint;
    } catch (error) {
      logger.error('Failed to get relayer nonce', error);
      return 0n;
    }
  }

  /**
   * Check if relayer has the required role
   */
  async hasRelayerRole(relayer: Address): Promise<boolean> {
    try {
      const relayerRole = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainDestinationAbi,
        functionName: 'RELAYER_ROLE',
      });

      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainDestinationAbi,
        functionName: 'hasRole',
        args: [relayerRole as `0x${string}`, relayer],
      });
      
      return result as boolean;
    } catch (error) {
      logger.error('Failed to check relayer role', error);
      return false;
    }
  }

  /**
   * Get source domain separator (for signature verification)
   */
  async getSourceDomainSeparator(): Promise<`0x${string}`> {
    try {
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainDestinationAbi,
        functionName: 'getSourceDomainSeparator',
      });
      return result as `0x${string}`;
    } catch (error) {
      logger.error('Failed to get source domain separator', error);
      throw error;
    }
  }

  /**
   * Execute a cross-chain message
   * Fixed to include sourceBlockNumber parameter as required by the contract
   */
  async executeMessage(
    sourceChainId: bigint,
    sourceBlockNumber: bigint, 
    messageId: bigint,
    sender: Address,
    payload: `0x${string}`,
    destContract: Address,
    nonce: bigint,
    deadline: bigint,
    v: number,
    r: `0x${string}`,
    s: `0x${string}`
  ): Promise<{ hash: `0x${string}` | null; success: boolean; returnData?: `0x${string}` }> {
    try {
      logger.info(`Executing message ${messageId} to ${destContract}`);

      // First simulate the transaction
      const { request } = await this.publicClient.simulateContract({
        account: this.account,
        address: this.contractAddress,
        abi: crossChainDestinationAbi,
        functionName: 'executeMessage',
        args: [
          sourceChainId,
          sourceBlockNumber,
          messageId,
          sender,
          payload,
          destContract,
          nonce,
          deadline,
          v,
          r,
          s
        ],
      });

      // Execute the transaction
      const hash = await this.walletClient.writeContract(request);
      logger.tx(hash, `Message ${messageId} execution transaction sent`);

      // Wait for confirmation
      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash,
        confirmations: config.sourceChain.confirmationBlocks,
      });

      if (receipt.status === 'success') {
        // Parse events to get execution result
        const logs = parseEventLogs({
          abi: crossChainDestinationAbi,
          logs: receipt.logs,
          eventName: 'MessageExecuted',
        });

        if (logs.length > 0) {
          const event = logs[0] as any;
          logger.info(`Message ${messageId} executed successfully: ${event.args.success}`);
          return {
            hash,
            success: event.args.success,
            returnData: event.args.returnData,
          };
        }

        return { hash, success: true };
      } else {
        logger.error(`Message ${messageId} execution transaction reverted`);
        return { hash, success: false };
      }
    } catch (error: any) {
      logger.error(`Failed to execute message ${messageId}`, error);
      
      // Check if it's a specific contract error
      if (error.message?.includes('SignatureExpired')) {
        logger.warn(`Message ${messageId} signature expired`);
      } else if (error.message?.includes('InvalidNonce')) {
        logger.warn(`Message ${messageId} invalid nonce`);
      } else if (error.message?.includes('MessageAlreadyExecuted')) {
        logger.warn(`Message ${messageId} already executed`);
      }

      return { hash: null, success: false };
    }
  }

  /**
   * Batch execute multiple messages (if we add this functionality later)
   */
  async executeMessages(
    messages: Array<{
      sourceChainId: bigint;
      sourceBlockNumber: bigint;
      messageId: bigint;
      sender: Address;
      payload: `0x${string}`;
      destContract: Address;
      nonce: bigint;
      deadline: bigint;
      signature: { v: number; r: `0x${string}`; s: `0x${string}` };
    }>
  ): Promise<Array<{ messageId: bigint; hash: `0x${string}` | null; success: boolean }>> {
    const results = [];

    // Execute messages sequentially to maintain nonce order
    for (const msg of messages) {
      const result = await this.executeMessage(
        msg.sourceChainId,
        msg.sourceBlockNumber, 
        msg.messageId,
        msg.sender,
        msg.payload,
        msg.destContract,
        msg.nonce,
        msg.deadline,
        msg.signature.v,
        msg.signature.r,
        msg.signature.s
      );

      results.push({
        messageId: msg.messageId,
        hash: result.hash,
        success: result.success,
      });

      // If a message fails due to nonce issues, subsequent messages will also fail
      if (!result.success && result.hash === null) {
        logger.warn('Stopping batch execution due to transaction failure');
        break;
      }
    }

    return results;
  }

  /**
   * Get current gas price
   */
  async getGasPrice(): Promise<bigint> {
    return await this.publicClient.getGasPrice();
  }

  /**
   * Get account balance
   */
  async getBalance(): Promise<bigint> {
    return await this.publicClient.getBalance({
      address: this.account.address,
    });
  }

  /**
   * Estimate gas for message execution
   */
  async estimateGas(
    sourceChainId: bigint,
    sourceBlockNumber: bigint, 
    messageId: bigint,
    sender: Address,
    payload: `0x${string}`,
    destContract: Address,
    nonce: bigint,
    deadline: bigint,
    v: number,
    r: `0x${string}`,
    s: `0x${string}`
  ): Promise<bigint> {
    try {
      return await this.publicClient.estimateContractGas({
        account: this.account,
        address: this.contractAddress,
        abi: crossChainDestinationAbi,
        functionName: 'executeMessage',
        args: [
          sourceChainId,
          sourceBlockNumber,
          messageId,
          sender,
          payload,
          destContract,
          nonce,
          deadline,
          v,
          r,
          s
        ],
      });
    } catch (error) {
      logger.error('Failed to estimate gas', error);
      return 200000n; // Default gas limit
    }
  }
}

// Export singleton instance
export const destChain = new DestinationChainClient();
