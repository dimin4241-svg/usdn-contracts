# [High] Liquidated LongFarming positions keep earning SDEX and steal active farmers' unclaimed yield

## Severity / in-scope impact

**High — Theft of unclaimed yield**

Affected mainnet asset:

- `UsdnLongFarming`: `0xF9D36078A248AF249AA57ae1D5D0c1033d6Bbe27`

The USDN Immunefi program explicitly lists `LongFarming` as an in-scope asset and `Theft of unclaimed yield` as a High impact.

## Summary

`UsdnLongFarming` does not remove a farming position from `_totalShares` when the underlying USDN long is liquidated. Instead, the position remains registered until a later `harvest()` / `withdraw()` call notices that `USDN_PROTOCOL.getTickVersion(tick) != storedTickVersion`.

The critical ordering is that `_harvest()` calls `_updateRewards()` **before** `_isLiquidated()`. `_updateRewards()` harvests all newly accrued SDEX from the external `FarmingRange` and distributes it across the current `_totalShares`, which still includes already-liquidated positions. Only afterwards is the selected position identified as liquidated and deleted.

Therefore, every block between underlying USDN liquidation and LongFarming notification lets the dead position capture SDEX that should have been allocated to still-active farming positions. The stale allocation is not burned: `_slash()` pays it to the former position owner (90% with an external notifier under the live 10% notifier fee, or 100% if the former owner self-notifies).

This is not a report about the intended rule that legitimate rewards accumulated **before liquidation** can be paid to the former owner. The bug is the allocation of **future rewards after the underlying position has already been liquidated**, which directly dilutes active farmers' unclaimed yield.

## Root cause

Current upstream `src/UsdnLongFarming.sol` follows this sequence:

```solidity
function _harvest(bytes32 positionIdHash)
    internal
    returns (bool isLiquidated_, uint256 rewards_, uint256 newRewardDebt_, address owner_)
{
    _updateRewards();

    PositionInfo memory posInfo = _positions[positionIdHash];
    ...

    (rewards_, newRewardDebt_) = _calcRewards(posInfo, _accRewardPerShare);
    isLiquidated_ = _isLiquidated(posInfo.tick, posInfo.tickVersion);
}
```

`_updateRewards()` harvests SDEX and divides it by `_totalShares`:

```solidity
function _updateRewards() internal {
    ...
    if (_totalShares == 0) return;

    uint256 rewardsBalanceBefore = REWARD_TOKEN.balanceOf(address(this));
    ...
    REWARDS_PROVIDER.harvest(campaignsIds);
    uint256 periodRewards = REWARD_TOKEN.balanceOf(address(this)) - rewardsBalanceBefore;

    if (periodRewards > 0) {
        _accRewardPerShare = _calcAccRewardPerShare(periodRewards);
    }
}

function _calcAccRewardPerShare(uint256 periodRewards)
    internal
    view
    returns (uint256)
{
    return _accRewardPerShare
        + FixedPointMathLib.fullMulDiv(periodRewards, SCALING_FACTOR, _totalShares);
}
```

Liquidation is only checked after the new rewards have already been assigned:

```solidity
function _isLiquidated(int24 tick, uint256 tickVersion)
    internal
    view
    returns (bool)
{
    return USDN_PROTOCOL.getTickVersion(tick) != tickVersion;
}
```

The stale shares are removed only later inside `_slash()` -> `_deletePosition()`.

As a result, liquidation in the USDN Protocol and removal from LongFarming reward accounting are two independent state transitions with an unbounded notification delay between them.

## Why the notifier design does not make this intended

The notifier mechanism itself is intentional, and PR #27 intentionally changed slash handling so that legitimate pending rewards go to the former owner rather than a burn address. This report does **not** challenge that design.

The separate invariant violation is:

> Once the underlying USDN position is liquidated, its farming shares must stop participating in future reward periods.

The official USDN Long Farming documentation describes notifier incentives as necessary so that, when a position is liquidated, LongFarming can **halt rewards to the owner and remove the position from the contract**.

The current implementation instead continues allocating future rewards until someone happens to notify LongFarming.

## Deterministic two-position PoC

A regression PoC was added only to the research branch and runs against the unchanged upstream LongFarming implementation/fixtures.

Workflow:

```text
.github/workflows/security-long-farming-post-liquidation-poc.yml
```

Successful CI run:

```text
run 31317371038
job 93254682308
```

The strongest test creates two positions with equal farming shares:

