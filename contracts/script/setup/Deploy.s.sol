// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/CrossChainSource.sol";
import "../../src/CrossChainDestination.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 chainIdOne = vm.envUint("CHAIN_ID_ONE");
        uint256 chainIdTwo = vm.envUint("CHAIN_ID_TWO");

        vm.startBroadcast(deployerPrivateKey);

        if (block.chainid == chainIdOne) {
            // Deploy on Chain One (Source)
            console.log("=== DEPLOYING ON CHAIN ONE (SOURCE) ===");
            console.log("Chain ID:", block.chainid);

            CrossChainSource source = new CrossChainSource();
            console.log("CrossChainSource deployed at:", address(source));
            console.log("Domain Separator:", vm.toString(source.getDomainSeparator()));

            console.log("\nAdd to your .env file:");
            console.log("SOURCE_CONTRACT=", address(source));
        } else if (block.chainid == chainIdTwo) {
            // Deploy on Chain Two (Destination)
            console.log("=== DEPLOYING ON CHAIN TWO (DESTINATION) ===");
            console.log("Chain ID:", block.chainid);

            address sourceContract = vm.envAddress("SOURCE_CONTRACT");
            require(sourceContract != address(0), "SOURCE_CONTRACT must be set for destination deployment");

            CrossChainDestination dest = new CrossChainDestination(
                chainIdOne, // sourceChainId
                sourceContract // sourceContract address from chain one
            );
            console.log("CrossChainDestination deployed at:", address(dest));
            console.log("Source Chain ID:", chainIdOne);
            console.log("Source Contract:", sourceContract);
            console.log("Source Domain Separator:", vm.toString(dest.getSourceDomainSeparator()));

            console.log("\nAdd to your .env file:");
            console.log("DEST_CONTRACT=", address(dest));
        } else {
            revert("Unsupported chain ID. Must be CHAIN_ID_ONE or CHAIN_ID_TWO");
        }

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
    }
}
