// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./utils/TestHelpers.sol";

contract CrossChainDestinationTest is TestHelpers {
    function setUp() public {
        setupContracts();
        vm.chainId(DEST_CHAIN_ID);
    }

    // ============ ACCEPTANCE PATHS ============

    function test_ValidSignatureExecution() public {
        uint256 messageId = 1;
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Hello World"));
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            createValidSignature(messageId, user, payload, address(mockTarget), nonce, deadline);

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID,
            100, // sourceBlockNumber
            messageId,
            user,
            payload,
            address(mockTarget),
            nonce,
            deadline,
            v,
            r,
            s
        );

        assertEq(mockTarget.getLastMessage(), "Hello World");
        assertEq(mockTarget.getCounter(), 1);
        assertEq(destContract.getRelayerNonce(relayer), 1);
    }

    function test_AuthorizedRelayerSignature() public {
        // Grant relayer role to a new address
        address newRelayer = vm.addr(0x5);

        // Ensure we're on destination chain and admin has the right role
        vm.chainId(DEST_CHAIN_ID);
        assertTrue(destContract.hasRole(destContract.DEFAULT_ADMIN_ROLE(), admin));

        // Use startPrank/stopPrank for better context control
        vm.startPrank(admin);
        destContract.grantRole(destContract.RELAYER_ROLE(), newRelayer);
        vm.stopPrank();

        uint256 messageId = 2;
        bytes memory payload = abi.encodeCall(MockTarget.receiveValue, (42));
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 domainSeparator =
            sigUtils.computeDomainSeparator("CrossChainMessenger", "1", SOURCE_CHAIN_ID, address(sourceContract));

        (uint8 v, bytes32 r, bytes32 s) = sigUtils.signMessage(
            0x5, // New relayer's private key
            domainSeparator,
            SOURCE_CHAIN_ID,
            DEST_CHAIN_ID,
            messageId,
            user,
            payload,
            address(mockTarget),
            nonce,
            deadline
        );

        vm.prank(newRelayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 101, messageId, user, payload, address(mockTarget), nonce, deadline, v, r, s
        );

        assertEq(mockTarget.getCounter(), 42);
    }

    function test_CorrectNonceUsage() public {
        uint256 messageId1 = 10;
        uint256 messageId2 = 11;
        bytes memory payload1 = abi.encodeCall(MockTarget.receiveValue, (10));
        bytes memory payload2 = abi.encodeCall(MockTarget.receiveValue, (20));
        uint256 deadline = block.timestamp + 1 hours;

        // First message with nonce 0
        (uint8 v1, bytes32 r1, bytes32 s1) = createValidSignature(
            messageId1,
            user,
            payload1,
            address(mockTarget),
            0, // nonce 0
            deadline
        );

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 200, messageId1, user, payload1, address(mockTarget), 0, deadline, v1, r1, s1
        );

        // Second message with nonce 1
        (uint8 v2, bytes32 r2, bytes32 s2) = createValidSignature(
            messageId2,
            user,
            payload2,
            address(mockTarget),
            1, // nonce 1
            deadline
        );

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 201, messageId2, user, payload2, address(mockTarget), 1, deadline, v2, r2, s2
        );

        assertEq(destContract.getRelayerNonce(relayer), 2);
        assertEq(mockTarget.getCounter(), 30); // 10 + 20
    }

    // ============ REJECTION PATHS ============

    function test_RevertOnExpiredSignature() public {
        uint256 messageId = 100;
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Test"));
        uint256 nonce = 0;
        uint256 deadline = block.timestamp - 1; // Expired deadline

        (uint8 v, bytes32 r, bytes32 s) =
            createValidSignature(messageId, user, payload, address(mockTarget), nonce, deadline);

        expectCustomError(CrossChainDestination.SignatureExpired.selector);

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 300, messageId, user, payload, address(mockTarget), nonce, deadline, v, r, s
        );
    }

    function test_RevertOnInvalidNonce() public {
        uint256 messageId = 200;
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Test"));
        uint256 deadline = block.timestamp + 1 hours;

        // Use wrong nonce (should be 0, using 5)
        (uint8 v, bytes32 r, bytes32 s) =
            createValidSignature(messageId, user, payload, address(mockTarget), 5, deadline);

        expectCustomErrorWithData(abi.encodeWithSelector(CrossChainDestination.InvalidNonce.selector, 0, 5));

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 400, messageId, user, payload, address(mockTarget), 5, deadline, v, r, s
        );
    }

    function test_RevertOnUnauthorizedRelayer() public {
        uint256 messageId = 300;
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Test"));
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            createUnauthorizedSignature(messageId, user, payload, address(mockTarget), nonce, deadline);

        expectCustomError(CrossChainDestination.UnauthorizedRelayer.selector);

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 500, messageId, user, payload, address(mockTarget), nonce, deadline, v, r, s
        );
    }

    function test_RevertOnInvalidSignature() public {
        uint256 messageId = 400;
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Test"));
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = sigUtils.createInvalidSignature();

        // Invalid signature that recovers to unauthorized address should revert with UnauthorizedRelayer
        expectCustomError(CrossChainDestination.UnauthorizedRelayer.selector);

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 600, messageId, user, payload, address(mockTarget), nonce, deadline, v, r, s
        );
    }

    function test_RevertOnMalformedSignature() public {
        uint256 messageId = 500;
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Test"));
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = sigUtils.createMalformedSignature();

        expectCustomError(CrossChainDestination.InvalidSignature.selector);

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 700, messageId, user, payload, address(mockTarget), nonce, deadline, v, r, s
        );
    }

    function test_RevertOnReplayAttack() public {
        uint256 messageId = 600;
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Test"));
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            createValidSignature(messageId, user, payload, address(mockTarget), nonce, deadline);

        // Execute once successfully
        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 800, messageId, user, payload, address(mockTarget), nonce, deadline, v, r, s
        );

        // Try to replay the same message - should fail on message hash, not nonce
        // Create a new signature with incremented nonce but same message details
        (uint8 v2, bytes32 r2, bytes32 s2) =
            createValidSignature(messageId, user, payload, address(mockTarget), 1, deadline);

        expectCustomError(CrossChainDestination.MessageAlreadyProcessed.selector);

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 800, messageId, user, payload, address(mockTarget), 1, deadline, v2, r2, s2
        );
    }

    // ============ MESSAGE EXECUTION TESTS ============

    function test_SuccessfulMessageExecution() public {
        uint256 messageId = 700;
        bytes memory payload = abi.encodeCall(MockTarget.receiveMessage, ("Success"));
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            createValidSignature(messageId, user, payload, address(mockTarget), nonce, deadline);

        vm.expectEmit(true, true, true, true);
        emit CrossChainDestination.MessageExecuted(
            SOURCE_CHAIN_ID,
            messageId,
            address(mockTarget),
            destContract.calculateMessageHash(SOURCE_CHAIN_ID, 900, messageId, user, payload, address(mockTarget)),
            true,
            ""
        );

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 900, messageId, user, payload, address(mockTarget), nonce, deadline, v, r, s
        );
    }

    function test_FailedMessageExecution() public {
        // Set up mock to revert
        mockTarget.setShouldRevert(true, "Mock revert");

        uint256 messageId = 800;
        bytes memory payload = abi.encodeCall(MockTarget.revertingFunction, ());
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            createValidSignature(messageId, user, payload, address(mockTarget), nonce, deadline);

        vm.expectEmit(true, true, true, true);
        emit CrossChainDestination.MessageFailed(
            SOURCE_CHAIN_ID,
            messageId,
            address(mockTarget),
            destContract.calculateMessageHash(SOURCE_CHAIN_ID, 1000, messageId, user, payload, address(mockTarget)),
            "Mock revert"
        );

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 1000, messageId, user, payload, address(mockTarget), nonce, deadline, v, r, s
        );

        // Message should still be marked as processed even if execution failed
        bytes32 messageHash =
            destContract.calculateMessageHash(SOURCE_CHAIN_ID, 1000, messageId, user, payload, address(mockTarget));
        assertTrue(destContract.isMessageProcessed(messageHash));
    }

    // ============ EDGE CASES ============

    function test_NonceIncrementAfterExecution() public {
        uint256 initialNonce = destContract.getRelayerNonce(relayer);

        uint256 messageId = 900;
        bytes memory payload = abi.encodeCall(MockTarget.emptyFunction, ());
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) =
            createValidSignature(messageId, user, payload, address(mockTarget), initialNonce, deadline);

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 1100, messageId, user, payload, address(mockTarget), initialNonce, deadline, v, r, s
        );

        assertEq(destContract.getRelayerNonce(relayer), initialNonce + 1);
    }

    function test_DifferentRelayerNonces() public {
        address relayer2 = vm.addr(0x6);

        vm.chainId(DEST_CHAIN_ID);
        vm.startPrank(admin);
        destContract.grantRole(destContract.RELAYER_ROLE(), relayer2);
        vm.stopPrank();

        assertEq(destContract.getRelayerNonce(relayer), 0);
        assertEq(destContract.getRelayerNonce(relayer2), 0);

        // Execute with first relayer
        uint256 messageId1 = 1000;
        bytes memory payload1 = abi.encodeCall(MockTarget.receiveValue, (100));
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v1, bytes32 r1, bytes32 s1) =
            createValidSignature(messageId1, user, payload1, address(mockTarget), 0, deadline);

        vm.prank(relayer);
        destContract.executeMessage(
            SOURCE_CHAIN_ID, 1200, messageId1, user, payload1, address(mockTarget), 0, deadline, v1, r1, s1
        );

        // First relayer nonce should increment, second should remain 0
        assertEq(destContract.getRelayerNonce(relayer), 1);
        assertEq(destContract.getRelayerNonce(relayer2), 0);
    }
}
