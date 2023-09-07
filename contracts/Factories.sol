// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract PresaleFactory is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    address[] private presales;
    EnumerableSet.AddressSet private presaleGenerators;
    mapping(address => EnumerableSet.AddressSet) private presaleOwners;

    event presaleRegistered(address presaleContract);

    function adminAllowPresaleGenerator (address _address, bool _allow) public onlyOwner {
        if (_allow) {
            presaleGenerators.add(_address);
        } else {
            presaleGenerators.remove(_address);
        }
    }
    function registerPresale (address _presaleAddress) public {
        require(presaleGenerators.contains(msg.sender), 'FORBIDDEN');
        presales.push(_presaleAddress);
        emit presaleRegistered(_presaleAddress);
    }
    function presaleGeneratorsLength() external view returns (uint256) {
        return presaleGenerators.length();
    }
    function presaleGeneratorAtIndex(uint256 _index) external view returns (address) {
        return presaleGenerators.at(_index);
    }
    function PresaleList() external view returns(address[] memory) {
        return presales;
    }
}