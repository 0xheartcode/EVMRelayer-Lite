#!/usr/bin/env node
import express from 'express';
import { MessageRelayer } from './services/messageRelayer';
import { logger } from './utils/logger';
import config from './config';

class RelayerApp {
  private app: express.Application;
  private relayer: MessageRelayer;
  private server?: any;

  constructor() {
    this.app = express();
    this.relayer = new MessageRelayer();
    this.setupMiddleware();
    this.setupRoutes();
    this.setupGracefulShutdown();
  }

  private setupMiddleware(): void {
    this.app.use(express.json());
    
    // Request logging middleware
    this.app.use((req, _res, next) => {
      logger.debug(`${req.method} ${req.path}`);
      next();
    });
  }

  private setupRoutes(): void {
    // Health check endpoint
    this.app.get('/health', async (_req, res) => {
      try {
        const health = await this.relayer.getHealth();
        const statusCode = health.status === 'healthy' ? 200 : 
                          health.status === 'degraded' ? 206 : 500;
        
        res.status(statusCode).json(health);
      } catch (error) {
        logger.error('Health check failed', error);
        res.status(500).json({
          status: 'unhealthy',
          error: 'Health check failed',
        });
      }
    });

    // Status endpoint
    this.app.get('/status', (_req, res) => {
      try {
        const status = this.relayer.getStatus();
        res.json(status);
      } catch (error) {
        logger.error('Status check failed', error);
        res.status(500).json({ error: 'Status check failed' });
      }
    });

    // Manual block processing endpoint (for testing/recovery)
    this.app.post('/process-block/:blockNumber', async (req, res) => {
      try {
        const blockNumber = BigInt(req.params.blockNumber);
        await this.relayer.processBlockManual(blockNumber);
        
        res.json({
          success: true,
          message: `Block ${blockNumber} processing initiated`,
        });
      } catch (error: any) {
        logger.error('Manual block processing failed', error);
        res.status(500).json({
          success: false,
          error: error.message,
        });
      }
    });

    // Retry specific transaction endpoint
    this.app.post('/retry-transaction', async (req, res) => {
      try {
        const { blockNumber, messageId } = req.body;
        
        if (!blockNumber || !messageId) {
          res.status(400).json({
            success: false,
            error: 'blockNumber and messageId are required',
          });
          return;
        }

        const success = await this.relayer.retryTransaction(
          BigInt(blockNumber),
          BigInt(messageId)
        );

        res.json({
          success,
          message: success ? 'Transaction retried successfully' : 'Transaction retry failed',
        });
      } catch (error: any) {
        logger.error('Transaction retry failed', error);
        res.status(500).json({
          success: false,
          error: error.message,
        });
      }
    });

    // Metrics endpoint
    this.app.get('/metrics', (_req, res) => {
      try {
        const status = this.relayer.getStatus();
        
        // Simple text metrics format
        const metrics = [
          `# HELP relayer_last_processed_block Last block processed by relayer`,
          `# TYPE relayer_last_processed_block gauge`,
          `relayer_last_processed_block ${status.state.lastProcessedBlock}`,
          ``,
          `# HELP relayer_failed_transactions Number of failed transactions`,
          `# TYPE relayer_failed_transactions gauge`,
          `relayer_failed_transactions ${status.state.failedTransactionCount}`,
          ``,
          `# HELP relayer_uptime_seconds Relayer uptime in seconds`,
          `# TYPE relayer_uptime_seconds gauge`,
          `relayer_uptime_seconds ${Math.floor(status.state.uptimeMs / 1000)}`,
          ``,
          `# HELP relayer_running Whether relayer is running`,
          `# TYPE relayer_running gauge`,
          `relayer_running ${status.isRunning ? 1 : 0}`,
        ].join('\n');

        res.setHeader('Content-Type', 'text/plain');
        res.send(metrics);
      } catch (error) {
        logger.error('Metrics generation failed', error);
        res.status(500).json({ error: 'Metrics generation failed' });
      }
    });

    // Root endpoint
    this.app.get('/', (_req, res) => {
      res.json({
        name: 'Cross-Chain Message Relayer',
        version: '1.0.0',
        status: 'running',
        endpoints: {
          health: '/health',
          status: '/status',
          metrics: '/metrics',
          processBlock: 'POST /process-block/:blockNumber',
          retryTransaction: 'POST /retry-transaction',
        },
      });
    });
  }

