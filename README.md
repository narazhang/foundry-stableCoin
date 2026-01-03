# Foundry Stablecoin (DSC)

一个基于 Foundry 框架开发的去中心化超额抵押稳定币系统，类似于 MakerDAO 的 DAI，但设计更加简洁高效。

## 📋 目录

- [项目概述](#项目概述)
- [核心特性](#核心特性)
- [架构设计](#架构设计)
- [技术栈](#技术栈)
- [快速开始](#快速开始)
- [合约说明](#合约说明)
- [使用指南](#使用指南)
- [测试](#测试)
- [部署](#部署)
- [风险参数](#风险参数)
- [安全说明](#安全说明)
- [许可证](#许可证)

## 项目概述

DSC (Decentralized Stable Coin) 是一种完全由外生资产（ETH、BTC）作为抵押的美元稳定币。系统通过智能合约自动维护 1 DSC = 1 USD 的锚定关系，无需治理代币或人工干预。

### 设计理念

- **超额抵押**：始终保持抵押品价值 > 发行 DSC 的价值
- **无需治理**：完全算法化运行，无人工干预
- **零费用**：不收取任何铸造或赎回费用
- **多资产支持**：支持 WETH、WBTC 等多种抵押资产

## 核心特性

### ✨ 主要功能

- **存入抵押品**：支持存入 WETH、WBTC 等认可的抵押资产
- **铸造 DSC**：基于抵押品价值铸造稳定币（最高 LTV 为 50%）
- **赎回抵押品**：偿还 DSC 后取回抵押资产
- **清算机制**：健康因子 < 1 时可被清算，清算人获得 10% 奖励
- **实时价格**：通过 Chainlink 预言机获取实时市场价格

### 🛡️ 安全特性

- **重入保护**：使用 ReentrancyGuard 防止重入攻击
- **健康因子检查**：确保始终超额抵押
- **清算保护**：防止清算人不健康地参与清算
- **权限分离**：只有 DSCEngine 能铸造/销毁 DSC

## 架构设计

### 系统架构

```
┌─────────────────────────────────────────────────────────┐
│                    DSC 生态系统                            │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  用户 ────────────────────────────────────┐             │
│          │                                │             │
│          ▼                                │             │
│  ┌──────────────┐     ┌─────────────────┼────┐        │
│  │   WETH/WBTC  │────▶│    DSCEngine    │    │        │
│  │  (抵押资产)   │     │  (核心引擎合约)  │    │        │
│  └──────────────┘     │                 │    │        │
│                       │                 │    │        │
│  ┌──────────────┐     │  ┌───────────┐   │    │        │
│  │ Chainlink    │────▶│  │    DSC    │◀──┘    │        │
│  │ 预言机       │     │  │  稳定币    │         │        │
│  └──────────────┘     │  └───────────┘         │        │
│                       └─────────────────────────┘        │
└─────────────────────────────────────────────────────────┘
```

### 核心合约

1. **DecentralizedStableCoin.sol**
   - ERC20 标准的稳定币合约
   - 只能由 DSCEngine 调用 mint/burn
   - 1 DSC = 1 USD（18 位精度）

2. **DSCEngine.sol**
   - 系统核心引擎
   - 管理所有抵押品和债务
   - 计算健康因子
   - 处理清算逻辑

## 技术栈

- **开发框架**: Foundry (Forge, Cast, Anvil)
- **智能合约语言**: Solidity ^0.8.18
- **测试框架**: Foundry Test
- **预言机**: Chainlink Price Feeds
- **安全库**: OpenZeppelin Contracts

## 快速开始

### 环境要求

- Git
- Foundry (安装方法见下方)
- Node.js (可选，用于前端)

### 安装 Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 克隆仓库

```bash
git clone https://github.com/narazhang/foundry-stableCoin.git
cd foundry-stableCoin
forge install
```

### 编译合约

```bash
forge build
```

## 合约说明

### DecentralizedStableCoin

#### 函数

- `mint(address _to, uint256 _amount)` - 铸造 DSC（仅 DSCEngine 可调用）
- `burn(uint256 _amount)` - 销毁 DSC（仅 DSCEngine 可调用）

#### 参数

- **名称**: DecentralizedStableCoin
- **符号**: DSC
- **精度**: 18 decimals
- **初始供应**: 0

### DSCEngine

#### 核心参数

| 参数 | 值 | 说明 |
|------|------|------|
| LIQUIDATION_THRESHOLD | 50 | 清算阈值 50% |
| LIQUIDATION_BONUS | 10 | 清算奖励 10% |
| MIN_HEALTH_FACTOR | 1e18 | 最低健康因子 1.0 |
| PRECISION | 1e18 | 计算精度 |

#### 主要函数

| 函数 | 说明 |
|------|------|
| `depositCollateral(address, uint256)` | 存入抵押品 |
| `mintDsc(uint256)` | 铸造 DSC |
| `depositCollateralAndMintDsc(address, uint256, uint256)` | 存入抵押品并铸造 DSC |
| `redeemCollateral(address, uint256)` | 赎回抵押品 |
| `burnDsc(uint256)` | 销毁 DSC |
| `redeemCollateralForDsc(address, uint256, uint256)` | 用 DSC 赎回抵押品 |
| `liquidate(address, address, uint256)` | 清算不健康账户 |

#### 查询函数

| 函数 | 说明 |
|------|------|
| `getHealthFactor(address)` | 获取用户健康因子 |
| `getAccountInformation(address)` | 获取用户账户信息 |
| `getAccountCollateralValue(address)` | 获取用户抵押品总价值 |
| `getCollateralBalanceOfUser(address, address)` | 获取用户特定抵押品余额 |
| `getCollateralTokens()` | 获取支持的抵押品列表 |

## 使用指南

### 健康因子

健康因子（Health Factor）是衡量账户安全性的核心指标：

```
健康因子 = (抵押品价值 × 清算阈值) / 已铸造 DSC
```

- **健康因子 > 1**: 账户安全
- **健康因子 = 1**: 达到清算线
- **健康因子 < 1**: 可被清算

### 使用流程示例

#### 1. 存入抵押品并铸造 DSC

```javascript
// 假设 ETH 价格 = $2000
// 用户存入 1 WETH，最多可铸造 1000 DSC（50% LTV）

// 步骤 1: 授权 DSCEngine 使用用户的 WETH
await weth.approve(dscEngineAddress, ethers.parseEther("1"));

// 步骤 2: 存入 1 WETH 并铸造 500 DSC
await dscEngine.depositCollateralAndMintDsc(
  wethAddress,           // 抵押品地址
  ethers.parseEther("1"), // 1 WETH
  ethers.parseEther("500") // 500 DSC
);
```

#### 2. 偿还债务并赎回抵押品

```javascript
// 步骤 1: 授权 DSCEngine 使用用户的 DSC
await dsc.approve(dscEngineAddress, ethers.parseEther("500"));

// 步骤 2: 用 500 DSC 赎回 0.25 WETH
await dscEngine.redeemCollateralForDsc(
  wethAddress,           // 抵押品地址
  ethers.parseEther("0.25"), // 赎回 0.25 WETH
  ethers.parseEther("500")   // 销毁 500 DSC
);
```

#### 3. 清算不健康账户

```javascript
// 假设用户 A 的健康因子 < 1，清算 100 USD 债务
// 清算人获得: 基础抵押品 + 10% 奖励

// 步骤 1: 清算人准备好 DSC
await dsc.approve(dscEngineAddress, ethers.parseEther("100"));

// 步骤 2: 执行清算
await dscEngine.liquidate(
  wethAddress,           // 清算 WETH
  userAAddress,          // 被清算用户
  ethers.parseEther("100") // 清算 100 USD 债务
);
```

## 测试

### 运行所有测试

```bash
forge test
```

### 运行单元测试

```bash
forge test --match-path test/unit/DSCEngineTest.t.sol
```

### 运行模糊测试

```bash
forge test --match-path test/fuzz/
```

### 运行不变量测试

```bash
forge test --match-path test/fuzz/OpenInvariantsTest.t.sol
```

### Gas 快照

```bash
forge snapshot
```

### 查看测试覆盖率

```bash
forge coverage
```

### 测试统计

```bash
forge test --summary
```

## 部署

### 本地部署（Anvil）

```bash
# 1. 启动本地节点
anvil

# 2. 部署合约（新终端）
forge script script/DeployDSC.s.sol:DeployDSC --rpc-url http://localhost:8545 --broadcast
```

### Sepolia 测试网部署

```bash
# 1. 创建 .env 文件
echo "PRIVATE_KEY=your_private_key" > .env

# 2. 部署合约
forge script script/DeployDSC.s.sol:DeployDSC \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/your_api_key \
  --broadcast \
  --verify \
  -vvv
```

### 验证合约

```bash
forge verify-contract <contract_address> <contract_name> \
  --chain-id 11155111 \
  --watch
```

## 风险参数

### 系统参数

| 参数 | 值 | 描述 |
|------|------|------|
| 清算阈值 | 50% | 用户最多借出抵押品价值的 50% |
| 清算奖励 | 10% | 清算人额外获得的抵押品奖励 |
| 最低健康因子 | 1.0 | 账户必须维持的健康因子下限 |

### 价格预言机

系统使用 Chainlink 去中心化预言机获取实时价格：

- **ETH/USD**: Chainlink ETH/USD Price Feed
- **BTC/USD**: Chainlink BTC/USD Price Feed

## 安全说明

### 已实施的安全措施

1. **重入攻击防护**: 所有修改状态的函数都使用 `nonReentrant` 修饰器
2. **健康因子检查**: 铸造和赎回前自动验证账户健康状态
3. **清算保护**: 清算后验证被清算人健康因子是否改善
4. **零地址检查**: 防止向零地址转账
5. **输入验证**: 所有数值输入必须大于零

### 潜在风险

1. **预言机操纵**: 预言机价格被恶意操纵可能导致误清算
2. **快速脱锚**: 抵押品价格极速下跌可能导致系统无法及时清算
3. **黑天鹅事件**: 极端市场条件下可能面临系统性风险

### 审计状态

本项目仅供学习参考，未经过第三方安全审计。生产环境使用前必须进行全面安全审计。

## 常见问题

### Q: 为什么最低健康因子是 1？

A: 健康因子 = (抵押品价值 × 50%) / 债务。当健康因子 = 1 时，抵押品价值 = 债务 × 2，即 200% 抵押率，这是系统安全运行的最低要求。

### Q: 清算奖励为什么是 10%？

A: 10% 的奖励用于激励清算人及时参与清算，维持系统健康。这个数值需要在激励清算人和保护被清算人之间取得平衡。

### Q: 支持哪些抵押资产？

A: 目前支持 WETH 和 WBTC，未来可扩展支持更多 ERC20 抵押资产（如 USDC、DAI 等）。

### Q: 如何添加新的抵押资产？

A: 需要修改部署脚本，添加新资产的价格预言机地址，并重新部署 DSCEngine 合约。

## 贡献指南

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 参考资料

- [Foundry 文档](https://book.getfoundry.sh/)
- [Chainlink 预言机](https://docs.chain.link/)
- [MakerDAO DSS](https://github.com/makerdao/dss)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)

## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 作者

- Patrick Collins (原始设计)
- narazhang (项目实现)

## 免责声明

本项目仅供教育和研究目的使用。不构成任何投资建议。使用本合约涉及风险，请自行承担所有责任。

---

**⚠️ 重要提示**: 本项目目前处于开发阶段，未经过安全审计，请勿在主网使用真实资产进行测试！
