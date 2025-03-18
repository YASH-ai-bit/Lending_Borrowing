//SPDX-License-Identifer: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract LendingBorrowing is ReentrancyGuard{
    /////////////////ERRORS//////////////////
    error LendingBorrowing__NotEnoughCollateral();
    error LendingBorrowing__DoNotOverpay();
    error LendingBorrowing__TransferFailed();
    error LendingBorrowing__UserHealthOK();
    error LendingBorrowing__UserIsNotBorrower();
    error LendingBorrowing__DebtCantBePaidUsinCollateral();
    error LendingBorrowing__CantWithdrawYourCollateralIsLocked();
    error LendingBorrowing__ZeroAmount();
    error LendingBorrowing__YouAreNotABorrower_UseWithdrawFunction();
    error LendingBorrowing__CantWithdrawPartially__WithdrawingTooMuch();

    ////////////////MODIFIERS////////////////
    modifier nonZero(uint256 _amount){
        if(_amount == 0){
            revert LendingBorrowing__ZeroAmount();
        }
        _;
    }

    ////////////////EVENTS///////////////////
    event deposited(address indexed user, uint256 indexed amount, uint256 indexed time);
    event borrowed(address indexed user, uint256 indexed amount, uint256 indexed time);
    event repayed(address indexed user, uint256 indexed amount, uint256 indexed time);
    event withdrawn(address indexed user, uint256 indexed amount, uint256 indexed time);
    event liquidated(address indexed user);

    ///////////////STATE VARIABLES///////////
    IERC20 public weth;
    IERC20 public usdc;
    uint256 public weth_price;
    uint256 public constant USDC_PRICE = 1 ; // $1 --> assuming constant

    struct User {
        uint256 deposit;
        uint256 collateral;
        uint256 debt;
        uint256 lastBorrowTime;
        uint256 lastDepositionTime;
        uint256 healthFactor;
        bool isBorrower;
    }
    
    mapping(address => User) public users;

    uint256 public constant LENDING_INTEREST = 3;  // 3%
    uint256 public constant BORROWING_INTEREST = 5;  //5%
    uint256 public constant NUMBER_OF_SECONDS_IN_A_YEAR = 60 * 60 * 24 * 365 ;
    uint256 public constant COLLATERAL_FACTOR = 50; // 55% of USDC converted value from ETH can be maximum borrowed
    uint256 public constant LIQUIDATION_THRESHOLD = 75; //75%
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant LIQUIDATION_BONUS = 3 ; //3 %
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1;

    constructor(address _weth, address _usdc) {
        weth = IERC20(_weth);       //token1 can be deposited
        usdc = IERC20(_usdc);       //token2 can be borrowed
    }

    function deposit(uint256 weth_amount) public nonZero(weth_amount){
        bool success = weth.transferFrom(msg.sender, address(this), weth_amount);
        if(!success) {
            revert LendingBorrowing__TransferFailed();
        }
        users[msg.sender].deposit += weth_amount;
        users[msg.sender].collateral += weth_amount;
        users[msg.sender].lastDepositionTime = block.timestamp;
        emit deposited(msg.sender, weth_amount, block.timestamp);
    }

    function borrow(uint256 usdc_amount) public nonZero(usdc_amount){                          //borrower wants usdc_amount of USDC.
        uint256 collateralAmount = users[msg.sender].collateral;
        uint256 MaximumCanBorrow = collateralAmount * weth_price * COLLATERAL_FACTOR;

        if(usdc_amount > MaximumCanBorrow){
            revert LendingBorrowing__NotEnoughCollateral();
        }

        usdc.transferFrom(address(this), msg.sender, usdc_amount);
        users[msg.sender].debt += usdc_amount;                          //updating debt
        users[msg.sender].lastBorrowTime = block.timestamp;             //updating timestamp to use in repay calculation
        users[msg.sender].isBorrower = true;
        emit borrowed(msg.sender, usdc_amount, block.timestamp);
    }

    function repay(uint256 usdc_amount) public nonZero(usdc_amount){
        uint256 amountToPay = calculateDebtWithInterest(msg.sender);
        if(usdc_amount > amountToPay){
            revert LendingBorrowing__DoNotOverpay();
        }
        usdc.transferFrom(msg.sender , address(this), usdc_amount);

        users[msg.sender].debt -= usdc_amount;
        users[msg.sender].lastBorrowTime = block.timestamp;

        if(users[msg.sender].debt == 0) {
            users[msg.sender].isBorrower = false;
        }

        emit repayed(msg.sender, usdc_amount, block.timestamp);
    }

    function liquidation(address user) public nonReentrant{           //use collateral(USD) to cover debt(already in USD)
        uint256 healthFactor = users[user].healthFactor;
        if(!users[user].isBorrower) {
            revert LendingBorrowing__UserIsNotBorrower();
        }
        if(healthFactor > MIN_HEALTH_FACTOR) {
            revert LendingBorrowing__UserHealthOK();
        }
        uint256 collateralInWEth = users[user].collateral;
        uint256 collateralInUsdc = getWEthPriceInUsd(collateralInWEth);
        uint256 debtAlreadyInUsdc = users[user].debt;
        uint256 liquidationBonus = (debtAlreadyInUsdc * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION ;
        uint256 totalDebtToBeCovered = debtAlreadyInUsdc + liquidationBonus;

        if(totalDebtToBeCovered > collateralInUsdc){
            revert LendingBorrowing__DebtCantBePaidUsinCollateral();
        }

        users[user].collateral -= collateralInWEth;
        users[user].debt = 0 ;
        users[user].isBorrower = false;

        payable(msg.sender).transfer(liquidationBonus);        //paying the liquidator

        emit liquidated(user);
    }

    function withdraw(uint256 weth_amount) public nonZero(weth_amount) nonReentrant{
        if(users[msg.sender].isBorrower){
            revert LendingBorrowing__CantWithdrawYourCollateralIsLocked();
        }
        uint256 amountWithInterest = calculateWithdrawalWithInterest(msg.sender, weth_amount);

        weth.transferFrom(address(this), msg.sender, amountWithInterest);
    }

    function partialWithdraw(uint256 weth_amount) public nonReentrant{
        if(!users[msg.sender].isBorrower){
            revert LendingBorrowing__YouAreNotABorrower_UseWithdrawFunction();
        }
        uint256 healthFactorAfterWithdrawal = _healthFactor(msg.sender, (users[msg.sender].collateral - weth_amount));
        if(healthFactorAfterWithdrawal < 1) {
            revert LendingBorrowing__CantWithdrawPartially__WithdrawingTooMuch();
        }
    }

    /////////////HELPER FUNCTIONS//////////////////
    function calculateDebtWithInterest(address user) internal view returns(uint256){
        uint256 debt_amount = users[user].debt;

        uint256 timeGone = block.timestamp - users[user].lastBorrowTime ;

        uint256 interest = (debt_amount * BORROWING_INTEREST * timeGone) / (100 * NUMBER_OF_SECONDS_IN_A_YEAR);

        return (debt_amount + interest);
    }

    function calculateWithdrawalWithInterest(address user, uint256 weth_amount) internal view returns(uint256){
        uint256 timeGone = block.timestamp - users[user].lastDepositionTime ;
        uint256 interest = (weth_amount * LENDING_INTEREST * timeGone) / (100 * NUMBER_OF_SECONDS_IN_A_YEAR);

        return (weth_amount + interest);
    }

    function _healthFactor(address user, uint256 collateralValueInWEth) internal returns(uint256){
        collateralValueInWEth = users[user].collateral ;
        uint256 collateralInUsdc = getWEthPriceInUsd(collateralValueInWEth);
        uint256 debt_amount = users[user].debt;
        uint256 __healthFactor = (collateralInUsdc * LIQUIDATION_THRESHOLD) / debt_amount; 

        users[user].healthFactor = __healthFactor;     //updating struct
        return __healthFactor;
    }

    function getWEthPriceInUsd(uint256 weth_amount) internal view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(address(weth));
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * weth_amount) / PRECISION;
    } 
}