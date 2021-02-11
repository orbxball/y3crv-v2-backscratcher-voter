// SPDX-License-Identifier: AGPL-3.0

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// Import interfaces for many popular DeFi projects, or add your own!
interface Uni {
    function swapExactTokensForTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external;
}

interface ICurveFi {
    function add_liquidity(
        uint256[3] calldata amounts,
        uint256 min_mint_amount
    ) external;
}

interface IVoterProxy {
    function withdraw(
        address _gauge,
        address _token,
        uint256 _amount
    ) external returns (uint256);
    function balanceOf(address _gauge) external view returns (uint256);
    function withdrawAll(address _gauge, address _token) external returns (uint256);
    function deposit(address _gauge, address _token) external;
    function harvest(address _gauge) external;
    function lock() external;
    function approveStrategy(address) external;
    function revokeStrategy(address) external;
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant curve = address(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);
    address public constant gauge = address(0xbFcF63294aD7105dEa65aA58F8AE5BE2D9d0952A);
    address public constant voter = address(0xF147b8125d2ef93FB6965Db97D6746952a133934);

    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // used for crv <> weth <> dai route

    address public constant uniswap = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public constant sushiswap = address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    uint256 public keepCRV = 1000;
    uint256 public constant FEE_DENOMINATOR = 10000;

    address public proxy;
    address public dex;

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        profitFactor = 1000;
        // debtThreshold = 0;
        proxy = address(0x9a3a03C614dc467ACC3e81275468e033c98d960E);
        dex = sushiswap;
    }

    function setKeepCRV(uint256 _keepCRV) external onlyGovernance {
        keepCRV = _keepCRV;
    }

    function setProxy(address _proxy) external onlyGovernance {
        proxy = _proxy;
    }

    function switchDex(bool isUniswap) external onlyAuthorized {
        if (isUniswap) {
            dex = uniswap;
        } else {
            dex = sushiswap;
        }
    }

    function name() external view override returns (string memory) {
        return "StrategyCurve3CRVVoterProxy";
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        return IVoterProxy(proxy).balanceOf(gauge);
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        IVoterProxy(proxy).harvest(gauge);
        uint256 _crv = IERC20(crv).balanceOf(address(this));
        if (_crv > 0) {
            uint256 _keepCRV = _crv.mul(keepCRV).div(FEE_DENOMINATOR);
            IERC20(crv).safeTransfer(voter, _keepCRV);
            _crv = _crv.sub(_keepCRV);

            IERC20(crv).safeApprove(dex, 0);
            IERC20(crv).safeApprove(dex, _crv);

            address[] memory path = new address[](3);
            path[0] = crv;
            path[1] = weth;
            path[2] = dai;

            Uni(dex).swapExactTokensForTokens(_crv, uint256(0), path, address(this), now.add(1800));
        }
        uint256 _dai = IERC20(dai).balanceOf(address(this));
        if (_dai > 0) {
            IERC20(dai).safeApprove(curve, 0);
            IERC20(dai).safeApprove(curve, _dai);
            ICurveFi(curve).add_liquidity([_dai, 0, 0], 0);
        }

        _profit = want.balanceOf(address(this));

        if (_debtOutstanding > 0) {
            _debtPayment = _withdrawSome(_debtOutstanding);
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _want = want.balanceOf(address(this));
        if (_want > 0) {
            want.safeTransfer(proxy, _want);
            IVoterProxy(proxy).deposit(gauge, address(want));
        }
        IVoterProxy(proxy).lock();
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        return IVoterProxy(proxy).withdraw(gauge, address(want), _amount);
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _balance = want.balanceOf(address(this));
        if (_balance < _amountNeeded) {
            _liquidatedAmount = _withdrawSome(_amountNeeded.sub(_balance));
            _liquidatedAmount = _liquidatedAmount.add(_balance);
            // _loss = _amountNeeded.sub(_liquidatedAmount);
        }
        else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        IVoterProxy(proxy).withdrawAll(gauge, address(want));
        uint256 _balance = want.balanceOf(address(this));
        want.safeTransfer(_newStrategy, _balance);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](3);
        protected[0] = address(want);
        protected[1] = crv;
        protected[2] = dai;
        return protected;
    }
}
