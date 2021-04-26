pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import {SAFEEngine} from 'geb/SAFEEngine.sol';
import {Coin} from 'geb/Coin.sol';
import {LiquidationEngine} from 'geb/LiquidationEngine.sol';
import {AccountingEngine} from 'geb/AccountingEngine.sol';
import {TaxCollector} from 'geb/TaxCollector.sol';
import {BasicCollateralJoin, CoinJoin} from 'geb/BasicTokenAdapters.sol';
import {OracleRelayer} from 'geb/OracleRelayer.sol';
import {EnglishCollateralAuctionHouse} from 'geb/CollateralAuctionHouse.sol';
import {GebSafeManager} from "geb-safe-manager/GebSafeManager.sol";

import {SaviourCRatioSetter} from "../SaviourCRatioSetter.sol";
import {SAFESaviourRegistry} from "../SAFESaviourRegistry.sol";

import "../integrations/uniswap/uni-v2/UniswapV2Factory.sol";
import "../integrations/uniswap/uni-v2/UniswapV2Pair.sol";
import "../integrations/uniswap/uni-v2/UniswapV2Router02.sol";

import "../integrations/uniswap/liquidity-managers/UniswapV2LiquidityManager.sol";
import "../integrations/uniswap/liquidity-managers/UniswapV3LiquidityManager.sol";

import "../saviours/NativeUnderlyingUniswapSafeSaviour.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

contract TestSAFEEngine is SAFEEngine {
    uint256 constant RAY = 10 ** 27;

    constructor() public {}

    function mint(address usr, uint wad) public {
        coinBalance[usr] += wad * RAY;
        globalDebt += wad * RAY;
    }
    function balanceOf(address usr) public view returns (uint) {
        return uint(coinBalance[usr] / RAY);
    }
}

// --- Median Contracts ---
contract MockMedianizer {
    uint256 public price;
    bool public validPrice;
    uint public lastUpdateTime;
    address public priceSource;

    constructor(uint256 price_, bool validPrice_) public {
        price = price_;
        validPrice = validPrice_;
        lastUpdateTime = now;
    }
    function updatePriceSource(address priceSource_) external {
        priceSource = priceSource_;
    }
    function changeValidity() external {
        validPrice = !validPrice;
    }
    function updateCollateralPrice(uint256 price_) external {
        price = price_;
        lastUpdateTime = now;
    }
    function read() external view returns (uint256) {
        return price;
    }
    function getResultWithValidity() external view returns (uint256, bool) {
        return (price, validPrice);
    }
}

