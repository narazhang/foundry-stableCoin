// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 *   → 该系统被设计得尽可能简洁，并确保代币始终维持 1 枚代币 = 1 美元的锚定关系。
 *
 * This is a stablecoin with the properties:
 *   → 这是一种具备以下特性的稳定币：
 * - Exogenously Collateralized
 *   → - 由外生资产作为抵押（即抵押品来自系统外部，如 ETH、BTC）
 * - Dollar Pegged
 *   → - 锚定美元（价值与美元 1:1 挂钩）
 * - Algorithmically Stable
 *   → - 通过算法机制维持稳定性
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *   → 它类似于 DAI，但假设 DAI 没有治理机制、没有费用，并且仅由 WETH 和 WBTC 作为抵押 backing。
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *   → 我们的 DSC 系统必须始终保持"超额抵押"。在任何时刻，所有抵押品的总价值都不得低于所发行 DSC 的美元背书价值。
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 *   → @notice 本合约是去中心化稳定币系统的核心。它处理所有关于铸造(minting)和赎回(redeeming)DSC 的逻辑，以及存入和提取抵押品的操作。
 *
 * @notice This contract is based on the MakerDAO DSS system
 *   → @notice 本合约基于 MakerDAO 的 DSS(Dai Stablecoin System)系统构建。
 */

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "chainlink-brownie-contracts/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    //error//

    /// @notice 当函数要求传入的数值必须大于零（例如抵押数量、借出金额等），
    ///         但实际传入了 0 时抛出此错误。
    ///         用于防止无意义的操作，确保所有操作都有实际价值。
    error DSCEngine__NeedsMoreThanZero();

    /// @notice 在合约初始化时，如果传入的代币地址数组长度与价格预言机地址数组长度不一致，
    ///         则抛出此错误。
    ///         此检查确保每个支持的抵押代币都对应一个有效且唯一的 Chainlink 价格源。
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();

    /// @notice 当用户尝试使用未被系统允许的代币（即未在部署时注册的代币）作为抵押品时抛出。
    ///         只有在构造函数中明确注册并绑定价格预言机的代币才被视为合法抵押资产。
    error DSCEngine__NotAllowedToken();

    /// @notice 当 ERC20 代币转账失败时抛出（例如：从用户向引擎存入抵押品，或从引擎向用户发放 DSC）。
    ///         常见原因包括：余额不足、未授权（allowance 不足）、或代币合约本身拒绝转账。
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEnging_MintFailed();
    error DSCEnging_HealthFactorOk();
    error DSCEnging_HealthFactorNotImproved();

    uint256 private constant ADDITION_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Liquidation（清算） Threshold（阈值 / 临界线）
    uint256 private constant LIQUIDATION_PRECISION = 100; //Precision（精度）
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_BONUS = 10;

    // ============= 状态变量（State Variables） =============

    /// @notice 将支持的抵押代币地址映射到其对应的 Chainlink 价格预言机地址。
    ///         例如：s_priceFeeds[WETH] = WETH/USD 预言机地址。
    ///         此映射在构造函数中一次性初始化，之后不可修改。
    ///         用于快速获取抵押品的实时美元价格，以计算用户抵押价值。
    mapping(address token => address priceFeed) private s_priceFeeds;

    /// @notice 记录每个用户存入的各类抵押代币的数量。
    ///         结构为：s_collateralDeposited[用户地址][代币地址] = 存入数量（单位为代币最小精度，如 wei）。
    ///         例如：s_collateralDeposited[0xabc...][WETH] = 1e18 表示该用户存入了 1 WETH。
    ///         该数据用于：
    ///           - 计算用户总抵押价值（结合 s_priceFeeds）
    ///           - 验证用户提取抵押品时是否超额提取
    ///           - 计算健康因子（Health Factor）
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

    /// @notice 记录每个用户已铸造（借出）的 DSC 数量，即用户的债务余额。
    ///         单位：1 DSC = 1e18（遵循 ERC20 标准）。
    ///         系统要求：用户抵押品总价值（USD）必须始终 ≥ s_DSCMinted[user] * $1。
    ///         当用户偿还 DSC 时，此值会相应减少。
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    /// @notice 指向已部署的 DecentralizedStableCoin 合约的不可变引用。
    ///         使用 `immutable` 确保该地址只能在构造函数中设置一次，防止被篡改。
    ///         通过此接口，DSCEngine 可安全调用 DSC 合约的 mint() 和 burn() 方法，
    ///         实现向用户发放稳定币或销毁偿还的稳定币。
    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////
    // Events
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemedTo, address token, uint256 amount);

    //modifier//
    //抵押品的数量必须大于0 才能进行抵押
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    // 存入允许特定的代币地址
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // 🧱 构造函数：初始化 DSC Engine（去中心化稳定币引擎）
    // 👥 参数说明：
    //   - tokenAddresses: 支持作为抵押品的代币地址列表（如 WETH、WBTC 等）
    //   - priceFeedAddress: 对应每个代币的价格预言机（Chainlink）地址列表
    //   - dscAddress: 去中心化稳定币（DSC）合约的地址
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        // 🔒 安全检查：代币数量必须和价格预言机数量一致！
        //    比如你有 2 个代币，就必须提供 2 个对应的价格源，否则就出错。
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        // 🗺️ 建立“代币 → 价格预言机”的映射表
        //    例如：s_priceFeeds[WETH] = 0x123...（WETH 的 Chainlink 预言机地址）
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        // 💰 初始化 DSC（去中心化稳定币）合约接口
        //    把传入的 dscAddress 转成 DecentralizedStableCoin 合约对象，方便后续 mint/burn
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // 💳 存入抵押品函数（用户调用）
    // 📌 功能：用户把指定代币作为抵押品存入协议

    function depositCollateral(
        address tokenCollateralAddress, // 🪙 要存入的抵押代币地址（如 WETH）
        uint256 amountCollateral // 📏 存入的数量
    )
        public
        moreThanZero(amountCollateral) // 🚫 修饰器：确保存入数量 > 0
        isAllowedToken(tokenCollateralAddress) // 🛂 修饰器：确保该代币是协议支持的抵押品
        nonReentrant
        // 🔄 防重入锁：防止黑客通过回调重复调用（安全必备！）

    {
        // 📊 更新用户的抵押品余额
        //    s_collaterlDeposited[用户地址][代币地址] += 新增数量
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        // 🔔 发送事件日志（便于前端/链下监听）
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // 💸 从用户钱包中把代币转到本合约（Engine 合约）
        //    使用 ERC20 的 transferFrom：需要用户先 approve 本合约
        bool suc = IERC20(tokenCollateralAddress)
            .transferFrom(
                msg.sender, // 从谁转出（调用者）
                address(this), // 转给谁（本合约）
                amountCollateral // 转多少
            );

        // ❌ 如果转账失败（比如没授权或余额不足），直接回滚交易
        if (!suc) {
            revert DSCEngine__TransferFailed();
        }

        // ✅ 至此，用户成功存入抵押品，可以后续借 DSC 了！
    }

    /**
     * @notice 遵循CEI模式（先检查、后生效、再交互）
     * @param amountDscToMint 要铸造的去中心化稳定币数量
     * @notice 用户必须有超过最低阈值的抵押品价值
     */
    // mint(铸造) + Dsc(去中心化稳定币) → 铸造 DSC 代币(需先存入足额抵押品)
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEnging_MintFailed();
        }
    }

    // deposit(存入) + collateral(抵押品) + and(并) + mint(铸造) + Dsc(DSC代币)
    // → 存入抵押品并同时铸造 DSC(组合操作，提升用户体验)
    // 用户只需一次调用，即可完成“存 ETH → 借 DSC”两步
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress, // 🪙 抵押品地址（如 WETH）
        uint256 amountCollateral, // 📏 存多少抵押品
        uint256 amountDscToMint // 💵 想借多少 DSC
    ) external {
        // 第一步：存入抵押品（会触发 transferFrom，需用户授权）
        depositCollateral(tokenCollateralAddress, amountCollateral);

        // 第二步：铸造 DSC（内部会检查健康因子是否达标）
        mintDsc(amountDscToMint);

        // ✅ 成功！用户现在有 DSC 可用，同时抵押品已锁定
    }

    // 🏦 赎回抵押品函数：用户可取回已偿还债务对应的抵押物（如 DAI、ETH 等）
    // 🔑 函数名含义：redeem(赎回) + collateral(抵押品) → 赎回你存进去的抵押资产

    /**
     * @notice 允许用户从协议中提取指定数量的抵押品（前提是他们已经还清了对应债务）
     * @param tokenCollateralAddress 抵押品代币的合约地址（例如 WETH、DAI 等）
     * @param amountCollateral 要赎回的抵押品数量（单位：wei 或最小单位）
     */
    function redeemCollateral(
        address tokenCollateralAddress, // 🪙 抵押品代币地址（比如 0x...WETH）
        uint256 amountCollateral // 💰 要取回多少（必须 > 0，由修饰器保证）
    )
        public // 👥 任何人都能调用（但只能取自己的）
        moreThanZero(amountCollateral) // ✅ 修饰器：确保 amountCollateral > 0，防无效操作
        nonReentrant // 🛡️ 防重入攻击（避免在转账回调中被恶意重复调用）

    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        // ✅ 成功！用户收到抵押品，协议中的记录也已更新
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 🧨 burnDsc 函数：销毁 DSC 代币（常用于用户偿还债务前，先销毁自己手里的 DSC）
    // 🔥 功能说明：
    //    用户调用此函数，会从自己的“已铸造 DSC 额度”中减去 amount，
    //    并将 amount 数量的 DSC 从用户钱包转到合约地址，然后彻底销毁。
    //    销毁后，系统总流通量减少，有助于降低用户的债务风险。
    //
    // ⚠️ 注意：这不是直接还债！而是“准备还债”的一步 —— 先销毁 DSC，再调用 repay() 才真正减少抵押债务。

    function burnDsc(uint256 amount)
        public // ✅ 任何人都能调用（但通常只有 mint 过 DSC 的用户才有意义）
        moreThanZero(amount) // 🚫 要求 amount > 0（防止无意义操作）
        nonReentrant // 🔒 防重入锁（避免黑客通过回调反复调用造成漏洞）

    {
        _burnDsc(amount, msg.sender, msg.sender);

        // 🩺 第四步：检查用户健康因子（Health Factor）是否仍安全
        //         健康因子 = 抵押品价值 / 债务价值
        //         销毁 DSC 相当于减少债务（虽然还没正式还），所以理论上健康因子会上升
        //         但为了保险起见，还是检查一下 —— 如果反而变差了（比如计算逻辑有误），就回滚交易
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 🔄 redeemCollateralForDsc 函数：用销毁 DSC 的方式，赎回部分抵押品
    // 💡 场景说明：
    //    用户之前用抵押品（如 WETH）借出了 DSC 代币。
    //    现在想拿回一部分抵押品？可以！但必须先“销毁”等值的 DSC（相当于提前还债），
    //    然后再赎回对应价值的抵押资产。
    //
    // 🔗 这是一个组合操作：先 burn DSC → 再取回抵押物，保证系统始终安全（不会超额赎回）

    function redeemCollateralForDsc(
        address tokenCollateralAddress, // 🪙 抵押品代币地址（例如：WETH、WBTC 等）
        uint256 amountCollateral, // 💰 想赎回的抵押品数量（必须 > 0，由调用方或修饰器保证）
        uint256 amountDscToBurn // 🔥 要销毁的 DSC 数量（代表你“还”的债务额度）
    )
        external
    {
        // ✅ 只能由外部账户或合约调用（不能被内部直接调用）

        // 🔥 第一步：销毁指定数量的 DSC
        //         - 会从 msg.sender 手中 transfer 并 burn 掉 amountDscToBurn 的 DSC
        //         - 同时减少该用户的 s_DSCMinted 记录
        //         - 并检查健康因子是否仍安全（防止销毁后反而资不抵债？虽然罕见但防御性编程）
        burnDsc(amountDscToBurn);

        // 📦 第二步：赎回指定数量的抵押品
        //         - 从协议的抵押池中取出 amountCollateral 数量的 tokenCollateralAddress 代币
        //         - 发送给 msg.sender
        //         - 此操作通常也会检查：剩余抵押是否仍足以覆盖未偿还债务（即健康因子）
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /*
    📌 关键逻辑 & 安全设计：
    1️⃣ **顺序很重要**：必须先销毁 DSC（降低债务），再赎回抵押品（减少担保）。
       如果反过来，可能瞬间导致抵押不足 → 被清算！

    2️⃣ **经济对等性**：理想情况下，amountDscToBurn 对应的债务价值 ≈ amountCollateral 的抵押价值。
       （实际由价格预言机 + 风险参数控制，函数内部可能通过 _revertIfHealthFactorIsBroken 间接校验）

    3️⃣ **用户责任**：用户需确保自己有足够的 DSC 余额并已授权给 DSCEngine，否则 burnDsc 会失败。

    4️⃣ **不是免费午餐**：这不是套利！你只是拿回自己之前锁进去的资产，前提是先“还债”（burn DSC）。

    🎨 举个栗子🌰：
    - 你抵押了 1 WETH（值 $2000），mint 了 1000 DSC（假设 1 DSC = $1，且 LTV=50%）
    - 现在你想拿回 0.3 WETH（$600）？那你至少要先 burn 掉 600 DSC（相当于还 $600 债）
    - 调用此函数：redeemCollateralForDsc(WETH, 0.3e18, 600e18)
    - 成功后：你钱包多了 0.3 WETH，少了 600 DSC；协议里你的债务和抵押都相应减少。
    */

    /**
     * @param collateral：要从用户那里清算的 ERC20 抵押品代币地址
     * @param user：健康因子（Health Factor）已经跌破最低阈值的用户
     * @param debtToCover：你想通过销毁多少 DSC 来"改善"该用户的健康因子
     * @notice 你可以部分清算一个用户（不一定要全部拿走）
     * @notice 你会因为拿走用户的资产而获得一笔"清算奖励"
     * @notice 这个函数假设协议整体是大约 200% 的超额抵押，这样才能正常运行
     * @notice 已知的一个漏洞是：如果协议只做到 100% 或更少的抵押，我们就无法激励清算人来干活
     * @notice 比如说，如果抵押品价格暴跌得太快，还没等任何人被清算，系统就已经崩了
     */
    /**
     * @notice 清算函数：当用户的健康因子低于最低阈值时，允许清算人代偿债务并获取抵押品
     *
     * @param collateral       抵押品代币地址（如 WETH、WBTC）
     * @param user             被清算的用户地址（健康因子已跌破最低阈值）
     * @param debtToCover      清算人打算偿还的债务金额（以 USD 计价，单位 wei）
     *
     * 工作流程：
     * 1. 检查被清算用户是否真的处于可清算状态（健康因子 < 1）
     * 2. 计算覆盖指定债务需要的抵押品数量
     * 3. 计算清算奖励（激励清算人参与系统维护）
     * 4. 执行清算：转移抵押品给清算人，销毁相应DSC
     * 5. 验证清算后用户健康因子是否得到改善
     * 6. 检查清算人自身的健康因子是否安全
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover) // 🛑 要求债务偿还金额 > 0，防止无意义操作
        nonReentrant // 🔒 防重入攻击，避免在回调函数中被恶意递归调用

    {
        // 🔍 第一步：检查用户是否真的处于可清算状态
        uint256 startingUserHealthFactor = _healthFactor(user);
        // 健康因子计算公式：(抵押品价值 * 清算阈值) / 已铸造DSC数量
        // 如果健康因子 < 1e18（即1.0），表示用户抵押品不足以覆盖其债务

        // ❌ 如果健康因子 ≥ 1.0，说明用户还未达到清算条件，不能执行清算
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEnging_HealthFactorOk(); // 抛出错误：健康因子正常，禁止清算
        }
        // MIN_HEALTH_FACTOR 是一个常量 = 1e18，表示最低健康因子阈值

        // 💱 第二步：将要偿还的 USD 债务金额转换为对应抵押品的数量
        // 例如：偿还 100 USD 的债务，当前 WETH 价格为 2000 USD/WETH → 需要 0.05 WETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // getTokenAmountFromUsd 函数实现：
        // return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITION_FEED_PRECISION);
        // 这个函数考虑了代币价格和精度差异，确保计算准确

        // 🎁 第三步：计算清算奖励（额外给清算人的抵押品）
        // 清算奖励的设计目的：激励清算人积极参与系统维护，保持系统健康
        // 奖励计算公式：(基础抵押品数量 * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION
        // LIQUIDATION_BONUS = 10, LIQUIDATION_PRECISION = 100 → 奖励率为 10%
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // 举例：tokenAmountFromDebtCovered = 100 单位 → 奖励 = (100 * 10) / 100 = 10 单位

        // 📦 第四步：计算清算人总共能获得的抵押品数量 = 基础抵押品 + 奖励
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // 🔄 第五步：执行抵押品转移操作
        // 从被清算用户账户中扣除抵押品，转移给清算人
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        // _redeemCollateral 函数内部执行：
        // 1. 更新用户的抵押品余额映射：s_collateralDeposited[from][token] -= amount在·
        // 2. 发出事件：emit CollateralRedeemed(from, to, token, amount)
        // 3. 执行实际代币转账：IERC20(token).transfer(to, amount)

        // 🔥 第六步：销毁相应数量的 DSC 代币
        // 清算人支付 DSC 来偿还部分债务，系统销毁这些 DSC
        _burnDsc(debtToCover, user, msg.sender);
        // _burnDsc 函数内部执行：
        // 1. 减少用户的债务记录：s_DSCMinted[onBehalfOf] -= amountDscToBurn
        // 2. 从清算人转移 DSC 到合约：i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn)
        // 3. 销毁这些 DSC：i_dsc.burn(amountDscToBurn)

        // 🩺 第七步：验证清算后用户的健康因子是否得到改善
        uint256 endingUserHealthFactor = _healthFactor(user);
        // 如果清算后用户的健康因子没有提高（甚至恶化），说明清算过程有问题
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEnging_HealthFactorNotImproved(); // 抛出错误：健康因子未改善
        }
        // 正常情况下，减少债务应该提高健康因子

        // 🛡️ 第八步：检查清算人自身的健康因子是否安全
        // 确保清算人在参与清算后不会因为持有过多抵押品而陷入风险
        _revertIfHealthFactorIsBroken(msg.sender);
        // 如果清算人的健康因子 < MIN_HEALTH_FACTOR，交易将被回滚
    }

    // get(获取) + Health(健康) + Factor(因子) → 获取账户健康因子(= 抵押品价值 / 债务价值；>1 安全，<1 可被清算)
    function getHealthFactor() external view returns (uint256) {}

    //============= Private and Internal Functions =============

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        // 📉 第一步：从用户的“已铸造 DSC 总量”记录中减去 amount
        //         s_DSCMinted 是一个 mapping(address => uint256)，记录每个用户 mint 了多少 DSC
        //         如果用户没 mint 过或要销毁的数量超过已 mint 量，这里会下溢 → 触发 revert（因为 Solidity 0.8+ 默认检查溢出）
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        // 💸 第二步：从用户钱包中把 amount 数量的 DSC 转到本合约
        //         因为 DSC 是 ERC20 代币，必须先授权（approve）本合约才能 transferFrom
        //         如果用户没授权 or 余额不足 → transferFrom 返回 false
        bool suc = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!suc) {
            revert DSCEngine__TransferFailed(); // ❌ 自定义错误：转账失败！请检查授权和余额
        }

        // 🔥 第三步：在 DSC 合约内部销毁这些代币（即从合约地址中永久移除）
        //         i_dsc 是 DSC 代币合约的接口实例
        //         burn() 通常是内部函数，但这里假设 DSC 合约允许外部调用者（如本合约）销毁自己持有的代币
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        // 📉 第一步：从用户的抵押品余额中扣除要赎回的数量
        // s_collateralDeposited 是一个 mapping: [用户地址 => [代币地址 => 数量]]
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        // 🔊 第二步：发出事件，便于链上追踪（如前端或区块浏览器监听）
        emit CollateralRedeemed(
            from, // 🧑 谁在赎回
            to,
            tokenCollateralAddress, // 🪙 赎回哪种代币
            amountCollateral // 💵 赎回多少
        );

        // 💸 第三步：把抵押品实际转给用户（调用 ERC20 的 transfer 方法）
        bool suc = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);

        // ❌ 第四步：如果转账失败（比如代币合约有 bug 或余额不足），就回滚交易
        if (!suc) {
            revert DSCEngine__TransferFailed(); // 自定义错误：转账失败！
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user]; // 📌 示例：s_DSCMinted[user] = 80e18 → 借了 80 DSC
        collateralValueInUsd = getAccountCollateralValue(user); // 📌 示例：返回 200e18 → 抵押品总值 $200
    }

    // 计算某个用户的“健康值”（Health Factor）
    // 健康值 > 1 表示安全，< 1 表示可能被清算（银行要收走抵押品）
    function _healthFactor(address user) private view returns (uint256) {
        // 第一步：获取这个用户的信息
        // totalDscMinted：用户总共借了多少 DSC（相当于借的钱）
        // collateralValueInUsd：用户抵押的资产当前值多少美元（比如 ETH 换算成 USD）
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        // 📌 示例：totalDscMinted = 80 * 1e18, collateralValueInUsd = 200 * 1e18
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    // 如果用户的健康因子被破坏（即抵押不足），则回滚交易
    // 1. Check health factor (do they have enough collateral?) 检查健康因子（他们是否有足够的抵押品？）
    // 2. Revert if they don't 如果没有，就回滚交易
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user); // 📌 示例：返回 1.25e18
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            // 📌 MIN_HEALTH_FACTOR = 1e18（即 1.0）
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
        // ✅ 1.25e18 >= 1e18 → 不 revert，交易继续
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        // 第二步：把抵押品的价值“打个折”，因为银行不能按原价信任它
        // 例如：抵押品值 100 美元，但银行只按 50% 计算（LIQUIDATION_THRESHOLD = 50）
        // LIQUIDATION_PRECISION = 100 是为了不用小数，用整数模拟百分比（50/100 = 50%）
        // 所以这里算出的是“银行真正认可的抵押价值”
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // 📌 示例：(200e18 * 50) / 100 = 100e18 → 协议只认可 $100 的抵押价值

        // 第三步：计算健康值 = （打折后的抵押价值） ÷ （借的 DSC 数量）
        // 但因为 Solidity 不支持小数，所以乘以一个 PRECISION（比如 1e18）来保留精度
        // 最终结果是一个放大了 PRECISION 倍的整数，外部调用时再除以 PRECISION 就能得到小数形式的健康值
        // 注意：这行目前是占位符（Placeholder），实际使用时需确保 totalDscMinted 不为 0，避免除零错误
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; // Placeholder
        // 📌 示例：(100e18 * 1e18) / 80e18 = (100 / 80) * 1e18 = 1.25e18 → 健康因子 = 1.25
    }

    // ============= Public and External View Function =============

    /**
     * 💵 辅助函数：将 USD 金额（以 wei 表示）转换为指定代币的数量
     *
     * @param token            目标代币地址（如 WETH）
     * @param usdAmountInWei   USD 金额（单位：wei，即 1 USD = 1e18）
     * @return                 对应的代币数量（按 PRECISION = 1e18 精度）
     *
     * 📌 举例：
     *   usdAmountInWei = 1e18 （= 1 USD）
     *   priceFeed 返回 price = 200000000000 （= 2000.00000000，因为 Chainlink 通常 8 位小数）
     *   则：
     *      result = (1e18 * 1e18) / (200000000000 * 1e10)
     *             = 1e36 / (2e11 * 1e10) = 1e36 / 2e21 = 5e14 → 即 0.0005 个代币（若代币精度为 1e18）
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // 🔗 获取该代币的价格喂价合约（来自 Chainlink）
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);

        // 📈 读取最新价格（注意：price 是 int256，且通常有 8 位小数）
        (, int256 price,,,) = priceFeed.latestRoundData();

        // ⚖️ 核心换算公式：
        //   代币数量 = (USD 金额 × 主精度) / (价格 × 喂价精度调整)
        //   => (usdAmountInWei * PRECISION) / (uint256(price) * ADDITION_FEED_PRECISION)
        //
        // 为什么乘 ADDITION_FEED_PRECISION？
        //   因为 Chainlink 的 price 已经是 price * 1e8，而我们希望最终结果在 1e18 精度下，
        //   所以需要再乘一个 1e10 来对齐：1e8 * 1e10 = 1e18 → 与 PRECISION 一致。
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITION_FEED_PRECISION);
    }

    /**
     * @notice 获取指定用户所有抵押资产的总美元价值（USD Value）
     * @dev 该函数遍历系统支持的所有抵押代币类型，累加用户在每种代币上的抵押价值。
     *      使用 Chainlink 预言机获取实时价格，并通过 getUsdValue() 完成单位换算。
     *      此函数为 view 函数，不修改状态，可安全被外部或前端调用。
     * @param user 要查询的用户地址
     * @return totalCollaterValueInUsd 用户所有抵押品按当前市场价格折算的总美元价值（单位：wei 级别，即 1 USD = 1e18）
     */
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollaterValueInUsd = 0;

        // 📌 假设 s_collateralTokens = [WETH, WBTC]
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];

            // 📌 示例：user 在 WETH 上存了 1 WETH → s_collateralDeposited[user][WETH] = 1e18
            uint256 amount = s_collateralDeposited[user][token];

            // 调用 getUsdValue 将代币数量转为 USD
            uint256 value = _getUsdValue(token, amount);
            // 📌 对 WETH：若 ETH 价格 = $2000 → getUsdValue 返回 2000e18
            // 📌 对 WBTC：若用户没存，amount=0 → value=0

            totalCollaterValueInUsd += value;
            // 📌 最终 total = 2000e18（仅 WETH）→ 但注意：在 _healthFactor 中我们简化为 $200 示例
            //    实际中可根据需要调整示例数值（如用 $200 代表测试场景）
        }

        return totalCollaterValueInUsd;
    }

    /**
     * @notice 将指定数量的抵押代币（如 WETH、WBTC）转换为其等值的美元金额（USD Value）
     * @dev 该函数通过 Chainlink 预言机获取代币的最新 USD 价格，并进行单位换算，
     *      确保最终返回的美元价值与 DSC 的精度一致（即 1 USD = 1e18）。
     * @param token 要估值的 ERC20 抵押代币地址（必须是系统已注册的合法抵押品）
     * @param amount 该代币的数量（单位为代币自身的最小单位，例如 wei）
     * @return uint256 对应的美元价值，以 DSC 的精度表示（1 USD = 1e18）
     */
    function _getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);

        (, int256 price,,,) = priceFeed.latestRoundData();
        // 📌 示例：ETH/USD 预言机返回 price = 200000000000（即 $2000.00，8 位小数）

        // Chainlink ETH/USD 通常 8 decimals → 需要补 10 位到 18 decimals
        // ADDITION_FEED_PRECISION = 1e10, PRECISION = 1e18
        return ((uint256(price) * ADDITION_FEED_PRECISION) * amount) / PRECISION;
        // 📌 代入：
        //   price = 200000000000          → $2000.00（8 decimals）
        //   ADDITION_FEED_PRECISION = 1e10
        //   amount = 1e18                 → 1 WETH
        //   计算：
        //     numerator = (200000000000 * 1e10) * 1e18 = 2e12 * 1e10 * 1e18 = 2e40
        //     denominator = 1e18
        //     result = 2e40 / 1e18 = 2e22 → ❌ 这不对！

        // ⚠️ 注意：上面推导有误！正确理解如下：
        // Chainlink price = 2000 * 1e8 = 2e11（不是 2e12！2000.00 × 1e8 = 200,000,000,000 = 2e11）
        // 所以：
        //   (2e11 * 1e10) = 2e21 → 再 * amount (1e18) = 2e39 → / 1e18 = 2e21 = 2000 * 1e18 ✅
        // 📌 最终返回 2000e18 → 正确！
    }

    // 获取指定用户的账户信息：已 mint 的 DSC 总量 和 抵押品的美元价值
    // 供外部调用（如前端、清算机器人）
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        // 调用内部私有函数 _getAccountInformation 执行实际逻辑
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    // 计算健康因子（Health Factor）——衡量用户头寸安全性的核心指标
    // 公式通常为：collateralValueInUsd / totalDscMinted
    // 健康因子 < MIN_HEALTH_FACTOR（如 1e18）表示可被清算
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure // 不读取状态变量，仅依赖输入参数
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    // 将指定数量的抵押品代币（如 WETH、WBTC）转换为美元价值
    // amount 单位是 token 的最小单位（如 wei），返回值为带精度的 USD（如 1e18 = $1）
    function getUsdValue(
        address token,
        uint256 amount // in WEI（即 token 的最小单位，例如 1 WETH = 1e18 wei）
    )
        external
        view // 需读取价格预言机状态
        returns (uint256)
    {
        return _getUsdValue(token, amount);
    }

    // 查询某用户在协议中存入的某种抵押品的数量
    // 数据来自状态变量 s_collateralDeposited[user][token]
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    // 返回协议内部使用的主精度常量（通常为 1e18）
    // 用于统一数值计算，避免浮点数
    function getPrecision() external pure returns (uint256) {
        return PRECISION; // 通常定义为 1e18
    }

    // 返回价格预言机数据的额外精度（如 Chainlink 通常为 1e8）
    // 用于在 USD 计算中对齐不同精度的数据源
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION; // 通常为 1e8（Chainlink 默认）
    }

    // 返回清算阈值（Liquidation Threshold），例如 50% → 用户最多借出抵押品价值的 50%
    // 实际值通常以精度表示，如 0.5 * PRECISION = 5e17
    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    // 返回清算奖励比例（Liquidation Bonus），例如 10% → 清算人可多拿 10% 抵押品
    // 通常以精度表示，如 1.1 * PRECISION = 1.1e18
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    // 返回清算计算中使用的精度（通常与 PRECISION 一致，用于内部计算一致性）
    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    // 返回最低健康因子阈值（Minimum Health Factor）
    // 当用户健康因子 ≤ 此值时，可被清算（通常为 1 * PRECISION = 1e18）
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    // 返回协议支持的所有抵押品代币地址列表
    // 例如 [WETH, WBTC]
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens; // s_ 前缀通常表示状态变量（state variable）
    }

    // 返回 DSC 稳定币合约的地址
    function getDsc() external view returns (address) {
        return address(i_dsc); // i_ 前缀通常表示不可变变量（immutable）
    }

    // 返回指定抵押品代币对应的价格预言机（price feed）地址
    // 例如 getCollateralTokenPriceFeed(weth) → 返回 ETH/USD Chainlink 地址
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token]; // s_priceFeeds 是 mapping(address => address)
    }

    // 返回指定用户的当前健康因子（实时计算）
    // 内部会调用 _getAccountInformation 并传给 _calculateHealthFactor
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user); // 通常是一个内部 view 函数，封装了完整计算流程
    }
}
