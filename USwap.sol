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
 * @dev 獎勵代幣介面（延伸 IERC20，加入鑄幣與燒幣功能）
 * @custom:security-contact security@xcure.com
 */
interface TokenERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

/**
 * @title SwapCoverLayer – 純 Swap 獎勵專用周邊層（極簡終極版）
 * @dev 本合約專注於 Uniswap V4 的 Swap 獎勵機制：
 *   - 只有 Swap 操作會觸發獎勵（加/減流動性完全無獎勵）
 *   - 獎勵完全基於穩定幣（USDC/USDT）美元價值計算
 *   - 任何人都可以初始化池子（initializePool 已公開）
 *   - 不使用任何 Hook，所有邏輯在 unlockCallback 原子執行
 *   - 支援 Gasless Swap（EIP-712 簽名代付 gas，手續費燒毀）
 * @custom:security-contact security@xcure.com
 */
contract SwapCoverLayer is Ownable, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    /// @dev Uniswap V4 PoolManager 合約（immutable，部署後不可更改）
    IPoolManager public immutable poolManager;

    /// @dev 獎勵代幣合約
    TokenERC20 public rewardERC20;

    /// @dev 穩定幣快速查找映射（USDC、USDT 等 6 decimals 穩定幣）
    mapping(address token => bool isStable) public isStableCoin;

    /// @dev 是否啟用獎勵功能
    bool public rewardEnabled;

    /// @dev Gasless 手續費比率，預設 1%（100 = 1%）
    uint256 public gaslessFeeRate = 100;

    /// @dev Swap 獎勵比率分母（例如 1000 = 0.1%，100 USDT 獎勵 0.1 顆）
    uint256 public swapRewardRate;

    /// @dev 固定獎勵額度（預設 0，純百分比模式，可由 owner 調整）
    uint256 public fixedReward;

    /// @dev 緊急暫停旗標（暫停所有外部操作）
    bool public paused;

    enum ActionType { ModifyLiquidity, Swap }

    // ==================== 事件 ====================

    /// @dev 當池子初始化時發出（純記錄用）
    event PoolInitialized(PoolId indexed poolId);

    /// @dev 當流動性變更時發出（僅記錄，無獎勵）
    event LiquidityModified(PoolId indexed poolId, BalanceDelta delta, BalanceDelta feesAccrued);

    /// @dev 當 Swap 執行完成並計算獎勵時發出
    event SwapExecuted(PoolId indexed poolId, BalanceDelta delta);

    /// @dev 當獎勵代幣被鑄造時發出
    event RewardMinted(address indexed to, uint256 amount);

    /// @dev 當獎勵功能開關變更時發出
    event RewardEnabledUpdated(bool indexed enabled);

    /// @dev 當獎勵參數更新時發出
    event RatesUpdated(uint256 indexed feeRate, uint256 indexed swapRate, uint256 indexed fixedAmount);

    /// @dev 當合約暫停狀態變更時發出
    event Paused(bool indexed isPaused);

    /// @dev 當 Gasless Swap 手續費被燒毀時發出
    event FeeBurned(address indexed from, uint256 amount);

    // ==================== 錯誤 ====================

    error ContractPaused();              // 合約已暫停
    error NoHooksAllowed();             // 不允許使用 Hooks（安全考量）
    error UnauthorizedCaller();          // 非 PoolManager 呼叫
    error RewardExceedsMaxPerAction();   // 獎勵超過單次上限
    error InvalidAction();               // 無效的操作類型
    error DeadlineExceeded();             // 簽名已過期
    error InvalidSignature();            // 簽名驗證失敗
    error ETHTransferFailed();           // ETH 轉帳失敗
    error TokenNotInitialized();         // 獎勵代幣尚未設定
    error NoStablecoinInvolved();        // Gasless Swap 必須涉及穩定幣

    /// @dev 若合約暫停則 revert
    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /**
     * @dev 建構子
     * @param _poolManager PoolManager 地址（Base 鏈主網地址）
     */
    constructor(address _poolManager) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);

        // 2025年11月22日 Base 鏈最活躍穩定幣地址（已確認無變）
        isStableCoin[0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913] = true; // Circle 原生 USDC（最主流）
        isStableCoin[0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2] = true; // Bridged USDT（交易量最大）

        rewardEnabled = false;
        gaslessFeeRate = 100;          // 預設 1%
        swapRewardRate = 1000;          // 預設 0.1%
        fixedReward = 0;                // 純百分比模式

        emit RatesUpdated(gaslessFeeRate, swapRewardRate, fixedReward);
    }

    /**
     * @dev Owner 可新增或移除穩定幣標記（適應未來新版本）
     */
    function setStableCoin(address token, bool status) external onlyOwner {
        isStableCoin[token] = status;
    }

    /**
     * @dev 緊急暫停 / 恢復合約功能
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /**
     * @dev 更新獎勵代幣地址
     */
    function updateRewardToken(address _newRewardERC20) external onlyOwner {
        require(_newRewardERC20 != address(0), "Address(0) not allowed.");
        rewardERC20 = TokenERC20(_newRewardERC20);
    }

    /**
     * @dev 開關獎勵功能
     */
    function setRewardEnabled(bool _enabled) external onlyOwner {
        rewardEnabled = _enabled;
        emit RewardEnabledUpdated(_enabled);
    }

    /**
     * @dev 設定獎勵參數
     * @param _gaslessFeeRate Gasless Swap 手續費
     * @param _swapRewardRate Swap 獎勵分母
     * @param _fixedReward 固定獎勵（可選）
     */
    function setRewardRates(
        uint256 _swapRewardRate,
        uint256 _fixedReward,
        uint256 _gaslessFeeRate
    ) external onlyOwner {
        swapRewardRate = _swapRewardRate;
        fixedReward = _fixedReward;
        gaslessFeeRate = _gaslessFeeRate;
        emit RatesUpdated(_gaslessFeeRate, _swapRewardRate, _fixedReward);
    }

    /**
     * @dev 公開函數：任何人都可以開新池子
     */
    function initializePool(
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external notPaused returns (int24 tick) {
        if (address(key.hooks) != address(0)) revert NoHooksAllowed();
        tick = poolManager.initialize(key, sqrtPriceX96);
        emit PoolInitialized(key.toId());
    }

    /**
     * @dev 加/減流動性（無獎勵）
     */
    function modifyLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external nonReentrant notPaused returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        bytes memory data = abi.encode(msg.sender, ActionType.ModifyLiquidity, key, abi.encode(params), hookData);
        bytes memory result = poolManager.unlock(data);
        (callerDelta, feesAccrued) = abi.decode(result, (BalanceDelta, BalanceDelta));
    }

    /**
     * @dev Swap 入口（唯一有獎勵的操作）
     */
    function swap(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external nonReentrant notPaused returns (BalanceDelta delta) {
        bytes memory data = abi.encode(msg.sender, ActionType.Swap, key, abi.encode(params), hookData);
        bytes memory result = poolManager.unlock(data);
        delta = abi.decode(result, (BalanceDelta));
    }

    /**
     * @dev 計算 USD 交易量（僅穩定幣部分）
     *      兩邊都是穩定幣時取較小值（標準 USD volume 計算方式）
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
     * @dev PoolManager.unlock 回調核心（所有獎勵在此原子執行）
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory result) {
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

        } else if (action == ActionType.ModifyLiquidity) {
            IPoolManager.ModifyLiquidityParams memory modParams = abi.decode(paramsData, (IPoolManager.ModifyLiquidityParams));
            (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, modParams, hookData);
            return abi.encode(callerDelta, feesAccrued);

        } else {
            revert InvalidAction();
        }
    }

    // ==================== Gasless Swap (EIP-712 簽名) ====================

    /**
     * @dev 驗證 Gasless Swap 的 EIP-712 簽名
     * @return valid 簽名是否有效
     */
    function verifySwapSignature(
        address caller,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData,
        uint256 fee,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public view returns (bool valid) {
        bytes32 messageHash = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR(),
            keccak256(abi.encode(
                keccak256("Swap(address caller,PoolKey key,SwapParams params,bytes hookData,uint256 fee,uint256 deadline)"),
                caller,
                key,
                swapParams,
                keccak256(hookData),
                fee,
                deadline
            ))
        ));

        bytes memory signature = abi.encodePacked(r, s, v);
        valid = SignatureChecker.isValidSignatureNow(caller, messageHash, signature);
    }

