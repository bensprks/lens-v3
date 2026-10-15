# Lens Protocol V3 on Monad

Lens V3 is deployed on Lens Chain, a ZKsync (ZK Stack) chain whose native token is GHO. This document explains what is
needed to run it on [Monad](https://docs.monad.xyz), an EVM-equivalent L1 whose native token is MON, and how to build,
test and deploy it with Foundry's Monad support.

## Quickstart

Monad execution ships with official Foundry since v1.8.0 (the ZKsync fork used for `--zksync` does not include it):

```
foundryup --install v1.8.5
yarn
```

Run the whole test suite with Monad's EVM semantics, and check the contract sizes against Monad's limits:

```
FOUNDRY_PROFILE=monad forge test
FOUNDRY_PROFILE=monad forge build --sizes
```

Run a local Monad node and deploy the protocol to it:

```
anvil --network monad --auto-impersonate
FOUNDRY_PROFILE=monad forge script script/DeployMonad.s.sol --rpc-url http://127.0.0.1:8545 \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast
```

The `monad` profile sets `network = "monad"`, the same as passing `--network monad`, which selects Monad's execution
rules: gas schedule, 128 KB code size limit, Monad precompiles and reserve balance tracking. It also uses the compiler
settings of Monad deployments (see [Compiler settings](#compiler-settings)), whereas `forge test --network monad` uses
Monad's rules with the default settings. The legacy `--monad` flag is still accepted as a hidden alias of
`--network monad`, and scripts and forks pointed to Monad mainnet or testnet RPCs select Monad automatically.

## What changed and why

### LensCreate2 on EVM chains (the only contract change)

Lens deploys its singletons (`LensFees`, `LensNativePaymentHelper`, `ActionHub`, rules and actions) through
`LensCreate2`, which gives them addresses that only depend on a salt. Moreover, every primitive, payment rule and action
resolves the `LensFees` and `LensNativePaymentHelper` addresses through `LensCreate2` in its constructor. Nothing of
that worked outside ZKsync, because:

- `LensCreate2.getAddress` implemented ZKsync's CREATE2 derivation, `keccak256(keccak256("zksyncCreate2") ++ ...)`.
- `LENS_CREATE_2_ADDRESS` is the nonce 0 CREATE address of its deployer on ZKsync, which also derives CREATE addresses
  differently. No EVM deployer can ever get that address, so on Monad there was no `LensCreate2` to resolve anything.

Changes, in `contracts/core/upgradeability/LensCreate2.sol`:

- `LENS_CREATE_2_EVM_ADDRESS`: where `LensCreate2` lives on EVM chains, as the nonce 0 CREATE address of
  `LENS_CREATE_2_EVM_DEPLOYER`. Same deployment scheme as on ZKsync, and the same address on every EVM chain.
- `lensCreate2Address()`: returns `LENS_CREATE_2_ADDRESS` if there is code there (ZKsync), and
  `LENS_CREATE_2_EVM_ADDRESS` otherwise. Code can never exist at the ZKsync-derived address on an EVM chain, so this
  cannot be spoofed. `LensPaymentHandler`, `LensRulePaymentHandler` and `PayableUsingNativePaymentHelper` use it instead
  of the constant.
- `LensCreate2` derives the standard `keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))` CREATE2 addresses on
  EVM chains. On ZKsync it keeps computing the exact same addresses as before.

> [!IMPORTANT]
> `LENS_CREATE_2_EVM_DEPLOYER` is a **placeholder** (`0x…dEaD`, whose key nobody holds), so nothing can be deployed at
> `LENS_CREATE_2_EVM_ADDRESS` on a live chain yet. Before deploying to Monad, replace it with the deployer that will own
> the deployment, which must not have sent any transaction on the target chains, and replace `LENS_CREATE_2_EVM_ADDRESS`
> with `cast compute-address <deployer> --nonce 0`. The `test_EvmAddressIsFirstCreateAddressOfEvmDeployer` test checks
> both stay in sync, and `DeployMonad` refuses to run on Monad while the placeholder is in place.

### MON as the native token (configuration only)

- `NATIVE_TOKEN` (`0x800A`, ZKsync's base token contract) keeps being the marker for "the chain's native token" in
  payment configurations, so on Monad it means MON. The contracts only compare against it, they never call it or send
  value to it, and there is nothing at `0x800A` on Monad.
- `Account` takes the native and wrapped native tokens as constructor arguments. On Monad they are `NATIVE_TOKEN` and
  WMON: `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` on mainnet, `0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541` on testnet.
  `DeployMonad` uses them by default.

### Compiler settings

Lens Chain runs bytecode compiled by zksolc with its own optimizer, whereas Monad runs solc's bytecode, which the default
profile leaves unoptimized. The `monad` profile in `foundry.toml` enables solc's optimizer (200 runs) and targets
`cancun` (PUSH0, MCOPY), leaving the default profile and the ZKsync builds as they are. Measured with Monad's rules:

| Gas used | Default profile | `monad` profile | |
| --- | --- | --- | --- |
| Create an account | 2.22M | 1.42M | -36% |
| Deploy a feed through `LensFactory` | 4.25M | 2.79M | -34% |
| Deploy the protocol (`DeployMonad`, 91 transactions) | 192M | 115M | -40% |
| Post / follow / tip 1 MON | 547k / 487k / 257k | 530k / 474k / 245k | -3% to -5% |

Over 80% of the cost of creating an account goes to deploying its own `ProxyAdmin` and `BeaconProxy`, which is cheap on
ZKsync, where known bytecode is deployed by its hash, but paid per byte on Monad. `via_ir` cannot compile the contracts
without code changes (stack too deep).

> [!NOTE]
> The addresses `LensCreate2` derives depend on the proxy bytecode, so deploy to a given chain with the same compiler
> settings every time, i.e. the `monad` profile.

### ZKsync compatibility

The codebase still builds and runs on Lens Chain: the ZKsync addresses are unchanged, and so are the default profile and
the zksolc settings. Supporting both costs ~20 lines in `LensCreate2`, plus ~10k gas each time a contract resolving it is
deployed (one cold `EXTCODESIZE`), and nothing on user actions. New code has to keep compiling with zksolc too, which for
instance rejects `transfer` and `send`.

### Tooling

- `script/DeployMonad.s.sol`: deploys the whole protocol with Foundry, as the Hardhat deployment scripts are ZKsync
  specific. See [Deploying to Monad](#deploying-to-monad).
- `foundry.toml`: the `monad` profile, `[lint] lint_on_build = false`, as recent Foundry versions lint after every build
  and `deny_warnings` makes that fail, and the `monad` and `monad_testnet` RPC endpoints.
- CI: a new `monad` job checking the contract sizes and running the tests with the `monad` profile.
- Tests:
  - `test/upgradeability/LensCreate2Evm.t.sol`: `LensCreate2` on EVM chains, deployed the same way as on a live chain.
  - `test/monad/MonadReserveBalance.t.sol`: how Monad's reserve balance affects MON payments (see below).
  - `test/script/DeployMonad.t.sol`: runs the deployment script, then posts, follows and tips in MON.
  - Test helpers: `isMonad()` / `onlyMonad`, and `assumeNotCheatcodeAddress`, which also excludes the address of Foundry's
    Monad cheatcodes (`0xc0FFee…0CEA`), as the fuzzer picks it when running with `--network monad`.
  - Two TokenDistributor fuzz tests now exclude `address(0)` inputs, which Foundry 1.8 finds.

The account system, the GHO naming in `Account`, the Hardhat/ZKsync tooling and the default compiler settings are
unchanged.

## Monad behaviour reviewed

| Monad behaviour | Impact on Lens | Change |
| --- | --- | --- |
| [Reserve balance](https://docs.monad.xyz/developer-essentials/reserve-balance): a transaction reverts (still paying gas) if it leaves an EOA or an EIP-7702 delegated EOA below `min(10 MON, its balance at transaction start)` because of the MON it spent. Undelegated senders can still empty their account if they did not transact in the previous 3 blocks. Contracts are exempt. | Lens contracts are exempt: `Account`, `LensNativePaymentHelper`, actions and rules can move all their MON. Users paying in MON (tips, collects, payment rules) can hit it: undelegated EOAs when making several payments in quick succession, EIP-7702 delegated EOAs whenever a payment leaves them below 10 MON. Paying in WMON or from a Lens `Account` avoids it. | None, documented and covered by `MonadReserveBalance.t.sol` |
| [Gas is charged on the gas limit](https://docs.monad.xyz/developer-essentials/gas-pricing), not on the gas used. | Frontends and scripts pay for any gas limit overestimation. `forge script` multiplies estimates by 130% by default (`--gas-estimate-multiplier`). | None |
| [Repriced cold accesses](https://docs.monad.xyz/developer-essentials/opcode-pricing): 10,100 gas per cold account, 8,100 gas per cold storage page of 128 slots (MIP-8). | The same flows use more gas units than on Ethereum, e.g. posting, following and tipping in `DeployMonad.t.sol` takes 1.67M gas with Monad's rules vs 0.95M. No Lens code relies on hardcoded gas amounts or the 2300 stipend (native transfers use `.call{value: ...}`). | None |
| 128 KB contract code and 256 KB init code limits (MIP-2), 30M gas per transaction. | Without the optimizer, 7 Lens contracts exceed Ethereum's 24 KB limit, the biggest being `Namespace` at 45.6 KB. With the `monad` profile, `Namespace` (27.2 KB) and `LensFactory` (25.5 KB) still do. They all fit on Monad. The biggest deployment transaction uses 6M gas. | None |
| Fusaka-level EVM, no blob transactions. | Lens compiles for `paris`, or `cancun` with the `monad` profile, which only use opcodes Monad supports. | None |
| 300 ms blocks, `block.timestamp` in seconds (several blocks share it). | Lens only uses timestamps for deadlines and creation times. `EventEmitterEarly` (inherited by `Lock` and `Beacon`) only lets anyone emit events while `block.number < 30,000`, which is long gone on Monad mainnet and testnet, but not on a fresh local chain. | None |
| EIP-7702 is supported. | `Account` only allows ERC-20 `transferFrom` from `msg.sender` "until EIP-7702 is supported by ZkSync". That could be revisited on Monad, but it is left as is. | None |
| Precompiles: staking at `0x1000`, reserve balance at `0x1001` (MIP-4). | Not used by Lens, no conflict with `NATIVE_TOKEN`. | None |
| Asynchronous execution: `latest` is a proposed block, accounts funded from a zero balance must wait 3 blocks before sending, and each sender has about 10 MON of in-flight gas (limit × price). | Backends should wait for `finalized` blocks before treating actions as irreversible. Deployer keys must be funded beforehand, and deployments sent one transaction at a time. | None |

Foundry tracks the reserve balance but does not revert transactions that violate it yet
([monad-revm#50](https://github.com/category-labs/monad-revm/issues/50)), which is why the test suite passes as is.
`MonadReserveBalance.t.sol` asks the MIP-4 precompile, `dippedIntoReserve()`, instead.

## Deploying to Monad

`script/DeployMonad.s.sol` deploys `LensCreate2`, then through it `LensFees`, `LensNativePaymentHelper`, `ActionHub`, the
19 rules, the 3 actions and `LensFactory` (using the same `lens.contract.<Name>` salts as on Lens Chain), along with
the locks, implementations, beacons and factories, and the global Feed and Graph. It does not deploy the global `lens`
Namespace, as `LensFactory` reserves that name, nor the `TokenDistributor`.

On a local `anvil --network monad --auto-impersonate` node (see [Quickstart](#quickstart)) every address defaults to the
deployer, except the proxy admins (they cannot call the contracts behind their proxies), which default to anvil's
second account, and WMON is a mock. On other chains:

1. Replace the placeholder `LENS_CREATE_2_EVM_DEPLOYER` (see above).
2. Fund the deployer and the `LensCreate2` deployer, at least 3 blocks ahead. The deployment uses ~115M gas, so ~12 MON
   at the 100 gwei base fee, plus the gas estimate multiplier, as the full gas limit is charged.
3. Set the owners and admins in `.env` (see `.env.example`): `LENS_CREATE_2_PROXY_ADMIN`, `PROXY_ADMIN_LOCK_OWNER`,
   `ACCESS_CONTROL_LOCK_OWNER`, `BEACON_OWNER`, `FACTORIES_PROXY_OWNER`, `RULES_PROXY_OWNER`, `RULES_OWNER`,
   `ACTIONS_OWNER`, `PRIMITIVES_OWNER`, `TREASURY_ADDRESS` and `TREASURY_FEE_BPS`. `WRAPPED_NATIVE_TOKEN` defaults to
   WMON.
4. Deploy, signing with both deployers:

```
FOUNDRY_PROFILE=monad forge script script/DeployMonad.s.sol --rpc-url monad_testnet \
  --account <deployer> --account <lensCreate2Deployer> --sender <deployerAddress> --broadcast --slow
```

To verify the contracts on [MonadVision](https://monadvision.com), add
`--verify --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/`, or use
`--verify --verifier etherscan --etherscan-api-key <key>` for [Monadscan](https://monadscan.com).

The deployer stays the owner of `LensCreate2`, so it can deploy future contracts at their deterministic addresses.
