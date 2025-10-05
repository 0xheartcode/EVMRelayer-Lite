// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

contract SignatureUtils is Test {
    struct EIP712Domain {
        string name;
        string version;
        uint256 chainId;
        address verifyingContract;
    }

    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 constant MESSAGE_TYPEHASH = keccak256(
        "CrossChainMessage(uint256 sourceChainId,uint256 destChainId,uint256 messageId,address sender,bytes32 payloadHash,address destContract,uint256 nonce,uint256 deadline)"
    );

    function computeDomainSeparator(
        string memory name,
        string memory version,
        uint256 chainId,
        address verifyingContract
    ) public pure returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
    }

    function signMessage(
        uint256 privateKey,
        bytes32 domainSeparator,
        uint256 sourceChainId,
        uint256 destChainId,
        uint256 messageId,
        address sender,
        bytes memory payload,
        address destContract,
        uint256 nonce,
        uint256 deadline
    ) public pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                MESSAGE_TYPEHASH,
                sourceChainId,
                destChainId,
                messageId,
                sender,
                keccak256(payload),
                destContract,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        return vm.sign(privateKey, digest);
    }

    function createMalformedSignature() public pure returns (uint8 v, bytes32 r, bytes32 s) {
        return (0, bytes32(0), bytes32(0));
    }

    function createInvalidSignature() public pure returns (uint8 v, bytes32 r, bytes32 s) {
        return (27, keccak256("invalid"), keccak256("signature"));
    }
}
