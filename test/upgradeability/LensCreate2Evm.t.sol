// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {
    LENS_CREATE_2_EVM_ADDRESS,
    LENS_CREATE_2_EVM_DEPLOYER,
    LensCreate2,
    lensCreate2Address
} from "@core/upgradeability/LensCreate2.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ActionHub} from "@extensions/actions/ActionHub.sol";
import {LensFees} from "@extensions/fees/LensFees.sol";
import {LensNativePaymentHelper, PayableUsingNativePaymentHelper} from "@extensions/fees/LensNativePaymentHelper.sol";
import {LensPaymentHandler} from "@extensions/fees/LensPaymentHandler.sol";
import {LensRulePaymentHandler} from "@extensions/fees/LensRulePaymentHandler.sol";
import {CONTRACT__LENS_FEES, CONTRACT__LENS_NATIVE_PAYMENT_HELPER, NATIVE_TOKEN} from "@core/types/Constants.sol";
import {Errors} from "@core/types/Errors.sol";
import {ZkTest} from "test/helpers/ZkTest.sol";

contract LensCreate2EvmTest is ZkTest {
    // bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1)
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    LensCreate2 create2;
    address IMPLEMENTATION;
    address PROXY_ADMIN = makeAddr("PROXY_ADMIN");

    address lensCreate2ProxyAdmin = makeAddr("LENS_CREATE_2_PROXY_ADMIN");
    address lensCreate2Owner = makeAddr("LENS_CREATE_2_OWNER");

    function setUp() public virtual onlyEvm nonFork {
        // Same bootstrap as on a live EVM chain: the first transaction (nonce 0) of the deployer creates the proxy.
        address create2Impl = address(new LensCreate2());
        vm.prank(LENS_CREATE_2_EVM_DEPLOYER);
        address lensCreate2Proxy = address(
            new TransparentUpgradeableProxy(
                create2Impl, lensCreate2ProxyAdmin, abi.encodeCall(LensCreate2.initialize, (lensCreate2Owner))
            )
        );
        assertEq(lensCreate2Proxy, LENS_CREATE_2_EVM_ADDRESS);
        create2 = LensCreate2(lensCreate2Proxy);

        IMPLEMENTATION = address(new ActionHub());
    }

    function test_EvmAddressIsFirstCreateAddressOfEvmDeployer() public pure {
        assertEq(vm.computeCreateAddress(LENS_CREATE_2_EVM_DEPLOYER, 0), LENS_CREATE_2_EVM_ADDRESS);
    }

    function test_LensCreate2AddressResolvesToEvmAddress() public view {
        assertEq(lensCreate2Address(), LENS_CREATE_2_EVM_ADDRESS);
    }

    function test_GetAddress_UsesStandardCreate2Derivation(bytes32 salt) public view {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(LENS_CREATE_2_EVM_ADDRESS, LENS_CREATE_2_EVM_ADDRESS, "")
            )
        );
        assertEq(create2.PROXY_BYTECODE_HASH(), initCodeHash);
        assertEq(create2.getAddress(salt), vm.computeCreate2Address(salt, initCodeHash, LENS_CREATE_2_EVM_ADDRESS));
    }

    function test_CreatesProxyAtExpectedAddress(bytes32 salt, address proxyAdmin) public {
        vm.assume(proxyAdmin != address(0));
        address expectedAddress = create2.getAddress(salt);
        assertEq(expectedAddress.code.length, 0);

        vm.prank(lensCreate2Owner);
        address deployedContract = create2.createTransparentUpgradeableProxy({
            salt: salt,
            implementation: IMPLEMENTATION,
            proxyAdmin: proxyAdmin,
            initializerCall: "",
            expectedAddress: expectedAddress
        });

        assertEq(deployedContract, expectedAddress);
        assertEq(address(uint160(uint256(vm.load(deployedContract, IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
        assertEq(address(uint160(uint256(vm.load(deployedContract, ADMIN_SLOT)))), proxyAdmin);
    }

    function test_CreatesProxyAtExpectedAddress_WithInitializerCall(bytes32 salt, address initializeWith) public {
        address initializableImpl = address(new InitializableImplementation());
        address expectedAddress = create2.getAddress(salt);
        vm.prank(lensCreate2Owner);
        address deployedContract = create2.createTransparentUpgradeableProxy({
            salt: salt,
            implementation: initializableImpl,
            proxyAdmin: PROXY_ADMIN,
            initializerCall: abi.encodeCall(InitializableImplementation.initialize, (initializeWith)),
            expectedAddress: expectedAddress
        });

        assertEq(deployedContract, expectedAddress);

        assertEq(InitializableImplementation(deployedContract).initializedWith(), initializeWith);
    }

    function test_CannotCreateTwiceWithSameSalt(bytes32 salt) public {
        vm.prank(lensCreate2Owner);
        create2.createTransparentUpgradeableProxy(salt, IMPLEMENTATION, PROXY_ADMIN, "", address(0));

        vm.expectRevert();
        vm.prank(lensCreate2Owner);
        create2.createTransparentUpgradeableProxy(salt, IMPLEMENTATION, PROXY_ADMIN, "", address(0));
    }

    function test_CannotCreate_IfExpectedAddressDoesNotMatch(bytes32 salt, address expectedAddress) public {
        vm.assume(expectedAddress != address(0));
        vm.assume(expectedAddress != create2.getAddress(salt));

        vm.expectRevert(Errors.UnexpectedValue.selector);
        vm.prank(lensCreate2Owner);
        create2.createTransparentUpgradeableProxy(salt, IMPLEMENTATION, PROXY_ADMIN, "", expectedAddress);
    }

    function test_CannotCreate_IfNotOwner(address notOwner) public {
        vm.assume(notOwner != lensCreate2Owner);

        vm.expectRevert();
        vm.prank(notOwner);
        create2.createTransparentUpgradeableProxy(bytes32(0), IMPLEMENTATION, PROXY_ADMIN, "", address(0));
    }

    function test_PaymentContractsResolveAddressesThroughLensCreate2() public {
        address lensFees = _createProxy(CONTRACT__LENS_FEES, address(new LensFees(makeAddr("TREASURY"), 150)));
        address payable nativePaymentHelper =
            payable(_createProxy(CONTRACT__LENS_NATIVE_PAYMENT_HELPER, address(new LensNativePaymentHelper())));

        assertEq(new LensPaymentHandlerHarness().lensFees(), lensFees);

        PayableUsingNativePaymentHelperHarness payableHarness = new PayableUsingNativePaymentHelperHarness();
        assertEq(payableHarness.nativePaymentHelper(), nativePaymentHelper);
        vm.deal(address(this), 1 ether);
        payableHarness.pay{value: 1 ether}();
        assertEq(nativePaymentHelper.balance, 1 ether);

        // LensRulePaymentHandler keeps its helper private, so check it is wired by spending the helper's funds.
        address recipient = makeAddr("RECIPIENT");
        new LensRulePaymentHandlerHarness().sendNative(recipient, 1 ether);
        assertEq(recipient.balance, 1 ether);
        assertEq(nativePaymentHelper.balance, 0);
    }

    function _createProxy(bytes32 salt, address implementation) internal returns (address) {
        address expectedAddress = create2.getAddress(salt);
        vm.prank(lensCreate2Owner);
        return create2.createTransparentUpgradeableProxy(salt, implementation, PROXY_ADMIN, "", expectedAddress);
    }
}

contract InitializableImplementation {
    address public initializedWith;

    function initialize(address value) external {
        initializedWith = value;
    }
}

contract LensPaymentHandlerHarness is LensPaymentHandler {
    function lensFees() external view returns (address) {
        return LENS_FEES;
    }
}

contract PayableUsingNativePaymentHelperHarness is PayableUsingNativePaymentHelper {
    function nativePaymentHelper() external view returns (address) {
        return address(LENS_NATIVE_PAYMENT_HELPER);
    }

    function pay() external payable usingNativePaymentHelper {}
}

contract LensRulePaymentHandlerHarness is LensRulePaymentHandler {
    function sendNative(address recipient, uint256 amount) external {
        _sendToken(NATIVE_TOKEN, address(0), recipient, amount);
    }
}
