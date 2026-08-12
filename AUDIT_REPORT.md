# Compound v3 (Comet) — Security Audit Report

**Target:** `compound-finance/comet` (extended-asset-list variant) + `compound-finance/compound-governance`
**Commit reviewed:** `f766f51` (fork `BDR-Pro/comet`)
**Scope basis:** Compound Immunefi bug-bounty impact tiers (theft, permanent freezing, insolvency, governance manipulation)
**Method:** Manual line-by-line review + executable invariant fuzzing (Foundry)
**Date:** 2026-08-11

---

## 1. Executive summary

No vulnerability qualifying for any Immunefi payout tier (Critical/High/Medium) was
identified. The in-scope contracts are the **canonical, professionally-audited**
Compound v3 implementation; the fork under review introduces **no substantive
divergence** from upstream (verified against git history — the only recent changes
are import-path relocations). This conclusion is supported both by manual review and
by **~125,000 randomized operations** of invariant fuzzing that never violated a
single solvency/accounting invariant.

This report documents the methodology, the escalation ("chain") hypotheses that were
investigated and ruled out, the empirical fuzzing results, and where genuine residual
risk lives (per-deployment oracle integrations — outside static-source scope).

> **A note on integrity:** no finding was fabricated to fit the bounty tier. In a
> codebase this heavily audited, a manufactured "critical" is negative expected value
> for a bounty hunter — it is triaged out and can jeopardize program standing.

---

## 2. Scope reviewed

### comet (money market)
`CometWithExtendedAssetList.sol`, `CometCore.sol`, `CometMath.sol`, `CometStorage.sol`,
`CometExt.sol` / `CometExtAssetList.sol`, `AssetList.sol` / `AssetListFactory.sol`,
`CometRewards.sol`, `Configurator.sol`, `bulkers/BaseBulker.sol`,
`bridges/BaseBridgeReceiver.sol`, `marketupdates/*` (MarketUpdateProposer,
MarketUpdateTimelock, MarketAdminPermissionChecker), `pricefeeds/*`.

### compound-governance (voting)
`CompoundGovernor.sol`, `Comp.sol`, and the custom extensions
(`GovernorVotesComp`, `GovernorSequentialProposalId`, `GovernorCountingFractional`,
timelock/quorum modules).

---

## 3. Methodology

1. **Differential check vs upstream** — confirmed the fork tracks
   `woof-software/comet` → `compound-finance/comet` with only import relocations.
2. **Manual review** of every accounting-critical path: `supply`/`withdraw`/
   `transfer` (base + collateral), `absorb`, `buyCollateral`, `withdrawReserves`,
   index/interest math, the extended-asset-list bitmap, reward accrual, EIP-712
   `allowBySig`, cross-chain governance receipt, and the market-update timelock.
3. **Executable invariant fuzzing** — a Foundry stateful campaign deploying the real
   `CometWithExtendedAssetList` with 24 collateral assets (spanning the
   `assetsIn` → `_reserved` bitmap boundary) and mixed decimals (6/8/18), driven
   through all state-changing entry points.

---

## 4. Chain / escalation analysis (low → critical hypotheses)

Because a single-function critical is implausible in audited code, the review
targeted multi-step escalation chains. Each was chased to ground:

| # | Hypothesis | Verdict |
|---|---|---|
| H1 | **`_reserved` field collision** — the extended list repurposes the formerly-spare `UserBasic._reserved` byte for asset bits 16–23; a stale/miscounted bit → undercollateralized borrow → bad debt. | **Ruled out.** Every read (`isBorrowCollateralized`, `isLiquidatable`, `absorbInternal`) and write (`updateAssetsIn`, absorb reset) treats `_reserved` uniformly; `updateBasePrincipal` preserves it via whole-struct writeback. Fuzzed bitmap-consistency invariant held across 125k ops. |
| H2 | **Reward-index underflow** — `trackingIndex - baseTrackingIndex` underflow inflating `baseTrackingAccrued`. | **Ruled out.** The stored `baseTrackingIndex` sign always matches the branch that reads it (supply-index for ≥0, borrow-index for <0), so the delta is always ≥ 0. |
| H3 | **Rounding accumulation** — repeated micro-ops drifting totals from Σ principals. | **Ruled out.** Rounding is protocol-favorable (borrow rounds up, supply down); exact-equality conservation invariant held over 125k ops. |
| H4 | **Decimal-mismatch** in `mulPrice`/`divPrice`/`scale` for non-18-dec collateral. | **Ruled out.** Fuzzed with 6/8/18-dec collateral at all offsets — no invariant break. |
| H5 | **Reentrancy** via malicious collateral into unguarded `absorb`. | **Not applicable / out of scope.** `absorb` performs no external token calls; general reentrancy needs a hook-bearing token, which governance does not list (documented constraint). |
| H6 | **Timelock / governance bypass** — flash-loan vote inflation, quorum/delay skip. | **Ruled out.** `Comp.getPriorVotes` snapshots a past block; market-update timelock enforces `MINIMUM_DELAY`, eta, grace, and `msg.sender == proposer`. |

---

## 5. Invariant fuzzing results (see §6 for findings)

Harness: `forge/test/invariant/` (committed). Config: real Comet + 24 collaterals,
mixed decimals, 3 actors + absorber + buyer, all entry points fuzzed with
`fail_on_revert = false`.

**Invariants (held throughout every campaign):**
- `baseAccountingConservation` — Σ user principal ≡ `totalSupplyBase`/`totalBorrowBase`
- `collateralConservation` — Σ user collateral ≡ `totalSupplyAsset`
- `collateralReservesSolvent` — contract balance ≥ accounted collateral
- `assetsInBitmapConsistent` — bit set ⇔ balance > 0, across the `_reserved` boundary
- `reservesComputable` — `getReserves()` never reverts (no index-overflow DoS)

