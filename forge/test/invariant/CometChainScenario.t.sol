// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "forge-std/Test.sol";
import {CometConfiguration} from "@comet-contracts/CometConfiguration.sol";
import {CometWithExtendedAssetList} from "@comet-contracts/CometWithExtendedAssetList.sol";
import {CometExtAssetList} from "@comet-contracts/CometExtAssetList.sol";
import {AssetListFactory} from "@comet-contracts/AssetListFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceFeed} from "./mocks/MockPriceFeed.sol";

interface IExtView {
    function collateralBalanceOf(address, address) external view returns (uint128);
}

/// @notice Deterministic end-to-end walk of the full borrow -> price-crash -> absorb ->
///         buyCollateral lifecycle, driven through a collateral at OFFSET 16 — i.e. the
///         first bit of UserBasic._reserved, the novel extended-asset-list storage.
///         Proves the escalation path's target states are reachable AND that the bitmap +
///         accounting invariants hold at every step of a real liquidation.
contract CometChainScenario is Test {
    CometWithExtendedAssetList internal comet;
    MockERC20 internal base;
    MockERC20[] internal col;
    MockPriceFeed[] internal feed;

    address internal supplier = address(0x51);
    address internal borrower = address(0xB0);
    address internal absorber = address(0xAB);
    address internal buyer = address(0xB1);

    uint8 internal constant N = 20;
    uint8 internal constant OFF = 16; // target offset -> _reserved bit 0

    function setUp() public {
        base = new MockERC20("Base", "bUSD", 6);
        MockPriceFeed baseFeed = new MockPriceFeed(1e8);

        CometConfiguration.AssetConfig[] memory assets = new CometConfiguration.AssetConfig[](N);
        for (uint256 i = 0; i < N; i++) {
            MockERC20 c = new MockERC20("C", "C", 18);
            MockPriceFeed f = new MockPriceFeed(int256(1000e8)); // $1000
            col.push(c);
            feed.push(f);
            assets[i] = CometConfiguration.AssetConfig({
                asset: address(c),
                priceFeed: address(f),
                decimals: 18,
                borrowCollateralFactor: 5e17,      // 0.50
                liquidateCollateralFactor: 6e17,   // 0.60
                liquidationFactor: 9e17,           // 0.90
                supplyCap: 1_000_000_000e18
            });
        }

        AssetListFactory factory = new AssetListFactory();
        CometExtAssetList ext = new CometExtAssetList(
            CometConfiguration.ExtConfiguration({name32: bytes32("Comet"), symbol32: bytes32("CMT")}),
            address(factory)
        );

        CometConfiguration.Configuration memory config = CometConfiguration.Configuration({
            governor: address(this), pauseGuardian: address(this),
            baseToken: address(base), baseTokenPriceFeed: address(baseFeed),
            extensionDelegate: address(ext),
            supplyKink: 8e17, supplyPerYearInterestRateSlopeLow: 2e16,
            supplyPerYearInterestRateSlopeHigh: 4e17, supplyPerYearInterestRateBase: 0,
            borrowKink: 8e17, borrowPerYearInterestRateSlopeLow: 3e16,
            borrowPerYearInterestRateSlopeHigh: 5e17, borrowPerYearInterestRateBase: 1e16,
            storeFrontPriceFactor: 5e17, trackingIndexScale: 1e15,
            baseTrackingSupplySpeed: 1e15, baseTrackingBorrowSpeed: 1e15,
            baseMinForRewards: 1e6, baseBorrowMin: 1e6, targetReserves: 100_000e6,
            assetConfigs: assets
        });

        comet = new CometWithExtendedAssetList(config);
        comet.initializeStorage();
    }

    function _bitSet(address who, uint256 off) internal view returns (bool) {
        (, , , uint16 assetsIn, uint8 reserved) = comet.userBasic(who);
        if (off < 16) return (assetsIn & (uint16(1) << uint8(off))) != 0;
        return (reserved & (uint8(1) << uint8(off - 16))) != 0;
    }

    function _assertConserved() internal view {
        // collateral conservation for the target asset
        uint256 sum;
        address[4] memory accs = [supplier, borrower, absorber, buyer];
        for (uint256 i = 0; i < 4; i++) {
            sum += IExtView(address(comet)).collateralBalanceOf(accs[i], address(col[OFF]));
        }
        (uint128 tsa,) = comet.totalsCollateral(address(col[OFF]));
        assertEq(sum, uint256(tsa), "collateral desync");
        // collateral reserves solvent
        assertGe(col[OFF].balanceOf(address(comet)), uint256(tsa), "reserve underflow");
    }

    function test_ChainLifecycle_OffsetSixteen() public {
        // 1) supplier funds the base pool
        base.mint(supplier, 200_000e6);
        vm.startPrank(supplier);
        base.approve(address(comet), type(uint256).max);
        comet.supply(address(base), 200_000e6);
        vm.stopPrank();

        // 2) borrower posts collateral at OFFSET 16 (=_reserved bit 0)
        col[OFF].mint(borrower, 100e18); // value 100 * $1000 = $100k ; bcf 0.5 -> $50k capacity
        vm.startPrank(borrower);
        col[OFF].approve(address(comet), type(uint256).max);
        comet.supply(address(col[OFF]), 100e18);
        vm.stopPrank();

        assertTrue(_bitSet(borrower, OFF), "offset-16 bit must be set after supply");
        assertEq(IExtView(address(comet)).collateralBalanceOf(borrower, address(col[OFF])), 100e18);
        _assertConserved();

        // 3) borrower draws a $40k base loan against the offset-16 collateral
        vm.prank(borrower);
        comet.withdraw(address(base), 40_000e6);
        (int104 p,,,,) = comet.userBasic(borrower);
        assertLt(p, int104(0), "borrower must hold debt");
        assertTrue(comet.isBorrowCollateralized(borrower), "must be collateralized at borrow time");
        assertFalse(comet.isLiquidatable(borrower), "not yet liquidatable");
        _assertConserved();

        // 4) crash the offset-16 collateral price: $1000 -> $300  (value $30k, lcf 0.6 -> $18k < $40k debt)
        feed[OFF].setAnswer(int256(300e8));
        assertTrue(comet.isLiquidatable(borrower), "must be liquidatable after crash");

        // 5) absorb the underwater borrower
        uint256 seizedTotalBefore;
        (uint128 tsaBefore,) = comet.totalsCollateral(address(col[OFF]));
        seizedTotalBefore = tsaBefore;
        address[] memory accs = new address[](1);
        accs[0] = borrower;
        vm.prank(absorber);
        comet.absorb(absorber, accs);

        assertEq(IExtView(address(comet)).collateralBalanceOf(borrower, address(col[OFF])), 0, "collateral must be seized");
        assertFalse(_bitSet(borrower, OFF), "offset-16 bit must be cleared after absorb");
        (int104 pAfter,,,,) = comet.userBasic(borrower);
        assertGe(pAfter, int104(0), "debt must be cleared to >= 0 by reserves");
        _assertConserved();

        // 6) buyer purchases the seized collateral (now protocol reserves) at the store-front discount
        base.mint(buyer, 50_000e6);
        vm.startPrank(buyer);
        base.approve(address(comet), type(uint256).max);
        uint256 quoted = comet.quoteCollateral(address(col[OFF]), 10_000e6);
        comet.buyCollateral(address(col[OFF]), 0, 10_000e6, buyer);
        vm.stopPrank();

        assertGt(col[OFF].balanceOf(buyer), 0, "buyer must receive collateral");
        assertEq(col[OFF].balanceOf(buyer), quoted, "buyer receives exactly the quote");
        _assertConserved();

        emit log_named_uint("collateral bought (1e18)", col[OFF].balanceOf(buyer));
        emit log_named_int ("borrower principal after", int256(pAfter));
        emit log_string("PASS: full borrow->crash->absorb->buy lifecycle safe through _reserved offset 16");
    }
}
