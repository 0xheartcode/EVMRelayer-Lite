import { config as loadEnv } from 'dotenv';
import { Address, isAddress } from 'viem';
import { existsSync } from 'fs';
import { join } from 'path';

// Load environment variables
const envPath = join(__dirname, '../.env');
if (existsSync(envPath)) {
  loadEnv({ path: envPath });
} else {
  console.warn('Warning: .env file not found. Using environment variables.');
}

export interface RelayerConfig {
  // Chain configuration
  sourceChain: {
    rpcUrl: string;
    chainId: number;
    contractAddress: Address;
    startBlock: bigint;
    confirmationBlocks: number;
  };
  
  destChain: {
    rpcUrl: string;
    chainId: number;
    contractAddress: Address;
  };
  
  // Relayer configuration
  relayer: {
    privateKey: `0x${string}`;
    address: Address;
    maxRetries: number;
    retryDelay: number;
  };
  
  // State management
  stateFile: string;
  
  // Health check
  healthCheckPort: number;
}

function getEnvVar(key: string, defaultValue?: string): string {
  const value = process.env[key];
  if (!value) {
    if (defaultValue !== undefined) {
      return defaultValue;
    }
    throw new Error(`Environment variable ${key} is required`);
  }
  return value;
}

function parseAddress(value: string, name: string): Address {
  if (!isAddress(value)) {
    throw new Error(`Invalid address for ${name}: ${value}`);
  }
  return value as Address;
}

// Create and validate configuration
export const config: RelayerConfig = {
  sourceChain: {
    rpcUrl: getEnvVar('RPC_URL_ONE'),
    chainId: parseInt(getEnvVar('CHAIN_ID_ONE', '31337')),
    contractAddress: parseAddress(getEnvVar('SOURCE_CONTRACT'), 'SOURCE_CONTRACT'),
    startBlock: BigInt(getEnvVar('START_BLOCK', '0')),
    confirmationBlocks: parseInt(getEnvVar('CONFIRMATION_BLOCKS', '2')),
  },
  
  destChain: {
    rpcUrl: getEnvVar('RPC_URL_TWO'),
    chainId: parseInt(getEnvVar('CHAIN_ID_TWO', '31338')),
    contractAddress: parseAddress(getEnvVar('DEST_CONTRACT'), 'DEST_CONTRACT'),
  },
  
  relayer: {
    privateKey: getEnvVar('PRIVATE_KEY') as `0x${string}`,
    address: parseAddress(getEnvVar('RELAYER_ADDRESS'), 'RELAYER_ADDRESS'),
    maxRetries: parseInt(getEnvVar('MAX_RETRIES', '3')),
    retryDelay: parseInt(getEnvVar('RETRY_DELAY', '5000')), // ms
  },
  
  stateFile: getEnvVar('STATE_FILE', join(__dirname, '../../relayer-state.json')),
  healthCheckPort: parseInt(getEnvVar('HEALTH_CHECK_PORT', '8080')),
};

// Validate private key format
if (!config.relayer.privateKey.startsWith('0x') || config.relayer.privateKey.length !== 66) {
  throw new Error('Invalid PRIVATE_KEY format. Must be 0x-prefixed 64 character hex string');
}

// Log configuration (without sensitive data)
console.log('Relayer Configuration:');
console.log(`  Source Chain: ${config.sourceChain.chainId} @ ${config.sourceChain.rpcUrl}`);
console.log(`  Dest Chain: ${config.destChain.chainId} @ ${config.destChain.rpcUrl}`);
console.log(`  Source Contract: ${config.sourceChain.contractAddress}`);
console.log(`  Dest Contract: ${config.destChain.contractAddress}`);
console.log(`  Relayer Address: ${config.relayer.address}`);
console.log(`  Start Block: ${config.sourceChain.startBlock}`);
console.log(`  Confirmation Blocks: ${config.sourceChain.confirmationBlocks}`);
console.log(`  State File: ${config.stateFile}`);

export default config;
