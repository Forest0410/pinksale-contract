// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./TransferHelper.sol";
import "./dutchAction.sol";

interface IPresaleFactory {
    function registerPresale (address _presaleAddress) external;
    function presaleIsRegistered(address _presaleAddress) external view returns (bool);
}

contract DutchAuctionGenerator01 is Ownable {

    using SafeMath for uint256;
    IPresaleFactory public PRESALE_FACTORY;
    uint256 private pricePresale = 0.01 ether;
    address payable private adminWallet;
    constructor(address _presaleFactory) {
        PRESALE_FACTORY = IPresaleFactory(_presaleFactory);
        adminWallet = payable(msg.sender);
    }
    function setAdminWallet (address _wallet) public onlyOwner {
        adminWallet = payable(_wallet);
    }
    //  tokenAddress : [Presale Owner, Base Token, Presale Token, FactoryAddress, WETH address, PresaleLockForwarder address]
    // tokenFlags: [isWhiteList, feeOption, returnType]
    function createPresale (address[] calldata tokenAddresses, uint256[] calldata initialInfos, bool[] calldata tokenFlags) public payable {
        require(msg.value >= pricePresale, "Not enough BNB");
        // hardcap/ presaleRate + hardcap * percentage/ rate
        uint256 tokensRequiredForPresale;
        if(!tokenFlags[1]){
            // presale amount + presale amount * liqudity% * 95%
            tokensRequiredForPresale = initialInfos[0] + initialInfos[0] *initialInfos[6] * 95 / (100 * 1000);
        } else {
            tokensRequiredForPresale = initialInfos[0] + initialInfos[0] *initialInfos[6] * 98 / (100 * 1000);
        }
        DuthcAuctionContract newPresale = new DuthcAuctionContract(address(this), tokenAddresses[3], tokenAddresses[4], tokenAddresses[5]);
        TransferHelper.safeTransferFrom(address(tokenAddresses[2]), address(msg.sender), address(newPresale), tokensRequiredForPresale);
        payable (adminWallet).transfer(address(this).balance);
        newPresale.initialize(tokenAddresses, initialInfos, tokenFlags, adminWallet);
        newPresale.setWhitelistFlag(tokenFlags[0]);
        PRESALE_FACTORY.registerPresale(address(newPresale));
    }
}