1. Position A belongs to the attacker and becomes liquidated in the mock USDN Protocol.
2. Position B remains active.
3. LongFarming is not notified about A for 100 blocks.
4. Rewards provider emits 5 SDEX/block.
5. A remains in `_totalShares`, so the 500 future SDEX are split 50/50.
6. The former owner self-notifies and receives A's stale allocation.

Observed result:

```text
immediate-cleanup control:
  former owner = 5 SDEX (pre-liquidation only)
  active user  = 505 SDEX

delayed notification:
  former owner = 255 SDEX
  active user  = 255 SDEX

stolen_from_honest              = 250 SDEX
attacker_post_liquidation_gain  = 250 SDEX
```

Thus the post-liquidation payout is exactly taken from the active user's unclaimed yield, not created as an independent notifier reward.

A separate single-position test proves the timing boundary directly:

```text
pending at liquidation:       5 SDEX
pending 100 blocks later:   505 SDEX
strictly post-liquidation:  +500 SDEX
```

The subsequent `harvest()` recognizes the position as liquidated but still pays the accumulated stale allocation.

## Production occurrence — historical delays

Mainnet LongFarming history was reconstructed from indexed events. It contains 1,465 deposits, 1,232 withdrawals, 216 slashes and 2,295 harvests, and the reconstructed current position count matches live storage.

Real examples where the USDN Protocol liquidated a farming position well before LongFarming removed it:

### Example 1 — 2,906 block delay

```text
tick/version:       82000 / 0
USDN LiquidatedTick block: 21,756,069
liquidation tx:     0x7230361c9924ce9740447f3c9827487ee4e20f297eb5b93b57f4a050193311f2
LongFarming Slash block:   21,758,975
slash tx:           0xec531ddc63988894a6e5c3d4718b5360d33bd3352e3a1718886eae81739c4dfa
delay:              2,906 blocks
owner payout:       55,350.465282065918760293 SDEX
notifier payout:    0 (self-notification)
```

This occurred during an active reward epoch of approximately `149.146814241486068111 SDEX/block`.

### Example 2 — 413 block delay

```text
tick/version:       79200 / 0
USDN liquidation:  block 21,762,906
liquidation tx:     0xf0b9f3ddd09eb93a4feeb99d8a4374064921f4441520a24933af98fee0be85b6
LongFarming slash: block 21,763,319
slash tx:           0xa7c268ea30aa04029d8efac26efd06b0ddea2a1cb2bfd50b64b8abb2e48ef65e
delay:              413 blocks
total slash payout: 107,428.932620494560771610 SDEX
```

### Example 3 — 1,460 block delay

```text
tick/version:       78100 / 0
USDN liquidation:  block 21,941,949
liquidation tx:     0xe86203631dabae1d6db6161c7037c3ab5b9b8157a88edea09bfcda48cd5c15d5
LongFarming slash: block 21,943,409
slash tx:           0x705d64defcdf6cadecec09f205a0115838c15dc6684b955c23e56ab8084f8f3d
delay:              1,460 blocks
total slash payout: 327,499.097412829931140102 SDEX
```

These production examples show that notifier delay is not hypothetical or limited to one block.

## Current live impact — three liquidated positions are still registered

A read-only reconstruction of current LongFarming state found 17 stored farming positions. Three are already liquidated in the USDN Protocol (`currentTickVersion != storedTickVersion`) but remain in LongFarming with non-zero pending rewards.

| Position | Owner | Stored -> current version | Shares | Current pending SDEX |
|---|---|---:|---:|---:|
| `74200/0/5` | `0x11D052d20B3c9F87F7F454443DbC0500930940C4` | `0 -> 1` | `18.144369031690637954` | `1,837,503.818724216647333900` |
| `79500/2/2` | `0x4Bfd6E06481439DC78263436Ef53AcCd90E9ea64` | `2 -> 4` | `6.466855779060435454` | `498,509.200987667827752255` |
| `83100/0/9` | `0xa8ac5e86f6b02584E157E12A2f7faA3ea835E2d7` | `0 -> 1` | `21.591176744821905256` | `1,134,542.367165033145917196` |

Combined stale shares:

```text
46.202401555572978664 / 89.874793386011103305 total shares
= 51.4075% of the current reward denominator
```

Combined stale pending:

```text
3,470,555.386876917621003351 SDEX
```

Current LongFarming SDEX balance:

```text
5,354,289.788799037650902174 SDEX
```

So the stale claims are fully backed by the reward token balance.

