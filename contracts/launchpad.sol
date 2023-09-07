// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

contract Presale is ReentrancyGuard, Context, Ownable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    /// @notice Presale Contract Version, used to choose the correct ABI to decode the contract
    uint256 public CONTRACT_VERSION = 1;
    
    address payable public PRESALE_OWNER;
    address public S_TOKEN; // sale token
    address public B_TOKEN; // base token // usually WETH (ETH)
    bool public returnType;
    struct PresaleInfo {
        uint256 TOKEN_PRICE; // 1 base token = ? s_tokens, fixed price
        uint256 MAX_SPEND_PER_BUYER; // maximum base token BUY amount per account
        uint256 AMOUNT; // the amount of presale tokens up for presale
        uint256 HARDCAP;
        uint256 SOFTCAP;
        uint256 LIQUIDITY_PERCENT; // divided by 1000
        uint256 LISTING_RATE; // fixed rate at which the token will list on uniswap
        uint256 START_BLOCK;
        uint256 END_BLOCK;
        uint256 LOCK_PERIOD; // unix timestamp -> e.g. 2 weeks
        bool autoList;
        bool PRESALE_IN_ETH; // if this flag is true the presale is raising ETH, otherwise an ERC20 token such as DAI
    }
    struct PresaleFeeInfo {
        uint256 PINK_BASE_FEE; // divided by 1000
        uint256 PINK_TOKEN_FEE; // divided by 1000
        address payable BASE_FEE_ADDRESS;
        address payable TOKEN_FEE_ADDRESS;
    }
    struct PresaleStatus {
        bool WHITELIST_ONLY; // if set to true only whitelisted members may participate
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
    EnumerableSet.AddressSet private WHITELIST;

    constructor(address _presaleGenerator, address _factoryAddress, address _WETH, address _presalelockforwarder) {
        PRESALE_GENERATOR = _presaleGenerator;
        UNI_FACTORY = IUniswapV2Factory(_factoryAddress);
        WETH = IWETH(_WETH);
        // PRESALE_SETTINGS = IPresaleSettings(0x21876F9B3e7aA5F3604784de2724F55B92ceFA9d);
        PRESALE_LOCK_FORWARDER = IPresaleLockForwarder(_presalelockforwarder);
    }
    modifier onlyPresaleOwner() {
        require(PRESALE_OWNER == msg.sender || PRESALE_GENERATOR == msg.sender, "NOT PRESALE OWNER");
        _;
    }
    // tokenFlags: [isWhiteList, autoList, feeOption, returnType]
    function initialize (address[] calldata tokenAddresses, uint256[] calldata initialInfos, bool[] calldata tokenFlags, address payable feeAddress, uint256 tokenAmount) public {
        require(msg.sender == PRESALE_GENERATOR, "FORBIDDEN");
        require(!PRESALE_LOCK_FORWARDER.uniswapPairIsInitialised(tokenAddresses[2], tokenAddresses[1]), 'PAIR INITIALISED');
        PRESALE_OWNER = payable(tokenAddresses[0]);
        
        S_TOKEN = tokenAddresses[2];
        B_TOKEN = tokenAddresses[1];

        PRESALE_INFO.PRESALE_IN_ETH = tokenAddresses[1] == address(0x0000000000000000000000000000000000000000);
        PRESALE_INFO.AMOUNT = tokenAmount;
        PRESALE_INFO.TOKEN_PRICE = initialInfos[0];
        PRESALE_INFO.MAX_SPEND_PER_BUYER = initialInfos[1];
        PRESALE_INFO.HARDCAP = initialInfos[2];
        PRESALE_INFO.SOFTCAP = initialInfos[3];
        PRESALE_INFO.LIQUIDITY_PERCENT = initialInfos[4];
        PRESALE_INFO.LISTING_RATE = initialInfos[5];
        PRESALE_INFO.START_BLOCK = initialInfos[6];
        PRESALE_INFO.END_BLOCK = initialInfos[7];
        PRESALE_INFO.LOCK_PERIOD = initialInfos[8];
        PRESALE_INFO.autoList = tokenFlags[1];
        returnType = tokenFlags[3];
        if(!tokenFlags[2]) {
            PRESALE_FEE_INFO.PINK_BASE_FEE = 50;
            PRESALE_FEE_INFO.PINK_TOKEN_FEE = 0;
        } else {
            PRESALE_FEE_INFO.PINK_BASE_FEE = 20;
            PRESALE_FEE_INFO.PINK_TOKEN_FEE = 20;
        }
        PRESALE_FEE_INFO.BASE_FEE_ADDRESS = feeAddress;
        PRESALE_FEE_INFO.TOKEN_FEE_ADDRESS = feeAddress;
        // setting for fee
    }
    function presaleStatus () public view returns (uint256) {
        if (STATUS.FORCE_FAILED) {
        return 3; // FAILED - force fail
        }
        if ((block.timestamp > PRESALE_INFO.END_BLOCK) && (STATUS.TOTAL_BASE_COLLECTED < PRESALE_INFO.SOFTCAP)) {
        return 3; // FAILED - softcap not met by end block
        }
        if (STATUS.TOTAL_BASE_COLLECTED >= PRESALE_INFO.HARDCAP) {
        return 2; // SUCCESS - hardcap met
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
        if (STATUS.WHITELIST_ONLY) {
            require(WHITELIST.contains(msg.sender), 'NOT WHITELISTED');
        }
        if(!PRESALE_INFO.PRESALE_IN_ETH) {
            require(IERC20(B_TOKEN).balanceOf(msg.sender) >= _amount, "NOT ENOUGH AMOUNT");
            IERC20(B_TOKEN).approve(address(this), _amount);
            IERC20(B_TOKEN).transferFrom(msg.sender, address(this), _amount);
        }
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 amount_in = PRESALE_INFO.PRESALE_IN_ETH ? msg.value : _amount;
        uint256 allowance = PRESALE_INFO.MAX_SPEND_PER_BUYER.sub(buyer.baseDeposited);
        uint256 remaining = PRESALE_INFO.HARDCAP - STATUS.TOTAL_BASE_COLLECTED;
        allowance = allowance > remaining ? remaining : allowance;
        if (amount_in > allowance) {
            amount_in = allowance;
        }
        uint256 tokensSold = amount_in.mul(10 ** ERC20(S_TOKEN).decimals()).div(PRESALE_INFO.TOKEN_PRICE);
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
            TransferHelper.safeTransferFrom(B_TOKEN, address(this), msg.sender,  _amount.sub(amount_in));
        }
    }
    // withdraw presale tokens
    // percentile withdrawls allows fee on transfer or rebasing tokens to still work
    function userWithdrawTokens () external nonReentrant {
        
        if(presaleStatus() == 2) STATUS.LP_GENERATION_COMPLETE = true;

        require(STATUS.LP_GENERATION_COMPLETE, 'AWAITING LP GENERATION');
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 tokensRemainingDenominator = STATUS.TOTAL_TOKENS_SOLD.sub(STATUS.TOTAL_TOKENS_WITHDRAWN);
        uint256 tokensOwed = ERC20(S_TOKEN).balanceOf(address(this)).mul(buyer.tokensOwed).div(tokensRemainingDenominator);
        require(tokensOwed > 0, 'NOTHING TO WITHDRAW');
        STATUS.TOTAL_TOKENS_WITHDRAWN = STATUS.TOTAL_TOKENS_WITHDRAWN.add(buyer.tokensOwed);
        buyer.tokensOwed = 0;
        TransferHelper.safeTransfer(S_TOKEN, msg.sender, tokensOwed);
    }
    // on presale failure
    // percentile withdrawls allows fee on transfer or rebasing tokens to still work
    function userWithdrawBaseTokens () external nonReentrant {
        require(presaleStatus() == 3, 'NOT FAILED'); // FAILED
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 baseRemainingDenominator = STATUS.TOTAL_BASE_COLLECTED.sub(STATUS.TOTAL_BASE_WITHDRAWN);
        uint256 remainingBaseBalance = PRESALE_INFO.PRESALE_IN_ETH ? address(this).balance : ERC20(B_TOKEN).balanceOf(address(this));
        uint256 tokensOwed = remainingBaseBalance.mul(buyer.baseDeposited).div(baseRemainingDenominator);
        require(tokensOwed > 0, 'NOTHING TO WITHDRAW');
        STATUS.TOTAL_BASE_WITHDRAWN = STATUS.TOTAL_BASE_WITHDRAWN.add(buyer.baseDeposited);
        buyer.baseDeposited = 0;
        TransferHelper.safeTransferBaseToken(B_TOKEN, payable(msg.sender), tokensOwed, !PRESALE_INFO.PRESALE_IN_ETH);
    }

    //  Emergency Withdraw
    function userWithdrawBaseTokensEmergency () external nonReentrant {
        require(presaleStatus() == 1, 'NOT ACTIVE'); // FAILED
        BuyerInfo storage buyer = BUYERS[msg.sender];
        require(buyer.baseDeposited > 0, "NOTHING TO WITHDRAW");
        TransferHelper.safeTransferBaseToken(B_TOKEN, payable(msg.sender), buyer.baseDeposited.mul(9).div(10), !PRESALE_INFO.PRESALE_IN_ETH);
        STATUS.TOTAL_BASE_COLLECTED = STATUS.TOTAL_BASE_COLLECTED.sub(buyer.baseDeposited.mul(9).div(10));
        buyer.baseDeposited = 0;
        buyer.tokensOwed = 0;
        STATUS.NUM_BUYERS -= 1;
    }
    // on presale failure
    // allows the owner to withdraw the tokens they sent for presale & initial liquidity
    function ownerWithdrawTokens () private {
        require(presaleStatus() == 3); // FAILED
        TransferHelper.safeTransfer(S_TOKEN, PRESALE_OWNER, ERC20(S_TOKEN).balanceOf(address(this)));
    }
    function forceFailIfPairExists () external onlyPresaleOwner {
        require(!STATUS.LP_GENERATION_COMPLETE && !STATUS.FORCE_FAILED);
        if (PRESALE_LOCK_FORWARDER.uniswapPairIsInitialised(S_TOKEN, B_TOKEN)) {
            STATUS.FORCE_FAILED = true;
        }
    }
    
    function finalizePool() external onlyPresaleOwner {
        require(presaleStatus() == 2, "NOT ACTIVE"); // ACTIVE
        PRESALE_INFO.END_BLOCK = block.timestamp;
        if(PRESALE_INFO.autoList) {
            addLiquidity();
        } else {
            STATUS.LP_GENERATION_COMPLETE = true;
            // send remaining base tokens to presale owner
            uint256 remainingBaseBalance = PRESALE_INFO.PRESALE_IN_ETH ? address(this).balance : IERC20(B_TOKEN).balanceOf(address(this));
            TransferHelper.safeTransferBaseToken(B_TOKEN, PRESALE_OWNER, remainingBaseBalance, !PRESALE_INFO.PRESALE_IN_ETH);
            // burn unsold tokens
            uint256 remainingSBalance = IERC20(S_TOKEN).balanceOf(address(this));
            if (remainingSBalance > STATUS.TOTAL_TOKENS_SOLD) {
                uint256 burnAmount = remainingSBalance.sub(STATUS.TOTAL_TOKENS_SOLD);
                if(returnType)TransferHelper.safeTransfer(S_TOKEN, PRESALE_OWNER, burnAmount);
                else TransferHelper.safeTransfer(S_TOKEN, 0x000000000000000000000000000000000000dEaD, burnAmount);
            }
        }
    }
    function cancelPool() external onlyPresaleOwner {
        require(!STATUS.LP_GENERATION_COMPLETE && !STATUS.FORCE_FAILED);
        STATUS.FORCE_FAILED = true;
        PRESALE_INFO.END_BLOCK = block.timestamp;
        ownerWithdrawTokens();
    }
    receive() external payable{}
    function addLiquidity() private nonReentrant {
        require(!STATUS.LP_GENERATION_COMPLETE, 'GENERATION COMPLETE');
        require(PRESALE_INFO.autoList, "This is not auto listing");
        require(presaleStatus() == 2, 'NOT SUCCESS'); // SUCCESS
        // Fail the presale if the pair exists and contains presale token liquidity
        if (PRESALE_LOCK_FORWARDER.uniswapPairIsInitialised(S_TOKEN, B_TOKEN)) {
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
        else TransferHelper.safeApprove(B_TOKEN, address(PRESALE_LOCK_FORWARDER), baseLiquidity);
        // // sale token liquidity
        uint256 tokenLiquidity = baseLiquidity.mul(10 ** uint256(ERC20(S_TOKEN).decimals())).div(PRESALE_INFO.LISTING_RATE);
        TransferHelper.safeApprove(S_TOKEN, address(PRESALE_LOCK_FORWARDER), tokenLiquidity);
        if (PRESALE_INFO.PRESALE_IN_ETH) {
            PRESALE_LOCK_FORWARDER.lockLiquidity(IERC20(address(WETH)), IERC20(S_TOKEN), baseLiquidity, tokenLiquidity, block.timestamp + PRESALE_INFO.LOCK_PERIOD, PRESALE_OWNER);    
        }
        else PRESALE_LOCK_FORWARDER.lockLiquidity(IERC20(B_TOKEN), IERC20(S_TOKEN), baseLiquidity, tokenLiquidity, block.timestamp + PRESALE_INFO.LOCK_PERIOD, PRESALE_OWNER);
        
        // // transfer fees
        if(PRESALE_FEE_INFO.PINK_TOKEN_FEE > 0) {
            uint256 unicryptTokenFee = STATUS.TOTAL_TOKENS_SOLD.mul(PRESALE_FEE_INFO.PINK_TOKEN_FEE).div(1000);
            TransferHelper.safeTransfer(S_TOKEN, PRESALE_FEE_INFO.TOKEN_FEE_ADDRESS, unicryptTokenFee);
        }
        TransferHelper.safeTransferBaseToken(B_TOKEN, PRESALE_FEE_INFO.BASE_FEE_ADDRESS, unicryptBaseFee, !PRESALE_INFO.PRESALE_IN_ETH);
        
        // burn unsold tokens
        uint256 remainingSBalance = IERC20(S_TOKEN).balanceOf(address(this));
        if (remainingSBalance > STATUS.TOTAL_TOKENS_SOLD) {
            uint256 burnAmount = remainingSBalance.sub(STATUS.TOTAL_TOKENS_SOLD);
            if(returnType)TransferHelper.safeTransfer(S_TOKEN, PRESALE_OWNER, burnAmount);
            else TransferHelper.safeTransfer(S_TOKEN, 0x000000000000000000000000000000000000dEaD, burnAmount);
        }
        
        // send remaining base tokens to presale owner
        uint256 remainingBaseBalance = PRESALE_INFO.PRESALE_IN_ETH ? address(this).balance : IERC20(B_TOKEN).balanceOf(address(this));
        TransferHelper.safeTransferBaseToken(B_TOKEN, PRESALE_OWNER, remainingBaseBalance, !PRESALE_INFO.PRESALE_IN_ETH);
        
        STATUS.LP_GENERATION_COMPLETE = true;
    }
    function updateMaxSpendLimit(uint256 _maxSpend) external onlyPresaleOwner {
        PRESALE_INFO.MAX_SPEND_PER_BUYER = _maxSpend;
    }
    function setWhitelistFlag(bool _flag) external onlyPresaleOwner {
        STATUS.WHITELIST_ONLY = _flag;
    }
    // editable at any stage of the presale
    function editWhitelist(address[] memory _users, bool _add) external onlyPresaleOwner {
        if (_add) {
            for (uint i = 0; i < _users.length; i++) {
            WHITELIST.add(_users[i]);
            }
        } else {
            for (uint i = 0; i < _users.length; i++) {
            WHITELIST.remove(_users[i]);
            }
        }
    }

    // whitelist getters
    function getWhitelistedUsersLength () external view returns (uint256) {
        return WHITELIST.length();
    }
    
    function getWhitelistedUserAtIndex (uint256 _index) external view returns (address) {
        return WHITELIST.at(_index);
    }
    
    function getUserWhitelistStatus (address _user) external view returns (bool) {
        return WHITELIST.contains(_user);
    }
}

