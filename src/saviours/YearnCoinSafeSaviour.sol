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
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.6.7;

import "../interfaces/YVaultLike.sol";
import "../interfaces/SaviourCRatioSetterLike.sol";
import "../interfaces/SafeSaviourLike.sol";
import "../math/SafeMath.sol";

contract YearnCoinSafeSaviour is SafeMath, SafeSaviourLike {
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
        require(authorizedAccounts[msg.sender] == 1, "YearnCoinSafeSaviour/account-not-authorized");
        _;
    }

    mapping (address => uint256) public allowedUsers;
    /**
     * @notice Allow a user to deposit assets
     * @param usr User to whitelist
     */
    function allowUser(address usr) external isAuthorized {
        allowedUsers[usr] = 1;
        emit AllowUser(usr);
    }
    /**
     * @notice Disallow a user from depositing assets
     * @param usr User to disallow
     */
    function disallowUser(address usr) external isAuthorized {
        allowedUsers[usr] = 0;
        emit DisallowUser(usr);
    }
    /**
    * @notice Checks whether an address is an allowed user
    **/
    modifier isAllowed {
        require(
          either(restrictUsage == 0, both(restrictUsage == 1, allowedUsers[msg.sender] == 1)),
          "YearnCoinSafeSaviour/account-not-allowed"
        );
        _;
    }

    // --- Variables ---
    // Flag that tells whether usage of the contract is restricted to allowed users
    uint256                     public restrictUsage;

    // Amount of collateral deposited to cover each SAFE
    mapping(bytes32 => mapping(address => uint256)) public yvTokenCover;
    // The yVauly address
    YVaultLike                  public yVault;
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
    event AllowUser(address usr);
    event DisallowUser(address usr);
    event ModifyParameters(bytes32 indexed parameter, uint256 val);
    event ModifyParameters(bytes32 indexed parameter, address data);
    event Deposit(
      address indexed caller,
      bytes32 collateralType,
      address indexed safeHandler,
      uint256 systemCoinAmount,
      uint256 yvTokenAmount
    );
    event Withdraw(
      address indexed caller,
      bytes32 collateralType,
      address indexed safeHandler,
      address dst,
      uint256 systemCoinAmount,
      uint256 yvTokenAmount
    );

    constructor(
      address coinJoin_,
      address cRatioSetter_,
      address systemCoinOrcl_,
      address liquidationEngine_,
      address oracleRelayer_,
      address safeManager_,
      address saviourRegistry_,
      address yVault_,
      uint256 keeperPayout_,
      uint256 minKeeperPayoutValue_

    ) public {
        require(coinJoin_ != address(0), "YearnCoinSafeSaviour/null-coin-join");
        require(cRatioSetter_ != address(0), "YearnCoinSafeSaviour/null-cratio-setter");
        require(systemCoinOrcl_ != address(0), "YearnCoinSafeSaviour/null-system-coin-oracle");
        require(oracleRelayer_ != address(0), "YearnCoinSafeSaviour/null-oracle-relayer");
        require(liquidationEngine_ != address(0), "YearnCoinSafeSaviour/null-liquidation-engine");
        require(safeManager_ != address(0), "YearnCoinSafeSaviour/null-safe-manager");
        require(saviourRegistry_ != address(0), "YearnCoinSafeSaviour/null-saviour-registry");
        require(yVault_ != address(0), "YearnCoinSafeSaviour/null-y-vault");
        require(keeperPayout_ > 0, "YearnCoinSafeSaviour/invalid-keeper-payout");
        require(minKeeperPayoutValue_ > 0, "YearnCoinSafeSaviour/invalid-min-payout-value");

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
        yVault               = YVaultLike(yVault_);

        systemCoinOrcl.read();
        systemCoinOrcl.getResultWithValidity();
        oracleRelayer.redemptionPrice();

        require(address(safeEngine) != address(0), "YearnCoinSafeSaviour/null-safe-engine");
        require(address(systemCoin) != address(0), "YearnCoinSafeSaviour/null-sys-coin");

        emit AddAuthorization(msg.sender);
        emit ModifyParameters("keeperPayout", keeperPayout);
        emit ModifyParameters("minKeeperPayoutValue", minKeeperPayoutValue);
        emit ModifyParameters("liquidationEngine", liquidationEngine_);
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
        if (parameter == "keeperPayout") {
            require(val > 0, "YearnCoinSafeSaviour/null-payout");
            keeperPayout = val;
        }
        else if (parameter == "minKeeperPayoutValue") {
            require(val > 0, "YearnCoinSafeSaviour/null-min-payout");
            minKeeperPayoutValue = val;
        }
        else if (parameter == "restrictUsage") {
            require(val <= 1, "YearnCoinSafeSaviour/invalid-restriction");
            restrictUsage = val;
        }
        else revert("YearnCoinSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /**
     * @notice Modify an address param
     * @param parameter The name of the parameter
     * @param data New address for the parameter
     */
    function modifyParameters(bytes32 parameter, address data) external isAuthorized {
        require(data != address(0), "YearnCoinSafeSaviour/null-data");

        if (parameter == "systemCoinOrcl") {
            systemCoinOrcl = PriceFeedLike(data);
            systemCoinOrcl.read();
            systemCoinOrcl.getResultWithValidity();
        }
        else if (parameter == "oracleRelayer") {
            oracleRelayer = OracleRelayerLike(data);
            oracleRelayer.redemptionPrice();
        }
        else if (parameter == "liquidationEngine") {
            liquidationEngine = LiquidationEngineLike(data);
        }
        else revert("YearnCoinSafeSaviour/modify-unrecognized-param");
        emit ModifyParameters(parameter, data);
    }

    // --- Adding/Withdrawing Cover ---
    /*
    * @notice Deposit collateralToken in the contract in order to provide cover for a specific SAFE controlled by the SAFE Manager
    * @param safeID The ID of the SAFE to protect. This ID should be registered inside GebSafeManager
    * @param collateralTokenAmount The amount of collateralToken to deposit
    */
    function deposit(bytes32 collateralType, uint256 safeID, uint256 systemCoinAmount)
      external isAllowed() liquidationEngineApproved(address(this)) nonReentrant {
        uint256 defaultCRatio = cRatioSetter.defaultDesiredCollateralizationRatios(collateralType);
        require(systemCoinAmount > 0, "YearnCoinSafeSaviour/null-system-coin-amount");
        require(defaultCRatio > 0, "YearnCoinSafeSaviour/collateral-not-set");

        // Check that the SAFE exists inside GebSafeManager
        address safeHandler = safeManager.safes(safeID);
        require(safeHandler != address(0), "YearnCoinSafeSaviour/null-handler");

        // Check that the SAFE has debt
        (, uint256 safeDebt) = safeEngine.safes(collateralType, safeHandler);
        require(safeDebt > 0, "YearnCoinSafeSaviour/safe-does-not-have-debt");

        // Deposit Into Yearn
        systemCoin.transferFrom(msg.sender, address(this), systemCoinAmount);
        systemCoin.approve(address(yVault), systemCoinAmount);
        uint256 yvTokens = yVault.deposit(systemCoinAmount); // use return value to save on math operations
        require(yvTokens > 0, "YearnCoinSafeSaviour/no-vault-tokens-returned");

        // Update the cToken balance used to cover the SAFE
        yvTokenCover[collateralType][safeHandler] += yvTokens;

        emit Deposit(msg.sender, collateralType, safeHandler, systemCoinAmount, yvTokens);
    }
    /*
    * @notice Withdraw collateralToken from the contract and provide less cover for a SAFE
    * @dev Only an address that controls the SAFE inside GebSafeManager can call this
    * @param safeID The ID of the SAFE to remove cover from. This ID should be registered inside GebSafeManager
    * @param collateralTokenAmount The amount of collateralToken to withdraw
    * @param dst The address that will receive the withdrawn tokens
    */
    function withdraw(bytes32 collateralType, uint256 safeID, uint256 yvTokenAmount, address dst)
      external controlsSAFE(msg.sender, safeID) nonReentrant {
        require(yvTokenAmount > 0, "YearnCoinSafeSaviour/null-yvToken-amount");

        // Fetch the handler from the SAFE manager
        address safeHandler = safeManager.safes(safeID);
        require(yvTokenCover[collateralType][safeHandler] >= yvTokenAmount, "YearnCoinSafeSaviour/withdraw-request-higher-than-balance");

        // Redeem system coins from Compound and transfer them to the caller
        yvTokenCover[collateralType][safeHandler] = sub(yvTokenCover[collateralType][safeHandler], yvTokenAmount);

        uint256 withdrawnAmount = yVault.withdraw(yvTokenAmount); // use return value to save on math operations
        require(withdrawnAmount > 0, "YearnCoinSafeSaviour/no-coins-withdrawn");
        systemCoin.transfer(dst, withdrawnAmount);

        emit Withdraw(
          msg.sender,
          collateralType,
          safeHandler,
          dst,
          withdrawnAmount,
          yvTokenAmount
        );
      }

    // --- Saving Logic ---
    /*
    * @notice Saves a SAFE by adding more collateralToken into it
    * @dev Only the LiquidationEngine can call this
    * @param keeper The keeper that called LiquidationEngine.liquidateSAFE and that should be rewarded for spending gas to save a SAFE
    * @param collateralType The collateral type backing the SAFE that's being liquidated
    * @param safeHandler The handler of the SAFE that's being liquidated
    * @return Whether the SAFE has been saved, the amount of collateralToken added in the SAFE as well as the amount of
    *         collateralToken sent to the keeper as their payment
    */
    function saveSAFE(address keeper, bytes32 collateralType, address safeHandler) override external returns (bool, uint256, uint256) {
        require(address(liquidationEngine) == msg.sender, "YearnCoinSafeSaviour/caller-not-liquidation-engine");
        require(keeper != address(0), "YearnCoinSafeSaviour/null-keeper-address");

        if (both(both(collateralType == "", safeHandler == address(0)), keeper == address(liquidationEngine))) {
            return (true, uint(-1), uint(-1));
        }

        // Check that the fiat value of the keeper payout is high enough
        require(keeperPayoutExceedsMinValue(), "YearnCoinSafeSaviour/small-keeper-payout-value");

        // Compute and check the validity of the amount of yvTokens used to save the SAFE
        uint256 tokenAmountUsed = tokenAmountUsedToSave(collateralType, safeHandler);
        require(both(tokenAmountUsed != MAX_UINT, tokenAmountUsed != 0), "YearnCoinSafeSaviour/invalid-tokens-used-to-save");

        // Check that there are enough yvTokens added to cover both the keeper's payout and the amount used to save the SAFE
        uint256 keeperYTokenPayout = div(mul(keeperPayout, WAD), yVault.pricePerShare());
        uint256 amountToWithdraw = add(keeperYTokenPayout, tokenAmountUsed);
        require(yvTokenCover[collateralType][safeHandler] >= amountToWithdraw, "YearnCoinSafeSaviour/not-enough-cover-deposited");

        // Update the remaining cover
        yvTokenCover[collateralType][safeHandler] = sub(yvTokenCover[collateralType][safeHandler], add(keeperYTokenPayout, tokenAmountUsed));

        // Mark the SAFE in the registry as just having been saved
        saviourRegistry.markSave(collateralType, safeHandler);

        // Get system coins back from Yearn Vault
        uint256 withdrawnAmount = yVault.withdraw(amountToWithdraw);
        require(withdrawnAmount > 0, "YearnCoinSafeSaviour/withdraw-request-higher-than-balance");
        uint256 systemCoinsToRepay = sub(withdrawnAmount, keeperPayout);

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
          -int256(systemCoinsToRepay)
        );

        // Send the fee to the keeper
        systemCoin.transfer(keeper, keeperPayout);

        // Emit an event
        emit SaveSAFE(keeper, collateralType, safeHandler, tokenAmountUsed);

        return (true, tokenAmountUsed, keeperPayout);
    }

    // --- Getters ---
    /*
    * @notice Compute whether the value of keeperPayout collateralToken is higher than or equal to minKeeperPayoutValue
    * @dev Used to determine whether it's worth it for the keeper to save the SAFE in exchange for keeperPayout collateralToken
    * @return A bool representing whether the value of keeperPayout collateralToken is >= minKeeperPayoutValue
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
    * @notice Determine whether a SAFE can be saved with the current amount of collateralToken deposited as cover for it
    * @param collateralType The SAFE collateral type (ignored in this implementation)
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return Whether the SAFE can be saved or not
    */
    function canSave(bytes32 collateralType, address safeHandler) override external returns (bool) {
        uint256 tokenAmountUsed = tokenAmountUsedToSave(collateralType, safeHandler);

        if (either(tokenAmountUsed == MAX_UINT, tokenAmountUsed == 0)) {
            return false;
        }

        uint256 keeperYTokenPayout = div(mul(keeperPayout, WAD), yVault.pricePerShare());
        return (yvTokenCover[collateralType][safeHandler] >= add(tokenAmountUsed, keeperYTokenPayout));
    }
    /*
    * @notice Calculate the amount of collateralToken used to save a SAFE and bring its CRatio to the desired level
    * @param collateralType The SAFE collateral type (ignored in this implementation)
    * @param safeHandler The handler of the SAFE which the function takes into account
    * @return The amount of collateralToken used to save the SAFE and bring its CRatio to the desired level
    */
    function tokenAmountUsedToSave(bytes32 collateralType, address safeHandler) override public returns (uint256) {
        if (yvTokenCover[collateralType][safeHandler] == 0) return 0;

        (uint256 depositedCollateralToken, uint256 safeDebt) = safeEngine.safes(collateralType, safeHandler);
        (address ethFSM,,) = oracleRelayer.collateralTypes(collateralType);
        if (ethFSM == address(0)) return MAX_UINT;

        (uint256 priceFeedValue, bool hasValidValue) = PriceFeedLike(ethFSM).getResultWithValidity();

        // If the SAFE doesn't have debt, if the price feed is faulty or if the default desired CRatio is null, abort
        uint256 defaultCRatio = cRatioSetter.defaultDesiredCollateralizationRatios(collateralType);
        if (either(either(safeDebt == 0, either(priceFeedValue == 0, !hasValidValue)), defaultCRatio == 0)) {
            return MAX_UINT;
        }

        // Calculate the amount of debt that needs to be repaid so the SAFE gets to the target CRatio
        uint256 targetCRatio = (cRatioSetter.desiredCollateralizationRatios(collateralType, safeHandler) == 0) ?
          defaultCRatio : cRatioSetter.desiredCollateralizationRatios(collateralType, safeHandler);

        uint256 targetDebtAmount = mul(
          mul(HUNDRED, mul(depositedCollateralToken, priceFeedValue) / WAD) / targetCRatio, RAY
        ) / oracleRelayer.redemptionPrice();

        // If you need to repay more than the amount of debt in the SAFE (or all the debt), return 0
        if (targetDebtAmount >= safeDebt) {
          return 0;
        } else {
          return div(mul(sub(safeDebt, targetDebtAmount), WAD), yVault.pricePerShare());
        }
    }
}