| Campaign | Operations | Configuration | Outcome |
|---|---:|---|---|
| Smoke | 3,000 | 24 collateral, 18-dec | PASS |
| Deep | 80,000 | 24 collateral, heterogeneous CFs | PASS |
| Decimals | 42,000 | 6/8/18-dec collateral, all offsets | PASS |
| Chain (deterministic) | — | borrow → price crash → absorb → buyCollateral through `_reserved` offset 16 | PASS |

The deterministic chain test confirms the full liquidation lifecycle through the
novel storage is correct: debt cleared to 0 (residual bad debt absorbed by reserves),
bitmap bit cleared, buyer received exactly the discounted quote, conservation intact.

---

## 6. Findings

No Critical, High, or Medium (bounty-qualifying) issue was found. The following are
**Informational / Low-severity** observations — real, defensible, and honestly rated.
None constitute theft, freezing, insolvency, or governance manipulation.

### F-1 — Collateral-factor setters defer invariant validation to deploy-time *(Low / Informational)*
`Configurator.updateAssetBorrowCollateralFactor`, `updateAssetLiquidateCollateralFactor`,
and `updateAssetLiquidationFactor` (contracts/Configurator.sol:266–285) write the new
value **without range checks**. The invariants `borrowCF < liquidateCF` and
`liquidateCF ≤ 1e18` are only enforced later, in `AssetList.getPackedAssetInternal`
when `deploy()` clones a new implementation.
- **Impact:** a staged inconsistent config causes the *next* `deploy()` to revert
  (`BorrowCFTooLarge`), temporarily blocking parameter rollout. No fund impact.
- **Access:** governor / market-admin only (trusted roles). **Matches upstream** —
  not fork-introduced.
- **Recommendation:** add fail-fast range checks in the setters (defense-in-depth).

### F-2 — No on-chain oracle staleness / sequencer checks *(Informational — accepted design)*
`getPrice()` validates only `answer > 0`; `updatedAt` / `answeredInRound` are unused.
Rate-based feeds hardcode `updatedAt = block.timestamp`, defeating any downstream
staleness gate.
- **Impact:** stale-feed or L2-sequencer-downtime pricing is a per-deployment risk;
  Compound intentionally relies on Chainlink heartbeats + collateral-factor buffers.
- **Recommendation:** per-market, consider staleness bounds where the heartbeat warrants.

### F-3 — LST / rate price feeds forward an unbounded external rate *(Informational — integration risk)*
`RateBasedScalingPriceFeed`, `EzETHExchangeRatePriceFeed`, `PriceFeedWith4626Support`,
`WstETHPriceFeed` pass through `getRate()` / `convertToAssets()` / `tokensPerStEth()`
with **no min/max or deviation bounds**. Collateral valuation trusts the external
source atomically.
- **Impact:** *if* a specific live market's rate provider were atomically manipulable
  (donation, spot-pool skew, ERC4626 share inflation), it would escalate to
  over-collateralized borrowing → insolvency. **Not exploitable generically** — depends
  entirely on the deployed provider, which is why this cannot be confirmed from source.
- **This is the single highest-value lead for continued research** (see §8).

### F-4 — Documented reentrancy / non-standard-token constraints *(Informational — by design)*
`buyCollateral`'s pre-transfer-hook note, and fee-on-transfer / ERC-777 collateral
incompatibility, are mitigated by the `nonReentrant` guard plus the governance
constraint "do not list such assets." Flagged for completeness; not a code defect.

---

## 7. Known, accepted design assumptions (not findings)

These are documented Compound design choices, previously reported and closed as
out-of-scope — listed so they are not re-litigated:

- **No on-chain oracle staleness check** — Comet relies on Chainlink heartbeats +
  collateral-factor buffers; feeds pass through underlying round data unmodified.
- **`buyCollateral` reentrancy note / fee-on-transfer / ERC-777 collateral** —
  mitigated by "do not list such assets" at governance time, enforced by the
  `nonReentrant` guard on user entry points.
- **Trusted roles** — governor and market-admin multisig can change parameters
  within bounds; abuse requires key compromise (excluded from bounty scope).

---

## 8. Residual risk & recommendation

The remaining surface with genuine expected value is **per-deployment oracle
integration**, which cannot be assessed from source alone:

- LST / rate-based feeds (`RateBasedScalingPriceFeed`, `EzETHExchangeRatePriceFeed`,
  `PriceFeedWith4626Support`, `WstETHPriceFeed`) forward an underlying
  `getRate()` / `convertToAssets()` **without bounds**. If a *specific live market's*
  rate provider is atomically manipulable (donation, spot-pool skew, share inflation),
  that escalates to over-collateralized borrowing → insolvency.
- **Action:** pick a named live market and fork-test its actual rate source for
  atomic manipulability. The adapter code is correct; the risk (if any) is in the
  external source it trusts, per deployment.

---

## 9. Artifacts

Committed to branch `claude/compound-v3-security-audit-9j4emv`:

```
forge/test/invariant/
├── CometInvariant.t.sol        # stateful invariant campaign (24 assets, mixed decimals)
├── CometChainScenario.t.sol    # deterministic borrow→crash→absorb→buy lifecycle
├── CometHandler.sol            # bounded random action driver + coverage counters
└── mocks/
    ├── MockERC20.sol
    └── MockPriceFeed.sol
```

Run: `FOUNDRY_SOLC=<solc-0.8.15> forge test --match-contract "CometInvariant|CometChainScenario"`

---

*Prepared as an authorized security review under Compound's Immunefi program.
Conclusion: no qualifying vulnerability found; core protocol and governance are
sound and now fuzz-corroborated.*
