// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IReactive {
    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3,
        bytes   calldata data,
        uint256 block_number,
        uint256 op_code
    ) external;
}

interface ISubscriptionService {
    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;
}

abstract contract AbstractReactive is IReactive {

    address internal constant REACTIVE_SUBSCRIPTION_SERVICE =
        0x9b9BB25f1A81078C544C829c5EB7822d747Cf434;

    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    event Callback(
        uint256 indexed destination_chain_id,
        address indexed destination,
        uint64  indexed gas_limit,
        uint256         value,
        bytes           payload
    );

    uint256 private _reentryLock;

    modifier nonReentrant() {
        require(_reentryLock == 0, "Reentrant");
        _reentryLock = 1;
        _;
        _reentryLock = 0;
    }
}

contract AaveRateReactiveContract is AbstractReactive {

    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;

    address private constant AAVE_POOL_SEPOLIA =
        0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

    uint256 private constant RESERVE_DATA_UPDATED_TOPIC =
        0x804c9b842b2748a22bb64b345453a3de7ca54a6ca45ce00d415894979e22897a;

    uint256 private constant RATE_THRESHOLD_RAY = 5e25;

    address public immutable trackedAsset;
    address public immutable destination;
    uint64  public immutable callbackGasLimit;

    bool private aboveThreshold;

    event RateMonitored(
        address indexed reserve,
        uint256         variableBorrowRate,
        bool            thresholdCrossed,
        bool            callbackDispatched
    );

    constructor(
        address _trackedAsset,
        address _destination,
        uint64  _callbackGasLimit
    ) {
        require(_trackedAsset != address(0), "Zero asset");
        require(_destination  != address(0), "Zero dest");
        require(_callbackGasLimit >= 100_000, "Gas too low");

        trackedAsset      = _trackedAsset;
        destination       = _destination;
        callbackGasLimit  = _callbackGasLimit;

        ISubscriptionService(REACTIVE_SUBSCRIPTION_SERVICE).subscribe(
            SEPOLIA_CHAIN_ID,
            AAVE_POOL_SEPOLIA,
            RESERVE_DATA_UPDATED_TOPIC,
            uint256(uint160(_trackedAsset)),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function react(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256,
        uint256,
        bytes   calldata data,
        uint256,
        uint256
    ) external override nonReentrant {

        if (chain_id  != SEPOLIA_CHAIN_ID)               return;
        if (_contract != AAVE_POOL_SEPOLIA)               return;
        if (topic_0   != RESERVE_DATA_UPDATED_TOPIC)      return;
        if (topic_1   != uint256(uint160(trackedAsset)))  return;

        if (data.length < 96) return;

        uint256 variableBorrowRate;
        assembly {
            variableBorrowRate := calldataload(add(data.offset, 64))
        }

        bool nowAbove = variableBorrowRate >= RATE_THRESHOLD_RAY;
        bool changed  = nowAbove != aboveThreshold;

        emit RateMonitored(
            address(uint160(topic_1)),
            variableBorrowRate,
            nowAbove,
            changed
        );

        if (!changed) return;

        aboveThreshold = nowAbove;

        emit Callback(
            SEPOLIA_CHAIN_ID,
            destination,
            callbackGasLimit,
            0,
            abi.encodeWithSignature("rebalance()")
        );
    }

    function isAboveThreshold() external view returns (bool) {
        return aboveThreshold;
    }

    function thresholdBps() external pure returns (uint256) {
        return RATE_THRESHOLD_RAY * 10_000 / 1e27;
    }
}
