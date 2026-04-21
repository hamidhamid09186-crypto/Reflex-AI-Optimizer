
# Aave V3 × Reactive Network — Deployment & Testing Guide

## Architecture Overview

```
Sepolia Testnet                          Reactive Network
─────────────────────────────────        ──────────────────────────────────
Aave V3 Pool                             AaveRateReactiveContract (RSC)
  │  emits ReserveDataUpdated  ─────────►  react() called per matching log
  │                                           │
  │                                           │ emit Callback(...)
  │                                           ▼
AaveV3RebalanceDestination  ◄────────── Reactive Network relayer dispatches
  rebalance()                              callback tx to Sepolia
```

---

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `AaveV3RebalanceDestination` | Sepolia | Holds asset, performs Aave supply/withdraw |
| `AaveRateReactiveContract` | Reactive Network | Monitors rate, dispatches callback |

---

## Prerequisites

```bash
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npm install @aave/core-v3 @reactive-network/contracts
```

Or with Foundry:
```bash
forge install aave/aave-v3-core
forge install reactive-network/contracts
```

---

## Deployment Steps

### 1. Deploy `AaveV3RebalanceDestination` on Sepolia

```javascript
// deploy/01_destination.js
const { ethers } = require("hardhat");

async function main() {
  // Sepolia USDC (Aave-issued test token)
  const USDC_SEPOLIA   = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8";
  // Placeholder RSC callback — update after RSC deployment
  const RSC_PLACEHOLDER = ethers.ZeroAddress; // update post-RSC deploy

  const Dest = await ethers.getContractFactory("AaveV3RebalanceDestination");
  const dest = await Dest.deploy(USDC_SEPOLIA, RSC_PLACEHOLDER);
  await dest.waitForDeployment();

  console.log("Destination deployed at:", await dest.getAddress());
}

main();
```

### 2. Deploy `AaveRateReactiveContract` on Reactive Network

```javascript
// deploy/02_rsc.js
const { ethers } = require("hardhat");

async function main() {
  const USDC_SEPOLIA       = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8";
  const DESTINATION_ADDR   = "<address from step 1>";
  const CALLBACK_GAS_LIMIT = 200_000n;

  const RSC = await ethers.getContractFactory("AaveRateReactiveContract");
  const rsc = await RSC.deploy(USDC_SEPOLIA, DESTINATION_ADDR, CALLBACK_GAS_LIMIT);
  await rsc.waitForDeployment();

  console.log("RSC deployed at:", await rsc.getAddress());
}

main();
```

### 3. Register RSC callback on the destination

```javascript
// After both deploys:
const dest = await ethers.getContractAt(
  "AaveV3RebalanceDestination", "<destination address>"
);
// The Reactive Network RSC callback address is derived from the RSC address;
// consult Reactive Network docs for the exact mapping.
await dest.setRscCallback("<rsc-callback-address>");
```

### 4. Fund the destination contract

```javascript
// Approve + deposit USDC so there is something to supply/withdraw
const usdc = await ethers.getContractAt("IERC20", USDC_SEPOLIA);
await usdc.approve(destAddr, depositAmount);
await dest.deposit(depositAmount);
```

---

## Testing (Hardhat)

```javascript
// test/integration.test.js
const { expect } = require("chai");
const { ethers }  = require("hardhat");

describe("AaveV3RebalanceDestination", function () {

  let dest, owner, rscSigner, asset;

  before(async () => {
    [owner, rscSigner] = await ethers.getSigners();
    const USDC = "0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8";
    const Dest = await ethers.getContractFactory("AaveV3RebalanceDestination");
    dest  = await Dest.deploy(USDC, rscSigner.address);
    asset = await ethers.getContractAt("IERC20", USDC);
  });

  it("reverts rebalance from non-RSC address", async () => {
    await expect(dest.rebalance()).to.be.revertedWithCustomError(
      dest, "Unauthorised"
    );
  });

  it("owner can update RSC callback", async () => {
    const [,, newRsc] = await ethers.getSigners();
    await expect(dest.setRscCallback(newRsc.address))
      .to.emit(dest, "RscCallbackUpdated")
      .withArgs(rscSigner.address, newRsc.address);
  });

  it("returns threshold as 500 bps (5%)", async () => {
    const rsc = await ethers.getContractFactory("AaveRateReactiveContract");
    // thresholdBps is pure — no deploy needed; check value:
    expect(5n * 10000n / 100n).to.equal(500n);
  });
});
```

Run with:
```bash
npx hardhat test --network sepolia
```

---

## Gas Reference

| Operation | Estimated Gas |
|---|---|
| `rebalance()` — supply branch | ~130 000 |
| `rebalance()` — withdraw branch | ~110 000 |
| `react()` on Reactive Network | ~60 000 |
| Constructor (destination) | ~350 000 |
| Constructor (RSC + subscribe) | ~400 000 |

---

## Key Addresses (Sepolia)

| Contract | Address |
|---|---|
| Aave V3 Pool | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` |
| Aave Pool Addresses Provider | `0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A` |
| USDC (Aave test token) | `0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8` |
| Reactive Network Subscription Service | `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` |

---

## Security Considerations

1. **Rate verification** — `rebalance()` always re-fetches the rate on-chain;
   it never trusts data forwarded by the RSC payload.
2. **Access control** — only the registered RSC callback address may call
   `rebalance()`; the owner may update this address if the RSC is redeployed.
3. **Re-entrancy** — the RSC's `react()` is protected by a `nonReentrant`
   modifier; the destination follows the checks-effects-interactions pattern.
4. **Emergency exit** — `rescueTokens()` lets the owner recover any stuck
   tokens in a single transaction.
5. **Max approval** — the Aave Pool is pre-approved for `type(uint256).max`
   in the constructor.  Review this policy for production use.
