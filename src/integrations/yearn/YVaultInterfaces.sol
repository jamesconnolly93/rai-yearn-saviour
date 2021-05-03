pragma solidity ^0.6.7;

import "./ComptrollerInterface.sol";
import "./InterestRateModel.sol";
import "./EIP20NonStandardInterface.sol";

contract YVaultStorage {
    /**
     * @dev Guard variable for re-entrancy checks
     */
    bool internal _notEntered;

    /**
     * @notice EIP-20 token name for this token
     */
    string public name;

    /**
     * @notice EIP-20 token symbol for this token
     */
    string public symbol;

    /**
     * @notice EIP-20 token decimals for this token
     */
    uint8 public decimals;

    /**
     * @notice Maximum borrow rate that can ever be applied (.0005% / block)
     */

    uint internal constant borrowRateMaxMantissa = 0.0005e16;

    /**
     * @notice Maximum fraction of interest that can be set aside for reserves
     */
    uint internal constant reserveFactorMaxMantissa = 1e18;

    /**
     * @notice Administrator for this contract
     */
    address payable public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address payable public pendingAdmin;

    /**
     * @notice Contract which oversees inter-YVault operations
     */
    ComptrollerInterface public comptroller;

    /**
     * @notice Model which tells what the current interest rate should be
     */
    InterestRateModel public interestRateModel;

    /**
     * @notice Initial exchange rate used when depositing the first YVaults (used when totalSupply = 0)
     */
    uint internal initialExchangeRateMantissa;

    /**
     * @notice Fraction of interest currently set aside for reserves
     */
    uint public reserveFactorMantissa;

    /**
     * @notice Block number that interest was last accrued at
     */
    uint public accrualBlockNumber;

    /**
     * @notice Accumulator of the total earned interest rate since the opening of the market
     */
    uint public borrowIndex;

    /**
     * @notice Total amount of outstanding borrows of the underlying in this market
     */
    uint public totalBorrows;

    /**
     * @notice Total amount of reserves of the underlying held in this market
     */
    uint public totalReserves;

    /**
     * @notice Total number of tokens in circulation
     */
    uint public totalSupply;

    /**
     * @notice Official record of token balances for each account
     */
    mapping (address => uint) internal accountTokens;

    /**
     * @notice Approved token transfer amounts on behalf of others
     */
    mapping (address => mapping (address => uint)) internal transferAllowances;

    /**
     * @notice Container for borrow balance information
     * @member principal Total balance (with accrued interest), after applying the most recent balance-changing action
     * @member interestIndex Global borrowIndex as of the most recent balance-changing action
     */
    struct BorrowSnapshot {
        uint principal;
        uint interestIndex;
    }

    /**
     * @notice Mapping of account addresses to outstanding borrow balances
     */
    mapping(address => BorrowSnapshot) internal accountBorrows;
}