## Exact currently withdrawable amount that accrued *after* liquidation

Using archive `eth_call`, `pendingRewards()` was queried at the exact USDN `LiquidatedTick` block for each currently stale position and compared with current pending rewards.

### `74200 / v0 / #5`

```text
LiquidatedTick block: 22,228,018
liquidation tx: 0x509d9f64f248e0774e4dde276d8a6102dada94f08a31ec52915dd070b9202493

pending at liquidation:
29,427.814663083047065544 SDEX

pending one block later:
29,429.494821834182278324 SDEX
(+1.680158751135212780 SDEX after liquidation in one block)

pending now:
1,837,503.818724216647333900 SDEX

strict post-liquidation misallocation:
1,808,076.004061133600268356 SDEX
```

### `79500 / v2 / #2`

```text
LiquidatedTick block: 22,640,863
liquidation tx: 0x4558578fa7dd8330881d1de2ac49e7c2d0599200b9da77065f3da81c5bf3ffb1

pending at liquidation:
846.462246222283344275 SDEX

pending one block later:
846.579937243537128492 SDEX
(+0.117691021253784217 SDEX)

pending now:
498,509.200987667827752255 SDEX

strict post-liquidation misallocation:
497,662.738741445544407980 SDEX
```

### `83100 / v0 / #9`

```text
LiquidatedTick block: 23,724,029
liquidation tx: 0xea01ef51aa9f4330093b26d0397268e409633419cf0ef6603fcdd89eb6427cde

pending at liquidation:
863.639052416889002427 SDEX

pending one block later:
864.085640739188033886 SDEX
(+0.446588322299031459 SDEX)

pending now:
1,134,542.367165033145917196 SDEX

strict post-liquidation misallocation:
1,133,678.728112616256914769 SDEX
```

### Total exact current post-liquidation misallocation

```text
3,439,417.470915195401591105 SDEX
```

This is not an estimate from emission rates. It is the direct difference between each stale position's on-chain entitlement at its liquidation boundary and its current entitlement.

The one-block archive reads also prove causality immediately after each liquidation.

After LongFarming's initial 914-block deployment-to-first-deposit gap, historical reconstruction found no later period with zero farming positions. Therefore, the post-liquidation SDEX allocated to these stale shares should have been distributed to other active farming shares rather than to the already-liquidated positions.

## Current payout path is executable

A read-only RPC simulation of the live contract was performed without broadcasting a transaction.

Live configuration:

```text
notifierRewardsBps = 1000 (10%)
```

For all three stale positions:

```text
harvest(...), from arbitrary notifier => (true, 0)
harvest(...), from stored owner       => (true, 0)
```

`(true, 0)` is the expected external return for a liquidated position; internally the function follows the `_slash()` branch and transfers the pending reward allocation.

Therefore:

- any address can currently clean up a stale position and receive 10% while 90% goes to its former owner;
- the former owner can self-notify and receive 100% of the stale allocation;
- no privileged permission is required;
- the current contract has enough SDEX to back the claims.

No state-changing transaction was broadcast as part of this research.

## Impact

The implementation allows already-liquidated positions to divert reward emissions from active LongFarming users. This is a direct theft/dilution of unclaimed farming yield.

The impact is demonstrated at three levels:

1. **Deterministic PoC:** an equal-share stale position steals exactly half of future SDEX from the still-active position.
2. **Historical production occurrence:** real positions remained stale for 413, 1,460 and 2,906 blocks during non-zero SDEX emissions and were later paid.
3. **Current live state:** three positions are liquidated but still claimable, with an exact `3,439,417.470915195401591105 SDEX` that accrued strictly after their USDN liquidation blocks.

The USDN program states that High theft of unclaimed yield is rewarded in the USD 3,000–5,000 range depending on funds at risk. The program also specifies that SDEX/USD payout pricing is based on the average of CoinMarketCap and CoinGecko at report submission time, so the token amount above should be used for the official funds-at-risk calculation at submission.

## Attack scenario

A malicious LongFarming user can:

1. Deposit a USDN long position into LongFarming.
2. Allow / cause the underlying USDN position to be liquidated normally.
3. Do not notify LongFarming about the liquidation.
4. While nobody else notifies, the dead position remains in `_totalShares` and receives a fraction of each future FarmingRange reward period.
5. Later call `harvest()` from the stored owner address.
6. `_updateRewards()` first assigns the latest period to the stale shares.
7. `_isLiquidated()` then notices the stale tick version.
8. Because owner == notifier, `_slash()` transfers the entire pending amount to the former owner and deletes the position.