  private setupGracefulShutdown(): void {
    const signals = ['SIGTERM', 'SIGINT', 'SIGUSR2'];
    
    signals.forEach(signal => {
      process.on(signal, async () => {
        logger.info(`Received ${signal}, starting graceful shutdown...`);
        await this.shutdown();
        process.exit(0);
      });
    });

    process.on('uncaughtException', (error) => {
      logger.error('Uncaught exception', error);
      this.shutdown().then(() => process.exit(1));
    });

    process.on('unhandledRejection', (reason) => {
      logger.error('Unhandled rejection', reason as Error);
      this.shutdown().then(() => process.exit(1));
    });
  }

  async start(): Promise<void> {
    try {
      // Initialize and start the relayer
      logger.info('🚀 Starting Cross-Chain Message Relayer...');
      
      await this.relayer.initialize();
      await this.relayer.start();

      // Start the HTTP server
      this.server = this.app.listen(config.healthCheckPort, () => {
        logger.info(`🌐 Health check server running on port ${config.healthCheckPort}`);
        logger.info(`📊 Health endpoint: http://localhost:${config.healthCheckPort}/health`);
        logger.info(`📈 Status endpoint: http://localhost:${config.healthCheckPort}/status`);
        logger.info(`📋 Metrics endpoint: http://localhost:${config.healthCheckPort}/metrics`);
      });

      logger.info('✅ Cross-Chain Message Relayer started successfully');
      logger.info('');
      logger.info('🔗 Relayer Configuration:');
      logger.info(`   Source Chain: ${config.sourceChain.chainId} @ ${config.sourceChain.rpcUrl}`);
      logger.info(`   Dest Chain: ${config.destChain.chainId} @ ${config.destChain.rpcUrl}`);
      logger.info(`   Relayer: ${config.relayer.address}`);
      logger.info('');
      logger.info('📡 Now monitoring for cross-chain messages...');

    } catch (error) {
      logger.error('Failed to start relayer', error);
      throw error;
    }
  }

  async shutdown(): Promise<void> {
    logger.info('🛑 Shutting down Cross-Chain Message Relayer...');

    try {
      // Stop the relayer service
      await this.relayer.stop();

      // Close the HTTP server
      if (this.server) {
        await new Promise<void>((resolve) => {
          this.server.close(() => {
            logger.info('HTTP server closed');
            resolve();
          });
        });
      }

      logger.info('✅ Graceful shutdown completed');
    } catch (error) {
      logger.error('Error during shutdown', error);
    }
  }
}

// Main execution
async function main(): Promise<void> {
  const app = new RelayerApp();
  
  try {
    await app.start();
  } catch (error) {
    logger.error('Failed to start application', error);
    process.exit(1);
  }
}

// Handle CLI arguments
const args = process.argv.slice(2);
if (args.includes('--help') || args.includes('-h')) {
  console.log(`
Cross-Chain Message Relayer

Usage: node dist/index.js [options]

Options:
  --help, -h          Show this help message
  --version, -v       Show version information

Environment Variables:
  PRIVATE_KEY           Relayer private key (0x prefixed)
  RELAYER_ADDRESS       Relayer address
  SOURCE_CONTRACT       Source contract address
  DEST_CONTRACT         Destination contract address
  RPC_URL_ONE           Source chain RPC URL
  CHAIN_ID_ONE          Source chain ID (default: 31337)
  RPC_URL_TWO           Destination chain RPC URL  
  CHAIN_ID_TWO          Destination chain ID (default: 31338)
  START_BLOCK           Starting block number (default: 0)
  CONFIRMATION_BLOCKS   Confirmation blocks (default: 2)
  STATE_FILE            State file path (default: ./relayer-state.json)
  HEALTH_CHECK_PORT     Health check port (default: 8080)
  LOG_LEVEL             Log level (DEBUG, INFO, WARN, ERROR)

Examples:
  # Start with environment file
  node dist/index.js

  # Check health
  curl http://localhost:8080/health

  # View status
  curl http://localhost:8080/status

  # Process specific block manually
  curl -X POST http://localhost:8080/process-block/123

For more information, visit: https://github.com/your-repo/evmrelayer-lite
`);
  process.exit(0);
}

if (args.includes('--version') || args.includes('-v')) {
  console.log('Cross-Chain Message Relayer v1.0.0');
  process.exit(0);
}

// Start the application
if (require.main === module) {
  main().catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}

export default RelayerApp;