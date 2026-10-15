// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../helpers/TypeHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NATIVE_TOKEN, BPS_MAX} from "contracts/core/types/Constants.sol";
import {BaseDeployments} from "test/helpers/BaseDeployments.sol";
import {ActionHub} from "contracts/extensions/actions/ActionHub.sol";
import {IAccount} from "contracts/extensions/account/IAccount.sol";
import {MockWrapperCurrency} from "test/mocks/MockWrapperCurrency.sol";

/// @custom:keccak lens.param.amount
bytes32 constant PARAM__TIP_AMOUNT = 0xc8a06abcb0f2366f32dc2741bdf075c3215e3108918311ec0ac742f1ffd37f49;
/// @custom:keccak lens.param.token
bytes32 constant PARAM__TIP_TOKEN = 0xee737c77be2981e91c179485406e6d793521b20aca5e2137b6c497949a74bc94;

// MIP-4 precompile. Not `view` on purpose: it must be invoked with CALL, a STATICCALL reverts.
interface IReserveBalance {
    function dippedIntoReserve() external returns (bool);
}

// Minimal smart wallet an EOA can delegate to through EIP-7702.
contract Minimal7702Wallet {
    function execute(address target, uint256 value, bytes calldata data) external {
        require(msg.sender == address(this));
        (bool callSucceeded, bytes memory returnData) = target.call{value: value}(data);
        if (!callSucceeded) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}

/**
 * Monad reverts a transaction that leaves an EOA or an EIP-7702 delegated EOA below min(10 MON, its balance at the
 * start of the transaction) due to the MON it spent; gas aside, and undelegated senders can still empty their account
 * if they did not transact in the previous k blocks. Contracts are exempt. See:
 * https://docs.monad.xyz/developer-essentials/reserve-balance
 *
 * Foundry tracks the reserve balance but does not revert, so these tests ask the MIP-4 precompile instead.
 * Run with: forge test --network monad
 */
contract MonadReserveBalanceTest is BaseDeployments {
    IReserveBalance constant RESERVE_BALANCE = IReserveBalance(address(0x1001));

    address user = makeAddr("USER"); // EIP-7702 delegated EOA
    address recipient = makeAddr("TIP_RECIPIENT");
    IAccount lensAccount; // Lens Account (a contract) owned by the user
    MockWrapperCurrency wmon;

    function setUp() public override onlyMonad {
        super.setUp();

        vm.etch(user, abi.encodePacked(hex"ef0100", address(new Minimal7702Wallet()))); // EIP-7702 designator
        lensAccount = IAccount(
            payable(lensFactory.deployAccount({
                    metadataURI: "uri://account-metadata",
                    owner: user,
                    accountManagers: _emptyAddressArray(),
                    accountManagersPermissions: _emptyAccountManagerPermissionsArray(),
                    sourceStamp: _emptySourceStamp(),
                    extraData: _emptyKeyValueArray()
                }))
        );

        // Funded here, as the reserve is relative to the balances at the start of each test transaction.
        wmon = new MockWrapperCurrency("Wrapped MON", "WMON");
        vm.deal(address(this), 5 ether);
        wmon.mint{value: 5 ether}(user, 5 ether);
        vm.deal(user, 12 ether);
        vm.deal(address(lensAccount), 5 ether);
    }

    function test_DelegatedEoa_TippingMonBelowReserve_DipsIntoReserve() public {
        _tipFromUser(NATIVE_TOKEN, 5 ether); // 12 MON -> 7 MON

        _assertTipReceived(NATIVE_TOKEN, 5 ether);
        assertTrue(RESERVE_BALANCE.dippedIntoReserve(), "On Monad this transaction would revert");
    }

    function test_DelegatedEoa_TippingMonDownToReserve_DoesNotDip() public {
        _tipFromUser(NATIVE_TOKEN, 2 ether); // 12 MON -> 10 MON

        _assertTipReceived(NATIVE_TOKEN, 2 ether);
        assertFalse(RESERVE_BALANCE.dippedIntoReserve());
    }

    function test_DelegatedEoa_TippingWmon_DoesNotDip() public {
        _tipFromUser(address(wmon), 5 ether); // ERC-20 transfer, the MON balance is untouched

        _assertTipReceived(address(wmon), 5 ether);
        assertFalse(RESERVE_BALANCE.dippedIntoReserve());
    }

    function test_LensAccount_TippingAllItsMon_DoesNotDip() public {
        vm.prank(user);
        lensAccount.executeTransaction(actionHub, 5 ether, _tipCalldata(NATIVE_TOKEN, 5 ether)); // 5 MON -> 0 MON

        _assertTipReceived(NATIVE_TOKEN, 5 ether);
        assertEq(address(lensAccount).balance, 0);
        assertFalse(RESERVE_BALANCE.dippedIntoReserve());
    }

    function _tipFromUser(address token, uint256 amount) internal {
        uint256 msgValue = token == NATIVE_TOKEN ? amount : 0;
        if (msgValue == 0) {
            vm.prank(user);
            Minimal7702Wallet(user).execute(token, 0, abi.encodeCall(IERC20.approve, (tippingAccountAction, amount)));
        }
        vm.prank(user);
        Minimal7702Wallet(user).execute(actionHub, msgValue, _tipCalldata(token, amount));
    }

    function _tipCalldata(address token, uint256 amount) internal view returns (bytes memory) {
        KeyValue[] memory params = _toKeyValueArray(
            KeyValue({key: PARAM__TIP_AMOUNT, value: abi.encode(amount)}),
            KeyValue({key: PARAM__TIP_TOKEN, value: abi.encode(token)})
        );
        return abi.encodeCall(ActionHub.executeAccountAction, (tippingAccountAction, recipient, params));
    }

    function _assertTipReceived(address token, uint256 amount) internal view {
        uint256 received = token == NATIVE_TOKEN ? recipient.balance : IERC20(token).balanceOf(recipient);
        assertEq(received, amount - amount * TREASURY_FEE_BPS / BPS_MAX);
    }
}
