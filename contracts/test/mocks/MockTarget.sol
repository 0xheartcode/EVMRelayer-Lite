// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract MockTarget {
    event MessageReceived(address sender, bytes data);
    event ValueReceived(uint256 value);

    uint256 public counter;
    string public lastMessage;
    bool public shouldRevert;
    string public revertMessage;

    function receiveMessage(string memory message) external {
        lastMessage = message;
        counter++;
        emit MessageReceived(msg.sender, abi.encode(message));
    }

    function receiveValue(uint256 value) external {
        counter += value;
        emit ValueReceived(value);
    }

    function setShouldRevert(bool _shouldRevert, string memory _revertMessage) external {
        shouldRevert = _shouldRevert;
        revertMessage = _revertMessage;
    }

    function revertingFunction() external view {
        if (shouldRevert) {
            revert(revertMessage);
        }
    }

    function emptyFunction() external pure {
        // Does nothing - for testing successful calls with no data
    }

    function getLastMessage() external view returns (string memory) {
        return lastMessage;
    }

    function getCounter() external view returns (uint256) {
        return counter;
    }
}
