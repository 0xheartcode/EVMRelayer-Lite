// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/CrossChainSource.sol";
import "../../src/CrossChainDestination.sol";

contract ConfigureScript is Script {
    function run() external {
        address sourceAddr = vm.envAddress("SOURCE_CONTRACT");
        address destAddr = vm.envAddress("DEST_CONTRACT");
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        
        console.log("=== CONFIGURING CONTRACTS ===");
        console.log("Source Contract:", sourceAddr);
        console.log("Destination Contract:", destAddr);
        console.log("Relayer Address:", relayer);
        
        vm.startBroadcast();
        
        CrossChainSource source = CrossChainSource(sourceAddr);
        CrossChainDestination dest = CrossChainDestination(destAddr);
        
        // Grant relayer roles
        console.log("\nGranting RELAYER_ROLE...");
        source.grantRole(source.RELAYER_ROLE(), relayer);
        console.log("✅ Source contract: RELAYER_ROLE granted");
        
        dest.grantRole(dest.RELAYER_ROLE(), relayer);
        console.log("✅ Destination contract: RELAYER_ROLE granted");
        
        vm.stopBroadcast();
        
        // Verify roles were granted
        console.log("\n=== VERIFICATION ===");
        bool sourceRoleGranted = source.hasRole(source.RELAYER_ROLE(), relayer);
        bool destRoleGranted = dest.hasRole(dest.RELAYER_ROLE(), relayer);
        
        console.log("Source relayer role granted:", sourceRoleGranted);
        console.log("Destination relayer role granted:", destRoleGranted);
        
        if (sourceRoleGranted && destRoleGranted) {
            console.log("\n🎉 CONFIGURATION COMPLETE!");
            console.log("All relayer permissions configured successfully.");
        } else {
            console.log("\n❌ CONFIGURATION FAILED!");
            console.log("Some permissions were not granted correctly.");
        }
    }
}