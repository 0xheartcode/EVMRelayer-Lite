import CrossChainSourceAbi from './CrossChainSource.json';
import CrossChainDestinationAbi from './CrossChainDestination.json';

// Export typed ABIs
export const crossChainSourceAbi = CrossChainSourceAbi;
export const crossChainDestinationAbi = CrossChainDestinationAbi;

// Export type-safe contract names
export const contractNames = {
  source: 'CrossChainSource',
  destination: 'CrossChainDestination',
} as const;