A third-party notifier can reduce the former owner's payout to 90%, but cannot undo the theft from active farmers: the stale position's allocation has already been removed from what active positions would otherwise receive.

The existence of three current stale positions and multiple historical multi-hundred/multi-thousand-block delays demonstrates that relying on prompt third-party notification does not eliminate the real-world attack window.

## Suggested remediation

Simply moving `_isLiquidated()` before `_updateRewards()` for the position currently being harvested is not a complete fix: other stale positions can still remain in `_totalShares` and dilute reward distribution.

A robust solution needs to enforce the invariant that a USDN position stops participating in LongFarming rewards at the underlying liquidation boundary. Possible approaches include:

1. **Atomic lifecycle notification:** make USDN liquidation notify the LongFarming owner/callback so that the farming shares are removed when liquidation occurs.
2. **Liquidation-boundary reward accounting:** checkpoint/cap each farming position's entitlement at its underlying liquidation block/version and ensure post-liquidation rewards are redistributed only among active shares.
3. **Mitigation before reactivating emissions:** remove/reconcile all currently stale positions and reassign the post-liquidation portion rather than paying it to former owners.

A permissionless keeper sweep alone is only a partial mitigation because it still leaves an arbitrary delay between underlying liquidation and the sweep.

## Public prior-art / duplicate check

I did not find a public report describing this exact root cause (`_updateRewards()` allocating future FarmingRange emissions over stale liquidated shares before `_isLiquidated()`).

Important design history was checked explicitly:

- PR #6 (`feat: harvest and notify liquidations`) introduced harvest / notification / liquidation logic. It was created on 16 Dec 2024 and merged on 20 Dec 2024.
- The publicly listed Guardian USDN audit was completed on 17 Dec 2024, before PR #6 was merged.
- The earlier BailSec USDN audit was completed in May 2024.
- The later BailSec report is scoped to the Router.
- PR #27 intentionally changed legitimate slash reward handling to pay the former owner and intentionally permits a self-notifying owner to receive the whole pending amount. This report treats that as intended behavior and reports only the **post-liquidation accrual/dilution** that occurs before notification.

Private/undisclosed Immunefi duplicates cannot be checked publicly.

## Evidence map

Research branch: `security/susdn-live-config`

Key workflows:

```text
.github/workflows/security-long-farming-post-liquidation-poc.yml
  deterministic one-position + two-position control PoCs

.github/workflows/security-long-farming-history.yml
  full LongFarming event history reconstruction

.github/workflows/security-long-farming-sample-correlation.yml
  historical LiquidatedTick -> Slash delay correlation

.github/workflows/security-long-farming-fast-current.yml
  current stale position discovery

.github/workflows/security-long-farming-current-stale-liquidations.yml
  exact LiquidatedTick blocks for current stale positions

.github/workflows/security-long-farming-live-cashout.yml
  owners, shares, pending amounts and live SDEX backing

.github/workflows/security-long-farming-exact-current-theft.yml
  archive pendingRewards at liquidation block / +1 / now

.github/workflows/security-long-farming-live-harvest-sim.yml
  read-only current harvest simulation from arbitrary notifier and stored owner
```

Primary successful evidence runs:

```text
PoC:                  run 31317371038 / job 93254682308
Historical samples:   run 31310313655 / job 93237030421
Current stale scan:   run 31317556988 / job 93255145488
Current liquidation:  run 31317662037 / job 93255410887
Live backing:         run 31317753744 / job 93255638161
Exact theft archive:  run 31317835910 / job 93255859685
Live harvest sim:     run 31318011073 / job 93256322912
```

## References

- Immunefi USDN scope: `https://immunefi.com/bug-bounty/usdn/scope/`
- Immunefi USDN information/rewards: `https://immunefi.com/bug-bounty/usdn/information/`
- USDN Long Farming docs: `https://docs.smardex.io/ultimate-synthetic-delta-neutral/periphery/long-farming`
- LongFarming mainnet contract: `https://etherscan.io/address/0xF9D36078A248AF249AA57ae1D5D0c1033d6Bbe27`
- LongFarming upstream: `https://github.com/SmarDex-Ecosystem/usdn-long-farming`
- PR #6: `https://github.com/SmarDex-Ecosystem/usdn-long-farming/pull/6`
- PR #27: `https://github.com/SmarDex-Ecosystem/usdn-long-farming/pull/27`
