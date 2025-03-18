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
    uint256 public constant INITIAL_BALANCE = 1000 ;

    function setUp() public {
        deployer = new DeployLB();
        (lb, config) = deployer.run();
        (wethUsdPriceFeed,  _weth,  _usdc, ) = config.activeNetworkConfig();
        weth = ERC20Mock(_weth);
        usdc = ERC20Mock(_usdc);

        weth.mint(USER, INITIAL_BALANCE);
        usdc.mint(USER, INITIAL_BALANCE);

        weth.mint(address(this), INITIAL_BALANCE);
        usdc.mint(address(this), INITIAL_BALANCE);

        weth.approve(address(lb), type(uint256).max);
        usdc.approve(address(lb), type(uint256).max);

        vm.startPrank(USER);
        weth.approve(address(lb), type(uint256).max);
        usdc.approve(address(lb), type(uint256).max);
        vm.stopPrank();
    }
}