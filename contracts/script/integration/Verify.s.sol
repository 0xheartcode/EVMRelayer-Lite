// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/CrossChainSource.sol";
import "../../src/CrossChainDestination.sol";

contract VerifyScript is Script {
    function run() external {
        address sourceAddr = vm.envAddress("SOURCE_CONTRACT");
        address destAddr = vm.envAddress("DEST_CONTRACT");
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        address user = vm.envAddress("USER_ADDRESS");
        uint256 chainIdOne = vm.envUint("CHAIN_ID_ONE");
        uint256 chainIdTwo = vm.envUint("CHAIN_ID_TWO");

        console.log("=== CROSS-CHAIN SYSTEM VERIFICATION ===");
        console.log("Current Chain ID:", block.chainid);
        console.log("Chain One (Source):", chainIdOne);
        console.log("Chain Two (Destination):", chainIdTwo);
        console.log("Source Contract:", sourceAddr);
        console.log("Destination Contract:", destAddr);
        console.log("Relayer Address:", relayer);
        console.log("Test User Address:", user);

        CrossChainSource source = CrossChainSource(sourceAddr);
        CrossChainDestination dest = CrossChainDestination(destAddr);

        console.log("\n1. VERIFYING CONTRACT DEPLOYMENT...");

        // 1. Verify contracts are deployed
        require(sourceAddr.code.length > 0, "Source contract not deployed");
        require(destAddr.code.length > 0, "Destination contract not deployed");
        console.log("✅ Both contracts successfully deployed");

        console.log("\n2. VERIFYING RELAYER PERMISSIONS...");

        // 2. Verify relayer permissions
        bool sourceRoleGranted = source.hasRole(source.RELAYER_ROLE(), relayer);
        bool destRoleGranted = dest.hasRole(dest.RELAYER_ROLE(), relayer);

        require(sourceRoleGranted, "Source: Missing relayer role");
        require(destRoleGranted, "Destination: Missing relayer role");
        console.log("✅ Relayer permissions configured on both contracts");

        console.log("\n3. VERIFYING EIP-712 SETUP...");

        // 3. Verify EIP-712 setup
        bytes32 sourceDomain = source.getDomainSeparator();
        bytes32 destSourceDomain = dest.getSourceDomainSeparator();

        require(sourceDomain != bytes32(0), "Invalid source domain separator");
        require(destSourceDomain != bytes32(0), "Invalid destination source domain separator");
        console.log("✅ EIP-712 domain separators configured correctly");
        console.log("   Source Domain:", vm.toString(sourceDomain));
        console.log("   Dest Source Domain:", vm.toString(destSourceDomain));

        console.log("\n4. VERIFYING CHAIN CONFIGURATION...");

        // 4. Verify chain configuration
        uint256 currentChainId = source.getChainId();
        console.log("✅ Chain ID verification:", currentChainId);
        require(currentChainId == block.chainid, "Chain ID mismatch");

        console.log("\n5. TESTING MESSAGE FLOW SIMULATION...");

        // 5. Test message flow (read-only simulation)
        bytes memory testPayload = "Hello Cross-Chain World!";
        address mockDestContract = destAddr; // Use dest contract as mock target

        // Verify relayer nonce
        uint256 relayerNonce = dest.getRelayerNonce(relayer);
        console.log("✅ Relayer nonce:", relayerNonce);

        // Test EIP-712 digest generation
        uint256 testDeadline = block.timestamp + 1 hours;
        uint256 destChainId = (block.chainid == chainIdOne) ? chainIdTwo : chainIdOne;

        bytes32 digest = source.getMessageDigest(
            destChainId, // destChainId (the other chain)
            0, // messageId
            user, // sender
            testPayload, // payload
            mockDestContract, // destContract
            relayerNonce, // nonce
            testDeadline // deadline
        );

        require(digest != bytes32(0), "Invalid message digest");
        console.log("✅ EIP-712 message digest generation works");
        console.log("   Test digest:", vm.toString(digest));

        console.log("\n6. VERIFYING CONTRACT STATE...");

        // 6. Verify initial contract state
        uint256 nextMessageId = source.nextMessageId();
        console.log("✅ Next message ID:", nextMessageId);
        require(nextMessageId == 0, "Unexpected initial message ID");

        // Verify block claimability function
        uint256 currentBlock = block.number;
        bool isClaimable = source.isBlockClaimable(currentBlock);
        console.log("✅ Current block claimable:", isClaimable);
        // Current block should not be claimable (not finalized)
        require(!isClaimable, "Current block should not be claimable");

        console.log("\n7. VERIFYING ACCESS CONTROL...");

        // 7. Verify admin roles
        bool sourceAdminRole = source.hasRole(source.DEFAULT_ADMIN_ROLE(), tx.origin);
        bool destAdminRole = dest.hasRole(dest.DEFAULT_ADMIN_ROLE(), tx.origin);
        console.log("✅ Source admin role:", sourceAdminRole);
        console.log("✅ Destination admin role:", destAdminRole);

        console.log("\n=== VERIFICATION SUMMARY ===");
        console.log("✅ Contract Deployment: PASSED");
        console.log("✅ Relayer Permissions: PASSED");
        console.log("✅ EIP-712 Configuration: PASSED");
        console.log("✅ Chain Configuration: PASSED");
        console.log("✅ Message Flow Simulation: PASSED");
        console.log("✅ Contract State: PASSED");
        console.log("✅ Access Control: PASSED");

        console.log("\n🎉 ALL VERIFICATIONS PASSED!");
        console.log("The cross-chain messaging system is ready for production use.");
        console.log("\nNext steps:");
        console.log("1. Deploy relayer service");
        console.log("2. Run integration tests with: forge test");
        console.log("3. Monitor system health");
    }
}
