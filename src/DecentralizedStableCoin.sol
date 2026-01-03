// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Patrick Collins
 * Collateral: Exogenous (ETH & BTC)         // 抵押品：外生资产（ETH 和 BTC）
 * Minting: Algorithmic                      // 发行机制：算法发行
 * Relative Stability: Pegged to USD         // 相对稳定性：锚定美元（USD）
 *
 * This is the contract that is governed by the DSCEngine.
 * This contract is just the ERC20 implementation of our stablecoin system.
 *                                                       // 这是由 DSCEngine 管理的合约。
 *                                                       // 该合约仅是我们稳定币系统的 ERC20 实现。
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin_MustBeMoreThanZero();
    error DecentralizedStableCoin_BurnAmountExceedsBalances();
    error DecentralizedStableCoin_NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin_MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin_BurnAmountExceedsBalances();
        }

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin_NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin_MustBeMoreThanZero();
        }

        _mint(_to, _amount);

        return true;
    }
}
