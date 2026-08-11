// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {CometConfiguration} from "@comet-contracts/CometConfiguration.sol";
import {CometWithExtendedAssetList} from "@comet-contracts/CometWithExtendedAssetList.sol";
import {CometExtAssetList} from "@comet-contracts/CometExtAssetList.sol";
import {AssetListFactory} from "@comet-contracts/AssetListFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";
import {CometHandler} from "./CometHandler.sol";

struct TB {
    uint64 baseSupplyIndex;
    uint64 baseBorrowIndex;
    uint64 trackingSupplyIndex;
    uint64 trackingBorrowIndex;
    uint104 totalSupplyBase;
    uint104 totalBorrowBase;
    uint40 lastAccrualTime;
    uint8 pauseFlags;
}

interface ICometRead {
    function userBasic(address) external view returns (int104, uint64, uint64, uint16, uint8);
    function totalsCollateral(address) external view returns (uint128, uint128);
    function getCollateralReserves(address) external view returns (uint256);
    function getReserves() external view returns (int256);
    function totalsBasic() external view returns (TB memory);
    function collateralBalanceOf(address, address) external view returns (uint128);
    function isBorrowCollateralized(address) external view returns (bool);
    function isLiquidatable(address) external view returns (bool);
}

/// @notice Invariant campaign for CometWithExtendedAssetList, deliberately configured with
///         20 collateral assets (offsets 0..19) so the fuzzer crosses the 16-bit boundary
///         where `assetsIn` (bits 0-15) hands off to `_reserved` (bits 16-23) in the
///         extended-asset-list bitmap — the newest, least-battle-tested accounting path.
contract CometInvariant is Test {
    CometWithExtendedAssetList internal comet;
    ICometRead internal cread;
    MockERC20 internal base;
    MockERC20[] internal collaterals;
    MockPriceFeed[] internal feeds;
    CometHandler internal handler;

    address[] internal actors;
    address[] internal allAccounts;
    address internal absorber = address(0xAB0B);
    address internal buyer = address(0xB0FF);

    uint8 internal constant N_COLLATERAL = 24; // MAX; fully exercises _reserved bits 16-23

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 6);
        MockPriceFeed baseFeed = new MockPriceFeed(1e8); // $1

        // 20 collaterals, offsets 0..19. Offsets 16..19 live in UserBasic._reserved.
        CometConfiguration.AssetConfig[] memory assets = new CometConfiguration.AssetConfig[](N_COLLATERAL);
        for (uint256 i = 0; i < N_COLLATERAL; i++) {
            MockERC20 c = new MockERC20(
                string(abi.encodePacked("COL", vm.toString(i))),
                string(abi.encodePacked("C", vm.toString(i))),
                18
            );
            // vary price a bit per asset
            MockPriceFeed f = new MockPriceFeed(int256((i + 1) * 100e8));
            collaterals.push(c);
            feeds.push(f);
            assets[i] = CometConfiguration.AssetConfig({
                asset: address(c),
                priceFeed: address(f),
                decimals: 18,
                borrowCollateralFactor: 8e17,      // 0.80
                liquidateCollateralFactor: 85e16,  // 0.85
                liquidationFactor: 9e17,           // 0.90
                supplyCap: 1_000_000_000e18
            });
        }

        AssetListFactory factory = new AssetListFactory();
        CometExtAssetList ext = new CometExtAssetList(
            CometConfiguration.ExtConfiguration({name32: bytes32("Comet"), symbol32: bytes32("COMET")}),
            address(factory)
        );

        CometConfiguration.Configuration memory config = CometConfiguration.Configuration({
            governor: address(this),
            pauseGuardian: address(this),
            baseToken: address(base),
            baseTokenPriceFeed: address(baseFeed),
            extensionDelegate: address(ext),
            supplyKink: 8e17,
            supplyPerYearInterestRateSlopeLow: 2e16,
            supplyPerYearInterestRateSlopeHigh: 4e17,
            supplyPerYearInterestRateBase: 0,
            borrowKink: 8e17,
            borrowPerYearInterestRateSlopeLow: 3e16,
            borrowPerYearInterestRateSlopeHigh: 5e17,
            borrowPerYearInterestRateBase: 1e16,
            storeFrontPriceFactor: 5e17,
            trackingIndexScale: 1e15,
            baseTrackingSupplySpeed: 1e15,
            baseTrackingBorrowSpeed: 1e15,
            baseMinForRewards: 1e6,
            baseBorrowMin: 1e6,
            targetReserves: 100_000e6,
            assetConfigs: assets
        });

        comet = new CometWithExtendedAssetList(config);
        comet.initializeStorage();
        cread = ICometRead(address(comet));

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        for (uint256 i = 0; i < actors.length; i++) allAccounts.push(actors[i]);
        allAccounts.push(absorber);
        allAccounts.push(buyer);

        handler = new CometHandler(comet, base, collaterals, feeds, actors, absorber, buyer);

        bytes4[] memory sel = new bytes4[](10);
        sel[0] = CometHandler.supplyBase.selector;
        sel[1] = CometHandler.withdrawBase.selector;
        sel[2] = CometHandler.transferBase.selector;
        sel[3] = CometHandler.supplyCollateral.selector;
        sel[4] = CometHandler.withdrawCollateral.selector;
        sel[5] = CometHandler.transferCollateral.selector;
        sel[6] = CometHandler.warp.selector;
        sel[7] = CometHandler.movePrice.selector;
        sel[8] = CometHandler.absorb.selector;
        sel[9] = CometHandler.buyCollateral.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    // ===== INVARIANT 1: base accounting conservation =====
    function invariant_baseAccountingConservation() public view {
        uint256 sumPos;
        uint256 sumNeg;
        for (uint256 i = 0; i < allAccounts.length; i++) {
            (int104 p,,,,) = cread.userBasic(allAccounts[i]);
            if (p >= 0) sumPos += uint256(uint104(p));
            else sumNeg += uint256(uint104(-p));
        }
        TB memory t = cread.totalsBasic();
        assertEq(sumPos, uint256(t.totalSupplyBase), "SUPPLY_BASE_DESYNC");
        assertEq(sumNeg, uint256(t.totalBorrowBase), "BORROW_BASE_DESYNC");
    }

    // ===== INVARIANT 2: collateral accounting conservation =====
    function invariant_collateralConservation() public view {
        for (uint256 c = 0; c < collaterals.length; c++) {
            address asset = address(collaterals[c]);
            uint256 sumBal;
            for (uint256 i = 0; i < allAccounts.length; i++) {
                sumBal += cread.collateralBalanceOf(allAccounts[i], asset);
            }
            (uint128 totalSupplyAsset,) = cread.totalsCollateral(asset);
            assertEq(sumBal, uint256(totalSupplyAsset), "COLLATERAL_DESYNC");
        }
    }

    // ===== INVARIANT 3: collateral reserves never underflow =====
    function invariant_collateralReservesSolvent() public view {
        for (uint256 c = 0; c < collaterals.length; c++) {
            (uint128 totalSupplyAsset,) = cread.totalsCollateral(address(collaterals[c]));
            assertGe(collaterals[c].balanceOf(address(comet)), uint256(totalSupplyAsset), "COLLATERAL_RESERVE_UNDERFLOW");
        }
    }

    // ===== INVARIANT 4: reserves/index math stays computable (no DoS) =====
    function invariant_reservesComputable() public view {
        cread.getReserves();
    }

    // ===== INVARIANT 5: assetsIn bitmap EXACTLY matches real balances =====
    // The core extended-asset-list safety property. For every account and every
    // collateral offset, the "is-in-asset" bit must be set iff the balance is > 0.
    //  - bit set but balance 0  => phantom collateral could be double-counted / mis-iterated
    //  - balance > 0 but bit 0  => real collateral NOT counted by isBorrowCollateralized
    //    => under-collateralized borrow => bad debt => insolvency (the escalation target)
    // This exercises the 16-bit assetsIn -> _reserved (_reserved bits 16..23) handoff.
    function invariant_assetsInBitmapConsistent() public view {
        for (uint256 a = 0; a < allAccounts.length; a++) {
            (, , , uint16 assetsIn, uint8 reserved) = cread.userBasic(allAccounts[a]);
            for (uint256 off = 0; off < collaterals.length; off++) {
                bool bitSet;
                if (off < 16) {
                    bitSet = (assetsIn & (uint16(1) << uint8(off))) != 0;
                } else {
                    bitSet = (reserved & (uint8(1) << uint8(off - 16))) != 0;
                }
                uint256 bal = cread.collateralBalanceOf(allAccounts[a], address(collaterals[off]));
                assertEq(bitSet, bal > 0, "ASSETSIN_BITMAP_DESYNC");
            }
        }
    }

    function invariant_callSummary() public view {
        console.log("supplyBase   ", handler.callsSupplyBase());
        console.log("withdrawBase ", handler.callsWithdrawBase());
        console.log("transferBase ", handler.callsTransferBase());
        console.log("supplyColl   ", handler.callsSupplyColl());
        console.log("withdrawColl ", handler.callsWithdrawColl());
        console.log("transferColl ", handler.callsTransferColl());
        console.log("absorb       ", handler.callsAbsorb());
        console.log("buyCollateral", handler.callsBuy());
        console.log("warp         ", handler.callsWarp());
        console.log("movePrice    ", handler.callsPrice());
        console.log("reverts      ", handler.reverts());
    }
}
