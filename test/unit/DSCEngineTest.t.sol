// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console, stdError} from "lib/forge-std/src/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol"; // 配置工具合约，提供测试网或本地 Mock 地址
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    //////////////////
    // Price Tests //
    //////////////////

    /**
     * @notice 测试getUsdValue函数的正确性
     * @dev 这个测试验证DSCEngine合约能够正确计算抵押品代币的美元价值
     *
     * 测试步骤：
     * 1. 定义要测试的ETH数量（15 ETH）
     * 2. 根据预期价格（$2000/ETH）计算预期USD价值（15 * 2000 = $30000）
     * 3. 调用DSCEngine的getUsdValue函数获取实际USD价值
     * 4. 验证实际价值与预期价值相等
     * 5. 输出调试信息
     */
    function testGetUsdValue() public {
        // 定义测试参数：要转换的ETH数量（15 ETH，单位为wei）
        uint256 ethAmount = 15e18; // 15 ETH，其中1 ETH = 1e18 wei

        // 预期结果：根据MockV3Aggregator中设置的价格$2000/ETH
        // 15 ETH * $2000/ETH = $30000（以DSC精度表示，即1 USD = 1e18）
        uint256 expectedUsd = 30000e18; // $30000，以1e18精度表示

        // 调用被测试函数：计算15 ETH对应的USD价值
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);

        // 验证结果：确保计算的USD价值与预期一致
        assertEq(actualUsd, expectedUsd, "Calculated ETH USD value does not match expected");

        // 输出调试信息：显示实际值和预期值，便于分析
        console.log("actualUsd:", actualUsd, "expectedUsd:", expectedUsd);
    }

    //////////////////////////////
    // deposittCollateral Tests //
    //////////////////////////////

    /**
     * @notice 测试存入零抵押品时的错误处理
     * @dev 这个测试验证DSCEngine合约正确拒绝存入零数量的抵押品
     *
     * 测试步骤：
     * 1. 使用vm.startPrank切换到USER账户
     * 2. 授权DSCEngine合约使用用户的WETH
     * 3. 设置期望的错误：DSCEngine__NeedsMoreThanZero
     * 4. 尝试存入0 WETH（应该失败）
     * 5. 停止模拟USER账户
     *
     * 安全性意义：
     * 防止用户执行无意义的操作，确保所有抵押品操作都有实际价值
     */
    function testIfRevertCollateralZero() public {
        // 步骤1: 开始模拟USER账户
        // 这使得所有后续操作都以USER的身份执行
        vm.startPrank(USER);

        // 步骤2: 授权DSCEngine合约使用用户的WETH
        // ERC20代币需要先授权（approve），合约才能调用transferFrom
        // 这里授权DSCEngine可以使用最多AMOUNT_COLLATERAL数量的WETH
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        // 步骤3: 设置期望的错误
        // vm.expectRevert告诉测试框架下一个操作应该回滚，
        // 并且应该抛出指定的错误
        // DSCEngine.DSCEngine__NeedsMoreThanZero.selector是错误的函数选择器
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);

        // 步骤4: 尝试存入0 WETH
        // 这应该触发moreThanZero修饰符检查，
        // 当amount=0时，修饰符会调用revert DSCEngine__NeedsMoreThanZero()
        dsce.depositCollateral(weth, 0); // 存入0 WETH，应该失败

        // 步骤5: 停止模拟USER账户
        // 这是一个好的实践，确保不会意外影响其他测试
        vm.stopPrank();
    }

    /**
     * @notice 测试正常存入抵押品的流程
     * @dev 这个测试验证DSCEngine合约能够正确处理正常的抵押品存入操作
     *
     * 测试步骤：
     * 1. 记录用户初始WETH余额
     * 2. 使用vm.startPrank切换到USER账户
     * 3. 授权DSCEngine合约使用用户的WETH
     * 4. 存入指定数量的WETH作为抵押品
     * 5. 验证用户WETH余额减少
     * 6. 停止模拟USER账户
     *
     * 安全性意义：
     * 确保抵押品存入流程按预期工作，是整个稳定币系统的基础
     */
    function testDepositCollateralWorks() public {
        // 记录用户初始WETH余额
        uint256 initialBalance = ERC20Mock(weth).balanceOf(USER);

        // 开始模拟USER账户
        vm.startPrank(USER);

        // 授权DSCEngine合约使用用户的WETH
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        // 存入抵押品
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // 停止模拟USER账户
        vm.stopPrank();

        // 验证用户WETH余额减少了正确的数量
        uint256 finalBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(initialBalance - finalBalance, AMOUNT_COLLATERAL, "USER WETH balance did not decrease correctly");
    }

    /**
     * @notice 测试存入未授权抵押品的错误处理
     * @dev 这个测试验证DSCEngine合约正确拒绝存入未授权的抵押品
     *
     * 测试步骤：
     * 1. 创建一个未注册的ERC20代币
     * 2. 使用vm.startPrank切换到USER账户
     * 3. 授权DSCEngine合约使用用户的未注册代币
     * 4. 尝试存入未注册的代币（应该失败）
     * 5. 停止模拟USER账户
     *
     * 安全性意义：
     * 确保只有预定义的抵押品代币能被系统接受，防止意外风险
     */
    function testDepositCollateralRevertsWithInvalidToken() public {
        // 创建一个未注册的ERC20代币
        ERC20Mock invalidToken = new ERC20Mock("Invalid", "INV", USER, 100 ether);

        // 开始模拟USER账户
        vm.startPrank(USER);

        // 授权DSCEngine合约使用用户的未注册代币
        invalidToken.approve(address(dsce), 10 ether);

        // 尝试存入未注册的代币（应该失败）
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(invalidToken), 10 ether);

        // 停止模拟USER账户
        vm.stopPrank();
    }

    //////////////////////////////
    // Constructor Tests //
    //////////////////////////////

    /**
     * @notice 测试构造函数中代币地址与价格源地址不匹配时的错误处理
     * @dev 这个测试验证DSCEngine合约在初始化时，当代币地址数组与价格源地址数组长度不一致时会正确回滚
     *
     * 测试步骤：
     * 1. 创建两个不同长度的数组（代币地址和价格源地址）
     * 2. 尝试部署DSCEngine合约
     * 3. 验证部署失败并抛出正确错误
     *
     * 安全性意义：
     * 确保每个抵押品代币都有对应的价格源，防止运行时错误
     */
    function testConstructorRevertsWithMismatchedArrayLengths() public {
        // 创建代币地址数组（包含2个地址）
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = weth;
        tokenAddresses[1] = makeAddr("wbtc");

        // 创建价格源地址数组（只包含1个地址，长度不匹配）
        address[] memory priceFeedAddresses = new address[](1);
        priceFeedAddresses[0] = ethUsdPriceFeed;

        // 尝试部署DSCEngine合约（应该失败，因为数组长度不匹配）
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    address[] public tokenAddresses2;
    address[] public priceFeedAddresses2;

    function testRevertsIfTokenLengthDoesntMatchPriceeFeeds() public {
        tokenAddresses2.push(weth);
        priceFeedAddresses2.push(ethUsdPriceFeed);
        priceFeedAddresses2.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses2, priceFeedAddresses2, address(dsc));
    }

    function testGetTokenAmountFromUsd_ReturnsCorrectAmount() public {
        // ========== Step 1: Arrange ==========
        uint256 usdAmountInWei = 100e18; // $100 USD
        uint256 expectedEthAmount = 0.05 ether; // 预期：0.05 ETH（假设ETH=$2000）

        // ========== Step 2: Act ==========
        uint256 actualEthAmount = dsce.getTokenAmountFromUsd(weth, usdAmountInWei);

        // ========== Step 3: Assert ==========
        assertEq(actualEthAmount, expectedEthAmount, "Token amount calculation is incorrect");

        console.log("USD Amount:", usdAmountInWei / 1e18);
        console.log("Expected ETH:", expectedEthAmount / 1e18);
        console.log("Actual ETH:", actualEthAmount / 1e18);
    }

    //usd转weth价格
    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100e18;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
        console.logUint(expectedWeth);
    }

    //报错存入没有授权的抵押贷币
    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMInted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMInted, totalDscMinted);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
        console.log(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    /**
     * @notice 测试用户能够成功赎回已存入的抵押品
     * @dev 这个测试验证DSCEngine合约能够正确处理抵押品赎回操作
     *
     * 测试流程：
     * 1. 使用depositedCollateral修饰符设置前置条件：用户已存入10 WETH作为抵押品
     * 2. 记录赎回前用户的WETH余额
     * 3. 赎回一半的抵押品（5 WETH）
     * 4. 验证用户余额增加了正确的数量
     * 5. 验证系统记录的抵押品价值更新正确
     *
     * 安全性意义：
     * 确保用户能够正常取回自己的抵押品，是协议基础功能的重要测试
     */
    function testCanRedeemCollateral() public depositedCollateral {
        uint256 initialBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 redeemAmount = AMOUNT_COLLATERAL / 2;

        vm.startPrank(USER);
        dsce.redeemCollateral(address(weth), redeemAmount);
        vm.stopPrank();

        uint256 finalBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(finalBalance - initialBalance, redeemAmount);
        console.log(finalBalance, initialBalance, redeemAmount);

        (, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedRemainingValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL - redeemAmount);
        assertEq(expectedRemainingValue, collateralValueInUsd);
        console.log(expectedRemainingValue, collateralValueInUsd);
    }

    /**
     * @notice 测试burnDsc函数的基本功能
     * @dev 验证用户可以成功销毁DSC代币，并更新债务记录
     *
     * 测试步骤：
     * 1. 用户先存入抵押品并铸造DSC
     * 2. 用户调用burnDsc函数销毁部分DSC
     * 3. 验证用户的DSC余额和债务记录正确更新
     * 4. 验证DSC总供应量减少
     */
    // function testBurnDscWorks() public {
    //     // 提示：先存入抵押品并铸造DSC
    //     // 使用depositCollateralAndMintDsc函数
    //     // 然后调用burnDsc函数
    //     // 验证：s_DSCMinted[msg.sender]减少，用户DSC余额减少
    //     // 提示：使用assertEq断言验证预期结果
    // }

    function testBurnDscWorks() public depositedCollateral {
        uint256 amountDscToMint = 5 ether;
        uint256 amountDSCToBUrn = 2 ether;

        vm.startPrank(USER);
        dsce.mintDsc(amountDscToMint);
        dsc.approve(address(dsce), amountDscToMint);
        uint256 initialUSERDscBalance = dsc.balanceOf(USER);

        (uint256 initialDscBalance,) = dsce.getAccountInformation(USER);
        dsce.burnDsc(amountDSCToBUrn);

        uint256 finalUSERDscBalance = dsc.balanceOf(USER);
        assertEq(finalUSERDscBalance, initialUSERDscBalance - amountDSCToBUrn);

        vm.stopPrank();
        console.log(finalUSERDscBalance, initialUSERDscBalance, amountDSCToBUrn);
    }

    function testBurnDscRevertWhenAmountIsZero() public depositedCollateral {
        uint256 amountDscMint = 10 ether;

        vm.startPrank(USER);
        dsc.approve(address(dsce), amountDscMint);
        dsce.mintDsc(amountDscMint);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);

        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();

        uint256 USERBalance = dsc.balanceOf(USER);
        assertEq(USERBalance, amountToMint);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
        console.log(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
}
