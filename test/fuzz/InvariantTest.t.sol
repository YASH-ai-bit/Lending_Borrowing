//SPDX-License-Idetifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployLB} from "../../script/DeployLB.s.sol";
import {LendingBorrowing} from "../../src/LendingBorrowing.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract InvariantTest is Test {
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
        (wethUsdPriceFeed,  _weth,  _usdc, ) = config.activeNetworkConfig();
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

        targetContract(address(lb));
    }

    //test user never exceeds the loan to value ration of collateral factor
    function invariant_testCollateralizationRatio() public view {    
        uint256 maxRatio = lb.COLLATERAL_FACTOR();
        uint256 debt_Value = lb.getUser(USER).debt;                //usdc
        uint256 collateral_Value = lb.getUser(USER).collateral;    //weth
        assert(debt_Value == 0 || (debt_Value / (collateral_Value * lb.getWEthPrice())) <= maxRatio);
    }

    function invariant_forceLiquidationIfUnhealthy() public {
        vm.prank(USER);
        lb.borrow(AMT_USDC, AMT_WETH);

        assert(lb.getUser(USER).healthFactor >= lb.MIN_HEALTH_FACTOR() || lb.getUser(USER).debt == 0);

    }

}