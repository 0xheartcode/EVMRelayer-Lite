// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "../../src/CrossChainSource.sol";
import "../../src/CrossChainDestination.sol";
import "./SignatureUtils.sol";
import "../mocks/MockTarget.sol";

contract TestHelpers is Test {
    // Test accounts
    uint256 constant ADMIN_PRIVATE_KEY = 0x1;
    uint256 constant RELAYER_PRIVATE_KEY = 0x2;
    uint256 constant UNAUTHORIZED_PRIVATE_KEY = 0x3;
    uint256 constant USER_PRIVATE_KEY = 0x4;

    address admin = vm.addr(ADMIN_PRIVATE_KEY);
    address relayer = vm.addr(RELAYER_PRIVATE_KEY);
    address unauthorized = vm.addr(UNAUTHORIZED_PRIVATE_KEY);
    address user = vm.addr(USER_PRIVATE_KEY);

    // Test constants
    uint256 constant SOURCE_CHAIN_ID = 1;
    uint256 constant DEST_CHAIN_ID = 2;
    
    CrossChainSource sourceContract;
    CrossChainDestination destContract;
    MockTarget mockTarget;
    SignatureUtils sigUtils;

    function setupContracts() internal {
        // Deploy mock target
        mockTarget = new MockTarget();
        
        // Deploy signature utils
        sigUtils = new SignatureUtils();

        // Deploy source contract on source chain
        vm.chainId(SOURCE_CHAIN_ID);
        vm.startPrank(admin);
        sourceContract = new CrossChainSource();
        sourceContract.grantRole(sourceContract.RELAYER_ROLE(), relayer);
        vm.stopPrank();

        // Deploy destination contract on destination chain  
        vm.chainId(DEST_CHAIN_ID);
        vm.startPrank(admin);
        destContract = new CrossChainDestination(SOURCE_CHAIN_ID, address(sourceContract));
        destContract.grantRole(destContract.RELAYER_ROLE(), relayer);
        vm.stopPrank();
    }

    function createValidSignature(
        uint256 messageId,
        address sender,
        bytes memory payload,
        address destContract_,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = sigUtils.computeDomainSeparator(
            "CrossChainMessenger",
            "1",
            SOURCE_CHAIN_ID,
            address(sourceContract)
        );

        return sigUtils.signMessage(
            RELAYER_PRIVATE_KEY,
            domainSeparator,
            SOURCE_CHAIN_ID,
            DEST_CHAIN_ID,
            messageId,
            sender,
            payload,
            destContract_,
            nonce,
            deadline
        );
    }

    function createUnauthorizedSignature(
        uint256 messageId,
        address sender,
        bytes memory payload,
        address destContract_,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = sigUtils.computeDomainSeparator(
            "CrossChainMessenger",
            "1",
            SOURCE_CHAIN_ID,
            address(sourceContract)
        );

        return sigUtils.signMessage(
            UNAUTHORIZED_PRIVATE_KEY, // Wrong private key
            domainSeparator,
            SOURCE_CHAIN_ID,
            DEST_CHAIN_ID,
            messageId,
            sender,
            payload,
            destContract_,
            nonce,
            deadline
        );
    }

    function expectCustomError(bytes4 selector) internal {
        vm.expectRevert(selector);
    }

    function expectCustomErrorWithData(bytes memory errorData) internal {
        vm.expectRevert(errorData);
    }
}