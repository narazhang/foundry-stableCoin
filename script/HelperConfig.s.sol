// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/*
🧠 代码目标：这个合约叫 HelperConfig，是用来在不同网络（比如 Sepolia 测试网 or 本地 Anvil 开发链）中
           自动提供部署或测试所需的“配置信息”——比如预言机地址、代币地址、私钥等。
           它会根据当前所在的链（chainid）自动判断用真实地址还是自己部署 Mock 合约来模拟依赖项。
*/

// 📦 导入 Foundry 工具包中的 Script 基类（用于写部署脚本）
import {Script} from "forge-std/Script.sol";

// 🧪 导入两个 Mock 合约：用于在本地模拟 Chainlink 预言机和 ERC20 代币
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol"; // 模拟 Chainlink 价格预言机
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol"; // 模拟 WETH / WBTC 这类代币

/// @title HelperConfig
/// @notice 🛠️ 辅助配置工具合约：让部署脚本能“自适应”不同网络环境（真实测试网 or 本地开发链）
contract HelperConfig is Script {
    /// 🗂️ NetworkConfig 结构体：打包所有需要的配置项，方便传递
    struct NetworkConfig {
        address wethUsdPriceFeed; // 🔮 WETH 对 USD 的价格预言机地址（Chainlink）
        address wbtcUsdPriceFeed; // 🔮 WBTC 对 USD 的价格预言机地址
        address weth; // 💰 WETH 代币合约地址（Wrapped ETH）
        address wbtc; // 💰 WBTC 代币合约地址（Wrapped BTC）
        uint256 deployerKey; // 🔑 部署者私钥（用于脚本广播交易时签名）
    }

    // 📏 Chainlink 预言机通用精度：8 位小数（即 1 美元 = 100,000,000 单位）
    uint8 public constant DECIMALS = 8;

    // 💵 模拟 ETH 价格：2000 美元 → 放大 1e8 倍变成整数（因为 Solidity 不支持浮点）
    // 例如：2000 * 10^8 = 200,000,000,000
    int256 public constant ETH_USD_PRICE = 2000e8;

    // 💵 模拟 BTC 价格：1000 美元 → 同样放大 1e8
    int256 public constant BTC_USD_PRICE = 1000e8;

    // 🔑 Anvil 本地开发链默认账户 0 的私钥（Foundry 默认生成的前 10 个账户之一）
    // 这个私钥对应地址：0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // 🧠 缓存当前网络的配置，避免重复部署 Mock 合约（尤其在脚本多次调用时有用）
    NetworkConfig public activeNetworkConfig;

    /// 🚪 构造函数：一部署就自动判断当前在哪条链，并加载对应配置
    constructor() {
        // 🔍 chainid = 11155111 是 Sepolia 测试网的标识
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaErhConfig(); // 使用真实 Sepolia 地址
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig(); // 本地开发链 → 自己部署 Mock
        }
    }

    /// 🌐 获取 Sepolia 测试网的真实配置（需提前设置 .env 文件中的 PRIVATE_KEY）
    /// ⚠️ 注意：这里假设你已经在 .env 里写了 PRIVATE_KEY=你的私钥
    function getSepoliaErhConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            // 🔮 Chainlink 官方 Sepolia 上的 WETH/USD 预言机地址
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            // 🔮 Chainlink 官方 Sepolia 上的 WBTC/USD 预言机地址
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            // 💰 Sepolia 上的 WETH 合约（注意：这不是标准地址，可能是项目自定义的）
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            // 💰 Sepolia 上的 WBTC 合约（同样需确认是否为真实 WBTC）
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            // 🔑 从环境变量读取私钥（Foundry 的 vm.envUint 功能）
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    /// 🧪 在本地 Anvil 链上创建 Mock 合约（预言机 + 代币），并返回配置
    /// ✅ 如果已经创建过（缓存非零），就直接返回，避免重复部署（节省 gas & 时间）
    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        // 🔄 检查是否已初始化（防止多次部署）
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        // 📢 开启交易广播：接下来的所有合约部署都会被“真实上链”（用脚本私钥签名）
        vm.startBroadcast();

        // 🏗️ 部署 Mock 预言机（ETH/USD）：精度 8 位，价格 2000 美元
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);

        // 🏗️ 部署 Mock WETH 代币：名称"WETH"，符号"WETH"，初始给 msg.sender 发 1000 * 1e8 个（最小单位）
        // 注意：1000e8 = 1000 * 10^8 = 100,000,000,000（因为 WETH 通常也是 18 位？但这里 mock 可能设为 8 位！需看 ERC20Mock 实现）
        ERC20Mock wetMock = new ERC20Mock("WETH", "WETH", msg.sender, 1000e8);

        // 🏗️ 部署 Mock 预言机（BTC/USD）：价格 1000 美元
        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);

        // 🏗️ 部署 Mock WBTC 代币
        ERC20Mock btcMock = new ERC20Mock("WBTC", "WBTC", msg.sender, 1000e8);

        // 🛑 停止广播：后续操作不再上链（安全）
        vm.stopBroadcast();

        // 💾 缓存配置到 storage（activeNetworkConfig），下次调用直接返回
        activeNetworkConfig = NetworkConfig({
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            weth: address(wetMock),
            wbtc: address(btcMock),
            deployerKey: DEFAULT_ANVIL_KEY // 用 Anvil 默认私钥（无需 .env）
        });

        return activeNetworkConfig;
    }
}

/*
💡 小贴士：
- 这个合约本身不处理业务逻辑，而是“配置工厂”，供其他部署脚本（如 Deploy.s.sol）调用。
- 在本地测试时，它帮你一键搭建完整依赖环境（Mock 预言机 + Mock 代币）。
- 在 Sepolia 上，它直接使用真实地址，让你无缝切换环境。
- 使用 vm.startBroadcast() 是 Foundry 脚本的关键技巧：让合约部署像“用户操作”一样真实上链。
*/