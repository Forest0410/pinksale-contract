// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./TransferHelper.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPresaleLockForwarder {
    function lockLiquidity (IERC20 _baseToken, IERC20 _saleToken, uint256 _baseAmount, uint256 _saleAmount, uint256 _unlock_date, address payable _withdrawer) external;
    function uniswapPairIsInitialised (address _token0, address _token1) external view returns (bool);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

contract FairLaunch is ReentrancyGuard, Context, Ownable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public CONTRACT_VERSION = 1;
    struct PresaleInfo {
        address payable PRESALE_OWNER;
        address S_TOKEN; // sale token
        address B_TOKEN; // base token // usually WETH (ETH)
        uint256 TOKEN_PRICE; // 1 base token = ? s_tokens, fixed price
        uint256 TOTAL_AMOUNT;
        uint256 SOFTCAP;
        uint256 LIQUIDITY_PERCENT; // divided by 1000
        uint256 START_BLOCK;
        uint256 END_BLOCK;
        uint256 LOCK_PERIOD; // unix timestamp -> e.g. 2 weeks
        bool PRESALE_IN_ETH;
    }
    struct PresaleFeeInfo {
        uint256 PINK_BASE_FEE; // divided by 1000
        uint256 PINK_TOKEN_FEE; // divided by 1000
        address payable BASE_FEE_ADDRESS;
        address payable TOKEN_FEE_ADDRESS;
    }
    struct PresaleStatus {
        bool LP_GENERATION_COMPLETE; // final flag required to end a presale and enable withdrawls
        bool FORCE_FAILED; // set this flag to force fail the presale
        uint256 TOTAL_BASE_COLLECTED; // total base currency raised (usually ETH)
        uint256 TOTAL_TOKENS_SOLD; // total presale tokens sold
        uint256 TOTAL_TOKENS_WITHDRAWN; // total tokens withdrawn post successful presale
        uint256 TOTAL_BASE_WITHDRAWN; // total base tokens withdrawn on presale failure
        uint256 ROUND1_LENGTH; // in blocks
        uint256 NUM_BUYERS; // number of unique participants
    }
    struct BuyerInfo {
        uint256 baseDeposited; // total base token (usually ETH) deposited by user, can be withdrawn on presale failure
        uint256 tokensOwed; // num presale tokens a user is owed, can be withdrawn on presale success
    }
    PresaleInfo public PRESALE_INFO;
    PresaleFeeInfo public PRESALE_FEE_INFO;
    PresaleStatus public STATUS;
    address public PRESALE_GENERATOR;
    IPresaleLockForwarder public PRESALE_LOCK_FORWARDER;
    IUniswapV2Factory public UNI_FACTORY;
    IWETH public WETH;
    mapping(address => BuyerInfo) public BUYERS;
    constructor(address _presaleGenerator, address _factoryAddress, address _WETH, address _presalelockforwarder) {
        PRESALE_GENERATOR = _presaleGenerator;
        UNI_FACTORY = IUniswapV2Factory(_factoryAddress);
        WETH = IWETH(_WETH);
        PRESALE_LOCK_FORWARDER = IPresaleLockForwarder(_presalelockforwarder);
    }
    modifier onlyPresaleOwner() {
        require(PRESALE_INFO.PRESALE_OWNER == msg.sender || PRESALE_GENERATOR == msg.sender, "NOT PRESALE OWNER");
        _;
    }
    function init1(address _owner, address _baseToken, address _presaleToken,uint256 _totalAmount, uint256 _softcap, uint256 _liquidityPercent, uint256 _startTime, uint256 _endTime, uint256 _lockTime) onlyPresaleOwner public {
        require(msg.sender == PRESALE_GENERATOR, "FORBIDDEN");
        PRESALE_INFO.PRESALE_OWNER = payable(_owner);
        PRESALE_INFO.PRESALE_IN_ETH = _baseToken == address(0x0000000000000000000000000000000000000000);
        PRESALE_INFO.B_TOKEN = _baseToken;
        PRESALE_INFO.S_TOKEN = _presaleToken;
        PRESALE_INFO.TOTAL_AMOUNT = _totalAmount;
        PRESALE_INFO.SOFTCAP = _softcap;
        PRESALE_INFO.TOKEN_PRICE = _totalAmount.div(_softcap);
        PRESALE_INFO.LIQUIDITY_PERCENT = _liquidityPercent;
        PRESALE_INFO.START_BLOCK = _startTime;
        PRESALE_INFO.END_BLOCK = _endTime;
        PRESALE_INFO.LOCK_PERIOD = _lockTime;
    }
    function init2(address _feeAddress, bool feeOption) public onlyPresaleOwner {
        PRESALE_FEE_INFO.BASE_FEE_ADDRESS = payable(_feeAddress);
        PRESALE_FEE_INFO.TOKEN_FEE_ADDRESS = payable(_feeAddress);
        if(!feeOption) {
            PRESALE_FEE_INFO.PINK_BASE_FEE = 50;
            PRESALE_FEE_INFO.PINK_TOKEN_FEE = 0;
        } else {
            PRESALE_FEE_INFO.PINK_BASE_FEE = 20;
            PRESALE_FEE_INFO.PINK_TOKEN_FEE = 20;
        }
    }
    function presaleStatus () public view returns (uint256) {
        if (STATUS.FORCE_FAILED) {
            return 3; // FAILED - force fail
        }
        if ((block.timestamp > PRESALE_INFO.END_BLOCK) && (STATUS.TOTAL_BASE_COLLECTED < PRESALE_INFO.SOFTCAP)) {
            return 3; // FAILED - softcap not met by end block
        }
        if ((block.timestamp > PRESALE_INFO.END_BLOCK) && (STATUS.TOTAL_BASE_COLLECTED >= PRESALE_INFO.SOFTCAP)) {
            return 2; // SUCCESS - endblock and soft cap reached
        }
        if ((block.timestamp >= PRESALE_INFO.START_BLOCK) && (block.timestamp <= PRESALE_INFO.END_BLOCK)) {
            return 1; // ACTIVE - deposits enabled
        }
        return 0; // QUED - awaiting start block
    }
    // accepts msg.value for eth or _amount for ERC20 tokens
    function userDeposit (uint256 _amount) external payable nonReentrant {
        require(presaleStatus() == 1, 'NOT ACTIVE'); // ACTIVE
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 amount_in = PRESALE_INFO.PRESALE_IN_ETH ? msg.value : _amount;
        uint256 allowance = PRESALE_INFO.SOFTCAP - STATUS.TOTAL_BASE_COLLECTED;
        if (amount_in > allowance) {
            amount_in = allowance;
        }
        if(!PRESALE_INFO.PRESALE_IN_ETH) {
            require(IERC20(PRESALE_INFO.B_TOKEN).balanceOf(msg.sender) >= _amount, "NOT ENOUGH AMOUNT");
            IERC20(PRESALE_INFO.B_TOKEN).transferFrom(msg.sender, address(this), _amount);
        }
        uint256 tokensSold = amount_in.mul(10 ** ERC20(PRESALE_INFO.S_TOKEN).decimals()).div(PRESALE_INFO.TOKEN_PRICE);
        require(tokensSold > 0, 'ZERO TOKENS');
        if (buyer.baseDeposited == 0) {
           STATUS.NUM_BUYERS++;
        }
        buyer.baseDeposited = buyer.baseDeposited.add(amount_in);
        buyer.tokensOwed = buyer.tokensOwed.add(tokensSold);
        STATUS.TOTAL_BASE_COLLECTED = STATUS.TOTAL_BASE_COLLECTED.add(amount_in);
        STATUS.TOTAL_TOKENS_SOLD = STATUS.TOTAL_TOKENS_SOLD.add(tokensSold);
        // return unused ETH
        if (PRESALE_INFO.PRESALE_IN_ETH && amount_in < msg.value) {
            payable(msg.sender).transfer(msg.value.sub(amount_in));
        }
        // deduct non ETH token from user
        if (!PRESALE_INFO.PRESALE_IN_ETH && _amount > amount_in) {
            TransferHelper.safeTransferFrom(PRESALE_INFO.B_TOKEN, address(this), msg.sender,  _amount.sub(amount_in));
        }
    }
    function addLiquidity() public onlyPresaleOwner nonReentrant {
        require(!STATUS.LP_GENERATION_COMPLETE, 'GENERATION COMPLETE');
        require(presaleStatus() == 2, 'NOT SUCCESS'); // SUCCESS
        // Fail the presale if the pair exists and contains presale token liquidity
        if (PRESALE_LOCK_FORWARDER.uniswapPairIsInitialised(PRESALE_INFO.S_TOKEN, PRESALE_INFO.B_TOKEN)) {
            STATUS.FORCE_FAILED = true;
            return;
        }
        uint256 unicryptBaseFee = STATUS.TOTAL_BASE_COLLECTED.mul(PRESALE_FEE_INFO.PINK_BASE_FEE).div(1000);
        // base token liquidity
        uint256 baseLiquidity = STATUS.TOTAL_BASE_COLLECTED.sub(unicryptBaseFee).mul(PRESALE_INFO.LIQUIDITY_PERCENT).div(1000);
        if (PRESALE_INFO.PRESALE_IN_ETH) {
            WETH.deposit{value : baseLiquidity}();
            TransferHelper.safeApprove(address(WETH), address(PRESALE_LOCK_FORWARDER), baseLiquidity);
        }
        else TransferHelper.safeApprove(PRESALE_INFO.B_TOKEN, address(PRESALE_LOCK_FORWARDER), baseLiquidity);
        uint256 unicryptTokenFee = 0;
        // transfer fees
        if(PRESALE_FEE_INFO.PINK_TOKEN_FEE > 0) {
            unicryptTokenFee = PRESALE_INFO.TOTAL_AMOUNT.mul(PRESALE_FEE_INFO.PINK_TOKEN_FEE).div(1000);
            TransferHelper.safeTransfer(PRESALE_INFO.S_TOKEN, PRESALE_FEE_INFO.TOKEN_FEE_ADDRESS, unicryptTokenFee);
        }
        // sale token liquidity
        uint256 tokenLiquidity = PRESALE_INFO.TOTAL_AMOUNT.sub(unicryptTokenFee).mul(PRESALE_INFO.LIQUIDITY_PERCENT).div(1000);
        TransferHelper.safeApprove(PRESALE_INFO.S_TOKEN, address(PRESALE_LOCK_FORWARDER), tokenLiquidity);
        if (PRESALE_INFO.PRESALE_IN_ETH) {
            PRESALE_LOCK_FORWARDER.lockLiquidity(IERC20(address(WETH)), IERC20(PRESALE_INFO.S_TOKEN), baseLiquidity, tokenLiquidity, block.timestamp + PRESALE_INFO.LOCK_PERIOD, PRESALE_INFO.PRESALE_OWNER);
        }
        else PRESALE_LOCK_FORWARDER.lockLiquidity(IERC20(PRESALE_INFO.B_TOKEN), IERC20(PRESALE_INFO.S_TOKEN), baseLiquidity, tokenLiquidity, block.timestamp + PRESALE_INFO.LOCK_PERIOD, PRESALE_INFO.PRESALE_OWNER);
        
        TransferHelper.safeTransferBaseToken(PRESALE_INFO.B_TOKEN, PRESALE_FEE_INFO.BASE_FEE_ADDRESS, unicryptBaseFee, !PRESALE_INFO.PRESALE_IN_ETH);
        
        // send remaining base tokens to presale owner
        uint256 remainingBaseBalance = PRESALE_INFO.PRESALE_IN_ETH ? address(this).balance : IERC20(PRESALE_INFO.B_TOKEN).balanceOf(address(this));
        TransferHelper.safeTransferBaseToken(PRESALE_INFO.B_TOKEN, PRESALE_INFO.PRESALE_OWNER, remainingBaseBalance, !PRESALE_INFO.PRESALE_IN_ETH);
        
        STATUS.LP_GENERATION_COMPLETE = true;
    }
    // withdraw presale tokens
    // percentile withdrawls allows fee on transfer or rebasing tokens to still work
    function userWithdrawTokens () external nonReentrant {
        if(presaleStatus() == 2) STATUS.LP_GENERATION_COMPLETE = true;
        require(STATUS.LP_GENERATION_COMPLETE, 'AWAITING LP GENERATION');
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 tokensOwed = IERC20(PRESALE_INFO.S_TOKEN).balanceOf(address(this)).mul(buyer.baseDeposited).div(STATUS.TOTAL_BASE_COLLECTED);
        require(tokensOwed > 0, 'NOTHING TO WITHDRAW');
        STATUS.TOTAL_TOKENS_WITHDRAWN = STATUS.TOTAL_TOKENS_WITHDRAWN.add(tokensOwed);
        buyer.tokensOwed = 0;
        TransferHelper.safeTransfer(PRESALE_INFO.S_TOKEN, msg.sender, tokensOwed);
    }
    // on presale failure
    // percentile withdrawls allows fee on transfer or rebasing tokens to still work
    function userWithdrawBaseTokens () external nonReentrant {
        require(presaleStatus() == 3, 'NOT FAILED'); // FAILED
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 remainingBaseBalance = PRESALE_INFO.PRESALE_IN_ETH ? address(this).balance : ERC20(PRESALE_INFO.B_TOKEN).balanceOf(address(this));
        uint256 tokensOwed = remainingBaseBalance.mul(buyer.baseDeposited).div(STATUS.TOTAL_BASE_COLLECTED);
        require(tokensOwed > 0, 'NOTHING TO WITHDRAW');
        STATUS.TOTAL_BASE_WITHDRAWN = STATUS.TOTAL_BASE_WITHDRAWN.add(buyer.baseDeposited);
        buyer.baseDeposited = 0;
        TransferHelper.safeTransferBaseToken(PRESALE_INFO.B_TOKEN, payable(msg.sender), tokensOwed, !PRESALE_INFO.PRESALE_IN_ETH);
    }
    //  Emergency Withdraw
    function userWithdrawBaseTokensEmergency () external nonReentrant {
        require(presaleStatus() == 1, 'NOT ACTIVE'); // FAILED
        BuyerInfo storage buyer = BUYERS[msg.sender];
        require(buyer.baseDeposited > 0, "NOTHING TO WITHDRAW");
        TransferHelper.safeTransferBaseToken(PRESALE_INFO.B_TOKEN, payable(msg.sender), buyer.baseDeposited.mul(9).div(10), !PRESALE_INFO.PRESALE_IN_ETH);
        STATUS.TOTAL_BASE_COLLECTED = STATUS.TOTAL_BASE_COLLECTED.sub(buyer.baseDeposited.mul(9).div(10));
        buyer.baseDeposited = 0;
        buyer.tokensOwed = 0;
        STATUS.NUM_BUYERS -= 1;
    }
    
    function forceFailIfPairExists () external {
        require(!STATUS.LP_GENERATION_COMPLETE && !STATUS.FORCE_FAILED);
        if (PRESALE_LOCK_FORWARDER.uniswapPairIsInitialised(PRESALE_INFO.S_TOKEN, PRESALE_INFO.B_TOKEN)) {
            STATUS.FORCE_FAILED = true;
        }
    }
    function finalizePool() external onlyPresaleOwner {
        require(presaleStatus() == 2, "NOT ACTIVE"); // ACTIVE
        PRESALE_INFO.END_BLOCK = block.timestamp;
        addLiquidity();
    }
    function cancelPool() external onlyPresaleOwner {
        require(!STATUS.LP_GENERATION_COMPLETE && !STATUS.FORCE_FAILED);
        STATUS.FORCE_FAILED = true;
        PRESALE_INFO.END_BLOCK = block.timestamp;
        ownerWithdrawTokens();
    }
    receive() external payable{}
    // on presale failure
    // allows the owner to withdraw the tokens they sent for presale & initial liquidity
    function ownerWithdrawTokens () private {
        require(presaleStatus() == 3); // FAILED
        TransferHelper.safeTransfer(PRESALE_INFO.S_TOKEN, PRESALE_INFO.PRESALE_OWNER, ERC20(PRESALE_INFO.S_TOKEN).balanceOf(address(this)));
    }
}