// Users
contract FakeUser {
    function doModifyParameters(
      NativeUnderlyingUniswapSafeSaviour saviour,
      bytes32 parameter,
      uint256 data
    ) public {
      saviour.modifyParameters(parameter, data);
    }

    function doModifyParameters(
      NativeUnderlyingUniswapSafeSaviour saviour,
      bytes32 parameter,
      address data
    ) public {
      saviour.modifyParameters(parameter, data);
    }

    function doOpenSafe(
        GebSafeManager manager,
        bytes32 collateralType,
        address usr
    ) public returns (uint256) {
        return manager.openSAFE(collateralType, usr);
    }

    function doSafeAllow(
        GebSafeManager manager,
        uint safe,
        address usr,
        uint ok
    ) public {
        manager.allowSAFE(safe, usr, ok);
    }

    function doHandlerAllow(
        GebSafeManager manager,
        address usr,
        uint ok
    ) public {
        manager.allowHandler(usr, ok);
    }

    function doTransferSAFEOwnership(
        GebSafeManager manager,
        uint safe,
        address dst
    ) public {
        manager.transferSAFEOwnership(safe, dst);
    }

    function doModifySAFECollateralization(
        GebSafeManager manager,
        uint safe,
        int deltaCollateral,
        int deltaDebt
    ) public {
        manager.modifySAFECollateralization(safe, deltaCollateral, deltaDebt);
    }

    function doApproveSAFEModification(
        SAFEEngine safeEngine,
        address usr
    ) public {
        safeEngine.approveSAFEModification(usr);
    }

    function doSAFEEngineModifySAFECollateralization(
        SAFEEngine safeEngine,
        bytes32 collateralType,
        address safe,
        address collateralSource,
        address debtDst,
        int deltaCollateral,
        int deltaDebt
    ) public {
        safeEngine.modifySAFECollateralization(collateralType, safe, collateralSource, debtDst, deltaCollateral, deltaDebt);
    }

    function doProtectSAFE(
        GebSafeManager manager,
        uint safe,
        address liquidationEngine,
        address saviour
    ) public {
        manager.protectSAFE(safe, liquidationEngine, saviour);
    }

    function doDeposit(
        NativeUnderlyingUniswapSafeSaviour saviour,
        DSToken lpToken,
        uint256 safeID,
        uint256 tokenAmount
    ) public {
        lpToken.approve(address(saviour), tokenAmount);
        saviour.deposit(safeID, tokenAmount);
    }

    function doWithdraw(
        NativeUnderlyingUniswapSafeSaviour saviour,
        uint256 safeID,
        uint256 lpTokenAmount
    ) public {
        saviour.withdraw(safeID, lpTokenAmount);
    }

    function doGetReserves(
        NativeUnderlyingUniswapSafeSaviour saviour,
        uint256 safeID
    ) public {
        saviour.getReserves(safeID);
    }

    function doTransferInternalCoins(
        GebSafeManager manager,
        uint256 safe,
        address dst,
        uint256 amt
    ) public {
        manager.transferInternalCoins(safe, dst, amt);
    }

    function doSetDesiredCollateralizationRatio(
        SaviourCRatioSetter cRatioSetter,
        bytes32 collateralType,
        uint safe,
        uint cRatio
    ) public {
        cRatioSetter.setDesiredCollateralizationRatio(collateralType, safe, cRatio);
    }
}

