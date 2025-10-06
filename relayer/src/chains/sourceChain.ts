import { createPublicClient, createWalletClient, http, PublicClient, WalletClient, Address, parseEventLogs } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { crossChainSourceAbi } from '../abi';
import config from '../config';
import { logger } from '../utils/logger';

export interface BlockClaim {
  blockNumber: bigint;
  blockHash: `0x${string}`;
  relayer: Address;
  messageCount: bigint;
  claimTime: bigint;
  state: number; // 0: AVAILABLE, 1: CLAIMED, 2: DELIVERED, 3: FAILED
}

export interface Message {
  sender: Address;
  destChainId: bigint;
  destContract: Address;
  payload: `0x${string}`;
  blockNumber: bigint;
}

export interface MessageSubmittedEvent {
  messageId: bigint;
  sender: Address;
  destContract: Address;
  destChainId: bigint;
  blockNumber: bigint;
}

export class SourceChainClient {
  public publicClient: PublicClient;
  public walletClient: WalletClient;
  public account: ReturnType<typeof privateKeyToAccount>;
  private contractAddress: Address;

  constructor() {
    this.contractAddress = config.sourceChain.contractAddress;
    
    // Create account from private key
    this.account = privateKeyToAccount(config.relayer.privateKey);
    config.relayer.address = this.account.address;

    // Create clients
    this.publicClient = createPublicClient({
      transport: http(config.sourceChain.rpcUrl),
    });

    this.walletClient = createWalletClient({
      account: this.account,
      transport: http(config.sourceChain.rpcUrl),
    });

    logger.info(`Source chain client initialized for chain ${config.sourceChain.chainId}`);
    logger.info(`Relayer address: ${this.account.address}`);
  }

  /**
   * Get the current block number
   */
  async getCurrentBlock(): Promise<bigint> {
    return await this.publicClient.getBlockNumber();
  }

