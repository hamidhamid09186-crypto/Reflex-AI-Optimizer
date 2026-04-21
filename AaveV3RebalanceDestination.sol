// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPool {
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40  lastUpdateTimestamp,
            uint16  id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        );

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16  referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}

contract AaveV3RebalanceDestination {

    uint256 private constant RAY = 1e27;
    uint256 public constant RATE_THRESHOLD_RAY = 5e25;
    address public constant AAVE_POOL =
        0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951;

    address public immutable asset;
    address public immutable owner;

    struct RebalanceState {
        address rscCallback;
        uint96  lastRate;
    }
    RebalanceState private s;

    event Rebalanced(
        bool    indexed withdrew,
        uint256         amount,
        uint256         rateBps
    );
    event RscCallbackUpdated(address indexed previous, address indexed next);
    event Deposited(address indexed by, uint256 amount);

    error Unauthorised();
    error ZeroAddress();
    error NoBalance();
    error AlreadyInDesiredState();

    constructor(address _asset, address _rscCallback) {
        if (_asset == address(0) || _rscCallback == address(0))
            revert ZeroAddress();

        asset = _asset;
        owner = msg.sender;

        s.rscCallback = address(uint160(_rscCallback));

        IERC20(_asset).approve(AAVE_POOL, type(uint256).max);
    }

    modifier onlyRsc() {
        if (msg.sender != s.rscCallback) revert Unauthorised();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorised();
        _;
    }

    function rebalance() external onlyRsc {
        (
            , , ,
            ,
            uint128 varBorrowRate,
            , , ,
            address aTokenAddr,
            , , , , ,
        ) = IPool(AAVE_POOL).getReserveData(asset);

        uint256 currentRate = uint256(varBorrowRate);

        unchecked {
            s.lastRate = uint96(currentRate);
        }

        if (currentRate >= RATE_THRESHOLD_RAY) {
            uint256 aBalance = IAToken(aTokenAddr).balanceOf(address(this));
            if (aBalance == 0) revert AlreadyInDesiredState();

            uint256 withdrawn = IPool(AAVE_POOL).withdraw(
                asset,
                type(uint256).max,
                address(this)
            );

            emit Rebalanced(true, withdrawn, _rayToBps(currentRate));

        } else {
            uint256 idleBalance = IERC20(asset).balanceOf(address(this));
            if (idleBalance == 0) revert AlreadyInDesiredState();

            IPool(AAVE_POOL).supply(asset, idleBalance, address(this), 0);

            emit Rebalanced(false, idleBalance, _rayToBps(currentRate));
        }
    }

    function setRscCallback(address _rscCallback) external onlyOwner {
        if (_rscCallback == address(0)) revert ZeroAddress();
        address prev = s.rscCallback;
        s.rscCallback = address(uint160(_rscCallback));
        emit RscCallbackUpdated(prev, _rscCallback);
    }

    function rescueTokens(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert NoBalance();
        IERC20(token).transfer(owner, bal);
    }

    function deposit(uint256 amount) external {
        IERC20(asset).approve(address(this), amount);
        (bool ok, bytes memory data) = asset.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender, address(this), amount
            )
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
        emit Deposited(msg.sender, amount);
    }

    function lastRate() external view returns (uint256) {
        return uint256(s.lastRate);
    }

    function rscCallback() external view returns (address) {
        return s.rscCallback;
    }

    function currentRateBps() external view returns (uint256 bps) {
        ( , , , , uint128 varBorrowRate, , , , , , , , , , ) =
            IPool(AAVE_POOL).getReserveData(asset);
        bps = _rayToBps(uint256(varBorrowRate));
    }

    function _rayToBps(uint256 rate) internal pure returns (uint256 bps) {
        unchecked {
            bps = rate * 10_000 / RAY;
        }
    }
}
