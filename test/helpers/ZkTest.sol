// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

// Foundry's Monad-specific cheatcodes (`MonadVm`), registered when running with `--network monad`.
address constant MONAD_VM_ADDRESS = 0xc0FFeeCD43A10e1C2b0De63c6CDCFe5B7d0e0CEA;

contract ZkTester {
    function isZkEvm() public view returns (bool) {
        return block.coinbase == address(0x8001);
    }
}

contract ZkTest is Test {
    function isZkEvm() public returns (bool) {
        ZkTester zkTester = new ZkTester();
        return zkTester.isZkEvm();
    }

    // Only Monad (e.g. `forge test --network monad`) has the MIP-4 reserve balance precompile, which must be CALLed.
    function isMonad() public returns (bool) {
        (bool callSucceeded, bytes memory returnData) =
            address(0x1001).call{gas: 10_000}(abi.encodeWithSignature("dippedIntoReserve()"));
        return callSucceeded && returnData.length == 32;
    }

    // Same as forge-std's assumeNotForgeAddress, but also excluding the Monad cheatcodes, which the fuzzer can pick.
    function assumeNotCheatcodeAddress(address addr) internal pure {
        assumeNotForgeAddress(addr);
        vm.assume(addr != MONAD_VM_ADDRESS);
    }

    modifier onlyZkEvm() {
        vm.skip(!isZkEvm());
        _;
    }

    modifier onlyMonad() {
        vm.skip(!isMonad());
        _;
    }

    modifier onlyEvm() {
        vm.skip(isZkEvm());
        _;
    }

    modifier nonFork() {
        vm.skip(isFork());
        _;
    }

    modifier onlyFork() {
        vm.skip(!isFork());
        _;
    }
}
