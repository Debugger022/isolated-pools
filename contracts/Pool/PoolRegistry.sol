// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.13;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ResilientOracleInterface } from "@venusprotocol/oracle/contracts/interfaces/OracleInterface.sol";
import { AccessControlManager } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlManager.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

import { PoolRegistryInterface } from "./PoolRegistryInterface.sol";
import { Comptroller } from "../Comptroller.sol";
import { VTokenProxyFactory } from "../Factories/VTokenProxyFactory.sol";
import { JumpRateModelFactory } from "../Factories/JumpRateModelFactory.sol";
import { WhitePaperInterestRateModelFactory } from "../Factories/WhitePaperInterestRateModelFactory.sol";
import { WhitePaperInterestRateModel } from "../WhitePaperInterestRateModel.sol";
import { VToken } from "../VToken.sol";
import { InterestRateModel } from "../InterestRateModel.sol";
import { Shortfall } from "../Shortfall/Shortfall.sol";
import { VTokenInterface } from "../VTokenInterfaces.sol";
import { ensureNonzeroAddress } from "../lib/validators.sol";

/**
 * @title PoolRegistry
 * @notice PoolRegistry is a registry for Venus interest rate pools.
 */
contract PoolRegistry is Ownable2StepUpgradeable, AccessControlledV8, PoolRegistryInterface {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    enum InterestRateModels {
        WhitePaper,
        JumpRate
    }

    struct AddMarketInput {
        address comptroller;
        address asset;
        uint8 decimals;
        string name;
        string symbol;
        InterestRateModels rateModel;
        uint256 baseRatePerYear;
        uint256 multiplierPerYear;
        uint256 jumpMultiplierPerYear;
        uint256 kink_;
        uint256 collateralFactor;
        uint256 liquidationThreshold;
        uint256 reserveFactor;
        AccessControlManager accessControlManager;
        address beaconAddress;
        uint256 initialSupply;
        address vTokenReceiver;
        uint256 supplyCap;
        uint256 borrowCap;
    }

    uint256 internal constant MAX_POOL_NAME_LENGTH = 100;

    /**
     * @notice VTokenProxyFactory contract address
     */
    VTokenProxyFactory public vTokenFactory;

    /**
     * @notice JumpRateModelFactory contract address
     */
    JumpRateModelFactory public jumpRateFactory;

    /**
     * @notice WhitePaperInterestRateModelFactory contract address
     */
    WhitePaperInterestRateModelFactory public whitePaperFactory;

    /**
     * @notice Shortfall contract address
     */
    Shortfall public shortfall;

    /**
     * @notice Shortfall contract address
     */
    address payable public protocolShareReserve;

    /**
     * @notice Maps pool's comptroller address to metadata.
     */
    mapping(address => VenusPoolMetaData) public metadata;

    /**
     * @dev Maps pool ID to pool's comptroller address
     */
    mapping(uint256 => address) private _poolsByID;

    /**
     * @dev Total number of pools created.
     */
    uint256 private _numberOfPools;

    /**
     * @dev Maps comptroller address to Venus pool Index.
     */
    mapping(address => VenusPool) private _poolByComptroller;

    /**
     * @dev Maps pool's comptroller address to asset to vToken.
     */
    mapping(address => mapping(address => address)) private _vTokens;

    /**
     * @dev Maps asset to list of supported pools.
     */
    mapping(address => address[]) private _supportedPools;

    /**
     * @dev Emitted when a new Venus pool is added to the directory.
     */
    event PoolRegistered(address indexed comptroller, VenusPool pool);

    /**
     * @dev Emitted when a pool name is set.
     */
    event PoolNameSet(address indexed comptroller, string oldName, string newName);

    /**
     * @dev Emitted when a pool metadata is updated.
     */
    event PoolMetadataUpdated(
        address indexed comptroller,
        VenusPoolMetaData oldMetadata,
        VenusPoolMetaData newMetadata
    );

    /**
     * @dev Emitted when a Market is added to the pool.
     */
    event MarketAdded(address indexed comptroller, address indexed vTokenAddress);

    /**
     * @notice Event emitted when shortfall contract address is changed
     */
    event NewShortfallContract(address indexed oldShortfall, address indexed newShortfall);

    /**
     * @notice Event emitted when protocol share reserve contract address is changed
     */
    event NewProtocolShareReserve(address indexed oldProtocolShareReserve, address indexed newProtocolShareReserve);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Note that the contract is upgradeable. Use initialize() or reinitializers
        // to set the state variables.
        _disableInitializers();
    }

    /**
     * @dev Initializes the deployer to owner
     * @param vTokenFactory_ vToken factory address
     * @param jumpRateFactory_ jump rate factory address
     * @param whitePaperFactory_ white paper factory address
     * @param protocolShareReserve_ protocol's shares reserve address
     * @param shortfall_ Shortfall contract address
     * @param accessControlManager_ AccessControlManager contract address
     * @custom:error ZeroAddressNotAllowed is thrown when shortfall contract address is zero
     * @custom:error ZeroAddressNotAllowed is thrown when protocol share reserve address is zero
     */
    function initialize(
        VTokenProxyFactory vTokenFactory_,
        JumpRateModelFactory jumpRateFactory_,
        WhitePaperInterestRateModelFactory whitePaperFactory_,
        Shortfall shortfall_,
        address payable protocolShareReserve_,
        address accessControlManager_
    ) external initializer {
        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager_);

        vTokenFactory = vTokenFactory_;
        jumpRateFactory = jumpRateFactory_;
        whitePaperFactory = whitePaperFactory_;
        _setShortfallContract(shortfall_);
        _setProtocolShareReserve(protocolShareReserve_);
    }

    /**
     * @notice Sets protocol share reserve contract address
     * @param protocolShareReserve_ The address of the protocol share reserve contract
     * @custom:error ZeroAddressNotAllowed is thrown when protocol share reserve address is zero
     * @custom:access Only Governance
     */
    function setProtocolShareReserve(address payable protocolShareReserve_) external onlyOwner {
        _setProtocolShareReserve(protocolShareReserve_);
    }

    /**
     * @notice Sets shortfall contract address
     * @param shortfall_ The address of the shortfall contract
     * @custom:error ZeroAddressNotAllowed is thrown when shortfall contract address is zero
     * @custom:access Only Governance
     */
    function setShortfallContract(Shortfall shortfall_) external onlyOwner {
        _setShortfallContract(shortfall_);
    }

    /**
     * @dev Deploys a new Venus pool and adds to the directory.
     * @param name The name of the pool
     * @param beaconAddress The upgradeable beacon contract address for Comptroller implementation
     * @param closeFactor The pool's close factor (scaled by 1e18)
     * @param liquidationIncentive The pool's liquidation incentive (scaled by 1e18)
     * @param minLiquidatableCollateral Minimal collateral for regular (non-batch) liquidations flow
     * @param priceOracle The pool's price oracle address
     * @param maxLoopsLimit The maximum number of iterations the loops can perform
     * @param accessControlManager AccessControlManager contract address
     * @return index The index of the registered Venus pool
     * @return proxyAddress The the Comptroller proxy address
     * @custom:error ZeroAddressNotAllowed is thrown when Comptroller beacon address is zero
     * @custom:error ZeroAddressNotAllowed is thrown when price oracle address is zero
     */
    function createRegistryPool(
        string calldata name,
        address beaconAddress,
        uint256 closeFactor,
        uint256 liquidationIncentive,
        uint256 minLiquidatableCollateral,
        address priceOracle,
        uint256 maxLoopsLimit,
        address accessControlManager
    ) external virtual returns (uint256 index, address proxyAddress) {
        _checkAccessAllowed("createRegistryPool(string,address,uint256,uint256,uint256,address,uint256,address)");
        // Input validation
        ensureNonzeroAddress(beaconAddress);
        ensureNonzeroAddress(priceOracle);

        BeaconProxy proxy = new BeaconProxy(
            beaconAddress,
            abi.encodeWithSelector(Comptroller.initialize.selector, maxLoopsLimit, accessControlManager)
        );

        proxyAddress = address(proxy);
        Comptroller comptrollerProxy = Comptroller(proxyAddress);

        uint256 poolId = _registerPool(name, proxyAddress);

        // Set Venus pool parameters
        comptrollerProxy.setCloseFactor(closeFactor);
        comptrollerProxy.setLiquidationIncentive(liquidationIncentive);
        comptrollerProxy.setMinLiquidatableCollateral(minLiquidatableCollateral);
        comptrollerProxy.setPriceOracle(ResilientOracleInterface(priceOracle));

        // Start transferring ownership to msg.sender
        comptrollerProxy.transferOwnership(msg.sender);

        // Register the pool with this PoolRegistry
        return (poolId, proxyAddress);
    }

    /**
     * @notice Add a market to an existing pool and then mint to provide initial supply.
     * @param input The structure describing the parameters for adding a market to a pool.
     * @custom:error ZeroAddressNotAllowed is thrown when Comptroller address is zero
     * @custom:error ZeroAddressNotAllowed is thrown when asset address is zero
     * @custom:error ZeroAddressNotAllowed is thrown when VToken beacon address is zero
     * @custom:error ZeroAddressNotAllowed is thrown when vTokenReceiver address is zero
     */
    function addMarket(AddMarketInput memory input) external {
        _checkAccessAllowed("addMarket(AddMarketInput)");
        ensureNonzeroAddress(input.comptroller);
        ensureNonzeroAddress(input.asset);
        ensureNonzeroAddress(input.beaconAddress);
        ensureNonzeroAddress(input.vTokenReceiver);

        // solhint-disable-next-line reason-string
        require(
            _vTokens[input.comptroller][input.asset] == address(0),
            "PoolRegistry: Market already added for asset comptroller combination"
        );

        InterestRateModel rate;
        if (input.rateModel == InterestRateModels.JumpRate) {
            rate = InterestRateModel(
                jumpRateFactory.deploy(
                    input.baseRatePerYear,
                    input.multiplierPerYear,
                    input.jumpMultiplierPerYear,
                    input.kink_,
                    input.accessControlManager
                )
            );
        } else {
            rate = InterestRateModel(whitePaperFactory.deploy(input.baseRatePerYear, input.multiplierPerYear));
        }

        Comptroller comptroller = Comptroller(input.comptroller);
        uint256 underlyingDecimals = IERC20Metadata(input.asset).decimals();

        VTokenProxyFactory.VTokenArgs memory initializeArgs = VTokenProxyFactory.VTokenArgs(
            input.asset,
            comptroller,
            rate,
            10**(underlyingDecimals + 18 - input.decimals),
            input.name,
            input.symbol,
            input.decimals,
            msg.sender,
            input.accessControlManager,
            VTokenInterface.RiskManagementInit(address(shortfall), protocolShareReserve),
            input.beaconAddress,
            input.reserveFactor
        );

        VToken vToken = vTokenFactory.deployVTokenProxy(initializeArgs);

        comptroller.supportMarket(vToken);
        comptroller.setCollateralFactor(vToken, input.collateralFactor, input.liquidationThreshold);

        uint256[] memory newSupplyCaps = new uint256[](1);
        uint256[] memory newBorrowCaps = new uint256[](1);
        VToken[] memory vTokens = new VToken[](1);

        newSupplyCaps[0] = input.supplyCap;
        newBorrowCaps[0] = input.borrowCap;
        vTokens[0] = vToken;

        comptroller.setMarketSupplyCaps(vTokens, newSupplyCaps);
        comptroller.setMarketBorrowCaps(vTokens, newBorrowCaps);

        _vTokens[input.comptroller][input.asset] = address(vToken);
        _supportedPools[input.asset].push(input.comptroller);

        IERC20Upgradeable token = IERC20Upgradeable(input.asset);
        uint256 amountToSupply = _transferIn(token, msg.sender, input.initialSupply);
        token.approve(address(vToken), 0);
        token.approve(address(vToken), amountToSupply);
        vToken.mintBehalf(input.vTokenReceiver, amountToSupply);

        emit MarketAdded(address(comptroller), address(vToken));
    }

    /**
     * @notice Modify existing Venus pool name
     * @param comptroller Pool's Comptroller
     * @param name New pool name
     */
    function setPoolName(address comptroller, string calldata name) external {
        _checkAccessAllowed("setPoolName(address,string)");
        _ensureValidName(name);
        string memory oldName = _poolByComptroller[comptroller].name;
        _poolByComptroller[comptroller].name = name;
        emit PoolNameSet(comptroller, oldName, name);
    }

    /**
     * @notice Update metadata of an existing pool
     * @param comptroller Pool's Comptroller
     * @param metadata_ New pool metadata
     */
    function updatePoolMetadata(address comptroller, VenusPoolMetaData memory metadata_) external {
        _checkAccessAllowed("updatePoolMetadata(address,VenusPoolMetaData)");
        VenusPoolMetaData memory oldMetadata = metadata[comptroller];
        metadata[comptroller] = metadata_;
        emit PoolMetadataUpdated(comptroller, oldMetadata, metadata_);
    }

    /**
     * @notice Returns arrays of all Venus pools' data
     * @dev This function is not designed to be called in a transaction: it is too gas-intensive
     * @return A list of all pools within PoolRegistry, with details for each pool
     */
    function getAllPools() external view override returns (VenusPool[] memory) {
        VenusPool[] memory _pools = new VenusPool[](_numberOfPools);
        for (uint256 i = 1; i <= _numberOfPools; ++i) {
            address comptroller = _poolsByID[i];
            _pools[i - 1] = (_poolByComptroller[comptroller]);
        }
        return _pools;
    }

    /**
     * @param comptroller The comptroller proxy address associated to the pool
     * @return  Returns Venus pool
     */
    function getPoolByComptroller(address comptroller) external view override returns (VenusPool memory) {
        return _poolByComptroller[comptroller];
    }

    /**
     * @param comptroller comptroller of Venus pool
     * @return Returns Metadata of Venus pool
     */
    function getVenusPoolMetadata(address comptroller) external view override returns (VenusPoolMetaData memory) {
        return metadata[comptroller];
    }

    function getVTokenForAsset(address comptroller, address asset) external view override returns (address) {
        return _vTokens[comptroller][asset];
    }

    function getPoolsSupportedByAsset(address asset) external view override returns (address[] memory) {
        return _supportedPools[asset];
    }

    /**
     * @dev Adds a new Venus pool to the directory (without checking msg.sender).
     * @param name The name of the pool
     * @param comptroller The pool's Comptroller proxy contract address
     * @return The index of the registered Venus pool
     */
    function _registerPool(string calldata name, address comptroller) internal returns (uint256) {
        VenusPool memory venusPool = _poolByComptroller[comptroller];

        require(venusPool.creator == address(0), "PoolRegistry: Pool already exists in the directory.");
        _ensureValidName(name);

        _numberOfPools++;

        VenusPool memory pool = VenusPool(name, msg.sender, comptroller, block.number, block.timestamp);

        _poolsByID[_numberOfPools] = comptroller;
        _poolByComptroller[comptroller] = pool;

        emit PoolRegistered(comptroller, pool);
        return _numberOfPools;
    }

    function _transferIn(
        IERC20Upgradeable token,
        address from,
        uint256 amount
    ) internal returns (uint256) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function _setShortfallContract(Shortfall shortfall_) internal {
        ensureNonzeroAddress(address(shortfall_));
        address oldShortfall = address(shortfall);
        shortfall = shortfall_;
        emit NewShortfallContract(oldShortfall, address(shortfall_));
    }

    function _setProtocolShareReserve(address payable protocolShareReserve_) internal {
        ensureNonzeroAddress(protocolShareReserve_);
        address oldProtocolShareReserve = protocolShareReserve;
        protocolShareReserve = protocolShareReserve_;
        emit NewProtocolShareReserve(oldProtocolShareReserve, protocolShareReserve_);
    }

    function _ensureValidName(string calldata name) internal pure {
        require(bytes(name).length <= MAX_POOL_NAME_LENGTH, "Pool's name is too large");
    }
}
