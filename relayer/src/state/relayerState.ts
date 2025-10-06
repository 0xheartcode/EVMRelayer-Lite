import { promises as fs } from 'fs';
import { existsSync } from 'fs';
import { logger } from '../utils/logger';
import config from '../config';

export interface FailedTransaction {
  blockNumber: bigint;
  messageId: bigint;
  error: string;
  timestamp: number;
  retryCount?: number;
}

export interface RelayerStateData {
  lastProcessedBlock: bigint;
  failedTransactions: FailedTransaction[];
  startupTime: number;
  version: string;
}

export class RelayerState {
  private stateFile: string;
  private state: RelayerStateData;

  constructor(stateFile?: string) {
    this.stateFile = stateFile || config.stateFile;
    this.state = {
      lastProcessedBlock: config.sourceChain.startBlock,
      failedTransactions: [],
      startupTime: Date.now(),
      version: '1.0.0',
    };
  }

  /**
   * Initialize state by loading from file or creating new
   */
  async initialize(): Promise<void> {
    try {
      if (existsSync(this.stateFile)) {
        await this.loadState();
        logger.info(`State loaded from ${this.stateFile}`);
        logger.info(`Last processed block: ${this.state.lastProcessedBlock}`);
        logger.info(`Failed transactions: ${this.state.failedTransactions.length}`);
      } else {
        await this.saveState();
        logger.info(`New state file created at ${this.stateFile}`);
        logger.info(`Starting from block: ${this.state.lastProcessedBlock}`);
      }
    } catch (error) {
      logger.error('Failed to initialize state', error);
      throw error;
    }
  }

  /**
   * Load state from JSON file
   */
  private async loadState(): Promise<void> {
    try {
      const data = await fs.readFile(this.stateFile, 'utf-8');
      const parsed = JSON.parse(data);
      
      // Convert string numbers back to bigints
      this.state = {
        lastProcessedBlock: BigInt(parsed.lastProcessedBlock || 0),
        failedTransactions: (parsed.failedTransactions || []).map((tx: any) => ({
          ...tx,
          blockNumber: BigInt(tx.blockNumber),
          messageId: BigInt(tx.messageId),
        })),
        startupTime: parsed.startupTime || Date.now(),
        version: parsed.version || '1.0.0',
      };
    } catch (error) {
      logger.error('Failed to load state file', error);
      throw error;
    }
  }

  /**
   * Save state to JSON file
   */
  private async saveState(): Promise<void> {
    try {
      // Convert bigints to strings for JSON serialization
      const serializable = {
        lastProcessedBlock: this.state.lastProcessedBlock.toString(),
        failedTransactions: this.state.failedTransactions.map(tx => ({
          ...tx,
          blockNumber: tx.blockNumber.toString(),
          messageId: tx.messageId.toString(),
        })),
        startupTime: this.state.startupTime,
        version: this.state.version,
      };

      await fs.writeFile(this.stateFile, JSON.stringify(serializable, null, 2));
    } catch (error) {
      logger.error('Failed to save state file', error);
      throw error;
    }
  }

  /**
   * Get the last processed block
   */
  getLastProcessedBlock(): bigint {
    return this.state.lastProcessedBlock;
  }

  /**
   * Set the last processed block and save state
   */
  async setLastProcessedBlock(blockNumber: bigint): Promise<void> {
    this.state.lastProcessedBlock = blockNumber;
    await this.saveState();
  }

  /**
   * Add a failed transaction
   */
  async addFailedTransaction(failedTx: FailedTransaction): Promise<void> {
    // Check if this transaction already exists
    const existing = this.state.failedTransactions.find(
      tx => tx.blockNumber === failedTx.blockNumber && tx.messageId === failedTx.messageId
    );

    if (existing) {
      // Update retry count
      existing.retryCount = (existing.retryCount || 0) + 1;
      existing.error = failedTx.error;
      existing.timestamp = failedTx.timestamp;
    } else {
      // Add new failed transaction
      this.state.failedTransactions.push({
        ...failedTx,
        retryCount: 0,
      });
    }

    await this.saveState();
  }

  /**
   * Remove a failed transaction (when successfully retried)
   */
  async removeFailedTransaction(blockNumber: bigint, messageId: bigint): Promise<void> {
    this.state.failedTransactions = this.state.failedTransactions.filter(
      tx => !(tx.blockNumber === blockNumber && tx.messageId === messageId)
    );
    await this.saveState();
  }

  /**
   * Get all failed transactions
   */
  getFailedTransactions(): FailedTransaction[] {
    return [...this.state.failedTransactions];
  }

  /**
   * Get failed transactions that should be retried
   */
  getRetryableFailedTransactions(maxRetries: number = 3): FailedTransaction[] {
    return this.state.failedTransactions.filter(
      tx => (tx.retryCount || 0) < maxRetries
    );
  }

  /**
   * Clear old failed transactions (older than 24 hours)
   */
  async cleanupOldFailedTransactions(maxAge: number = 24 * 60 * 60 * 1000): Promise<void> {
    const cutoff = Date.now() - maxAge;
    const initialCount = this.state.failedTransactions.length;
    
    this.state.failedTransactions = this.state.failedTransactions.filter(
      tx => tx.timestamp > cutoff
    );

    const removedCount = initialCount - this.state.failedTransactions.length;
    if (removedCount > 0) {
      logger.info(`Cleaned up ${removedCount} old failed transactions`);
      await this.saveState();
    }
  }

  /**
   * Get current state summary
   */
  getSummary(): {
    lastProcessedBlock: bigint;
    failedTransactionCount: number;
    uptimeMs: number;
    version: string;
  } {
    return {
      lastProcessedBlock: this.state.lastProcessedBlock,
      failedTransactionCount: this.state.failedTransactions.length,
      uptimeMs: Date.now() - this.state.startupTime,
      version: this.state.version,
    };
  }

  /**
   * Reset state (for testing or manual intervention)
   */
  async reset(startBlock?: bigint): Promise<void> {
    this.state = {
      lastProcessedBlock: startBlock || config.sourceChain.startBlock,
      failedTransactions: [],
      startupTime: Date.now(),
      version: '1.0.0',
    };
    await this.saveState();
    logger.info('State reset successfully');
  }

  /**
   * Backup current state
   */
  async backup(): Promise<string> {
    const backupFile = `${this.stateFile}.backup.${Date.now()}`;
    await fs.copyFile(this.stateFile, backupFile);
    logger.info(`State backed up to ${backupFile}`);
    return backupFile;
  }
}