contract NativeUnderlyingUniswapV2SafeSaviourTest is DSTest {
    Hevm hevm;

    UniswapV2Factory uniswapFactory;
    UniswapV2Router02 uniswapRouter;
    UniswapV2LiquidityManager liquidityManager;

    UniswapV2Pair raiWETHPair;

    Coin systemCoin;
    WETH9_ weth;

    TestSAFEEngine safeEngine;
    AccountingEngine accountingEngine;
    LiquidationEngine liquidationEngine;
    OracleRelayer oracleRelayer;
    TaxCollector taxCollector;

    BasicCollateralJoin collateralJoin;

    CoinJoin coinJoin;
    CoinJoin systemCoinJoin;

    EnglishCollateralAuctionHouse collateralAuctionHouse;

    GebSafeManager safeManager;

    NativeUnderlyingUniswapSafeSaviour saviour;
    SaviourCRatioSetter cRatioSetter;
    SAFESaviourRegistry saviourRegistry;

    MockMedianizer systemCoinOracle;
    MockMedianizer ethFSM;
    MockMedianizer ethMedian;

    FakeUser alice;

    address me;

    // Params
    uint256 initTokenAmount  = 100000 ether;
    uint256 initETHUSDPrice  = 250 * 10 ** 18;
    uint256 initRAIUSDPrice  = 4.242 * 10 ** 18;

    uint256 initETHRAIPairLiquidity = 5 ether;               // 1250 USD
    uint256 initRAIETHPairLiquidity = 294.672324375E18;      // 1 RAI = 4.242 USD

    uint256 ethRAISimulationExtraRAI = 100 ether;
    uint256 ethRAISimulationExtraETH = 0.5 ether;

    // Saviour params
    bool isSystemCoinToken0;
    uint256 saveCooldown = 1 days;
    uint256 minKeeperPayoutValue = 1000 ether;
    uint256 defaultDesiredCollateralizationRatio = 200;
    uint256 minDesiredCollateralizationRatio = 155;

    // Core system params
    uint256 minCRatio = 1.5 ether;
    uint256 ethToMint = 5000 ether;
    uint256 ethCeiling = uint(-1);
    uint256 ethLiquidationPenalty = 1 ether;

    uint256 defaultLiquidityMultiplier = 50;
    uint256 defaultCollateralAmount = 40 ether;
    uint256 defaultTokenAmount = 100 ether;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        // System coin
        systemCoin = new Coin("RAI", "RAI", 1);
        systemCoin.mint(address(this), initTokenAmount);
        systemCoinOracle = new MockMedianizer(initRAIUSDPrice, true);

        // Core system
        safeEngine = new TestSAFEEngine();
        safeEngine.initializeCollateralType("eth");
        safeEngine.mint(address(this), rad(initTokenAmount));

        ethFSM    = new MockMedianizer(initETHUSDPrice, true);
        ethMedian = new MockMedianizer(initETHUSDPrice, true);
        ethFSM.updatePriceSource(address(ethMedian));

        oracleRelayer = new OracleRelayer(address(safeEngine));
        oracleRelayer.modifyParameters("redemptionPrice", ray(initRAIUSDPrice));
        oracleRelayer.modifyParameters("eth", "orcl", address(ethFSM));
        oracleRelayer.modifyParameters("eth", "safetyCRatio", ray(minCRatio));
        oracleRelayer.modifyParameters("eth", "liquidationCRatio", ray(minCRatio));

        safeEngine.addAuthorization(address(oracleRelayer));
        oracleRelayer.updateCollateralPrice("eth");

        accountingEngine = new AccountingEngine(
          address(safeEngine), address(0x1), address(0x2)
        );
        safeEngine.addAuthorization(address(accountingEngine));

        taxCollector = new TaxCollector(address(safeEngine));
        taxCollector.initializeCollateralType("eth");
        taxCollector.modifyParameters("primaryTaxReceiver", address(accountingEngine));
        safeEngine.addAuthorization(address(taxCollector));

        liquidationEngine = new LiquidationEngine(address(safeEngine));
        liquidationEngine.modifyParameters("accountingEngine", address(accountingEngine));

        safeEngine.addAuthorization(address(liquidationEngine));
        accountingEngine.addAuthorization(address(liquidationEngine));

        weth = new WETH9_();
        weth.deposit{value: initTokenAmount}();

        collateralJoin = new BasicCollateralJoin(address(safeEngine), "eth", address(weth));

        coinJoin = new CoinJoin(address(safeEngine), address(systemCoin));
        systemCoin.addAuthorization(address(coinJoin));
        safeEngine.transferInternalCoins(address(this), address(coinJoin), safeEngine.coinBalance(address(this)));

        safeEngine.addAuthorization(address(collateralJoin));

        safeEngine.modifyParameters("eth", "debtCeiling", rad(ethCeiling));
        safeEngine.modifyParameters("globalDebtCeiling", rad(ethCeiling));

        collateralAuctionHouse = new EnglishCollateralAuctionHouse(address(safeEngine), address(liquidationEngine), "eth");
        collateralAuctionHouse.addAuthorization(address(liquidationEngine));

        liquidationEngine.addAuthorization(address(collateralAuctionHouse));
        liquidationEngine.modifyParameters("eth", "collateralAuctionHouse", address(collateralAuctionHouse));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", ethLiquidationPenalty);

        safeEngine.addAuthorization(address(collateralAuctionHouse));
        safeEngine.approveSAFEModification(address(collateralAuctionHouse));

        safeManager = new GebSafeManager(address(safeEngine));
        oracleRelayer.updateCollateralPrice("eth");

        // Uniswap setup
        uniswapFactory = new UniswapV2Factory(address(this));
        createUniswapPair();
        uniswapRouter = new UniswapV2Router02(address(uniswapFactory), address(weth));
        addPairLiquidityRouter(address(systemCoin), address(weth), initRAIETHPairLiquidity, initETHRAIPairLiquidity);

        // Liquidity manager
        liquidityManager = new UniswapV2LiquidityManager(address(raiWETHPair), address(uniswapRouter));

        // Saviour infra
        saviourRegistry = new SAFESaviourRegistry(saveCooldown);
        cRatioSetter = new SaviourCRatioSetter(address(oracleRelayer), address(safeManager));
        cRatioSetter.setDefaultCRatio("eth", defaultDesiredCollateralizationRatio);

        saviour = new NativeUnderlyingUniswapSafeSaviour(
            isSystemCoinToken0,
            address(coinJoin),
            address(collateralJoin),
            address(cRatioSetter),
            address(systemCoinOracle),
            address(liquidationEngine),
            address(oracleRelayer),
            address(safeManager),
            address(saviourRegistry),
            address(liquidityManager),
            address(raiWETHPair),
            minKeeperPayoutValue
        );
        saviourRegistry.toggleSaviour(address(saviour));
        liquidationEngine.connectSAFESaviour(address(saviour));

        me    = address(this);
        alice = new FakeUser();
    }

    // --- Math ---
    function ray(uint wad) internal pure returns (uint) {
        return wad * 10 ** 9;
    }
    function rad(uint wad) internal pure returns (uint) {
        return wad * 10 ** 27;
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    // --- Uniswap utils ---
    function createUniswapPair() internal {
        // Setup WETH/RAI pair
        uniswapFactory.createPair(address(weth), address(systemCoin));
        raiWETHPair = UniswapV2Pair(uniswapFactory.getPair(address(weth), address(systemCoin)));

        if (address(raiWETHPair.token0()) == address(systemCoin)) isSystemCoinToken0 = true;
    }
    function addPairLiquidityRouter(address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).approve(address(uniswapRouter), uint(-1));
        DSToken(token2).approve(address(uniswapRouter), uint(-1));
        uniswapRouter.addLiquidity(token1, token2, amount1, amount2, amount1, amount2, address(this), now);
        UniswapV2Pair updatedPair = UniswapV2Pair(uniswapFactory.getPair(token1, token2));
        updatedPair.sync();
    }
    function addPairLiquidityTransfer(UniswapV2Pair pair, address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).transfer(address(pair), amount1);
        DSToken(token2).transfer(address(pair), amount2);
        pair.sync();
    }

    // --- Default actions/scenarios ---
    function default_create_liquidatable_position(uint256 desiredCRatio, uint256 liquidatableCollateralPrice) internal returns (address) {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "eth", safe, desiredCRatio);
        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        ethMedian.updateCollateralPrice(liquidatableCollateralPrice);
        ethFSM.updateCollateralPrice(liquidatableCollateralPrice);
        oracleRelayer.updateCollateralPrice("eth");

        return safeHandler;
    }
    function default_save(uint256 safe, address safeHandler, uint desiredCRatio) internal {
        default_modify_collateralization(safe, safeHandler);

        alice.doTransferInternalCoins(safeManager, safe, address(coinJoin), safeEngine.coinBalance(safeHandler));
        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "eth", safe, desiredCRatio);
        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        ethMedian.updateCollateralPrice(initETHUSDPrice * 10 / 15);
        ethFSM.updateCollateralPrice(initETHUSDPrice * 10 / 15);
        oracleRelayer.updateCollateralPrice("eth");

        uint256 lpTokenAmount = raiWETHPair.balanceOf(address(this));
        addPairLiquidityRouter(
          address(systemCoin), address(weth), initRAIETHPairLiquidity * defaultLiquidityMultiplier, initETHRAIPairLiquidity * defaultLiquidityMultiplier
        );
        lpTokenAmount = sub(raiWETHPair.balanceOf(address(this)), lpTokenAmount);
        raiWETHPair.transfer(address(alice), lpTokenAmount);

        alice.doDeposit(saviour, DSToken(address(raiWETHPair)), safe, lpTokenAmount);
        assertEq(raiWETHPair.balanceOf(address(saviour)), lpTokenAmount);
        assertTrue(saviour.canSave("eth", safeHandler));

        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(111 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        uint256 preSaveSysCoinKeeperBalance = systemCoin.balanceOf(address(this));
        uint256 preSaveWETHKeeperBalance = weth.balanceOf(address(this));
        uint auction = liquidationEngine.liquidateSAFE("eth", safeHandler);
        (uint256 sysCoinReserve, uint256 collateralReserve) = saviour.underlyingReserves(safeHandler);

        assertEq(auction, 0);
        assertTrue(
          sysCoinReserve > 0 ||
          collateralReserve > 0
        );
        assertTrue(
          systemCoin.balanceOf(address(this)) - preSaveSysCoinKeeperBalance > 0 ||
          weth.balanceOf(address(this)) - preSaveWETHKeeperBalance > 0
        );
        assertEq(systemCoin.balanceOf(address(this)), 0);
        assertEq(weth.balanceOf(address(this)), 0);
        assertTrue(raiWETHPair.balanceOf(address(saviour)) < lpTokenAmount);
        assertEq(raiWETHPair.balanceOf(address(liquidityManager)), 0);
        assertEq(saviour.lpTokenCover(safeHandler), 0);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", safeHandler);
        assertEq(lockedCollateral * (initETHUSDPrice * 10 / 15) * 100 / (generatedDebt * oracleRelayer.redemptionPrice()), desiredCRatio);
    }
    function default_second_save(uint256 safe, address safeHandler, uint desiredCRatio) internal {
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "eth", safe, desiredCRatio);

        ethMedian.updateCollateralPrice(initETHUSDPrice / 3);
        ethFSM.updateCollateralPrice(initETHUSDPrice / 3);
        oracleRelayer.updateCollateralPrice("eth");

        uint256 lpTokenAmount = raiWETHPair.balanceOf(address(this));
        addPairLiquidityRouter(
          address(systemCoin), address(weth), initRAIETHPairLiquidity * defaultLiquidityMultiplier, initETHRAIPairLiquidity * defaultLiquidityMultiplier
        );
        lpTokenAmount = sub(raiWETHPair.balanceOf(address(this)), lpTokenAmount);
        raiWETHPair.transfer(address(alice), lpTokenAmount);

        alice.doDeposit(saviour, DSToken(address(raiWETHPair)), safe, lpTokenAmount);
        assertEq(raiWETHPair.balanceOf(address(saviour)), lpTokenAmount);
        assertTrue(saviour.canSave("eth", safeHandler));

        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(111 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        uint256 preSaveSysCoinKeeperBalance = systemCoin.balanceOf(address(this));
        uint256 preSaveWETHKeeperBalance = weth.balanceOf(address(this));
        uint auction = liquidationEngine.liquidateSAFE("eth", safeHandler);
        (uint256 sysCoinReserve, uint256 collateralReserve) = saviour.underlyingReserves(safeHandler);

        assertEq(auction, 0);
        assertTrue(
          sysCoinReserve > 0 ||
          collateralReserve > 0
        );
        assertTrue(
          systemCoin.balanceOf(address(this)) - preSaveSysCoinKeeperBalance > 0 ||
          weth.balanceOf(address(this)) - preSaveWETHKeeperBalance > 0
        );
        assertEq(systemCoin.balanceOf(address(this)), 0);
        assertEq(weth.balanceOf(address(this)), 0);
        assertTrue(raiWETHPair.balanceOf(address(saviour)) < lpTokenAmount);
        assertEq(raiWETHPair.balanceOf(address(liquidityManager)), 0);
        assertEq(saviour.lpTokenCover(safeHandler), 0);

        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", safeHandler);
        assertEq(lockedCollateral * (initETHUSDPrice / 3) * 100 / (generatedDebt * oracleRelayer.redemptionPrice()), desiredCRatio);
    }
    function default_liquidate_safe(address safeHandler) internal {
        ethMedian.updateCollateralPrice(initETHUSDPrice * 10 / 15);
        ethFSM.updateCollateralPrice(initETHUSDPrice * 10 / 15);
        oracleRelayer.updateCollateralPrice("eth");

        liquidationEngine.modifyParameters("eth", "liquidationQuantity", rad(111 ether));
        liquidationEngine.modifyParameters("eth", "liquidationPenalty", 1.1 ether);

        uint auction = liquidationEngine.liquidateSAFE("eth", safeHandler);
        // the full SAFE is liquidated
        (uint lockedCollateral, uint generatedDebt) = safeEngine.safes("eth", me);
        assertEq(lockedCollateral, 0);
        assertEq(generatedDebt, 0);
        // all debt goes to the accounting engine
        assertEq(accountingEngine.totalQueuedDebt(), rad(defaultTokenAmount));
        // auction is for all collateral
        (,uint amountToSell,,,,,, uint256 amountToRaise) = collateralAuctionHouse.bids(auction);
        assertEq(amountToSell, defaultCollateralAmount);
        assertEq(amountToRaise, rad(110 ether));
    }
    function default_create_liquidatable_position_deposit_cover(uint256 desiredCRatio, uint256 liquidatableCollateralPrice) internal returns (address) {
        // Create position
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        alice.doProtectSAFE(safeManager, safe, address(liquidationEngine), address(saviour));
        alice.doSetDesiredCollateralizationRatio(cRatioSetter, "eth", safe, desiredCRatio);
        assertEq(liquidationEngine.chosenSAFESaviour("eth", safeHandler), address(saviour));

        // Deposit cover
        uint256 lpTokenAmount = raiWETHPair.balanceOf(address(this));
        addPairLiquidityRouter(
          address(systemCoin), address(weth), initRAIETHPairLiquidity * defaultLiquidityMultiplier, initETHRAIPairLiquidity * defaultLiquidityMultiplier
        );
        lpTokenAmount = sub(raiWETHPair.balanceOf(address(this)), lpTokenAmount);
        raiWETHPair.transfer(address(alice), lpTokenAmount);

        alice.doDeposit(saviour, DSToken(address(raiWETHPair)), safe, lpTokenAmount);
        assertEq(raiWETHPair.balanceOf(address(saviour)), lpTokenAmount);
        assertEq(saviour.lpTokenCover(safeHandler), lpTokenAmount);

        return safeHandler;
    }
    function default_create_position_deposit_cover() internal returns (uint, address, uint) {
        uint safe = alice.doOpenSafe(safeManager, "eth", address(alice));
        address safeHandler = safeManager.safes(safe);
        default_modify_collateralization(safe, safeHandler);

        // Deposit cover
        uint256 lpTokenAmount = raiWETHPair.balanceOf(address(this));
        addPairLiquidityRouter(
          address(systemCoin), address(weth), initRAIETHPairLiquidity * defaultLiquidityMultiplier, initETHRAIPairLiquidity * defaultLiquidityMultiplier
        );
        lpTokenAmount = sub(raiWETHPair.balanceOf(address(this)), lpTokenAmount);
        raiWETHPair.transfer(address(alice), lpTokenAmount);

        alice.doDeposit(saviour, DSToken(address(raiWETHPair)), safe, lpTokenAmount);
        assertEq(raiWETHPair.balanceOf(address(saviour)), lpTokenAmount);
        assertEq(saviour.lpTokenCover(safeHandler), lpTokenAmount);

        return (safe, safeHandler, lpTokenAmount);
    }
    function default_modify_collateralization(uint256 safe, address safeHandler) internal {
        weth.approve(address(collateralJoin), uint(-1));
        collateralJoin.join(address(safeHandler), defaultTokenAmount);
        alice.doModifySAFECollateralization(safeManager, safe, int(defaultCollateralAmount), int(defaultTokenAmount));
    }

    // --- Tests ---
    function test_setup() public {
        assertEq(saviour.authorizedAccounts(address(this)), 1);
        assertTrue(saviour.isSystemCoinToken0() == isSystemCoinToken0);
        assertEq(saviour.minKeeperPayoutValue(), minKeeperPayoutValue);
        assertEq(saviour.restrictUsage(), 0);

        assertEq(address(saviour.coinJoin()), address(coinJoin));
        assertEq(address(saviour.collateralJoin()), address(collateralJoin));
        assertEq(address(saviour.cRatioSetter()), address(cRatioSetter));
        assertEq(address(saviour.liquidationEngine()), address(liquidationEngine));
        assertEq(address(saviour.oracleRelayer()), address(oracleRelayer));
        assertEq(address(saviour.systemCoinOrcl()), address(systemCoinOracle));
        assertEq(address(saviour.systemCoin()), address(systemCoin));
        assertEq(address(saviour.safeEngine()), address(safeEngine));
        assertEq(address(saviour.safeManager()), address(safeManager));
        assertEq(address(saviour.saviourRegistry()), address(saviourRegistry));
        assertEq(address(saviour.liquidityManager()), address(liquidityManager));
        assertEq(address(saviour.lpToken()), address(raiWETHPair));
        assertEq(address(saviour.collateralToken()), address(weth));
    }
}