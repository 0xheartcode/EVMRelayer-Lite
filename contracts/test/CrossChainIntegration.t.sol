// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./utils/TestHelpers.sol";

contract CrossChainIntegrationTest is TestHelpers {
    
    function setUp() public {
        setupContracts();
    }

    function test_EndToEndMessageFlow() public {
        // Step 1: User submits message on source chain
        vm.chainId(SOURCE_CHAIN_ID);
        
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Cross-chain Hello"));
        
        vm.prank(user);
        sourceContract.submitMessage(payload, address(mockTarget), DEST_CHAIN_ID);
        
        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);
        
        // Step 2: Block gets finalized (simulate by moving to next block)
        vm.roll(sourceBlockNumber + 1);
        
        // Step 3: Relayer claims the block
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 1);
        
        // Step 4: Switch to destination chain for execution
        vm.chainId(DEST_CHAIN_ID);
        vm.roll(100); // Set a specific block number on dest chain
        
        uint256 messageId = 0;
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        
        (uint8 v, bytes32 r, bytes32 s) = createValidSignature(
            messageId, user, payload, address(mockTarget), nonce, deadline
        );
        
        // Step 5: Relayer executes message on destination chain
        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, sourceBlockNumber, messageId, user, payload, address(mockTarget),
            nonce, deadline, v, r, s
        );
        
        // Step 6: Verify message was executed on target contract
        assertEq(mockTarget.getLastMessage(), "Cross-chain Hello");
        assertEq(mockTarget.getCounter(), 1);
        
        // Step 7: Relayer reports delivery back to source chain
        vm.chainId(SOURCE_CHAIN_ID);
        vm.roll(200); // Set block number back on source chain
        
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](1);
        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256(abi.encode("successful_tx")),
            receiptsRoot: keccak256(abi.encode("receipts")),
            success: true,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: ""
        });
        
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(sourceBlockNumber, proofs);
        
        // Step 8: Verify complete flow
        (bool delivered, bool success) = sourceContract.getMessageDeliveryStatus(messageId);
        assertTrue(delivered);
        assertTrue(success);
        
        bytes32 messageHash = destContract.calculateMessageHash(
            SOURCE_CHAIN_ID, sourceBlockNumber, messageId, user, payload, address(mockTarget)
        );
        assertTrue(destContract.isMessageProcessed(messageHash));
    }

    function test_MultipleMessagesInBlock() public {
        // Submit multiple messages in same block
        vm.chainId(SOURCE_CHAIN_ID);
        
        bytes memory payload1 = abi.encodeCall(MockTarget.receiveMessage, ("Message 1"));
        bytes memory payload2 = abi.encodeCall(MockTarget.receiveMessage, ("Message 2"));
        bytes memory payload3 = abi.encodeCall(MockTarget.receiveValue, (42));
        
        vm.prank(user);
        sourceContract.submitMessage(payload1, address(mockTarget), DEST_CHAIN_ID);
        vm.prank(user);
        sourceContract.submitMessage(payload2, address(mockTarget), DEST_CHAIN_ID);
        vm.prank(user);
        sourceContract.submitMessage(payload3, address(mockTarget), DEST_CHAIN_ID);
        
        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);
        vm.roll(sourceBlockNumber + 1);
        
        // Claim block
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 3);
        
        // Execute all messages on destination chain
        vm.chainId(DEST_CHAIN_ID);
        uint256 deadline = block.timestamp + 1 hours;
        
        // Execute message 1
        (uint8 v1, bytes32 r1, bytes32 s1) = createValidSignature(
            0, user, payload1, address(mockTarget), 0, deadline
        );
        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, sourceBlockNumber, 0, user, payload1, address(mockTarget),
            0, deadline, v1, r1, s1
        );
        
        // Execute message 2  
        (uint8 v2, bytes32 r2, bytes32 s2) = createValidSignature(
            1, user, payload2, address(mockTarget), 1, deadline
        );
        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, sourceBlockNumber, 1, user, payload2, address(mockTarget),
            1, deadline, v2, r2, s2
        );
        
        // Execute message 3
        (uint8 v3, bytes32 r3, bytes32 s3) = createValidSignature(
            2, user, payload3, address(mockTarget), 2, deadline
        );
        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, sourceBlockNumber, 2, user, payload3, address(mockTarget),
            2, deadline, v3, r3, s3
        );
        
        // Verify all executions
        assertEq(mockTarget.getLastMessage(), "Message 2"); // Last message wins
        assertEq(mockTarget.getCounter(), 44); // 1 + 1 + 42
        assertEq(destContract.getRelayerNonce(relayer), 3);
        
        // Report delivery
        vm.chainId(SOURCE_CHAIN_ID);
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](3);
        for (uint i = 0; i < 3; i++) {
            proofs[i] = CrossChainSource.DeliveryProof({
                destTxHash: keccak256(abi.encode("tx", i)),
                receiptsRoot: keccak256(abi.encode("receipts", i)),
                success: true,
                destBlockHash: blockhash(block.number - 1),
                destBlockNumber: block.number,
                relayerEoa: relayer,
                failureReason: ""
            });
        }
        
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(sourceBlockNumber, proofs);
        
        // Verify all messages delivered
        for (uint i = 0; i < 3; i++) {
            (bool delivered, bool success) = sourceContract.getMessageDeliveryStatus(i);
            assertTrue(delivered);
            assertTrue(success);
        }
    }

    function test_BlockFailureAndRetry() public {
        // Submit message
        vm.chainId(SOURCE_CHAIN_ID);
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Test"));
        
        vm.prank(user);
        sourceContract.submitMessage(payload, address(mockTarget), DEST_CHAIN_ID);
        
        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);
        vm.roll(sourceBlockNumber + 1);
        
        // Claim block
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 1);
        
        // Mark block as failed
        vm.expectEmit(true, true, false, false);
        emit CrossChainSource.BlockFailed(sourceBlockNumber, relayer, 0, "Network issue");
        
        vm.prank(relayer);
        sourceContract.markBlockFailed(sourceBlockNumber, "Network issue");
        
        // Verify block is in FAILED state
        (, , , , , CrossChainSource.BlockState state) = sourceContract.blockClaims(sourceBlockNumber);
        assertEq(uint256(state), uint256(CrossChainSource.BlockState.FAILED));
        
        // Block should be claimable again
        assertTrue(sourceContract.isBlockClaimable(sourceBlockNumber));
        
        // Retry by same relayer (simplified to avoid admin permission issues)
        vm.chainId(SOURCE_CHAIN_ID);
        
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 1);
        
        // Now successfully deliver
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](1);
        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("retry_tx"),
            receiptsRoot: keccak256("retry_receipts"),
            success: true,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: ""
        });
        
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(sourceBlockNumber, proofs);
        
        // Verify delivery
        (bool delivered, bool success) = sourceContract.getMessageDeliveryStatus(0);
        assertTrue(delivered);
        assertTrue(success);
    }

    function test_FailedMessageExecutionWithProof() public {
        // Setup mock to fail
        mockTarget.setShouldRevert(true, "Target contract error");
        
        vm.chainId(SOURCE_CHAIN_ID);
        bytes memory payload = abi.encodeCall(MockTarget.revertingFunction, ());
        
        vm.prank(user);
        sourceContract.submitMessage(payload, address(mockTarget), DEST_CHAIN_ID);
        
        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);
        vm.roll(sourceBlockNumber + 1);
        
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 1);
        
        // Execute on destination (will fail)
        vm.chainId(DEST_CHAIN_ID);
        
        (uint8 v, bytes32 r, bytes32 s) = createValidSignature(
            0, user, payload, address(mockTarget), 0, block.timestamp + 1 hours
        );
        
        vm.expectEmit(true, true, true, true);
        emit CrossChainDestination.MessageFailed(
            SOURCE_CHAIN_ID, 0, address(mockTarget),
            destContract.calculateMessageHash(SOURCE_CHAIN_ID, sourceBlockNumber, 0, user, payload, address(mockTarget)),
            "Target contract error"
        );
        
        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, sourceBlockNumber, 0, user, payload, address(mockTarget),
            0, block.timestamp + 1 hours, v, r, s
        );
        
        // Report failed delivery
        vm.chainId(SOURCE_CHAIN_ID);
        
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](1);
        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("failed_tx"),
            receiptsRoot: keccak256("failed_receipts"),
            success: false,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: "Target contract error"
        });
        
        vm.expectEmit(true, true, false, false);
        emit CrossChainSource.BlockDelivered(sourceBlockNumber, relayer, 0, 1); // 0 success, 1 failure
        
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(sourceBlockNumber, proofs);
        
        // Verify delivery status shows failure
        (bool delivered, bool success) = sourceContract.getMessageDeliveryStatus(0);
        assertTrue(delivered); // Delivered but failed
        assertFalse(success);
    }
}
