// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CrossChainDestination is AccessControl, ReentrancyGuard {
    // ============ Custom Errors ============
    error SignatureExpired();
    error InvalidNonce(uint256 expected, uint256 provided);
    error InvalidSignature();
    error UnauthorizedRelayer();
    error MessageAlreadyProcessed();

    // ============ Roles ============
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");

    // ============ EIP-712 Constants ============
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 public constant MESSAGE_TYPEHASH = keccak256(
        "CrossChainMessage(uint256 sourceChainId,uint256 destChainId,uint256 messageId,address sender,bytes32 payloadHash,address destContract,uint256 nonce,uint256 deadline)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public immutable SOURCE_DOMAIN_SEPARATOR;

    // ============ Structs ============
    struct ExecutedMessage {
        uint256 sourceChainId;
        uint256 sourceBlockNumber;
        uint256 messageId;
        address sender;
        bytes payload;
        address executor;
        uint256 timestamp;
        bool success;
        bytes returnData;
    }

    // ============ State Variables ============
    // Message hash => processed
    mapping(bytes32 => bool) public processedMessages;

    // Message hash => execution details
    mapping(bytes32 => ExecutedMessage) public executedMessages;

    // Relayer address => nonce (for replay protection)
    mapping(address => uint256) public relayerNonces;

    // ============ Events ============
    event MessageExecuted(
        uint256 indexed sourceChainId,
        uint256 indexed messageId,
        address indexed destContract,
        bytes32 messageHash,
        bool success,
        bytes returnData
    );

    event MessageFailed(
        uint256 indexed sourceChainId,
        uint256 indexed messageId,
        address indexed destContract,
        bytes32 messageHash,
        string reason
    );

    // ============ Constructor ============
    /**
     * @param sourceChainId The source chain ID for signature verification
     * @param sourceContract The source contract address for signature verification
     */
    constructor(uint256 sourceChainId, address sourceContract) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Domain separator for this contract (destination)
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("CrossChainMessenger"), keccak256("1"), block.chainid, address(this))
        );

        // Domain separator for source contract (for signature verification)
        SOURCE_DOMAIN_SEPARATOR = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("CrossChainMessenger"), keccak256("1"), sourceChainId, sourceContract)
        );
    }

    // ============ Relayer Functions ============

    /**
     * @notice Execute a cross-chain message with EIP-712 signature verification
     * @param sourceChainId The source chain ID
     * @param sourceBlockNumber The source block number
     * @param messageId The message ID from source chain
     * @param sender Original message sender
     * @param payload Message payload
     * @param destContract Destination contract to call
     * @param nonce The relayer nonce for replay protection
     * @param deadline The signature expiry deadline
     * @param v Signature component
     * @param r Signature component
     * @param s Signature component
     */
    function executeMessage(
        uint256 sourceChainId,
        uint256 sourceBlockNumber,
        uint256 messageId,
        address sender,
        bytes calldata payload,
        address destContract,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // Check deadline
        if (block.timestamp > deadline) revert SignatureExpired();

        // Verify nonce for relayer replay protection
        address relayer = msg.sender;
        if (relayerNonces[relayer] != nonce) {
            revert InvalidNonce(relayerNonces[relayer], nonce);
        }
        relayerNonces[relayer]++;

        // Create EIP-712 digest
        bytes32 structHash = keccak256(
            abi.encode(
                MESSAGE_TYPEHASH,
                sourceChainId,
                block.chainid, // destChainId
                messageId,
                sender,
                keccak256(payload),
                destContract,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", SOURCE_DOMAIN_SEPARATOR, structHash));

        // Recover signer
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        if (!hasRole(RELAYER_ROLE, signer)) revert UnauthorizedRelayer();

        // Calculate message hash for replay protection
        bytes32 messageHash =
            calculateMessageHash(sourceChainId, sourceBlockNumber, messageId, sender, payload, destContract);

        if (processedMessages[messageHash]) revert MessageAlreadyProcessed();
        processedMessages[messageHash] = true;

        // Execute the message
        (bool success, bytes memory returnData) = destContract.call(payload);

        // Store execution details
        executedMessages[messageHash] = ExecutedMessage({
            sourceChainId: sourceChainId,
            sourceBlockNumber: sourceBlockNumber,
            messageId: messageId,
            sender: sender,
            payload: payload,
            executor: msg.sender,
            timestamp: block.timestamp,
            success: success,
            returnData: returnData
        });

        if (success) {
            emit MessageExecuted(sourceChainId, messageId, destContract, messageHash, true, returnData);
        } else {
            string memory reason = _getRevertMsg(returnData);

            emit MessageFailed(sourceChainId, messageId, destContract, messageHash, reason);
        }
    }

    // ============ Internal Functions ============

    /**
     * @notice Extract revert message from failed call
     * @param _returnData The return data from failed call
     * @return The revert reason string
     */
    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        if (_returnData.length < 68) return "Transaction failed";

        assembly {
            _returnData := add(_returnData, 0x04)
        }

        return abi.decode(_returnData, (string));
    }

    // ============ View Functions ============

    /**
     * @notice Check if a message has been processed
     * @param messageHash The message hash to check
     * @return processed True if message was already executed
     */
    function isMessageProcessed(bytes32 messageHash) external view returns (bool) {
        return processedMessages[messageHash];
    }

    /**
     * @notice Calculate message hash
     * @dev Helper function for off-chain verification
     */
    function calculateMessageHash(
        uint256 sourceChainId,
        uint256 sourceBlockNumber,
        uint256 messageId,
        address sender,
        bytes calldata payload,
        address destContract
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(sourceChainId, sourceBlockNumber, messageId, sender, payload, destContract));
    }

    /**
     * @notice Get execution details for a processed message
     * @param messageHash The message hash to query
     * @return executed Whether the message was executed
     * @return details The execution details (if executed)
     */
    function getExecutionDetails(bytes32 messageHash)
        external
        view
        returns (bool executed, ExecutedMessage memory details)
    {
        executed = processedMessages[messageHash];
        if (executed) {
            details = executedMessages[messageHash];
        }
    }

    // ============ EIP-712 Helper Functions ============

    /**
     * @notice Verify a signature without executing the message
     * @dev Helper function for off-chain verification
     * @return signer The address that signed the message
     */
    function verifySignature(
        uint256 sourceChainId,
        uint256 messageId,
        address sender,
        bytes calldata payload,
        address destContract,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public view returns (address signer) {
        bytes32 structHash = keccak256(
            abi.encode(
                MESSAGE_TYPEHASH,
                sourceChainId,
                block.chainid,
                messageId,
                sender,
                keccak256(payload),
                destContract,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", SOURCE_DOMAIN_SEPARATOR, structHash));

        signer = ecrecover(digest, v, r, s);
    }

    /**
     * @notice Get the current nonce for a relayer
     * @param relayer The relayer address
     * @return The current nonce
     */
    function getRelayerNonce(address relayer) public view returns (uint256) {
        return relayerNonces[relayer];
    }

    /**
     * @notice Get the source domain separator
     * @return The domain separator used for signature verification
     */
    function getSourceDomainSeparator() public view returns (bytes32) {
        return SOURCE_DOMAIN_SEPARATOR;
    }
}
