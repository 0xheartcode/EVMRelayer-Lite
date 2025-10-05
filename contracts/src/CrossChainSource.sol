// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract CrossChainSource is AccessControl, ReentrancyGuard {
    // ============ Custom Errors ============
    error InvalidDestination();
    error EmptyPayload();
    error BlockNotFinalized();
    error NoMessagesInBlock();
    error MessageCountMismatch(uint256 expected, uint256 actual);
    error BlockAlreadyClaimed();
    error NotClaimOwner();
    error InvalidClaimState(BlockState current);
    error ProofCountMismatch(uint256 expected, uint256 actual);
    error MessageNotFound();
    error InvalidRange();

    // ============ Roles ============
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    
    // ============ EIP-712 Constants ============
    bytes32 public constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    
    bytes32 public constant MESSAGE_TYPEHASH = keccak256(
        "CrossChainMessage(uint256 sourceChainId,uint256 destChainId,uint256 messageId,address sender,bytes32 payloadHash,address destContract,uint256 nonce,uint256 deadline)"
    );
    
    bytes32 public immutable DOMAIN_SEPARATOR;

    // ============ Structs ============
    enum BlockState {
        UNCLAIMED,      // Has messages, no relayer assigned
        CLAIMED,        // Relayer claimed this block
        DELIVERED,      // Relayer confirmed delivery
        FAILED,         // Delivery failed, can be retried
        EXPIRED         // Claim expired without delivery
    }

    struct BlockClaim {
        uint256 blockNumber;
        bytes32 blockHash;
        address relayer;
        uint256 messageCount;
        uint256 claimTime;
        BlockState state;
    }

    struct Message {
        uint256 id;
        address sender;
        bytes payload;
        address destContract;
        uint256 destChainId;
        uint256 timestamp;
        uint256 blockNumber;
        uint256 indexInBlock;    // Order within the block
    }

    struct DeliveryProof {
        // Essential fields
        bytes32 destTxHash;        // Actual destination transaction hash
        bytes32 receiptsRoot;      // Cryptographic commitment to transaction
        bool success;              // Whether transaction succeeded

        // Extra information (nice to have for debugging/verification)
        bytes32 destBlockHash;     // Block containing the transaction
        uint256 destBlockNumber;   // Destination block number
        address relayerEoa;        // Address that sent the transaction
        string failureReason;      // Failure reason if success=false
    }

    struct MessageStatus {
        // Basic info
        uint256 blockNumber;
        uint256 indexInBlock;
        
        // Delivery info
        bool delivered;
        bool success;
        bytes32 destTxHash;
        
        // Block state
        BlockState blockState;
        address relayer;
        
        // Failure info (if any)
        string failureReason;
    }

    // ============ State Variables ============
    uint256 public nextMessageId;
    uint256 public constant CLAIM_TIMEOUT = 1 hours;

    // Block number => BlockClaim
    mapping(uint256 => BlockClaim) public blockClaims;

    // Block number => message count
    mapping(uint256 => uint256) public blockMessageCounts;

    // Message ID => Message
    mapping(uint256 => Message) public messages;

    // Block number => message index => message ID
    mapping(uint256 => mapping(uint256 => uint256)) public blockMessages;

    // Message ID => DeliveryProof
    mapping(uint256 => DeliveryProof) public deliveryProofs;

    // Message ID => block number (for reverse lookup)
    mapping(uint256 => uint256) public messageToBlock;

    // Block failure tracking
    mapping(uint256 => uint256) public blockFailureCount;
    mapping(uint256 => mapping(uint256 => string)) public blockFailureReasons; // block => attempt => reason

    // ============ Events ============
    event MessageSubmitted(
        uint256 indexed messageId,
        address indexed sender,
        address indexed destContract,
        uint256 destChainId,
        uint256 blockNumber
    );

    event BlockClaimed(
        uint256 indexed blockNumber,
        address indexed relayer,
        uint256 messageCount
    );

    event BlockDelivered(
        uint256 indexed blockNumber,
        address indexed relayer,
        uint256 successCount,
        uint256 failureCount
    );

    event ClaimExpired(
        uint256 indexed blockNumber,
        address indexed relayer
    );

    event BlockFailed(
        uint256 indexed blockNumber,
        address indexed relayer,
        uint256 attemptNumber,
        string reason
    );


    // ============ Constructor ============
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("CrossChainMessenger"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ============ Admin Functions ============


    // ============ User Functions ============

    /**
     * @notice Submit a cross-chain message
     * @param payload The message data to send
     * @param destContract The destination contract address
     * @param destChainId The destination chain ID
     */
    function submitMessage(
        bytes calldata payload,
        address destContract,
        uint256 destChainId
    ) external nonReentrant {
        if (destContract == address(0)) revert InvalidDestination();
        if (payload.length == 0) revert EmptyPayload();

        uint256 messageId = nextMessageId++;
        uint256 currentBlock = block.number;
        uint256 indexInBlock = blockMessageCounts[currentBlock];

        messages[messageId] = Message({
            id: messageId,
            sender: msg.sender,
            payload: payload,
            destContract: destContract,
            destChainId: destChainId,
            timestamp: block.timestamp,
            blockNumber: currentBlock,
            indexInBlock: indexInBlock
        });

        // Set up mappings for message ordering and lookup
        blockMessages[currentBlock][indexInBlock] = messageId;
        messageToBlock[messageId] = currentBlock;
        blockMessageCounts[currentBlock]++;

        emit MessageSubmitted(
            messageId,
            msg.sender,
            destContract,
            destChainId,
            currentBlock
        );
    }

    // ============ Relayer Functions ============

    /**
     * @notice Claim a block of messages for delivery
     * @param blockNumber The block number to claim
     * @param expectedMessageCount Expected number of messages in the block
     */
    function claimBlock(
        uint256 blockNumber,
        uint256 expectedMessageCount
    ) external onlyRole(RELAYER_ROLE) {
        if (blockNumber >= block.number) revert BlockNotFinalized();
        if (blockMessageCounts[blockNumber] == 0) revert NoMessagesInBlock();
        if (blockMessageCounts[blockNumber] != expectedMessageCount) {
            revert MessageCountMismatch(expectedMessageCount, blockMessageCounts[blockNumber]);
        }

        BlockClaim storage claim = blockClaims[blockNumber];
        if (!(claim.state == BlockState.UNCLAIMED ||
            claim.state == BlockState.FAILED ||
            (claim.state == BlockState.CLAIMED && block.timestamp > claim.claimTime + CLAIM_TIMEOUT))) {
            revert BlockAlreadyClaimed();
        }

        // If previous claim expired, emit event
        if (claim.state == BlockState.CLAIMED) {
            emit ClaimExpired(blockNumber, claim.relayer);
        }

        blockClaims[blockNumber] = BlockClaim({
            blockNumber: blockNumber,
            blockHash: blockhash(blockNumber),
            relayer: msg.sender,
            messageCount: expectedMessageCount,
            claimTime: block.timestamp,
            state: BlockState.CLAIMED
        });

        emit BlockClaimed(blockNumber, msg.sender, expectedMessageCount);
    }

    /**
     * @notice Confirm delivery of all messages in a block
     * @param blockNumber The block number being confirmed
     * @param proofs Array of delivery proofs for each message
     */
    function confirmBlockDelivery(
        uint256 blockNumber,
        DeliveryProof[] calldata proofs
    ) external onlyRole(RELAYER_ROLE) {
        BlockClaim storage claim = blockClaims[blockNumber];
        if (claim.relayer != msg.sender) revert NotClaimOwner();
        if (claim.state != BlockState.CLAIMED) revert InvalidClaimState(claim.state);
        if (proofs.length != claim.messageCount) {
            revert ProofCountMismatch(claim.messageCount, proofs.length);
        }


        uint256 successCount = 0;
        uint256 failureCount = 0;

        // Store all delivery proofs in order
        for (uint256 i = 0; i < proofs.length; i++) {
            uint256 messageId = blockMessages[blockNumber][i];
            deliveryProofs[messageId] = proofs[i];

            if (proofs[i].success) {
                successCount++;
            } else {
                failureCount++;
            }
        }

        claim.state = BlockState.DELIVERED;

        emit BlockDelivered(blockNumber, msg.sender, successCount, failureCount);
    }

    /**
     * @notice Mark a block as failed with reason
     * @param blockNumber The block number that failed
     * @param reason The failure reason
     */
    function markBlockFailed(
        uint256 blockNumber,
        string calldata reason
    ) external onlyRole(RELAYER_ROLE) {
        BlockClaim storage claim = blockClaims[blockNumber];
        if (claim.relayer != msg.sender) revert NotClaimOwner();
        if (claim.state != BlockState.CLAIMED) revert InvalidClaimState(claim.state);
        
        uint256 attemptNumber = blockFailureCount[blockNumber];
        blockFailureReasons[blockNumber][attemptNumber] = reason;
        blockFailureCount[blockNumber]++;
        
        claim.state = BlockState.FAILED;
        
        emit BlockFailed(blockNumber, msg.sender, attemptNumber, reason);
    }

    // ============ View Functions ============

    /**
     * @notice Get all message IDs in a block (in order)
     * @param blockNumber The block number to query
     * @return messageIds Array of message IDs in the block
     */
    function getBlockMessages(uint256 blockNumber)
        external
        view
        returns (uint256[] memory messageIds)
    {
        uint256 count = blockMessageCounts[blockNumber];
        messageIds = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            messageIds[i] = blockMessages[blockNumber][i];
        }
    }

    /**
     * @notice Find which block a message belongs to
     * @param messageId The message ID to look up
     * @return blockNumber The block number containing this message
     */
    function getMessageBlock(uint256 messageId)
        external
        view
        returns (uint256 blockNumber)
    {
        blockNumber = messageToBlock[messageId];
        if (blockNumber == 0 && messageId != 0) revert MessageNotFound();
    }

    /**
     * @notice Check if a block is available for claiming
     * @param blockNumber The block number to check
     * @return available True if the block can be claimed
     */
    function isBlockClaimable(uint256 blockNumber) external view returns (bool) {
        // Block must be finalized first
        if (blockNumber >= block.number) return false;
        
        BlockClaim storage claim = blockClaims[blockNumber];
        return blockMessageCounts[blockNumber] > 0 && (
            claim.state == BlockState.UNCLAIMED ||
            claim.state == BlockState.FAILED ||
            (claim.state == BlockState.CLAIMED && block.timestamp > claim.claimTime + CLAIM_TIMEOUT)
        );
    }

    /**
     * @notice Get delivery status for a message
     * @param messageId The message ID to check
     * @return delivered Whether the message has been delivered
     * @return success Whether the delivery was successful
     */
    function getMessageDeliveryStatus(uint256 messageId)
        external
        view
        returns (bool delivered, bool success)
    {
        uint256 blockNumber = messageToBlock[messageId];
        BlockClaim storage claim = blockClaims[blockNumber];

        delivered = claim.state == BlockState.DELIVERED;
        if (delivered) {
            success = deliveryProofs[messageId].success;
        }
    }

    // ============ Enhanced View Functions ============

    /**
     * @notice Get complete status information for a message
     * @param messageId The message ID to query
     * @return status Complete message status details
     */
    function getMessageStatus(uint256 messageId) 
        external 
        view 
        returns (MessageStatus memory status) 
    {
        if (messageId >= nextMessageId) revert MessageNotFound();
        
        Message storage message = messages[messageId];
        uint256 blockNum = message.blockNumber;
        BlockClaim storage claim = blockClaims[blockNum];
        DeliveryProof storage proof = deliveryProofs[messageId];
        
        return MessageStatus({
            blockNumber: blockNum,
            indexInBlock: message.indexInBlock,
            delivered: claim.state == BlockState.DELIVERED,
            success: proof.success,
            destTxHash: proof.destTxHash,
            blockState: claim.state,
            relayer: claim.relayer,
            failureReason: proof.failureReason
        });
    }

    /**
     * @notice Get failure history for a block
     * @param blockNumber The block number to query
     * @return attempts Number of failure attempts
     * @return reasons Array of failure reasons
     */
    function getBlockFailureHistory(uint256 blockNumber) 
        external 
        view 
        returns (uint256 attempts, string[] memory reasons) 
    {
        attempts = blockFailureCount[blockNumber];
        reasons = new string[](attempts);
        for(uint256 i = 0; i < attempts; i++) {
            reasons[i] = blockFailureReasons[blockNumber][i];
        }
    }

    /**
     * @notice Get blocks that have failed and can be retried
     * @param fromBlock Starting block number to check
     * @param toBlock Ending block number to check
     * @return failedBlocks Array of block numbers in FAILED state
     */
    function getFailedBlocks(uint256 fromBlock, uint256 toBlock) 
        external 
        view 
        returns (uint256[] memory failedBlocks) 
    {
        if (fromBlock > toBlock) revert InvalidRange();
        
        uint256[] memory temp = new uint256[](toBlock - fromBlock + 1);
        uint256 count = 0;
        
        for (uint256 i = fromBlock; i <= toBlock; i++) {
            if (blockClaims[i].state == BlockState.FAILED) {
                temp[count] = i;
                count++;
            }
        }
        
        // Create right-sized array
        failedBlocks = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            failedBlocks[i] = temp[i];
        }
    }

    /**
     * @notice Get processing gaps (blocks where later blocks are delivered but earlier ones aren't)
     * @param fromBlock Starting block number to check
     * @param toBlock Ending block number to check
     * @return gaps Array of block numbers with processing gaps
     */
    function getProcessingGaps(uint256 fromBlock, uint256 toBlock) 
        external 
        view 
        returns (uint256[] memory gaps) 
    {
        if (fromBlock > toBlock) revert InvalidRange();
        
        uint256[] memory temp = new uint256[](toBlock - fromBlock + 1);
        uint256 count = 0;
        
        bool foundDelivered = false;
        
        // Scan backwards to find gaps
        for (uint256 i = toBlock; i >= fromBlock; i--) {
            if (blockMessageCounts[i] == 0) continue; // Skip blocks with no messages
            
            if (blockClaims[i].state == BlockState.DELIVERED) {
                foundDelivered = true;
            } else if (foundDelivered && blockClaims[i].state != BlockState.DELIVERED) {
                // Found a gap: later block delivered but this one isn't
                temp[count] = i;
                count++;
            }
            
            if (i == 0) break; // Prevent underflow
        }
        
        // Create right-sized array and reverse order
        gaps = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            gaps[i] = temp[count - 1 - i];
        }
    }
    
    // ============ EIP-712 Helper Functions ============
    
    /**
     * @notice Generate EIP-712 message digest for off-chain signing
     * @param destChainId The destination chain ID
     * @param messageId The message ID
     * @param sender The original message sender
     * @param payload The message payload
     * @param destContract The destination contract address
     * @param nonce The relayer nonce for replay protection
     * @param deadline The signature expiry deadline
     * @return digest The EIP-712 message digest to be signed
     */
    function getMessageDigest(
        uint256 destChainId,
        uint256 messageId,
        address sender,
        bytes calldata payload,
        address destContract,
        uint256 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                MESSAGE_TYPEHASH,
                block.chainid,    
                destChainId,
                messageId,
                sender,
                keccak256(payload),
                destContract,
                nonce,
                deadline
            )
        );
        
        return keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );
    }
    
    /**
     * @notice Get the EIP-712 domain separator
     * @return The domain separator for this contract
     */
    function getDomainSeparator() public view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }
    
    /**
     * @notice Get chain ID
     * @return Current chain ID
     */
    function getChainId() public view returns (uint256) {
        return block.chainid;
    }
}
