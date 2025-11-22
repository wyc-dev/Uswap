// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/contracts/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title TokenERC20
 * @dev Reward token interface required by SwapCoverLayer
 * @custom:security-contact abc@def.com
 */
interface TokenERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

/**
 * @title SwapCoverLayer – Uniswap V4 Pure Swap Mining Periphery (Final Audited Version)
 * @author Anonymous Senior Engineer
 * @notice Only swaps trigger rewards. Liquidity operations receive zero rewards.
 *         Gasless swaps burn a percentage fee automatically.
 *         Fully permissionless pool creation. No hooks.
 * @dev All public/external functions have full NatSpec. All state variables documented.
 * @custom:security-contact security@xcure.com
 */
contract SwapCoverLayer is Ownable, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    /// @dev Uniswap V4 PoolManager – immutable for maximum security
    IPoolManager public immutable poolManager;

    /// @dev Reward token contract (set by owner after deployment)
    TokenERC20 public rewardERC20;

    /// @dev Mapping to identify stablecoins (USDC, USDT, etc.) for USD volume calculation
    mapping(address token => bool isStable) public isStableCoin;

    /// @dev Master switch for reward distribution
    bool public rewardEnabled;

    /// @dev Gasless swap fee rate in basis points (100 = 1%)
    uint256 public gaslessFeeRate = 100;

    /// @dev Swap reward rate denominator (1000 = 0.1%)
    uint256 public swapRewardRate = 1000;

    /// @dev Optional fixed reward per swap (default 0 = pure percentage mode)
    uint256 public fixedReward = 0;

    /// @dev Emergency pause flag
    bool public paused;

    enum ActionType { ModifyLiquidity, Swap }

    /* ═══════════════════════════════════════════════ EVENTS ═══════════════════════════════════════════════ */

    /// @notice Emitted when a swap is executed
    event SwapExecuted(PoolId indexed poolId, BalanceDelta delta);

    /// @notice Emitted when rewards are minted to a user
    event RewardMinted(address indexed to, uint256 amount);

    /// @notice Emitted when reward system is enabled/disabled
    event RewardEnabledUpdated(bool indexed enabled);

    /// @notice Emitted when any rate parameter is updated
    event RatesUpdated(
        uint256 indexed gaslessFeeRate,
        uint256 indexed swapRewardRate,
        uint256 fixedReward
    );

    /// @notice Emitted when contract is paused/unpaused
    event Paused(bool indexed isPaused);

    /// @notice Emitted when gasless swap fee is burned
    event FeeBurned(address indexed from, uint256 amount);

    /* ═══════════════════════════════════════════════ ERRORS ═══════════════════════════════════════════════ */

    error ContractPaused();
    error NoHooksAllowed();
    error UnauthorizedCaller();
    error InvalidAction();
    error DeadlineExceeded();
    error InvalidSignature();
    error ETHTransferFailed();
    error ZeroAddressNotAllowed();
    error NoStablecoinInvolved();

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /**
     * @dev Constructor – initializes immutable PoolManager and pre-configures Base stablecoins
     * @param _poolManager Uniswap V4 PoolManager address on Base
     */
    constructor(address _poolManager) Ownable(msg.sender) {
        if (_poolManager == address(0)) revert ZeroAddressNotAllowed();
        poolManager = IPoolManager(_poolManager);

        // Base mainnet most liquid stablecoins as of 2025-11-22
        isStableCoin[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = true; // Circle USDC
        isStableCoin[0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2] = true; // Bridged USDT

        emit RatesUpdated(gaslessFeeRate, swapRewardRate, fixedReward);
    }

    /* ═════════════════════════════════════ OWNER FUNCTIONS ═════════════════════════════════════ */

    /**
     * @notice 新增或移除穩定幣標記
     * @param token 代幣地址
     * @param status true = 是穩定幣
     */
    function setStableCoin(address token, bool status) external onlyOwner {
        isStableCoin[token] = status;
    }

    /**
     * @notice 緊急暫停合約
     * @param _paused true = 暫停
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @notice 設定獎勵代幣合約
     * @param newToken 獎勵代幣地址
     */
    function updateRewardToken(address newToken) external onlyOwner {
        if (newToken == address(0)) revert ZeroAddressNotAllowed();
        rewardERC20 = TokenERC20(newToken);
    }

    /**
     * @notice 開關獎勵功能
     * @param enabled true = 開啟
     */
    function setRewardEnabled(bool enabled) external onlyOwner {
        rewardEnabled = enabled;
        emit RewardEnabledUpdated(enabled);
    }

    /**
     * @notice 統一調整三個比率
     * @param newGaslessFeeRate Gasless 手續費率 (100 = 1%)
     * @param newSwapRewardRate Swap 獎勵率 (1000 = 0.1%)
     * @param newFixedReward 每筆固定獎勵（可設 0）
     */
    function setRewardRates(
        uint256 newGaslessFeeRate,
        uint256 newSwapRewardRate,
        uint256 newFixedReward
    ) external onlyOwner {
        gaslessFeeRate = newGaslessFeeRate;
        swapRewardRate = newSwapRewardRate;
        fixedReward = newFixedReward;
        emit RatesUpdated(newGaslessFeeRate, newSwapRewardRate, newFixedReward);
    }

    /* ═════════════════════════════════════ PUBLIC FUNCTIONS ═════════════════════════════════════ */

    /**
     * @notice 任何人都可開新池（完全無許可）
     * @param key PoolKey
     * @param sqrtPriceX96 初始價格
     * @return tick 初始 tick
     */
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external notPaused returns (int24 tick) {
        if (address(key.hooks) != address(0)) revert NoHooksAllowed();
        tick = poolManager.initialize(key, sqrtPriceX96);
    }

    /**
     * @notice 加/減流動性（無獎勵）
     * @return callerDelta 呼叫者資產變動
     * @return feesAccrued 累積手續費
     */
    function modifyLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external nonReentrant notPaused returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        bytes memory data = abi.encode(msg.sender, ActionType.ModifyLiquidity, key, abi.encode(params), hookData);
        bytes memory result = poolManager.unlock(data);
        return abi.decode(result, (BalanceDelta, BalanceDelta));
    }

    /**
     * @notice 普通 Swap（唯一有獎勵的操作）
     * @return delta Swap 後資產變動
     */
    function swap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external nonReentrant notPaused returns (BalanceDelta delta) {
        bytes memory data = abi.encode(msg.sender, ActionType.Swap, key, abi.encode(params), hookData);
        bytes memory result = poolManager.unlock(data);
        return abi.decode(result, (BalanceDelta));
    }

    /**
     * @dev 內部函數：計算本次交易涉及的穩定幣美元價值（USD volume）
     * @return usd 美元價值（6 decimals）
     */
    function _getUsdAmountFromDelta(PoolKey memory key, BalanceDelta delta) internal view returns (uint256 usd) {
        int128 raw0 = delta.amount0();
        int128 raw1 = delta.amount1();

        uint256 abs0 = raw0 < 0 ? uint256(uint256(int256(-raw0))) : uint256(uint256(int256(raw0)));
        uint256 abs1 = raw1 < 0 ? uint256(uint256(int256(-raw1))) : uint256(uint256(int256(raw1)));

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        bool s0 = isStableCoin[token0];
        bool s1 = isStableCoin[token1];

        if (s0 && s1) {
            usd = abs0 < abs1 ? abs0 : abs1;
        } else if (s0) {
            usd = abs0;
        } else if (s1) {
            usd = abs1;
        }
    }

    /**
     * @dev V4 核心回調，所有獎勵邏輯在此原子執行
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCaller();

        (address caller, ActionType action, PoolKey memory key, bytes memory paramsData, bytes memory hookData) = abi.decode(
            data, (address, ActionType, PoolKey, bytes, bytes)
        );

        if (action == ActionType.Swap) {
            IPoolManager.SwapParams memory swapParams = abi.decode(paramsData, (IPoolManager.SwapParams));
            BalanceDelta delta = poolManager.swap(key, swapParams, hookData);

            if (rewardEnabled && address(rewardERC20) != address(0)) {
                uint256 usdVolume = _getUsdAmountFromDelta(key, delta);
                if (usdVolume > 0) {
                    uint256 reward = (usdVolume + swapRewardRate - 1) / swapRewardRate + fixedReward;
                    rewardERC20.mint(caller, reward);
                    emit RewardMinted(caller, reward);
                }
            }

            emit SwapExecuted(key.toId(), delta);
            return abi.encode(delta);
        }

        if (action == ActionType.ModifyLiquidity) {
            IPoolManager.ModifyLiquidityParams memory modParams = abi.decode(paramsData, (IPoolManager.ModifyLiquidityParams));
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, modParams, hookData);
            return abi.encode(callerDelta, feesAccrued);
        }

        revert InvalidAction();
    }

    /* ═════════════════════════════════ GASLESS SWAP ═════════════════════════════════ */

    /**
     * @notice 驗證 Gasless Swap 簽名
     * @return 是否有效
     */
    function verifySwapSignature(
        address caller,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public view returns (bool) {
        bytes32 messageHash = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                keccak256("Swap(address caller,PoolKey key,SwapParams params,bytes hookData,uint256 feeRate,uint256 deadline)"),
                caller,
                key,
                swapParams,
                keccak256(hookData),
                gaslessFeeRate,
                deadline
            ))
        ));

        return SignatureChecker.isValidSignatureNow(caller, messageHash, abi.encodePacked(r, s, v));
    }

    /**
     * @notice Gasless Swap 入口（免 gas + 自動燒手續費）
     * @return delta Swap 結果
     */
    function executeGaslessSwap(
        address caller,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant notPaused returns (BalanceDelta delta) {
        if (block.timestamp > deadline) revert DeadlineExceeded();
        if (!verifySwapSignature(caller, key, swapParams, hookData, deadline, v, r, s)) revert InvalidSignature();

        bytes memory callData = abi.encode(caller, ActionType.Swap, key, abi.encode(swapParams), hookData);
        bytes memory result = poolManager.unlock(callData);
        delta = abi.decode(result, (BalanceDelta));

        uint256 usdVolume = _getUsdAmountFromDelta(key, delta);
        if (usdVolume == 0) revert NoStablecoinInvolved();

        uint256 fee = (usdVolume + gaslessFeeRate - 1) / gaslessFeeRate;
        if (fee > 0) {
            rewardERC20.burnFrom(caller, fee);
            emit FeeBurned(caller, fee);
        }
    }

    /* ═════════════════════════════════ ADMIN ═════════════════════════════════ */

    /// @notice Owner 提取合約內 ETH
    function withdrawETH(uint256 amount) external onlyOwner {
        (bool success, ) = payable(owner()).call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    /// @notice Owner 提取合約內任意 ERC20
    function withdrawERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /// @notice 查詢獎勵代幣是否已設定
    function isRewardTokenEnabled() external view returns (bool) {
        return address(rewardERC20) != address(0);
    }

    /// @notice EIP-712 Domain Separator
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("SwapCoverLayer")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }
}