  /**
   * Check if a block is claimable
   */
  async isBlockClaimable(blockNumber: bigint): Promise<boolean> {
    try {
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'isBlockClaimable',
        args: [blockNumber],
      });
      return result as boolean;
    } catch (error) {
      logger.error(`Failed to check if block ${blockNumber} is claimable`, error);
      return false;
    }
  }

  /**
   * Get block claim information
   */
  async getBlockClaim(blockNumber: bigint): Promise<BlockClaim | null> {
    try {
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'blockClaims',
        args: [blockNumber],
      }) as any[];

      return {
        blockNumber: result[0],
        blockHash: result[1],
        relayer: result[2],
        messageCount: result[3],
        claimTime: result[4],
        state: Number(result[5]),
      };
    } catch (error) {
      logger.error(`Failed to get block claim for block ${blockNumber}`, error);
      return null;
    }
  }

  /**
   * Get message count for a block
   */
  async getBlockMessageCount(blockNumber: bigint): Promise<bigint> {
    try {
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'blockMessageCounts',
        args: [blockNumber],
      });
      return result as bigint;
    } catch (error) {
      logger.error(`Failed to get message count for block ${blockNumber}`, error);
      return 0n;
    }
  }

  /**
   * Get all message IDs in a block
   */
  async getBlockMessages(blockNumber: bigint): Promise<bigint[]> {
    try {
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'getBlockMessages',
        args: [blockNumber],
      });
      return result as bigint[];
    } catch (error) {
      logger.error(`Failed to get messages for block ${blockNumber}`, error);
      return [];
    }
  }

  /**
   * Get message details
   */
  async getMessage(messageId: bigint): Promise<Message | null> {
    try {
      console.log(`Web3 Call: getMessage(messageId: ${messageId})`);
      
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'messages',
        args: [messageId],
      }) as any[];

      // Contract returns: [id, sender, payload, destContract, destChainId, timestamp, blockNumber, indexInBlock]
      // Fixed mapping to use correct indices:
      return {
        sender: result[1],          // index 1: sender
        destChainId: result[4],     // index 4: destChainId  
        destContract: result[3],    // index 3: destContract
        payload: result[2],         // index 2: payload
        blockNumber: result[6],     // index 6: blockNumber
      };
    } catch (error) {
      logger.error(`Failed to get message ${messageId}`, error);
      return null;
    }
  }

  /**
   * Get message events from a specific block
   */
  async getMessageEvents(blockNumber: bigint): Promise<MessageSubmittedEvent[]> {
    try {
      console.log(`Web3 Call: getLogs(block: ${blockNumber}, event: MessageSubmitted)`);
      
      const logs = await this.publicClient.getLogs({
        address: this.contractAddress,
        events: crossChainSourceAbi,
        fromBlock: blockNumber,
        toBlock: blockNumber,
      });

      const events = parseEventLogs({
        abi: crossChainSourceAbi,
        logs,
        eventName: 'MessageSubmitted',
      });

      return events.map(event => ({
        messageId: (event as any).args.messageId,
        sender: (event as any).args.sender,
        destContract: (event as any).args.destContract,
        destChainId: (event as any).args.destChainId,
        blockNumber: (event as any).args.blockNumber,
      }));
    } catch (error) {
      logger.error(`Failed to get message events for block ${blockNumber}`, error);
      return [];
    }
  }

  /**
   * Claim a block for processing
   */
  async claimBlock(blockNumber: bigint, expectedMessageCount: bigint): Promise<`0x${string}` | null> {
    try {
      logger.info(`Claiming block ${blockNumber} with ${expectedMessageCount} messages`);
      
      console.log(`Web3 Call: claimBlock(${blockNumber}, ${expectedMessageCount})`);
      
      const { request } = await this.publicClient.simulateContract({
        account: this.account,
        address: this.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'claimBlock',
        args: [blockNumber, expectedMessageCount],
      });

      const hash = await this.walletClient.writeContract(request);
      logger.tx(hash, `Block ${blockNumber} claim transaction sent`);
      
      // Wait for confirmation
      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash,
        confirmations: config.sourceChain.confirmationBlocks,
      });

      if (receipt.status === 'success') {
        logger.info(`Successfully claimed block ${blockNumber}`);
        return hash;
      } else {
        logger.error(`Failed to claim block ${blockNumber}: transaction reverted`);
        return null;
      }
    } catch (error) {
      logger.error(`Failed to claim block ${blockNumber}`, error);
      return null;
    }
  }

  /**
   * Get EIP-712 message digest for signing
   */
  async getMessageDigest(
    destChainId: bigint,
    messageId: bigint,
    sender: Address,
    payload: `0x${string}`,
    destContract: Address,
    nonce: bigint,
    deadline: bigint
  ): Promise<`0x${string}`> {
    const result = await this.publicClient.readContract({
      address: this.contractAddress,
      abi: crossChainSourceAbi,
      functionName: 'getMessageDigest',
      args: [destChainId, messageId, sender, payload, destContract, nonce, deadline],
    });
    return result as `0x${string}`;
  }

  /**
   * Get domain separator for EIP-712
   */
  async getDomainSeparator(): Promise<`0x${string}`> {
    const result = await this.publicClient.readContract({
      address: this.contractAddress,
      abi: crossChainSourceAbi,
      functionName: 'getDomainSeparator',
    });
    return result as `0x${string}`;
  }

  /**
   * Watch for new blocks that need processing
   */
  async watchBlocks(
    fromBlock: bigint,
    onBlock: (blockNumber: bigint, messageCount: bigint) => Promise<void>
  ): Promise<() => void> {
    logger.info(`Starting block watcher from block ${fromBlock}`);

    let isWatching = true;
    let currentBlock = fromBlock;

    const poll = async () => {
      while (isWatching) {
        try {
          const latestBlock = await this.getCurrentBlock();
          const targetBlock = latestBlock - BigInt(config.sourceChain.confirmationBlocks);

          while (currentBlock <= targetBlock && isWatching) {
            const messageCount = await this.getBlockMessageCount(currentBlock);
            
            if (messageCount > 0n) {
              const isClaimable = await this.isBlockClaimable(currentBlock);
              if (isClaimable) {
                logger.block(currentBlock, `Found ${messageCount} messages, block is claimable`);
                await onBlock(currentBlock, messageCount);
              }
            }
            
            currentBlock++;
          }

          // Wait before next poll
          await new Promise(resolve => setTimeout(resolve, 5000)); // 5 second polling
        } catch (error) {
          logger.error('Block watcher error', error);
          await new Promise(resolve => setTimeout(resolve, 10000)); // Wait longer on error
        }
      }
    };

    // Start polling in background
    poll().catch(error => logger.error('Block watcher crashed', error));

    // Return stop function
    return () => {
      isWatching = false;
      logger.info('Block watcher stopped');
    };
  }

  /**
   * Get detailed block delivery status
   */
  async getBlockDeliveryStatus(blockNumber: bigint): Promise<{
    state: number;
    successCount: number;
    failureCount: number;
    totalMessages: number;
  } | null> {
    try {
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'getBlockDeliveryStatus',
        args: [blockNumber],
      }) as [number, bigint, bigint, bigint];

      return {
        state: result[0],
        successCount: Number(result[1]),
        failureCount: Number(result[2]),
        totalMessages: Number(result[3]),
      };
    } catch (error) {
      logger.error(`Failed to get block delivery status for ${blockNumber}`, error);
      return null;
    }
  }

  /**
   * Get failed message IDs for a block
   */
  async getFailedMessagesForBlock(blockNumber: bigint): Promise<number[]> {
    try {
      const result = await this.publicClient.readContract({
        address: this.contractAddress,
        abi: crossChainSourceAbi,
        functionName: 'getFailedMessagesForBlock',
        args: [blockNumber],
      }) as bigint[];

      return result.map(id => Number(id));
    } catch (error) {
      logger.error(`Failed to get failed messages for block ${blockNumber}`, error);
      return [];
    }
  }
}

// Export singleton instance
export const sourceChain = new SourceChainClient();
