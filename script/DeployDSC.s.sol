// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// 导入 Foundry 脚本基类，用于编写部署逻辑
import {Script} from "forge-std/Script.sol";

// 导入项目核心合约
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol"; // 自定义的去中心化稳定币（类似 DAI）
import {DSCEngine} from "../src/DSCEngine.sol"; // 稳定币的铸币/抵押引擎（核心逻辑）
import {HelperConfig} from "../script/HelperConfig.s.sol"; // 配置工具合约，提供测试网或本地 Mock 地址

/// @title DeployDSC
/// @notice 该脚本用于部署去中心化稳定币系统（DSC + DSCEngine），
///         并正确设置它们之间的依赖关系和权限。
contract DeployDSC is Script {
    // 存储支持的抵押品代币地址列表（如 WETH、WBTC）
    address[] public tokenAddresses;

    // 存储对应的价格预言机地址列表（如 WETH/USD、WBTC/USD）
    address[] public priceFeedAddresses;

    /// @notice 主部署函数，由 Forge 脚本调用（如 `forge script DeployDSC --broadcast`）
    /// @return (dsc, engine) 返回已部署的稳定币和引擎实例，便于后续测试或验证
    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        // 创建 HelperConfig 实例以获取当前网络的配置
        HelperConfig config = new HelperConfig();

        // ⚠️ 注意：此处代码有误！应调用具体配置函数（如 getOrCreateAnvilEthConfig()）
        // 原代码写的是 config.activeNetworkConfig()，但 activeNetworkConfig 是状态变量，不是函数。
        // 正确写法应为：
        // HelperConfig.NetworkConfig memory networkConfig = config.getOrCreateAnvilEthConfig();
        // 然后解构 networkConfig 的字段。
        (
            address wethUsdPriceFeed, // WETH/USD Chainlink 预言机地址（真实或 Mock）
            address wbtcUsdPriceFeed, // WBTC/USD Chainlink 预言机地址
            address weth, // WETH 代币合约地址（真实或 Mock）
            address wbtc, // WBTC 代币合约地址
            uint256 deployerKey // 部署者私钥（用于交易签名）
        ) = config.activeNetworkConfig(); // ❌ 此行在当前 HelperConfig 中无法编译！

        // 将抵押品代币和价格预言机按顺序存入数组，供 DSCEngine 初始化使用
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        // 开始广播交易：后续所有合约部署将使用脚本中配置的私钥签名并上链
        vm.startBroadcast();

        // 1. 部署去中心化稳定币（DSC），初始无供应量，所有者为部署者（msg.sender）
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();

        // 2. 部署铸币引擎（DSCEngine），传入抵押品列表、价格预言机列表和 DSC 地址
        //    引擎需要知道：哪些资产可抵押、如何获取其价格、以及要铸造哪个稳定币
        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        // 3. 关键权限转移：将 DSC 合约的所有权从部署者转移给 DSCEngine
        //    ────────────────────────────────────────────────────────────────
        //    💡 为什么需要这一步？
        //    - DSC 合约通常继承自 Ownable（或类似权限控制），只有 owner 能调用 mint/burn。
        //    - 在去中心化稳定币系统中，**只有铸币引擎（DSCEngine）应该有权增发或销毁 DSC**，
        //      以确保用户只能通过抵押资产来铸造 DSC，防止随意增发导致脱锚。
        //    - 因此，部署后必须将 DSC 的 owner 从“部署者”改为“DSCEngine”。
        //    - 转移后，只有 DSCEngine 能调用 dsc.mint(...) 或 dsc.burn(...)。
        //    - 这是安全架构的关键设计：权限最小化 + 职责分离。
        //    ────────────────────────────────────────────────────────────────
        dsc.transferOwnership(address(engine));

        // 停止交易广播
        vm.stopBroadcast();

        // 返回部署好的合约实例（方便脚本后续使用或输出地址）
        return (dsc, engine, config);
    }
}
