// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import {Vm} from "forge-std/Vm.sol";
import {CometWithExtendedAssetList} from "@comet-contracts/CometWithExtendedAssetList.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";

/// @notice Stateful actor that drives Comet through randomized, bounded action sequences.
///         Every reachable state-changing entry point of the money market is exercised so the
///         invariant checks in CometInvariant.t.sol can detect any accounting divergence.
contract CometHandler {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    CometWithExtendedAssetList public comet;
    MockERC20 public base;
    MockERC20[] public collaterals;
    MockPriceFeed[] public feeds; // price feeds for collaterals, index-aligned
    address[] public actors;
    address public absorber;
    address public buyer;

    // ---- ghost counters (for the run summary) ----
    uint256 public callsSupplyBase;
    uint256 public callsSupplyColl;
    uint256 public callsWithdrawBase;
    uint256 public callsWithdrawColl;
    uint256 public callsTransferBase;
    uint256 public callsTransferColl;
    uint256 public callsAbsorb;
    uint256 public callsBuy;
    uint256 public callsWarp;
    uint256 public callsPrice;
    uint256 public reverts;
    uint256 public borrowsSeen;   // withdraws that left the actor with a debt
    uint256 public absorbsSeized; // absorb calls that actually seized an underwater account

    constructor(
        CometWithExtendedAssetList _comet,
        MockERC20 _base,
        MockERC20[] memory _collaterals,
        MockPriceFeed[] memory _feeds,
        address[] memory _actors,
        address _absorber,
        address _buyer
    ) {
        comet = _comet;
        base = _base;
        for (uint256 i = 0; i < _collaterals.length; i++) {
            collaterals.push(_collaterals[i]);
            feeds.push(_feeds[i]);
        }
        for (uint256 i = 0; i < _actors.length; i++) {
            actors.push(_actors[i]);
        }
        absorber = _absorber;
        buyer = _buyer;
    }

    function numActors() external view returns (uint256) { return actors.length; }
    function numCollaterals() external view returns (uint256) { return collaterals.length; }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _coll(uint256 seed) internal view returns (MockERC20 c, MockPriceFeed f) {
        uint256 i = seed % collaterals.length;
        return (collaterals[i], feeds[i]);
    }

    function _bound(uint256 x, uint256 max_) internal pure returns (uint256) {
        if (max_ == 0) return 0;
        return x % max_;
    }

    // ---------------------------------------------------------------------
    // Base asset
    // ---------------------------------------------------------------------

    function supplyBase(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = _bound(amount, 1_000_000e6) + 1; // up to 1M base (6 decimals)
        base.mint(a, amount);
        vm.prank(a);
        base.approve(address(comet), amount);
        vm.prank(a);
        try comet.supply(address(base), amount) { callsSupplyBase++; }
        catch { reverts++; }
    }

    function withdrawBase(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = _bound(amount, 1_000_000e6) + 1;
        vm.prank(a);
        try comet.withdraw(address(base), amount) {
            callsWithdrawBase++;
            (int104 p,,,,) = comet.userBasic(a);
            if (p < 0) borrowsSeen++;
        }
        catch { reverts++; }
    }

    function transferBase(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        amount = _bound(amount, 1_000_000e6) + 1;
        vm.prank(from);
        try comet.transfer(to, amount) { callsTransferBase++; }
        catch { reverts++; }
    }

    // ---------------------------------------------------------------------
    // Collateral
    // ---------------------------------------------------------------------

    function supplyCollateral(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        (MockERC20 c, ) = _coll(assetSeed);
        amount = _bound(amount, 1_000e18) + 1; // up to 1000 units (18 decimals)
        c.mint(a, amount);
        vm.prank(a);
        c.approve(address(comet), amount);
        vm.prank(a);
        try comet.supply(address(c), amount) { callsSupplyColl++; }
        catch { reverts++; }
    }

    function withdrawCollateral(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        (MockERC20 c, ) = _coll(assetSeed);
        amount = _bound(amount, 1_000e18) + 1;
        vm.prank(a);
        try comet.withdraw(address(c), amount) { callsWithdrawColl++; }
        catch { reverts++; }
    }

    function transferCollateral(uint256 fromSeed, uint256 toSeed, uint256 assetSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        (MockERC20 c, ) = _coll(assetSeed);
        amount = _bound(amount, 1_000e18) + 1;
        vm.prank(from);
        try comet.transferAsset(to, address(c), amount) { callsTransferColl++; }
        catch { reverts++; }
    }

    // ---------------------------------------------------------------------
    // Time & prices
    // ---------------------------------------------------------------------

    function warp(uint256 dt) external {
        dt = _bound(dt, 30 days) + 1;
        vm.warp(block.timestamp + dt);
        // accrue globally so index math is exercised even without a user op
        comet.accrueAccount(actors[0]);
        callsWarp++;
    }

    function movePrice(uint256 assetSeed, uint256 newPrice) external {
        (, MockPriceFeed f) = _coll(assetSeed);
        // Range roughly $10 .. $5000 (8-decimal). Base is pegged at $1.
        newPrice = _bound(newPrice, 5000e8) + 10e8;
        f.setAnswer(int256(newPrice));
        callsPrice++;
    }

    // ---------------------------------------------------------------------
    // Liquidation engine
    // ---------------------------------------------------------------------

    function absorb(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        if (!comet.isLiquidatable(a)) return;
        address[] memory accs = new address[](1);
        accs[0] = a;
        vm.prank(absorber);
        try comet.absorb(absorber, accs) { callsAbsorb++; absorbsSeized++; }
        catch { reverts++; }
    }

    function buyCollateral(uint256 assetSeed, uint256 baseAmount) external {
        (MockERC20 c, ) = _coll(assetSeed);
        baseAmount = _bound(baseAmount, 500_000e6) + 1;
        base.mint(buyer, baseAmount);
        vm.prank(buyer);
        base.approve(address(comet), baseAmount);
        vm.prank(buyer);
        try comet.buyCollateral(address(c), 0, baseAmount, buyer) { callsBuy++; }
        catch { reverts++; }
    }
}
