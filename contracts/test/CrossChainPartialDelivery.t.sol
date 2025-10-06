// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./utils/TestHelpers.sol";

contract CrossChainPartialDeliveryTest is TestHelpers {
    function setUp() public {
        setupContracts();
    }

    function test_PartialBlockDelivery() public {
        // Setup: Submit 3 messages in the same block
        vm.chainId(SOURCE_CHAIN_ID);

        bytes memory payload1 = abi.encodeCall(MockTarget.receiveMessage, ("Message 1"));
        bytes memory payload2 = abi.encodeCall(MockTarget.receiveMessage, ("Message 2"));
        bytes memory payload3 = abi.encodeCall(MockTarget.receiveMessage, ("Message 3"));

        vm.prank(user);
        sourceContract.submitMessage(payload1, address(mockTarget), DEST_CHAIN_ID);

        vm.prank(user);
        sourceContract.submitMessage(payload2, address(mockTarget), DEST_CHAIN_ID);

        vm.prank(user);
        sourceContract.submitMessage(payload3, address(mockTarget), DEST_CHAIN_ID);

        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);

        // Move to next block for finality
        vm.roll(sourceBlockNumber + 1);

        // Relayer claims the block
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 3);

        // Verify block is claimed
        (,,,,, CrossChainSource.BlockState state) = sourceContract.blockClaims(sourceBlockNumber);
        assertEq(uint256(state), 1); // CLAIMED

        // Switch to destination chain
        vm.chainId(DEST_CHAIN_ID);

        // Execute messages with mixed results: success, failure, success
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](3);

        // Message 1: Success
        bytes32 txHash1 = keccak256("success_tx_1");
        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: txHash1,
            receiptsRoot: keccak256("receipts_1"),
            success: true,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: ""
        });

        // Message 2: Failure
        bytes32 txHash2 = keccak256("failed_tx_2");
        proofs[1] = CrossChainSource.DeliveryProof({
            destTxHash: txHash2,
            receiptsRoot: keccak256("receipts_2"),
            success: false,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: "Contract execution failed"
        });

        // Message 3: Success
        bytes32 txHash3 = keccak256("success_tx_3");
        proofs[2] = CrossChainSource.DeliveryProof({
            destTxHash: txHash3,
            receiptsRoot: keccak256("receipts_3"),
            success: true,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: ""
        });

        // Switch back to source chain to submit proofs
        vm.chainId(SOURCE_CHAIN_ID);

        // Submit delivery proofs
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(sourceBlockNumber, proofs);

        // Verify block state is PARTIALLY_DELIVERED
        (,,,,, state) = sourceContract.blockClaims(sourceBlockNumber);
        assertEq(uint256(state), 3); // PARTIALLY_DELIVERED

        // Verify individual message delivery status
        assertTrue(sourceContract.isMessageDelivered(0)); // Message 1: success
        assertFalse(sourceContract.isMessageDelivered(1)); // Message 2: failed
        assertTrue(sourceContract.isMessageDelivered(2)); // Message 3: success

        // Test enhanced view functions
        (CrossChainSource.BlockState blockState, uint256 successCount, uint256 failureCount, uint256 totalMessages) =
            sourceContract.getBlockDeliveryStatus(sourceBlockNumber);

        assertEq(uint256(blockState), 3); // PARTIALLY_DELIVERED
        assertEq(successCount, 2);
        assertEq(failureCount, 1);
        assertEq(totalMessages, 3);

        // Test failed messages query
        uint256[] memory failedMessages = sourceContract.getFailedMessagesForBlock(sourceBlockNumber);
        assertEq(failedMessages.length, 1);
        assertEq(failedMessages[0], 1); // Message ID 1 failed
    }

    function test_AllSuccessfulDelivery() public {
        // Setup: Submit 2 messages
        vm.chainId(SOURCE_CHAIN_ID);

        bytes memory payload1 = abi.encodeCall(MockTarget.receiveMessage, ("Success 1"));
        bytes memory payload2 = abi.encodeCall(MockTarget.receiveMessage, ("Success 2"));

        vm.prank(user);
        sourceContract.submitMessage(payload1, address(mockTarget), DEST_CHAIN_ID);

        vm.prank(user);
        sourceContract.submitMessage(payload2, address(mockTarget), DEST_CHAIN_ID);

        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);
        vm.roll(sourceBlockNumber + 1);

        // Claim block
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 2);

        // Create all successful proofs
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](2);

        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("success_tx_1"),
            receiptsRoot: keccak256("receipts_1"),
            success: true,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: ""
        });

        proofs[1] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("success_tx_2"),
            receiptsRoot: keccak256("receipts_2"),
            success: true,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: ""
        });

        // Submit proofs
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(sourceBlockNumber, proofs);

        // Verify state is DELIVERED (not PARTIALLY_DELIVERED)
        (,,,,, CrossChainSource.BlockState state) = sourceContract.blockClaims(sourceBlockNumber);
        assertEq(uint256(state), 2); // DELIVERED

        // Verify all messages delivered successfully
        assertTrue(sourceContract.isMessageDelivered(0));
        assertTrue(sourceContract.isMessageDelivered(1));

        // Test delivery status
        (CrossChainSource.BlockState blockState, uint256 successCount, uint256 failureCount, uint256 totalMessages) =
            sourceContract.getBlockDeliveryStatus(sourceBlockNumber);

        assertEq(uint256(blockState), 2); // DELIVERED
        assertEq(successCount, 2);
        assertEq(failureCount, 0);
        assertEq(totalMessages, 2);
    }

    function test_AllFailedDelivery() public {
        // Setup: Submit 2 messages
        vm.chainId(SOURCE_CHAIN_ID);

        bytes memory payload1 = abi.encodeCall(MockTarget.receiveMessage, ("Fail 1"));
        bytes memory payload2 = abi.encodeCall(MockTarget.receiveMessage, ("Fail 2"));

        vm.prank(user);
        sourceContract.submitMessage(payload1, address(mockTarget), DEST_CHAIN_ID);

        vm.prank(user);
        sourceContract.submitMessage(payload2, address(mockTarget), DEST_CHAIN_ID);

        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);
        vm.roll(sourceBlockNumber + 1);

        // Claim block
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 2);

        // Create all failed proofs
        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](2);

        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("failed_tx_1"),
            receiptsRoot: keccak256("receipts_1"),
            success: false,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: "Network timeout"
        });

        proofs[1] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("failed_tx_2"),
            receiptsRoot: keccak256("receipts_2"),
            success: false,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: "Gas estimation failed"
        });

        // Submit proofs
        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(sourceBlockNumber, proofs);

        // Verify state is FAILED
        (,,,,, CrossChainSource.BlockState state) = sourceContract.blockClaims(sourceBlockNumber);
        assertEq(uint256(state), 4); // FAILED

        // Verify no messages delivered successfully
        assertFalse(sourceContract.isMessageDelivered(0));
        assertFalse(sourceContract.isMessageDelivered(1));

        // Test delivery status
        (CrossChainSource.BlockState blockState, uint256 successCount, uint256 failureCount, uint256 totalMessages) =
            sourceContract.getBlockDeliveryStatus(sourceBlockNumber);

        assertEq(uint256(blockState), 4); // FAILED
        assertEq(successCount, 0);
        assertEq(failureCount, 2);
        assertEq(totalMessages, 2);

        // Test failed messages query
        uint256[] memory failedMessages = sourceContract.getFailedMessagesForBlock(sourceBlockNumber);
        assertEq(failedMessages.length, 2);
        assertEq(failedMessages[0], 0);
        assertEq(failedMessages[1], 1);
    }

    function test_PartialDeliveryStateTransitions() public {
        // Test that we can retry a partially delivered block
        vm.chainId(SOURCE_CHAIN_ID);

        // Submit one message
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Test message"));
        vm.prank(user);
        sourceContract.submitMessage(payload, address(mockTarget), DEST_CHAIN_ID);

        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);
        vm.roll(sourceBlockNumber + 1);

        // First relayer claims and fails
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 1);

        // Mark as failed
        vm.prank(relayer);
        sourceContract.markBlockFailed(sourceBlockNumber, "Network error");

        // Verify state is FAILED
        (,,,,, CrossChainSource.BlockState state) = sourceContract.blockClaims(sourceBlockNumber);
        assertEq(uint256(state), 4); // FAILED

        // Block should be claimable again
        assertTrue(sourceContract.isBlockClaimable(sourceBlockNumber));

        // Second relayer can claim the failed block
        vm.startPrank(admin);
        sourceContract.grantRole(sourceContract.RELAYER_ROLE(), address(0x999));
        vm.stopPrank();

        vm.prank(address(0x999));
        sourceContract.claimBlock(sourceBlockNumber, 1);

        // Verify state changed back to CLAIMED
        (,,,,, state) = sourceContract.blockClaims(sourceBlockNumber);
        assertEq(uint256(state), 1); // CLAIMED
    }

    function test_MessageDeliveryStatusViews() public {
        // Test the enhanced view functions
        vm.chainId(SOURCE_CHAIN_ID);

        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("View test"));
        vm.prank(user);
        sourceContract.submitMessage(payload, address(mockTarget), DEST_CHAIN_ID);

        uint256 sourceBlockNumber = sourceContract.getMessageBlock(0);
        vm.roll(sourceBlockNumber + 1);

        // Initially, message should not be delivered
        assertFalse(sourceContract.isMessageDelivered(0));

        (bool delivered, bool success) = sourceContract.getMessageDeliveryStatus(0);
        assertFalse(delivered);
        assertFalse(success);

        // Claim and deliver successfully
        vm.prank(relayer);
        sourceContract.claimBlock(sourceBlockNumber, 1);

        CrossChainSource.DeliveryProof[] memory proofs = new CrossChainSource.DeliveryProof[](1);
        proofs[0] = CrossChainSource.DeliveryProof({
            destTxHash: keccak256("success_tx"),
            receiptsRoot: keccak256("receipts"),
            success: true,
            destBlockHash: blockhash(block.number - 1),
            destBlockNumber: block.number,
            relayerEoa: relayer,
            failureReason: ""
        });

        vm.prank(relayer);
        sourceContract.confirmBlockDelivery(sourceBlockNumber, proofs);

        // Now message should be delivered and successful
        assertTrue(sourceContract.isMessageDelivered(0));

        (delivered, success) = sourceContract.getMessageDeliveryStatus(0);
        assertTrue(delivered);
        assertTrue(success);
    }
}
