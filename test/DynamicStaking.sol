// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Token } from "src/Token.sol";
import { StakingInterface } from "src/interfaces/StakingInterface.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { console } from "forge-std/src/console.sol";

contract DynamicStaking is StakingInterface, AccessControl {
    bytes32 public constant TIMELOCK = keccak256("TIMELOCK");
    bytes32 public constant GAME = keccak256("GAME");

    Token public immutable token;

    constructor(address _token) {
        token = Token(_token);
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function totalStaked() external pure override returns (uint256) {
        return 0;
    }

    function totalStakers() external pure override returns (uint256) {
        return 0;
    }

    function getToken() external view override returns (address) {
        return address(token);
    }

    function getAddress() external view override returns (address) {
        return address(this);
    }

    function getStaked(address) external pure override returns (uint256) {
        return 0;
    }

    function reserveFunds(uint256 amount) external override onlyRole(GAME) {
        require(token.balanceOf(address(this)) * 5 / 100 >= amount, "DS01");
        token.transfer(_msgSender(), amount);
    }

    function addGame(address _game) external onlyRole(TIMELOCK) {
        _grantRole(GAME, _game);
    }

    function stake(address staker, uint256 amount) external view override {
        console.log("MOCK", staker, amount);
    }
}
