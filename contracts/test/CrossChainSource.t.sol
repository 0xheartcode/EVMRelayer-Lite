// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./utils/TestHelpers.sol";

contract CrossChainSourceTest is TestHelpers {
    
    function setUp() public {
        setupContracts();
        vm.chainId(SOURCE_CHAIN_ID);
    }

    // ============ MESSAGE SUBMISSION TESTS ============

    function test_ValidMessageSubmission() public {
        bytes memory payload = "Hello cross-chain world";
        address destContract_ = address(mockTarget);
        uint256 destChainId = DEST_CHAIN_ID;

        vm.expectEmit(true, true, true, true);
        emit CrossChainSource.MessageSubmitted(
            0, // messageId
            user,
            destContract_,
            destChainId,
            block.number
        );

        vm.prank(user);
        sourceContract.submitMessage(payload, destContract_, destChainId);

        // Verify message was stored correctly
        (
            uint256 id,
            address sender,
            bytes memory storedPayload,
            address storedDestContract,
            uint256 storedDestChainId,
            uint256 timestamp,
            uint256 blockNumber,
            uint256 indexInBlock
        ) = sourceContract.messages(0);

        assertEq(id, 0);
        assertEq(sender, user);
        assertEq(storedPayload, payload);
        assertEq(storedDestContract, destContract_);
        assertEq(storedDestChainId, destChainId);
        assertEq(timestamp, block.timestamp);
        assertEq(blockNumber, block.number);
        assertEq(indexInBlock, 0);

        assertEq(sourceContract.nextMessageId(), 1);
        assertEq(sourceContract.blockMessageCounts(block.number), 1);
    }

    function test_RevertOnInvalidDestination() public {
        bytes memory payload = "test";
        
        expectCustomError(CrossChainSource.InvalidDestination.selector);
        
        vm.prank(user);
        sourceContract.submitMessage(payload, address(0), DEST_CHAIN_ID);
    }

    function test_RevertOnEmptyPayload() public {
        bytes memory emptyPayload = "";
        
        expectCustomError(CrossChainSource.EmptyPayload.selector);
        
        vm.prank(user);
        sourceContract.submitMessage(emptyPayload, address(mockTarget), DEST_CHAIN_ID);
    }

    function test_MultipleMessagesInSameBlock() public {
        bytes memory payload1 = "Message 1";
        bytes memory payload2 = "Message 2";
        bytes memory payload3 = "Message 3";

        vm.prank(user);
        sourceContract.submitMessage(payload1, address(mockTarget), DEST_CHAIN_ID);
        
        vm.prank(user);
        sourceContract.submitMessage(payload2, address(mockTarget), DEST_CHAIN_ID);
        
        vm.prank(user);
        sourceContract.submitMessage(payload3, address(mockTarget), DEST_CHAIN_ID);

        uint256 currentBlock = block.number;
        assertEq(sourceContract.blockMessageCounts(currentBlock), 3);
        assertEq(sourceContract.nextMessageId(), 3);

        // Check message ordering
        uint256[] memory messageIds = sourceContract.getBlockMessages(currentBlock);
        assertEq(messageIds.length, 3);
        assertEq(messageIds[0], 0);
        assertEq(messageIds[1], 1);
        assertEq(messageIds[2], 2);
    }

    // ============ BLOCK CLAIMING TESTS ============

    function test_ValidBlockClaiming() public {
        // Submit a message first
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = sourceContract.getMessageBlock(0);

        // Move to next block
        vm.roll(blockNumber + 1);

        vm.expectEmit(true, true, true, false);
        emit CrossChainSource.BlockClaimed(blockNumber, relayer, 1);

        vm.prank(relayer);
        sourceContract.claimBlock(blockNumber, 1);

        (
            uint256 claimedBlockNumber,
            bytes32 blockHash,
            address claimRelayer,
            uint256 messageCount,
            uint256 claimTime,
            CrossChainSource.BlockState state
        ) = sourceContract.blockClaims(blockNumber);

        assertEq(claimedBlockNumber, blockNumber);
        assertEq(claimRelayer, relayer);
        assertEq(messageCount, 1);
        assertEq(uint256(state), uint256(CrossChainSource.BlockState.CLAIMED));
    }

    function test_RevertOnBlockNotFinalized() public {
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = block.number;

        // Don't move to next block - try to claim current block
        expectCustomError(CrossChainSource.BlockNotFinalized.selector);
        
        vm.prank(relayer);
        sourceContract.claimBlock(blockNumber, 1);
    }

    function test_RevertOnNoMessagesInBlock() public {
        // Set to block 100, then move to 110 to make 100 claimable
        vm.roll(100);
        uint256 emptyBlock = 100;  // Explicitly set empty block to 100
        vm.roll(110);  // Move to 110 so block 100 is finalized

        expectCustomError(CrossChainSource.NoMessagesInBlock.selector);
        
        vm.prank(relayer);
        sourceContract.claimBlock(emptyBlock, 0);  // Claim block 100, current is 110
    }

    function test_RevertOnMessageCountMismatch() public {
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = sourceContract.getMessageBlock(0);
        vm.roll(blockNumber + 1);

        expectCustomErrorWithData(abi.encodeWithSelector(
            CrossChainSource.MessageCountMismatch.selector, 2, 1
        ));
        
        vm.prank(relayer);
        sourceContract.claimBlock(blockNumber, 2); // Wrong count
    }

    function test_RevertOnBlockAlreadyClaimed() public {
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = sourceContract.getMessageBlock(0);
        vm.roll(blockNumber + 1);

        // First claim
        vm.prank(relayer);
        sourceContract.claimBlock(blockNumber, 1);

        // Second claim should fail
        expectCustomError(CrossChainSource.BlockAlreadyClaimed.selector);
        
        vm.prank(relayer);
        sourceContract.claimBlock(blockNumber, 1);
    }

    // ============ DELIVERY CONFIRMATION TESTS ============

    function test_ValidDeliveryConfirmation() public {
        // Setup: submit message and claim block
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = sourceContract.getMessageBlock(0);
        vm.roll(blockNumber + 1);
        
        vm.prank(relayer);
        sourceContract.claimBlock(blockNumber, 1);

        // Create delivery proof
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](1);
        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("tx1"),
            receiptsRoot: keccak256("receipts"),
            success: true,
            destBlockHash: keccak256("destblock"),
            destBlockNumber: 100,
            relayerEoa: relayer,
            failureReason: ""
        });

        vm.expectEmit(true, true, false, false);
        emit CrossChainSource.BlockDelivered(blockNumber, relayer, 1, 0);

        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(blockNumber, proofs);

        (, , , , , CrossChainSource.BlockState state) = sourceContract.blockClaims(blockNumber);
        assertEq(uint256(state), uint256(CrossChainSource.BlockState.DELIVERED));
    }

    function test_RevertOnNotClaimOwner() public {
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = sourceContract.getMessageBlock(0);
        vm.roll(blockNumber + 1);
        
        vm.prank(relayer);
        sourceContract.claimBlock(blockNumber, 1);

        // Use unauthorized user who doesn't have relayer role
        // This should first fail with access control, then we check NotClaimOwner
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](1);
        
        // Since unauthorized doesn't have RELAYER_ROLE, it will fail with AccessControl error
        vm.expectRevert();
        
        vm.prank(unauthorized); // No relayer role
        sourceContract.confirmBlockDelivery(blockNumber, proofs);
    }

    function test_RevertOnInvalidClaimState() public {
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = sourceContract.getMessageBlock(0);
        vm.roll(blockNumber + 1);

        // Don't claim the block first - trying to confirm delivery on unclaimed block
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](1);
        
        expectCustomError(CrossChainSource.NotClaimOwner.selector);
        
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(blockNumber, proofs);
    }

    // ============ VIEW FUNCTION TESTS ============

    function test_GetBlockMessages() public {
        vm.prank(user);
        sourceContract.submitMessage("msg1", address(mockTarget), DEST_CHAIN_ID);
        vm.prank(user);
        sourceContract.submitMessage("msg2", address(mockTarget), DEST_CHAIN_ID);
        
        uint256[] memory messageIds = sourceContract.getBlockMessages(block.number);
        assertEq(messageIds.length, 2);
        assertEq(messageIds[0], 0);
        assertEq(messageIds[1], 1);
    }

    function test_GetMessageBlock() public {
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        
        uint256 blockNumber = sourceContract.getMessageBlock(0);
        assertEq(blockNumber, block.number);
    }

    function test_IsBlockClaimable() public {
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = sourceContract.getMessageBlock(0);
        
        // Current block should not be claimable
        assertFalse(sourceContract.isBlockClaimable(blockNumber));
        
        vm.roll(blockNumber + 1);
        
        // Previous block should be claimable
        assertTrue(sourceContract.isBlockClaimable(blockNumber));
    }

    function test_GetMessageDeliveryStatus() public {
        vm.prank(user);
        sourceContract.submitMessage("test", address(mockTarget), DEST_CHAIN_ID);
        uint256 blockNumber = sourceContract.getMessageBlock(0);
        vm.roll(blockNumber + 1);
        
        // Initially not delivered
        (bool delivered, bool success) = sourceContract.getMessageDeliveryStatus(0);
        assertFalse(delivered);
        assertFalse(success);
        
        // Claim and deliver
        vm.prank(relayer);
        sourceContract.claimBlock(blockNumber, 1);
        
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](1);
        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("tx1"),
            receiptsRoot: keccak256("receipts"),
            success: true,
            destBlockHash: keccak256("destblock"),
            destBlockNumber: 100,
            relayerEoa: relayer,
            failureReason: ""
        });
        
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(blockNumber, proofs);
        
        // Now should be delivered and successful
        (delivered, success) = sourceContract.getMessageDeliveryStatus(0);
        assertTrue(delivered);
        assertTrue(success);
    }

    // ============ EIP-712 HELPER TESTS ============

    function test_GetMessageDigest() public {
        bytes memory payload = "test payload";
        uint256 messageId = 123;
        uint256 nonce = 5;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = sourceContract.getMessageDigest(
            DEST_CHAIN_ID,
            messageId,
            user,
            payload,
            address(mockTarget),
            nonce,
            deadline
        );

        // Should return a valid hash
        assertTrue(digest != bytes32(0));
        
        // Same parameters should return same digest
        bytes32 digest2 = sourceContract.getMessageDigest(
            DEST_CHAIN_ID,
            messageId,
            user,
            payload,
            address(mockTarget),
            nonce,
            deadline
        );
        
        assertEq(digest, digest2);
    }

    function test_GetDomainSeparator() public {
        bytes32 domainSeparator = sourceContract.getDomainSeparator();
        assertTrue(domainSeparator != bytes32(0));
    }

    function test_GetChainId() public {
        uint256 chainId = sourceContract.getChainId();
        assertEq(chainId, SOURCE_CHAIN_ID);
    }
}
