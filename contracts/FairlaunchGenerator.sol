// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./TransferHelper.sol";
import "./fairLaunch.sol";

interface IPresaleFactory {
    function registerPresale (address _presaleAddress) external;
    function presaleIsRegistered(address _presaleAddress) external view returns (bool);
}

contract FairLaunchGenerator01 is Ownable {

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
    function createPresale (address[] calldata tokenAddresses, uint256 _totalAmount, uint256 _softcap, uint256 _liquidityPercent, uint256 _startTime, uint256 _endTime, uint256 _lockTime, bool feeOption ) public payable {
        require(msg.value >= pricePresale, "Not enough BNB");
        FairLaunch newPresale = new FairLaunch(address(this), tokenAddresses[3], tokenAddresses[4], tokenAddresses[5]);
        uint256 tokensRequiredForPresale;
        if(!feeOption){
            // presale amount + presale amount * liqudity% * 95%
            tokensRequiredForPresale = _totalAmount + _totalAmount *_liquidityPercent * 95 / (100 * 1000);
        } else {
            tokensRequiredForPresale = _totalAmount + _totalAmount *_liquidityPercent * 98 / (100 * 1000);
        }
        TransferHelper.safeTransferFrom(address(tokenAddresses[2]), address(msg.sender), address(newPresale), tokensRequiredForPresale);
        payable (adminWallet).transfer(address(this).balance);
        newPresale.init1(tokenAddresses[0], tokenAddresses[1],tokenAddresses[2], _totalAmount, _softcap, _liquidityPercent, _startTime, _endTime, _lockTime);
        newPresale.init2(adminWallet, feeOption);
        PRESALE_FACTORY.registerPresale(address(newPresale));
    }
    
}