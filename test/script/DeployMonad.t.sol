// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../helpers/TypeHelpers.sol";
import {DeployMonad} from "script/DeployMonad.s.sol";
import {ZkTest} from "test/helpers/ZkTest.sol";
import {LENS_CREATE_2_EVM_ADDRESS, LensCreate2, lensCreate2Address} from "@core/upgradeability/LensCreate2.sol";
import {CONTRACT__LENS_NATIVE_PAYMENT_HELPER, NATIVE_TOKEN} from "@core/types/Constants.sol";
import {IFeed, CreatePostParams} from "@core/interfaces/IFeed.sol";
import {IGraph} from "@core/interfaces/IGraph.sol";
import {IAccount} from "@extensions/account/IAccount.sol";
import {ActionHub} from "@extensions/actions/ActionHub.sol";
import {LensNativePaymentHelper} from "@extensions/fees/LensNativePaymentHelper.sol";

/// @custom:keccak lens.param.amount
bytes32 constant PARAM__TIP_AMOUNT = 0xc8a06abcb0f2366f32dc2741bdf075c3215e3108918311ec0ac742f1ffd37f49;
/// @custom:keccak lens.param.token
bytes32 constant PARAM__TIP_TOKEN = 0xee737c77be2981e91c179485406e6d793521b20aca5e2137b6c497949a74bc94;

// Runs the Monad deployment script and uses the deployed protocol. Run with: forge test --network monad
contract DeployMonadTest is ZkTest {
    DeployMonad deployment;
    LensCreate2 lensCreate2 = LensCreate2(LENS_CREATE_2_EVM_ADDRESS);

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");
    IAccount aliceAccount;
    IAccount bobAccount;

    address feed;
    address graph;
    address actionHub;
    address tippingAccountAction;
    address payable nativePaymentHelper;

    function setUp() public onlyEvm nonFork {
        deployment = new DeployMonad();
        deployment.run();

        aliceAccount = _createAccount(alice);
        bobAccount = _createAccount(bob);
        feed = deployment.lensGlobalFeed();
        graph = deployment.lensGlobalGraph();
        actionHub = deployment.actionHub();
        tippingAccountAction = _lensCreate2Address("TippingAccountAction");
        nativePaymentHelper = payable(lensCreate2.getAddress(CONTRACT__LENS_NATIVE_PAYMENT_HELPER));
    }

    function test_DeploysLensCreate2AndItsContracts() public view {
        assertEq(lensCreate2Address(), LENS_CREATE_2_EVM_ADDRESS);
        assertEq(lensCreate2.owner(), address(this)); // The deployer

        string[5] memory names =
            ["LensFees", "LensNativePaymentHelper", "ActionHub", "LensFactory", "TippingAccountAction"];
        for (uint256 i = 0; i < names.length; i++) {
            address deployed = lensCreate2.getAddress(keccak256(bytes(string.concat("lens.contract.", names[i]))));
            assertGt(deployed.code.length, 0, names[i]);
        }
        assertEq(actionHub, _lensCreate2Address("ActionHub"));
        assertEq(address(deployment.lensFactory()), _lensCreate2Address("LensFactory"));
    }

    function test_PostFollowAndTipInMon() public {
        vm.prank(alice);
        bytes memory returnData = aliceAccount.executeTransaction(feed, 0, _createPostCalldata(aliceAccount));
        assertEq(IFeed(feed).getPostAuthor(abi.decode(returnData, (uint256))), address(aliceAccount));

        // MON sent along with a primitive call goes to the LensNativePaymentHelper resolved through LensCreate2.
        vm.deal(address(bobAccount), 0.5 ether);
        vm.prank(bob);
        bobAccount.executeTransaction(graph, 0.5 ether, _followCalldata(bobAccount, aliceAccount));
        assertTrue(IGraph(graph).isFollowing(address(bobAccount), address(aliceAccount)));
        assertEq(nativePaymentHelper.balance, 0.5 ether);
        LensNativePaymentHelper(nativePaymentHelper).refundNative(address(bobAccount));
        assertEq(address(bobAccount).balance, 0.5 ether);

        KeyValue[] memory tipParams = _toKeyValueArray(
            KeyValue({key: PARAM__TIP_AMOUNT, value: abi.encode(1 ether)}),
            KeyValue({key: PARAM__TIP_TOKEN, value: abi.encode(NATIVE_TOKEN)})
        );
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        ActionHub(actionHub).executeAccountAction{value: 1 ether}(tippingAccountAction, address(aliceAccount), tipParams);
        assertEq(address(aliceAccount).balance, 1 ether); // Local deployments default to a 0 bps treasury fee
    }

    function _createAccount(address owner) internal returns (IAccount) {
        return IAccount(
            payable(deployment.lensFactory().deployAccount({
                    metadataURI: "uri://account-metadata",
                    owner: owner,
                    accountManagers: _emptyAddressArray(),
                    accountManagersPermissions: _emptyAccountManagerPermissionsArray(),
                    sourceStamp: _emptySourceStamp(),
                    extraData: _emptyKeyValueArray()
                }))
        );
    }

    function _createPostCalldata(IAccount author) internal pure returns (bytes memory) {
        CreatePostParams memory postParams = CreatePostParams({
            author: address(author),
            contentURI: "uri://gmonad",
            repostedPostId: 0,
            quotedPostId: 0,
            repliedPostId: 0,
            ruleChanges: _emptyRuleChangeArray(),
            extraData: _emptyKeyValueArray()
        });
        return abi.encodeCall(
            IFeed.createPost,
            (
                postParams,
                _emptyKeyValueArray(),
                _emptyRuleProcessingParamsArray(),
                _emptyRuleProcessingParamsArray(),
                _emptyRuleProcessingParamsArray()
            )
        );
    }

    function _followCalldata(IAccount follower, IAccount followed) internal pure returns (bytes memory) {
        return abi.encodeCall(
            IGraph.follow,
            (
                address(follower),
                address(followed),
                _emptyKeyValueArray(),
                _emptyRuleProcessingParamsArray(),
                _emptyRuleProcessingParamsArray(),
                _emptyKeyValueArray()
            )
        );
    }

    function _lensCreate2Address(string memory name) internal view returns (address) {
        return lensCreate2.getAddress(keccak256(bytes(string.concat("lens.contract.", name))));
    }
}