/**
     * @dev Gasless Swap（EIP-712 簽名驗證 + 手續費自動按 USD 價值 X% 燒毀）
     *      必須涉及穩定幣才允許執行（無穩定幣直接 revert，節省 relayer gas）
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
        if (!verifySwapSignature(caller, key, swapParams, hookData, gaslessFeeRate, deadline, v, r, s)) revert InvalidSignature();  // 簽名包含 gaslessFeeRate 防止變動攻擊

        bytes memory callData = abi.encode(caller, ActionType.Swap, key, abi.encode(swapParams), hookData);
        bytes memory result = poolManager.unlock(callData);
        delta = abi.decode(result, (BalanceDelta));

        uint256 usdVolume = _getUsdAmountFromDelta(key, delta);

        if (usdVolume == 0) revert NoStablecoinInvolved();  // 強制必須涉及穩定幣

        uint256 fee = (usdVolume + gaslessFeeRate - 1) / gaslessFeeRate;

        if (fee > 0) {
            if (address(rewardERC20) == address(0)) revert TokenNotInitialized();
            rewardERC20.burnFrom(caller, fee);
            emit FeeBurned(caller, fee);
        }
    }

    // ==================== 管理功能 ====================

    /**
     * @dev Owner 提款合約內的 ETH
     */
    function withdrawETH(uint256 amount) external onlyOwner {
        (bool success, ) = payable(owner()).call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    /**
     * @dev Owner 提款合約內的任意 ERC20
     */
    function withdrawERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    /**
     * @dev 查詢獎勵代幣是否已設定
     */
    function isRewardTokenEnabled() external view returns (bool) {
        return address(rewardERC20) != address(0);
    }

    /**
     * @dev EIP-712 Domain Separator
     */
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