contract YVaultInterface is YVaultStorage {
    /**
     * @notice Indicator that this is a YVault contract (for inspection)
     */
    bool public constant isYVault = true;


    /*** Market Events ***/

    /**
     * @notice Event emitted when interest is accrued
     */
    event AccrueInterest(uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);

    /**
     * @notice Event emitted when tokens are deposited
     */
    event Deposit(address depositer, uint depositAmount, uint depositTokens);

    /**
     * @notice Event emitted when tokens are withdrawed
     */
    event Withdraw(address withdrawer, uint withdrawAmount, uint withdrawTokens);

    /**
     * @notice Event emitted when underlying is borrowed
     */
    event Borrow(address borrower, uint borrowAmount, uint accountBorrows, uint totalBorrows);

    /**
     * @notice Event emitted when a borrow is repaid
     */
    event RepayBorrow(address payer, address borrower, uint repayAmount, uint accountBorrows, uint totalBorrows);

    /**
     * @notice Event emitted when a borrow is liquidated
     */
    event LiquidateBorrow(address liquidator, address borrower, uint repayAmount, address YVaultCollateral, uint seizeTokens);


    /*** Admin Events ***/

    /**
     * @notice Event emitted when pendingAdmin is changed
     */
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /**
     * @notice Event emitted when pendingAdmin is accepted, which means admin is updated
     */
    event NewAdmin(address oldAdmin, address newAdmin);

    /**
     * @notice Event emitted when comptroller is changed
     */
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);

    /**
     * @notice Event emitted when interestRateModel is changed
     */
    event NewMarketInterestRateModel(InterestRateModel oldInterestRateModel, InterestRateModel newInterestRateModel);

    /**
     * @notice Event emitted when the reserve factor is changed
     */
    event NewReserveFactor(uint oldReserveFactorMantissa, uint newReserveFactorMantissa);

    /**
     * @notice Event emitted when the reserves are added
     */
    event ReservesAdded(address benefactor, uint addAmount, uint newTotalReserves);

    /**
     * @notice Event emitted when the reserves are reduced
     */
    event ReservesReduced(address admin, uint reduceAmount, uint newTotalReserves);

    /**
     * @notice EIP20 Transfer event
     */
    event Transfer(address indexed from, address indexed to, uint amount);

    /**
     * @notice EIP20 Approval event
     */
    event Approval(address indexed owner, address indexed spender, uint amount);

    /**
     * @notice Failure event
     */
    event Failure(uint error, uint info, uint detail);


    /*** User Interface ***/

    function transfer(address dst, uint amount) virtual external returns (bool) {}
    function transferFrom(address src, address dst, uint amount) virtual external returns (bool) {}
    function approve(address spender, uint amount) virtual external returns (bool) {}
    function allowance(address owner, address spender) virtual external view returns (uint) {}
    function balanceOf(address owner) virtual external view returns (uint) {}
    function balanceOfUnderlying(address owner) virtual external returns (uint) {}
    function getAccountSnapshot(address account) virtual external view returns (uint, uint, uint, uint) {}
    function borrowRatePerBlock() virtual external view returns (uint) {}
    function supplyRatePerBlock() virtual external view returns (uint) {}
    function totalBorrowsCurrent() virtual external returns (uint) {}
    function borrowBalanceCurrent(address account) virtual external returns (uint) {}
    function borrowBalanceStored(address account) virtual public view returns (uint) {}
    function exchangeRateCurrent() virtual public returns (uint) {}
    function exchangeRateStored() virtual public view returns (uint) {}
    function getCash() virtual external view returns (uint) {}
    function accrueInterest() virtual public returns (uint) {}
    function seize(address liquidator, address borrower, uint seizeTokens) virtual external returns (uint) {}


    /*** Admin Functions ***/

    function _setPendingAdmin(address payable newPendingAdmin) virtual external returns (uint) {}
    function _acceptAdmin() virtual external returns (uint) {}
    function _setComptroller(ComptrollerInterface newComptroller) virtual public returns (uint) {}
    function _setReserveFactor(uint newReserveFactorMantissa) virtual external returns (uint) {}
    function _reduceReserves(uint reduceAmount) virtual external returns (uint) {}
    function _setInterestRateModel(InterestRateModel newInterestRateModel) virtual public returns (uint) {}
}

contract YErc20Storage {
    /**
     * @notice Underlying asset for this YVault
     */
    address public underlying;
}

abstract contract YErc20Interface is YErc20Storage {

    /*** User Interface ***/

    function deposit(uint depositAmount) virtual external returns (uint) {}
    function withdraw(uint withdrawTokens) virtual external returns (uint) {}
    function withdrawUnderlying(uint withdrawAmount) virtual external returns (uint) {}
    function borrow(uint borrowAmount) virtual external returns (uint) {}
    function repayBorrow(uint repayAmount) virtual external returns (uint) {}
    function repayBorrowBehalf(address borrower, uint repayAmount) virtual external returns (uint) {}
    function liquidateBorrow(address borrower, uint repayAmount, YVaultInterface YVaultCollateral) virtual external returns (uint) {}
    function sweepToken(EIP20NonStandardInterface token) virtual external {}


    /*** Admin Functions ***/

    function _addReserves(uint addAmount) virtual external returns (uint);
}

contract CDelegationStorage {
    /**
     * @notice Implementation address for this contract
     */
    address public implementation;
}

contract CDelegatorInterface is CDelegationStorage {
    /**
     * @notice Emitted when implementation is changed
     */
    event NewImplementation(address oldImplementation, address newImplementation);

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param implementation_ The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(address implementation_, bool allowResign, bytes memory becomeImplementationData) virtual public {}
}

contract CDelegateInterface is CDelegationStorage {
    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @dev Should revert if any issues arise which make it unfit for delegation
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) virtual public {}

    /**admin
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() virtual public {}
}
