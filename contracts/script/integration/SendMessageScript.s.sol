// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import "../../src/CrossChainSource.sol";

contract SendMessageScript is Script {
    function run() external {
        uint256 userPrivateKey = vm.envUint("USER_PRIVATE_KEY");
        address sourceAddr = vm.envAddress("SOURCE_CONTRACT");
        address destContract = vm.envAddress("DEST_CONTRACT");
        uint256 destChainId = vm.envUint("CHAIN_ID_TWO");

        console.log("=== SENDING CROSS-CHAIN MESSAGE ===");
        console.log("Source Contract:", sourceAddr);
        console.log("Destination Contract:", destContract);
        console.log("Destination Chain ID:", destChainId);

        vm.startBroadcast(userPrivateKey);

        CrossChainSource source = CrossChainSource(sourceAddr);

        // Try to get custom message from environment, fallback to default
        string memory messageText;
        try vm.envString("MESSAGE") returns (string memory customMessage) {
            messageText = customMessage;
        } catch {
            messageText = "Hello Cross-Chain!";
        }

        console.log("Message text:", messageText);

        bytes memory payload = abi.encodeWithSignature("receiveMessage(string)", messageText);

        uint256 messageIdBefore = source.nextMessageId();
        source.submitMessage(payload, destContract, destChainId);
        uint256 messageId = messageIdBefore;

        console.log("Message submitted successfully!");
        console.log("Message ID:", messageId);
        console.log("Block number:", block.number);

        // Get message details for verification
        (
            uint256 id,
            address sender,
            bytes memory storedPayload,
            address storedDestContract,
            uint256 storedDestChainId,
            uint256 timestamp,
            uint256 blockNumber,
            uint256 indexInBlock
        ) = source.messages(messageId);

        console.log("\n=== MESSAGE DETAILS ===");
        console.log("Sender:", sender);
        console.log("Timestamp:", timestamp);
        console.log("Block Number:", blockNumber);
        console.log("Index in Block:", indexInBlock);

        vm.stopBroadcast();

        console.log("\nNext steps:");
        console.log("1. Wait for block finalization");
        console.log("2. Relayer can claim block:", blockNumber);
        console.log("3. Execute message on destination chain");
    }
}
