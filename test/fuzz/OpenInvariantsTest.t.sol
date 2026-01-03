// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// 导入 Forge-Std 测试库
import {Test} from "forge-std/Test.sol";               // 基础测试功能（如 vm、assert 等）
import {StdInvariant} from "forge-std/StdInvariant.sol"; // 不变量模糊测试支持

// 导入项目相关合约和脚本
import {DeployDSC} from "../../script/DeployDSC.s.sol";     // 部署 DSC 协议的脚本
import {HelperConfig} from "../../script/HelperConfig.s.sol"; // 网络与代币配置工具
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol"; // DSC 稳定币
import {DSCEngine} from "../../src/DSCEngine.sol";         // 抵押借贷引擎
import {ERC20Mock} from "../mocks/ERC20Mock.sol";          // 可 mint 的测试用 ERC20 代币
import {Handler} from "../fuzz/Handler.t.sol";             // 模糊测试操作处理器（模拟用户行为）

// 定义不变量测试合约：继承 StdInvariant（启用模糊测试）和 Test（使用测试工具）
contract OpenInvariantsTest is StdInvariant, Test {
    // 状态变量：用于在测试中引用已部署的合约实例
    DeployDSC deployer;              // 部署脚本实例
    DSCEngine dsce;                  // DSCEngine 合约（核心逻辑）
    DecentralizedStableCoin dsc;     // DSC 稳定币合约
    HelperConfig helperConfig;       // 配置管理器
    Handler handler;                 // 操作处理器，用于生成模糊测试调用序列

    // 存储 WETH 和 WBTC 的合约地址（从配置中读取）
    address public weth;
    address public wbtc;

    // setUp() 是 Foundry 测试的初始化函数，在每个测试开始前自动运行一次
    function setUp() external {
        // 1. 创建部署脚本实例
        deployer = new DeployDSC();

        // 2. 执行部署脚本，返回已部署的 DSC、DSCEngine 和配置对象
        (dsc, dsce, helperConfig) = deployer.run();

        // 3. 从配置中提取 WETH 和 WBTC 地址
        // activeNetworkConfig() 返回：(ethPriceFeed, btcPriceFeed, weth, wbtc, ...)
        // 使用逗号忽略不需要的字段，只保留第3、4个（weth, wbtc）
        (,, weth, wbtc,) = helperConfig.activeNetworkConfig();

        // 4. 创建 Handler 实例，传入引擎和稳定币合约
        // Handler 将在模糊测试中模拟用户操作（如存款、mint DSC、清算等）
        handler = new Handler(dsce, dsc);

        // 5. 告诉 Foundry：模糊测试时，只对 Handler 合约的方法进行调用
        // 这是不变量测试的关键：通过 Handler 操作协议状态
        targetContract(address(handler));
    }

    // 不变量函数：验证协议始终满足“抵押品总价值 ≥ DSC 总供应量”
    // Foundry 会在每次 Handler 操作后自动调用此函数，确保不变量未被破坏
    function invariant_protocolMustHaveMoreValueThatTotalSupplyDollars() public view {
        // 1. 获取当前 DSC 稳定币的总发行量（单位：wei，1 DSC = 1e18 wei ≈ $1）
        uint256 totalSupply = dsc.totalSupply();

        // 2. 查询 DSCEngine 合约中锁定的 WETH 和 WBTC 数量
        uint256 wethDeposited = ERC20Mock(weth).balanceOf(address(dsce));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce)); 

        // 3. 将抵押品数量转换为美元价值（使用 DSCEngine 内部的价格预言机）
        uint256 wethValue = dsce.getUsdValue(weth, wethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

        // 4. 核心断言：协议持有的抵押品总价值必须 ≥ 已发行的 DSC 总量（以美元计）
        // 注意：使用 >= 而非 >，因为初始状态（0 >= 0）必须成立
        assert(wethValue + wbtcValue >= totalSupply);
    }
}