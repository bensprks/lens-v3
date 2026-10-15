# Lens Protocol V3 on Monad

Lens V3 runs on Lens Chain, a ZKsync chain whose native token is GHO. This codebase also runs on
[Monad](https://docs.monad.xyz), an EVM-equivalent chain whose native token is MON. This document covers what changed
compared to the ZKsync deployment, and what to keep in mind when deploying and operating Lens on Monad.

## Changes

### LensCreate2 on EVM chains

Every primitive, payment rule and action resolves `LensFees` and `LensNativePaymentHelper` through `LensCreate2` when
deployed, and `LensCreate2` only supported ZKsync: it computed ZKsync's CREATE2 addresses, and lives at an address only
reachable on ZKsync. In `contracts/core/upgradeability/LensCreate2.sol`:

- `LENS_CREATE_2_EVM_ADDRESS` is where `LensCreate2` lives on EVM chains: the first contract deployed by
  `LENS_CREATE_2_EVM_DEPLOYER`, the same scheme as on ZKsync.
- `lensCreate2Address()` returns the ZKsync address when there is code at it, and the EVM address otherwise. The payment
  contracts use it instead of the ZKsync constant.
- On EVM chains, `LensCreate2` computes standard CREATE2 addresses. On ZKsync it computes the same addresses as before.

> [!IMPORTANT]
> `LENS_CREATE_2_EVM_DEPLOYER` is a placeholder. Before deploying to Monad, replace it with the deployer that will own
> the deployment, which must not have sent any transaction on the target chain, and set `LENS_CREATE_2_EVM_ADDRESS` to
> `cast compute-address <deployer> --nonce 0`. A test checks that both match.

### MON as the native token

No contract changes. `NATIVE_TOKEN` (`0x800A`) keeps meaning "the native token" in payment configurations, so MON on
Monad, and `Account` is deployed with `NATIVE_TOKEN` and WMON as its native and wrapped native tokens. WMON is
`0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` on mainnet and `0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541` on testnet.

### Compiler settings

Lens Chain runs bytecode optimized by zksolc, while Monad runs solc's bytecode, which the default profile leaves
unoptimized. The `monad` profile in `foundry.toml` enables the optimizer and targets `cancun`, which cuts the gas of
creating accounts and primitives by ~35% and of deploying the protocol by ~40%. It also sets `network = "monad"`, so
Foundry applies Monad's execution rules, as with `--network monad`.

The addresses `LensCreate2` computes depend on the compiled proxy bytecode, so always deploy with the `monad` profile.

### Tooling

- `script/DeployMonad.s.sol` deploys the protocol with Foundry, as the Hardhat scripts are ZKsync specific.
- A new `monad` CI job runs the tests with the `monad` profile, including new tests for `LensCreate2` on EVM chains,
  Monad's reserve balance, and the deployment script.

ZKsync support is unchanged. Keeping it costs ~20 lines in `LensCreate2` and ~10k gas each time a contract resolving it
is deployed, and new code must keep compiling with zksolc, which for instance rejects `transfer` and `send`.

## Running locally

With Foundry >= 1.8.0 (`foundryup --install v1.8.5`) and `yarn` installed:

```
FOUNDRY_PROFILE=monad forge test
anvil --network monad --auto-impersonate
FOUNDRY_PROFILE=monad forge script script/DeployMonad.s.sol --rpc-url http://127.0.0.1:8545 \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast
```

## Deploying to Monad

`DeployMonad` deploys `LensCreate2`, then through it `LensFees`, `LensNativePaymentHelper`, `ActionHub`, the rules, the
actions and `LensFactory`, with the same salts as on Lens Chain, along with the locks, implementations, beacons,
factories, and the global Feed and Graph.

1. Replace the placeholder `LENS_CREATE_2_EVM_DEPLOYER`.
2. Set the owners and admins listed in `.env.example` in `.env`.
3. Fund the deployer and the `LensCreate2` deployer. The deployment uses ~115M gas, ~12 MON at the 100 gwei base fee,
   plus the gas estimate multiplier, as Monad charges the full gas limit.
4. Deploy, signing with both deployers, and verify the contracts on MonadVision:

```
FOUNDRY_PROFILE=monad forge script script/DeployMonad.s.sol --rpc-url monad_testnet \
  --account <deployer> --account <lensCreate2Deployer> --sender <deployerAddress> --broadcast --slow \
  --verify --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/
```

## Monad behaviour

- **Reserve balance**: a transaction reverts if it leaves an EOA, or an EIP-7702 delegated EOA, below
  min(10 MON, its starting balance) because of the MON it spent. Contracts are exempt. Users paying in MON (tips,
  collects, payment rules) can hit it: delegated EOAs whenever a payment takes them below 10 MON, other EOAs when paying
  again within ~3 blocks. Paying in WMON, or from a Lens `Account`, avoids it.
- **Gas is charged on the gas limit**, not the gas used, so frontends and relayers should set tight gas limits.
- **Cold storage and account accesses cost more** than on Ethereum: posting, following and tipping use ~1.75x the gas.
- **Asynchronous execution**: `latest` is a proposed block, so backends should wait for `finalized` blocks before
  treating actions as final.
- **Timestamps** are in seconds and shared by several blocks, so order events by block number and log index.
- **EIP-7702** is supported, so `Account`'s restriction on ERC-20 `transferFrom`, kept "until EIP-7702 is supported by
  ZkSync", could be revisited.
