// Copyright (C) 2020 Reflexer Labs, INC

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.

pragma solidity 0.6.7;

import "../interfaces/CTokenLike.sol";
import "../interfaces/SaviourCRatioSetterLike.sol";
import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";

contract CompoundSystemCoinSafeSaviour is SafeMath, SafeSaviourLike {
    // --- Auth ---
    mapping (address => uint256) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "CompoundSystemCoinSafeSaviour/account-not-authorized");
        _;
    }

    // --- Variables ---
    // Amount of cTokens currently protecting each position
    mapping(bytes32 => mapping(address => uint256)) public cTokenCover;
    // The cToken address
    CTokenLike                  public cToken;
    // The ERC20 system coin
    ERC20Like                   public systemCoin;
    // The system coin join contract
    CoinJoinLike                public coinJoin;
    // Oracle providing the system coin price feed
    PriceFeedLike               public systemCoinOrcl;
    // Contract that defines desired CRatios for each Safe after it is saved
    SaviourCRatioSetterLike     public cRatioSetter;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(bytes32 indexed parameter, uint256 val);
    event ModifyParameters(bytes32 indexed parameter, address data);
    event Deposit(
      address indexed caller,
      bytes32 collateralType,
      address indexed safeHandler,
      uint256 systemCoinAmount,
      uint256 cTokenAmount
    );
    event Withdraw(
      address indexed caller,
      bytes32 collateralType,
      address indexed safeHandler,
      uint256 systemCoinAmount,
      uint256 cTokenAmount
    );

    constructor(
      address coinJoin_,
      address cRatioSetter_,
      address systemCoinOrcl_,
      address liquidationEngine_,
      address oracleRelayer_,
      address safeManager_,
      address saviourRegistry_,
      address cToken_,
      uint256 keeperPayout_,
      uint256 minKeeperPayoutValue_
    ) public {
        require(coinJoin_ != address(0), "CompoundSystemCoinSafeSaviour/null-coin-join");
        require(cRatioSetter_ != address(0), "CompoundSystemCoinSafeSaviour/null-cratio-setter");
        require(systemCoinOrcl_ != address(0), "CompoundSystemCoinSafeSaviour/null-system-coin-oracle");
        require(oracleRelayer_ != address(0), "CompoundSystemCoinSafeSaviour/null-oracle-relayer");
        require(liquidationEngine_ != address(0), "CompoundSystemCoinSafeSaviour/null-liquidation-engine");
        require(safeManager_ != address(0), "CompoundSystemCoinSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "CompoundSystemCoinSafeSaviour/null-saviour-registry");
        require(cToken_ != address(0), "CompoundSystemCoinSafeSaviour/null-c-token");
        require(keeperPayout_ > 0, "CompoundSystemCoinSafeSaviour/invalid-keeper-payout");
        require(minKeeperPayoutValue_ > 0, "CompoundSystemCoinSafeSaviour/invalid-min-payout-value");

        authorizedAccounts[msg.sender] = 1;

        keeperPayout         = keeperPayout_;
        minKeeperPayoutValue = minKeeperPayoutValue_;

        coinJoin             = CoinJoinLike(coinJoin_);
        cRatioSetter         = SaviourCRatioSetterLike(cRatioSetter_);
        liquidationEngine    = LiquidationEngineLike(liquidationEngine_);
        oracleRelayer        = OracleRelayerLike(oracleRelayer_);
        systemCoinOrcl       = PriceFeedLike(systemCoinOrcl_);
        systemCoin           = ERC20Like(coinJoin.systemCoin());
        safeEngine           = SAFEEngineLike(coinJoin.safeEngine());
        safeManager          = GebSafeManagerLike(safeManager_);
        saviourRegistry      = SAFESaviourRegistryLike(saviourRegistry_);
        cToken               = CTokenLike(cToken_);

        systemCoinOrcl.read();
        oracleRelayer.redemptionPrice();

        require(cToken.isCToken(), "CompoundSystemCoinSafeSaviour/not-c-token");
        require(address(safeEngine) != address(0), "CompoundSystemCoinSafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "CompoundSystemCoinSafeSaviour/null-sys-coin");

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("keeperPayout", keeperPayout);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("cRatioSetter", cRatioSetter_);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("systemCoinOrcl", systemCoinOrcl_);
    }

    // --- Administration ---
    /**
     * @notice Modify an uint256 param
     * @param parameter The name of the parameter
     * @param val New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        require(val > 0, "CompoundSystemCoinSafeSaviour/null-value");

        if (parameter == "keeperPayout") {
            keeperPayout = val;
        }
        else if (parameter == "minKeeperPayoutValue") {
            minKeeperPayoutValue = val;
        }
        else revert("CompoundSystemCoinSafeSaviour/modify-unrecognized-param");
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "CompoundSystemCoinSafeSaviour/null-data");

        if (parameter == "systemCoinOrcl") {
            systemCoinOrcl = PriceFeedLike(data);
            systemCoinOrcl.read();
        }
        else if (parameter == "cRatioSetter") {
            cRatioSetter = SaviourCRatioSetterLike(data);
        }
        else if (parameter == "oracleRelayer") {
            oracleRelayer = OracleRelayerLike(data);
            oracleRelayer.redemptionPrice();
        }
        else revert("CompoundSystemCoinSafeSaviour/modify-unrecognized-param");
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit system coins in the contract and lend them on Compound in order to provide cover for a specific
    *         SAFE controlled by the SAFE Manager
    * @param collateralType The collateral type used in the SAFE
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param systemCoinAmount The amount of system coins to deposit
    */
    function deposit(bytes32 collateralType, uint256 safeID, uint256 systemCoinAmount)
      external liquidationEngineApproved(address(this)) nonReentrant {
        require(systemCoinAmount > 0, "CompoundSystemCoinSafeSaviour/null-system-coin-amount");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "CompoundSystemCoinSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) = safeEngine.safes(collateralType, safeHandler);
        require(safeDebt > 0, "CompoundSystemCoinSafeSaviour/safe-does-not-have-debt");

        // Lend on Compound
        uint256 currentCTokenBalance = cToken.balanceOf(address(this));
        systemCoin.transferFrom(msg.sender, address(this), systemCoinAmount);
        systemCoin.approve(address(cToken), systemCoinAmount);
        require(cToken.mint(systemCoinAmount) == 0, "CompoundSystemCoinSafeSaviour/cannot-mint-ctoken");

        // Update the cToken balance used to cover the SAFE
        cTokenCover[collateralType][safeHandler] =
          add(cTokenCover[collateralType][safeHandler], sub(cToken.balanceOf(address(this)), currentCTokenBalance));

        emit Deposit(msg.sender, collateralType, safeHandler, systemCoinAmount, sub(cToken.balanceOf(address(this)), currentCTokenBalance));
    }

    /*
    * @notice Withdraw system coins from the contract by exiting your Compound lending position
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside GebSafeManager
    * @param cTokenAmount The amount of cTokens to use and redeem system coins from Compound
    */
    function withdraw(bytes32 collateralType, uint256 safeID, uint256 cTokenAmount)
      external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(cTokenAmount > 0, "CompoundSystemCoinSafeSaviour/null-cToken-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(cTokenCover[collateralType][safeHandler] >= cTokenAmount, "CompoundSystemCoinSafeSaviour/not-enough-to-redeem");

        // Redeem system coins from Compound and transfer them to the caller
        uint256 currentSystemCoinAmount = systemCoin.balanceOf(address(this));
        cTokenCover[collateralType][safeHandler] = sub(cTokenCover[collateralType][safeHandler], cTokenAmount);
        cToken.redeem(cTokenAmount);

        systemCoin.transfer(msg.sender, sub(systemCoin.balanceOf(address(this)), currentSystemCoinAmount));

        emit Withdraw(
          msg.sender,
          collateralType,
          safeHandler,
          sub(systemCoin.balanceOf(address(this)), currentSystemCoinAmount),
          cTokenAmount
        );
    }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by repaying some of its debt (using cTokens)
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being liquidated
    * @return Whether the SAFE has been saved, the amount of debt repaid as well as the amount of
    *         system coins sent to the keeper as their payment
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "CompoundSystemCoinSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "CompoundSystemCoinSafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        // Check that the fiat value of the keeper payout is high enough
        require(keeperPayoutExceedsMinValue(), "CompoundSystemCoinSafeSaviour/small-keeper-payout-value");

        // Compute and check the validity of the amount of cTokens used to save the SAFE
        uint256 tokenAmountUsed = tokenAmountUsedToSave(collateralType, safeHandler);
        require(both(tokenAmountUsed != MAX_UINT, tokenAmountUsed != 0), "CompoundSystemCoinSafeSaviour/invalid-tokens-used-to-save");

        // Check that there are enough cTokens added to cover both the keeper's payout and the amount used to save the SAFE
        uint256 keeperCTokenPayout = div(mul(keeperPayout, WAD), cToken.exchangeRateStored());
        require(cTokenCover[collateralType][safeHandler] >= add(keeperCTokenPayout, tokenAmountUsed), "GeneralTokenReserveSafeSaviour/not-enough-cover-deposited");

        // Update the remaining cover
        cTokenCover[collateralType][safeHandler] = sub(cTokenCover[collateralType][safeHandler], add(keeperCTokenPayout, tokenAmountUsed));

        // Mark the SAFE in the registry as just having been saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Get system coins back from Compound
        uint256 currentSystemCoinAmount = systemCoin.balanceOf(address(this));
        cToken.redeem(add(keeperCTokenPayout, tokenAmountUsed));
        uint256 systemCoinsToRepay = sub(sub(systemCoin.balanceOf(address(this)), currentSystemCoinAmount), keeperPayout);

        // Approve the coin join contract to take system coins and repay debt
        systemCoin.approve(address(coinJoin), 0);
        systemCoin.approve(address(coinJoin), systemCoinsToRepay);

        // Join system coins in the system and repay the SAFE's debt
        coinJoin.join(address(this), systemCoinsToRepay);
        safeEngine.modifySAFECollateralization(
          collateralType,
          safeHandler,
          address(0),
          address(this),
          int256(0),
          int256(systemCoinsToRepay)
        );

        // Send the fee to the keeper
        systemCoin.transfer(keeper, keeperPayout);

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, tokenAmountUsed);

        return (true, tokenAmountUsed, keeperPayout);
    }

    // --- Getters ---
    /*
    * @notice Compute whether the value of keeperPayout system coins is higher than or equal to minKeeperPayoutValue
    * @dev Used to determine whether it's worth it for the keeper to save the SAFE in exchange for keeperPayout system coins
    * @return A bool representing whether the value of keeperPayout system coins is >= minKeeperPayoutValue
    */
    function keeperPayoutExceedsMinValue() override public returns (bool) {
        (uint256 priceFeedValue, bool hasValidValue) = systemCoinOrcl.getResultWithValidity();

        if (either(!hasValidValue, priceFeedValue == 0)) {
          return false;
        }

        return (minKeeperPayoutValue <= mul(keeperPayout, priceFeedValue) / WAD);
    }
    /*
    * @notice Return the current value of the keeper payout
    */
    function getKeeperPayoutValue() override public returns (uint256) {
        (uint256 priceFeedValue, bool hasValidValue) = systemCoinOrcl.getResultWithValidity();

        if (either(!hasValidValue, priceFeedValue == 0)) {
          return 0;
        }

        return mul(keeperPayout, priceFeedValue) / WAD;
    }
    /*
    * @notice Determine whether a SAFE can be saved with the current amount of cTokens deposited as cover for it
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return Whether the SAFE can be saved or not
    */
    function canSave(bytes32 collateralType, address safeHandler) override external returns (bool) {
        uint256 tokenAmountUsed = tokenAmountUsedToSave(collateralType, safeHandler);

        if (tokenAmountUsed == MAX_UINT) {
            return false;
        }

        return (cTokenCover[collateralType][safeHandler] >= add(tokenAmountUsed, keeperPayout));
    }
    /*
    * @notice Calculate the amount of cTokens used to save a SAFE and bring its CRatio to the desired level
    * @param collateralType The SAFE collateral type
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of cTokens used to save the SAFE and bring its CRatio to the desired level
    */
    function tokenAmountUsedToSave(bytes32 collateralType, address safeHandler) override public returns (uint256 tokenAmountUsed) {
        (uint256 depositedCollateralToken, uint256 safeDebt) = safeEngine.safes(collateralType, safeHandler);
        (uint256 priceFeedValue, bool hasValidValue) = systemCoinOrcl.getResultWithValidity();

        // If the SAFE doesn't have debt or if the price feed is faulty, abort
        if (either(safeDebt == 0, either(priceFeedValue == 0, !hasValidValue))) {
            tokenAmountUsed = MAX_UINT;
            return tokenAmountUsed;
        }

        // Calculate the amount of debt that needs to be repaid so the SAFE gets to the target CRatio
        uint256 targetCRatio = (cRatioSetter.desiredCollateralizationRatios(collateralType, safeHandler) == 0) ?
          cRatioSetter.defaultDesiredCollateralizationRatios(collateralType) :
          cRatioSetter.desiredCollateralizationRatios(collateralType, safeHandler);

        uint256 targetDebtAmount = mul(
          mul(targetCRatio, mul(depositedCollateralToken, priceFeedValue) / WAD) / HUNDRED, oracleRelayer.redemptionPrice()
        ) / RAY;

        // If you need to repay more than the amount of debt in the SAFE (or all the debt), return 0
        if (targetDebtAmount >= safeDebt) {
          return 0;
        } else {
          return div(mul(sub(safeDebt, targetDebtAmount), WAD), cToken.exchangeRateCurrent());
        }
    }
}