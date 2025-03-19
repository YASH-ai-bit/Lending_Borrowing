//SPDX-License-Identifer: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployLB} from "../../script/DeployLB.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {LendingBorrowing} from "../../src/LendingBorrowing.sol";

contract LBTest is Test {
    DeployLB deployer;
    LendingBorrowing lb;
    HelperConfig config;
    address wethUsdPriceFeed;
    address _weth;
    address _usdc;
    ERC20Mock weth;
    ERC20Mock usdc;

    address public USER = makeAddr("User");
    uint256 public constant INITIAL_BALANCE_WETH = 5000;
    uint256 public constant INITIAL_BALANCE_USDC = 10000000;
    uint256 public constant AMT_WETH = 100;
    uint256 public constant AMT_USDC = 100;
    uint256 public constant TEST_AMT = 9000;

    function setUp() public {
        deployer = new DeployLB();
        (lb, config) = deployer.run();
        (wethUsdPriceFeed, _weth, _usdc,) = config.activeNetworkConfig();
        weth = ERC20Mock(_weth);
        usdc = ERC20Mock(_usdc);

        weth.mint(USER, INITIAL_BALANCE_WETH);
        usdc.mint(USER, INITIAL_BALANCE_USDC);

        weth.mint(address(this), INITIAL_BALANCE_WETH);
        usdc.mint(address(this), INITIAL_BALANCE_USDC);

        usdc.mint(address(lb), INITIAL_BALANCE_USDC);

        weth.approve(address(lb), type(uint256).max);
        usdc.approve(address(lb), type(uint256).max);

        vm.startPrank(USER);
        weth.approve(address(lb), type(uint256).max);
        usdc.approve(address(lb), type(uint256).max);
        vm.stopPrank();
    }

    ///////////////////DEPOSIT////////////////////////
    function testMappingUpdatesAfterDepositingSomeAmount() public {
        vm.prank(USER);
        lb.deposit(AMT_WETH);
        console.log(lb.getUser(USER).deposit);
        assert(lb.getUser(USER).deposit == 100);
    }

    /////////////////BORROW//////////////////////////
    function testRevertIfBorrowAmountLargerThanCollateral() public {
        // 100000000000000000000 eth --> 100 weth --> 1 eth = 2000 usdc --> maxborrow = 1,00,000 usdc --> 1,00,000e6
        vm.prank(USER);

        vm.expectRevert(LendingBorrowing.LendingBorrowing__NotEnoughCollateral.selector);
        lb.borrow(TEST_AMT, AMT_WETH);
        console.log(usdc.balanceOf(USER));
        console.log(usdc.balanceOf(address(this)));
        console.log(lb.getUser(USER).collateral);
        console.log(lb.getWEthPrice());
        console.log(usdc.balanceOf(USER));
        console.log(lb.getUser(USER).debt);
        console.log(lb.getUser(USER).deposit);
    }

    //////////////////REPAY///////////////////
    function testRevertIfRepayAmountIsMoreThanAmountToPay() public {
        vm.prank(USER);
        lb.borrow(AMT_USDC, AMT_WETH);
        console.log(lb.getUser(USER).debt);
        vm.warp(block.timestamp + (60 * 60 * 24 * 365));
        vm.roll(block.number + 1);
        console.log(lb.getUser(USER).debt);
        console.log(lb.getUser(USER).isBorrower);
        console.log(lb.calculateDebtWithInterest(USER));
        vm.expectRevert(LendingBorrowing.LendingBorrowing__DoNotOverpay.selector);
        lb.repay((AMT_USDC + (AMT_USDC * 8) / 100), USER); // after one year --> interest = AMT_USDC * INTEREST_RATE
        console.log(lb.getUser(USER).debt);
        console.log(usdc.balanceOf(USER));
    }

    ////////////////// LIQUIDATION //////////////////
    function testLiquidationHappensWhenDebtExceedsCollateral() public {
        vm.prank(USER);
        lb.borrow(TEST_AMT, AMT_WETH);

        vm.warp(block.timestamp + (60 * 60 * 24 * 365));
        vm.roll(block.number + 1);

        console.log(lb.getUser(USER).debt);
        console.log(lb.getUser(USER).deposit);
        console.log(lb.getUser(USER).collateral);
        console.log(lb.getWEthPriceInUsd(100));
        console.log(lb.calculateDebtWithInterest(USER));
        console.log(lb.getAmountToBeCoveredInUsd(USER));

        vm.prank(USER);
        lb.liquidation(USER);

        console.log(lb.getUser(USER).debt);
        console.log(lb.getUser(USER).deposit);
        assert(lb.getUser(USER).debt == 0);
    }

    ////////////////// WITHDRAW //////////////////
    function testFullWithdrawSucceedsIfNoDebt() public {
        vm.prank(USER);
        lb.deposit(AMT_WETH);

        vm.prank(USER);
        lb.withdraw(AMT_WETH, USER);

        console.log(weth.balanceOf(USER));
        assert(weth.balanceOf(USER) == INITIAL_BALANCE_WETH);
    }

    ////////////////// PARTIAL WITHDRAW //////////////////
    function testPartialWithdrawReducesDepositCorrectly() public {
        vm.prank(USER);
        lb.deposit(AMT_WETH);

        vm.prank(USER);
        lb.withdraw(AMT_WETH / 2, USER);

        console.log(lb.getUser(USER).deposit);
        assert(lb.getUser(USER).deposit == AMT_WETH / 2);
    }
}
