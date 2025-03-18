//SPDX-License-Identifer: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LendingBorrowing {
    IERC20 public token1;
    IERC20 public token2;
    
    mapping(address => uint256) public s_borrow;           //manage borrowed amounts by users
    mapping(address => uint256) public s_deposit;          //manage deposits by users
    mapping(address => uint256) public s_collateral;       //manage collateral given by borrowers

    uint256 public constant LENDING_INTEREST = 3;  // 3%
    uint256 public constant COLLATERALIZATION_RATIO = 200; // 200%

    constructor(address _token1, address _token2) {
        token1 = IERC20(_token1);       //token1 can be deposited
        token2 = IERC20(_token2);       //token2 can be borrowed
    }

    function deposit() public {}

    function giveCollateral(uint256 _amount) public {
        s_collateral[msg.sender] += _amount;
    }

    function borrow() public {}

    function repay() public {}

    function liquidation() public {}
}