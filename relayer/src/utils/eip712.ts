import { Address, encodeAbiParameters, keccak256, parseAbiParameters, toHex, TypedDataDomain } from 'viem';

// EIP-712 Domain type
export const EIP712_DOMAIN = {
  name: 'CrossChainMessenger',
  version: '1',
} as const;

// Message type definition matching smart contract
export const MESSAGE_TYPE = {
  CrossChainMessage: [
    { name: 'sourceChainId', type: 'uint256' },
    { name: 'destChainId', type: 'uint256' },
    { name: 'messageId', type: 'uint256' },
    { name: 'sender', type: 'address' },
    { name: 'payloadHash', type: 'bytes32' },
    { name: 'destContract', type: 'address' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

export interface CrossChainMessage {
  sourceChainId: bigint;
  destChainId: bigint;
  messageId: bigint;
  sender: Address;
  payloadHash: `0x${string}`;
  destContract: Address;
  nonce: bigint;
  deadline: bigint;
}

/**
 * Get the EIP-712 domain for a specific chain and contract
 */
export function getDomain(chainId: number, contractAddress: Address): TypedDataDomain {
  return {
    name: EIP712_DOMAIN.name,
    version: EIP712_DOMAIN.version,
    chainId,
    verifyingContract: contractAddress,
  };
}

/**
 * Create the typed data structure for signing
 */
export function createTypedData(
  domain: TypedDataDomain,
  message: CrossChainMessage
) {
  return {
    domain,
    types: MESSAGE_TYPE,
    primaryType: 'CrossChainMessage' as const,
    message,
  };
}

/**
 * Get the EIP-712 typed data hash for a message
 * This should match the contract's getMessageDigest function
 */
export function getMessageDigest(
  chainId: number,
  contractAddress: Address,
  message: CrossChainMessage
): `0x${string}` {
  const domain = getDomain(chainId, contractAddress);
  const domainSeparator = getDomainSeparator(domain);
  const messageHash = hashMessage(message);
  
  // EIP-712 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, messageHash))
  const digest = keccak256(
    encodeAbiParameters(
      parseAbiParameters('bytes1, bytes32, bytes32'),
      ['0x19', domainSeparator, messageHash]
    )
  );
  
  return digest;
}

/**
 * Calculate domain separator
 */
export function getDomainSeparator(domain: TypedDataDomain): `0x${string}` {
  const DOMAIN_TYPEHASH = keccak256(
    toHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
  );
  
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters('bytes32, bytes32, bytes32, uint256, address'),
      [
        DOMAIN_TYPEHASH,
        keccak256(toHex(domain.name!)),
        keccak256(toHex(domain.version!)),
        BigInt(domain.chainId!),
        domain.verifyingContract as Address,
      ]
    )
  );
}

/**
 * Hash a message according to EIP-712
 */
export function hashMessage(message: CrossChainMessage): `0x${string}` {
  const MESSAGE_TYPEHASH = keccak256(
    toHex('CrossChainMessage(uint256 sourceChainId,uint256 destChainId,uint256 messageId,address sender,bytes32 payloadHash,address destContract,uint256 nonce,uint256 deadline)')
  );
  
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters('bytes32, uint256, uint256, uint256, address, bytes32, address, uint256, uint256'),
      [
        MESSAGE_TYPEHASH,
        message.sourceChainId,
        message.destChainId,
        message.messageId,
        message.sender,
        message.payloadHash,
        message.destContract,
        message.nonce,
        message.deadline,
      ]
    )
  );
}

/**
 * Calculate the payload hash for a message
 */
export function getPayloadHash(payload: `0x${string}` | Uint8Array): `0x${string}` {
  return keccak256(payload);
}