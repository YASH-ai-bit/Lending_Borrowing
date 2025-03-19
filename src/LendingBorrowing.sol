//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";

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
    error LendingBorrowing__YouAreNotABorrower();
    error LendingBorrowing__CantWithdrawPartially__WithdrawingTooMuch();
    error LendingBorrowing__InvalidPriceFeed();
    error LendingBorrowing__ExceedsTotalBalance();
    error LendingBorrowing__DivisionByZero();

    ////////////////MODIFIERS////////////////
    modifier nonZero(uint256 _amount){
        if(_amount == 0){
            revert LendingBorrowing__ZeroAmount();
        }
        _;
    }

    ////////////////EVENTS///////////////////
    event deposited(address indexed user, uint256 indexed amount, uint256 time);
    event borrowed(address indexed user, uint256 indexed amount, uint256 time);
    event repayed(address indexed user, uint256 indexed amount, uint256 time);
    event withdrawn(address indexed user, uint256 indexed amount, uint256 time);
    event partiallyWithdrawn(address indexed user, uint256 indexed amount, uint256 time);
    event liquidated(address indexed user);

    ///////////////STATE VARIABLES///////////
    IERC20 public weth;
    IERC20 public usdc;
    AggregatorV3Interface priceFeed;
    uint256 public constant USDC_PRICE = 1e8 ; // $1 --> assuming constant

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
    uint256 public constant MIN_HEALTH_FACTOR = 1e18 ;

    constructor(address _weth, address _usdc, address _priceFeed) {
        weth = IERC20(_weth);       //token1 can be deposited
        usdc = IERC20(_usdc);       //token2 can be borrowed

        priceFeed = AggregatorV3Interface(_priceFeed);                //_priceFeed is ETH/USD priceFeed from chainlink
    }

    function deposit(uint256 weth_amount) public nonZero(weth_amount){
        bool success = weth.transferFrom(msg.sender, address(this), weth_amount);
        if(!success) {
            revert LendingBorrowing__TransferFailed();
        }
        users[msg.sender].deposit += weth_amount;
        users[msg.sender].lastDepositionTime = block.timestamp;
        emit deposited(msg.sender, weth_amount, block.timestamp);
    }

    function borrow(uint256 usdc_amount, uint256 collateral) public nonZero(usdc_amount){                          //borrower wants usdc_amount of USDC.
        deposit(collateral);
        users[msg.sender].collateral += collateral;
        uint256 collateralAmount = users[msg.sender].collateral;            // in weth
        uint256 maximumCanBorrow =(collateralAmount * getWEthPrice()) / 2;

        if(usdc_amount > maximumCanBorrow){
            revert LendingBorrowing__NotEnoughCollateral();
        }else{

        bool success = usdc.transfer(msg.sender, usdc_amount);
        if (!success) revert LendingBorrowing__TransferFailed();

        users[msg.sender].debt += usdc_amount;                          //updating debt
        users[msg.sender].lastBorrowTime = block.timestamp;             //updating timestamp to use in repay calculation
        users[msg.sender].isBorrower = true;
        emit borrowed(msg.sender, usdc_amount, block.timestamp);}
    }

    function repay(uint256 usdc_amount, address user) public nonZero(usdc_amount){
        require(users[user].debt > 0 , "you are not a borrower!");
        uint256 amountToPay = calculateDebtWithInterest(user);
        if(usdc_amount > amountToPay){
            revert LendingBorrowing__DoNotOverpay();
        }

        users[user].debt -= usdc_amount;
        users[user].lastBorrowTime = block.timestamp;

        if(users[user].debt == 0) {
            users[user].isBorrower = false;
        }

        usdc.transferFrom(user, address(this), usdc_amount);

        emit repayed(user, usdc_amount, block.timestamp);
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
        uint256 debtAlreadyInUsdc = users[user].debt * USDC_PRICE;
        uint256 liquidationBonus = (collateralInUsdc * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION ;
        uint256 totalDebtToBeCovered = debtAlreadyInUsdc + liquidationBonus;

        if(totalDebtToBeCovered > collateralInUsdc){
            revert LendingBorrowing__DebtCantBePaidUsinCollateral();
        }

        users[user].collateral -= collateralInWEth;
        users[user].debt = 0 ;
        users[user].isBorrower = false;

        usdc.transfer(msg.sender, liquidationBonus);        //paying the liquidator

        emit liquidated(user);
    }

    function withdraw(uint256 weth_amount, address user) public nonZero(weth_amount) nonReentrant{
        require(users[user].debt == 0, "you are a borrower, can't withdraw!");
        uint256 totalAmountWithInterest = calculateWithdrawalWithInterest(user);
        if(weth_amount > totalAmountWithInterest){
            revert LendingBorrowing__ExceedsTotalBalance();
        }

        weth.transfer(user, weth_amount);

        users[user].deposit = (totalAmountWithInterest - weth_amount);
        users[user].lastDepositionTime = block.timestamp;
        emit withdrawn(user, weth_amount, block.timestamp);
    }

    function partialWithdraw(uint256 weth_amount, address user) public nonReentrant{
        require(users[user].debt > 0, "you are not a borrower!");
        uint256 healthFactorAfterWithdrawal = _healthFactor(user, (users[user].collateral - weth_amount));
        if(healthFactorAfterWithdrawal < MIN_HEALTH_FACTOR) {
            revert LendingBorrowing__CantWithdrawPartially__WithdrawingTooMuch();
        }
        uint256 totalAmountWithInterest = calculateWithdrawalWithInterest(user);
        if(weth_amount > totalAmountWithInterest){
            revert LendingBorrowing__ExceedsTotalBalance();
        }
        weth.transfer(user, weth_amount);

        users[user].deposit = (totalAmountWithInterest - weth_amount);
        users[user].lastDepositionTime = block.timestamp;
        emit partiallyWithdrawn(user, weth_amount, block.timestamp);
    }

    /////////////HELPER FUNCTIONS//////////////////
    function calculateDebtWithInterest(address user) public view returns(uint256){
        uint256 debt_amount = users[user].debt;

        uint256 timeGone = block.timestamp - users[user].lastBorrowTime ;

        uint256 interest = (debt_amount * BORROWING_INTEREST * timeGone) / (100 * NUMBER_OF_SECONDS_IN_A_YEAR);

        return (debt_amount + interest);
    }

    function calculateWithdrawalWithInterest(address user) public view returns(uint256){
        uint256 depositedBalance = users[msg.sender].deposit;
        uint256 timeGone = block.timestamp - users[user].lastDepositionTime ;
        uint256 interest = (depositedBalance * LENDING_INTEREST * timeGone) / (100 * NUMBER_OF_SECONDS_IN_A_YEAR);

        return (depositedBalance + interest);
    }

    function _healthFactor(address user, uint256 collateralValueInWEth) public returns(uint256){
        uint256 collateralInUsdc = getWEthPriceInUsd(collateralValueInWEth);
        uint256 debt_amount = users[user].debt * USDC_PRICE;
        if(debt_amount == 0){
            revert LendingBorrowing__DivisionByZero();
        }
        uint256 __healthFactor = (collateralInUsdc * LIQUIDATION_THRESHOLD) / debt_amount; 

        users[user].healthFactor = __healthFactor;     //updating struct
        return __healthFactor;
    }

    function getWEthPriceInUsd(uint256 weth_amount) public view returns(uint256){
        (, int256 price,,,) = priceFeed.latestRoundData();
        if(price <= 0) {
            revert LendingBorrowing__InvalidPriceFeed();
        }
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * weth_amount) / PRECISION;
    } 

    function getWEthPrice() public view returns(uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        if(price <= 0) {
            revert LendingBorrowing__InvalidPriceFeed();
        }
        return (uint256(price) * ADDITIONAL_FEED_PRECISION) / PRECISION;
    }

    //////////////GETTER FUNCTIONS////////////////
    function getUser(address user) external view returns(User memory){
        return users[user];
    }
}
  



