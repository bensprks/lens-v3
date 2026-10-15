// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {NATIVE_TOKEN, BPS_MAX} from "contracts/core/types/Constants.sol";
import {RuleChange, KeyValue} from "contracts/core/types/Types.sol";
import {Beacon} from "contracts/core/upgradeability/Beacon.sol";
import {Lock} from "contracts/core/upgradeability/Lock.sol";
import {
    LensCreate2,
    LENS_CREATE_2_EVM_ADDRESS,
    LENS_CREATE_2_EVM_DEPLOYER
} from "contracts/core/upgradeability/LensCreate2.sol";

import {Feed} from "contracts/core/primitives/feed/Feed.sol";
import {Graph} from "contracts/core/primitives/graph/Graph.sol";
import {Group} from "contracts/core/primitives/group/Group.sol";
import {Namespace} from "contracts/core/primitives/namespace/Namespace.sol";
import {Account as LensAccount} from "contracts/extensions/account/Account.sol";
import {ActionHub} from "contracts/extensions/actions/ActionHub.sol";
import {LensFees} from "contracts/extensions/fees/LensFees.sol";
import {LensNativePaymentHelper} from "contracts/extensions/fees/LensNativePaymentHelper.sol";
import {App} from "contracts/extensions/primitives/app/App.sol";

import {AccessControlFactory} from "contracts/extensions/factories/AccessControlFactory.sol";
import {AccountFactory} from "contracts/extensions/factories/AccountFactory.sol";
import {AppFactory} from "contracts/extensions/factories/AppFactory.sol";
import {FeedFactory} from "contracts/extensions/factories/FeedFactory.sol";
import {GraphFactory} from "contracts/extensions/factories/GraphFactory.sol";
import {GroupFactory} from "contracts/extensions/factories/GroupFactory.sol";
import {NamespaceFactory} from "contracts/extensions/factories/NamespaceFactory.sol";
import {
    LensFactory,
    FactoryConstructorParams,
    RuleConstructorParams
} from "contracts/extensions/factories/LensFactory.sol";

import {AccountBlockingRule} from "contracts/rules/AccountBlockingRule.sol";
import {GroupGatedFeedRule} from "contracts/rules/feed/GroupGatedFeedRule.sol";
import {SimplePaymentFeedRule} from "contracts/rules/feed/SimplePaymentFeedRule.sol";
import {TokenGatedFeedRule} from "contracts/rules/feed/TokenGatedFeedRule.sol";
import {SimplePaymentFollowRule} from "contracts/rules/follow/SimplePaymentFollowRule.sol";
import {TokenGatedFollowRule} from "contracts/rules/follow/TokenGatedFollowRule.sol";
import {GroupGatedGraphRule} from "contracts/rules/graph/GroupGatedGraphRule.sol";
import {TokenGatedGraphRule} from "contracts/rules/graph/TokenGatedGraphRule.sol";
import {AdditionRemovalPidGroupRule} from "contracts/rules/group/AdditionRemovalPidGroupRule.sol";
import {BanMemberGroupRule} from "contracts/rules/group/BanMemberGroupRule.sol";
import {MembershipApprovalGroupRule} from "contracts/rules/group/MembershipApprovalGroupRule.sol";
import {SimplePaymentGroupRule} from "contracts/rules/group/SimplePaymentGroupRule.sol";
import {TokenGatedGroupRule} from "contracts/rules/group/TokenGatedGroupRule.sol";
import {TokenGatedNamespaceRule} from "contracts/rules/namespace/TokenGatedNamespaceRule.sol";
import {UsernameLengthNamespaceRule} from "contracts/rules/namespace/UsernameLengthNamespaceRule.sol";
import {UsernamePricePerLengthNamespaceRule} from "contracts/rules/namespace/UsernamePricePerLengthNamespaceRule.sol";
import {UsernameReservedNamespaceRule} from "contracts/rules/namespace/UsernameReservedNamespaceRule.sol";
import {UsernameSimpleCharsetNamespaceRule} from "contracts/rules/namespace/UsernameSimpleCharsetNamespaceRule.sol";
import {FollowersOnlyPostRule} from "contracts/rules/post/FollowersOnlyPostRule.sol";

import {TippingAccountAction} from "contracts/actions/account/TippingAccountAction.sol";
import {SimpleCollectAction} from "contracts/actions/post/collect/SimpleCollectAction.sol";
import {TippingPostAction} from "contracts/actions/post/TippingPostAction.sol";

import {MockWrapperCurrency} from "test/mocks/MockWrapperCurrency.sol";

/**
 * @notice Deploys the whole Lens protocol on Monad (or any other EVM chain), with MON as the native token.
 *
 * Always run it with the `monad` profile (implies `--network monad`), as the LensCreate2 addresses depend on the
 * compiler settings.
 *
 * Local Monad node:
 *   anvil --network monad --auto-impersonate
 *   FOUNDRY_PROFILE=monad forge script script/DeployMonad.s.sol --rpc-url http://127.0.0.1:8545 \
 *     --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast
 *
 * Monad testnet (10143) / mainnet (143), see MONAD.md for the required env vars and the LensCreate2 deployer:
 *   FOUNDRY_PROFILE=monad forge script script/DeployMonad.s.sol --rpc-url monad_testnet \
 *     --account <deployer> --account <lensCreate2Deployer> --sender <deployerAddress> --broadcast --slow
 */
contract DeployMonad is Script {
    uint256 constant LOCAL_CHAIN_ID = 31337;
    uint256 constant MONAD_MAINNET_CHAIN_ID = 143;
    uint256 constant MONAD_TESTNET_CHAIN_ID = 10143;

    address constant WMON_MAINNET = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address constant WMON_TESTNET = 0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541;

    address constant PLACEHOLDER_LENS_CREATE_2_EVM_DEPLOYER = 0x000000000000000000000000000000000000dEaD;
    // Anvil's second default account. Proxy admins cannot call through their proxies, so it can't be the deployer.
    address constant LOCAL_PROXY_ADMIN = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    LensCreate2 constant LENS_CREATE_2 = LensCreate2(LENS_CREATE_2_EVM_ADDRESS);

    struct Config {
        address lensCreate2ProxyAdmin;
        address proxyAdminLockOwner;
        address accessControlLockOwner;
        address beaconOwner;
        address factoriesProxyOwner;
        address rulesProxyOwner;
        address rulesOwner;
        address actionsOwner;
        address primitivesOwner;
        address treasury;
        uint256 treasuryFeeBps;
        address wrappedNativeToken;
    }

    Config config;
    address deployer;

    address appLock;
    address accountLock;
    address feedLock;
    address graphLock;
    address groupLock;
    address namespaceLock;
    address accessControlLock;

    address appBeacon;
    address accountBeacon;
    address feedBeacon;
    address graphBeacon;
    address groupBeacon;
    address namespaceBeacon;

    address public actionHub;
    LensFactory public lensFactory;
    address public lensGlobalFeed;
    address public lensGlobalGraph;

    function run() external {
        deployer = msg.sender;
        if (block.chainid == MONAD_MAINNET_CHAIN_ID || block.chainid == MONAD_TESTNET_CHAIN_ID) {
            require(
                LENS_CREATE_2_EVM_DEPLOYER != PLACEHOLDER_LENS_CREATE_2_EVM_DEPLOYER,
                "LENS_CREATE_2_EVM_DEPLOYER is still the placeholder, see MONAD.md"
            );
        }
        _loadConfig();

        _deployLensCreate2();

        vm.startBroadcast(deployer);
        _deployFeesAndActionHub();
        _deployLocks();
        _deployImplementationsAndBeacons();
        _deployFactories();
        _deployRules();
        _deployActions();
        _deployGlobalPrimitives();
        vm.stopBroadcast();
    }

    function _loadConfig() internal {
        bool isLocal = block.chainid == LOCAL_CHAIN_ID;
        config = Config({
            lensCreate2ProxyAdmin: _envAddress("LENS_CREATE_2_PROXY_ADMIN", LOCAL_PROXY_ADMIN, isLocal),
            proxyAdminLockOwner: _envAddress("PROXY_ADMIN_LOCK_OWNER", deployer, isLocal),
            accessControlLockOwner: _envAddress("ACCESS_CONTROL_LOCK_OWNER", deployer, isLocal),
            beaconOwner: _envAddress("BEACON_OWNER", deployer, isLocal),
            factoriesProxyOwner: _envAddress("FACTORIES_PROXY_OWNER", LOCAL_PROXY_ADMIN, isLocal),
            rulesProxyOwner: _envAddress("RULES_PROXY_OWNER", LOCAL_PROXY_ADMIN, isLocal),
            rulesOwner: _envAddress("RULES_OWNER", deployer, isLocal),
            actionsOwner: _envAddress("ACTIONS_OWNER", deployer, isLocal),
            primitivesOwner: _envAddress("PRIMITIVES_OWNER", deployer, isLocal),
            treasury: _envAddress("TREASURY_ADDRESS", deployer, isLocal),
            treasuryFeeBps: isLocal ? vm.envOr("TREASURY_FEE_BPS", uint256(0)) : vm.envUint("TREASURY_FEE_BPS"),
            wrappedNativeToken: vm.envOr("WRAPPED_NATIVE_TOKEN", address(0))
        });
        if (config.wrappedNativeToken == address(0)) {
            config.wrappedNativeToken = _defaultWrappedNativeToken();
        }
        _validateConfig(config);
    }

    function _validateConfig(Config memory configToValidate) internal view {
        require(configToValidate.lensCreate2ProxyAdmin != deployer, "LENS_CREATE_2_PROXY_ADMIN cannot be the deployer");
        require(configToValidate.factoriesProxyOwner != deployer, "FACTORIES_PROXY_OWNER cannot be the deployer");
        // Ownable allows a zero owner, which would leave the locks, beacons, rules, actions or primitives unmanageable.
        _requireNonZero(configToValidate.proxyAdminLockOwner, "PROXY_ADMIN_LOCK_OWNER");
        _requireNonZero(configToValidate.accessControlLockOwner, "ACCESS_CONTROL_LOCK_OWNER");
        _requireNonZero(configToValidate.beaconOwner, "BEACON_OWNER");
        _requireNonZero(configToValidate.rulesOwner, "RULES_OWNER");
        _requireNonZero(configToValidate.actionsOwner, "ACTIONS_OWNER");
        _requireNonZero(configToValidate.primitivesOwner, "PRIMITIVES_OWNER");
        // Checked before narrowing it to LensFees' uint16. Payments deduct the fee even if the treasury is zero.
        require(configToValidate.treasuryFeeBps <= BPS_MAX, "TREASURY_FEE_BPS cannot exceed 10000");
        require(
            configToValidate.treasuryFeeBps == 0 || configToValidate.treasury != address(0),
            "TREASURY_ADDRESS cannot be zero when charging a fee"
        );
    }

    function _requireNonZero(address account, string memory name) internal pure {
        require(account != address(0), string.concat(name, " cannot be the zero address"));
    }

    function _envAddress(string memory name, address localDefault, bool isLocal) internal view returns (address) {
        return isLocal ? vm.envOr(name, localDefault) : vm.envAddress(name);
    }

    // MON is the native token: Account tracks it under NATIVE_TOKEN and gets WMON as the wrapped native token.
    function _defaultWrappedNativeToken() internal returns (address) {
        if (block.chainid == MONAD_MAINNET_CHAIN_ID) {
            return WMON_MAINNET;
        } else if (block.chainid == MONAD_TESTNET_CHAIN_ID) {
            return WMON_TESTNET;
        }
        require(block.chainid == LOCAL_CHAIN_ID, "WRAPPED_NATIVE_TOKEN env var is required on this chain");
        vm.broadcast(deployer);
        return address(new MockWrapperCurrency("Wrapped MON", "WMON"));
    }

    // LensCreate2 has to be the first contract created by LENS_CREATE_2_EVM_DEPLOYER, as the other contracts resolve
    // LensFees and LensNativePaymentHelper through it at LENS_CREATE_2_EVM_ADDRESS when constructed.
    function _deployLensCreate2() internal {
        if (LENS_CREATE_2_EVM_ADDRESS.code.length != 0) {
            require(LENS_CREATE_2.owner() == deployer, "The deployer must own the existing LensCreate2");
            return;
        }
        require(vm.getNonce(LENS_CREATE_2_EVM_DEPLOYER) == 0, "LENS_CREATE_2_EVM_DEPLOYER already used its nonce 0");

        vm.startBroadcast(deployer);
        address lensCreate2Impl = address(new LensCreate2());
        // On Monad, accounts funded from a zero balance must wait k blocks before sending, so fund it beforehand there.
        if (block.chainid == LOCAL_CHAIN_ID && LENS_CREATE_2_EVM_DEPLOYER.balance == 0) {
            (bool funded,) = LENS_CREATE_2_EVM_DEPLOYER.call{value: 1 ether}("");
            require(funded, "Could not fund LENS_CREATE_2_EVM_DEPLOYER");
        }
        vm.stopBroadcast();

        vm.broadcast(LENS_CREATE_2_EVM_DEPLOYER);
        address lensCreate2 = address(
            new TransparentUpgradeableProxy(
                lensCreate2Impl, config.lensCreate2ProxyAdmin, abi.encodeCall(LensCreate2.initialize, (deployer))
            )
        );
        require(lensCreate2 == LENS_CREATE_2_EVM_ADDRESS, "LensCreate2 deployed at an unexpected address");
        console.log("LensCreate2:", lensCreate2);
    }

    function _deployFeesAndActionHub() internal {
        _create2(
            "LensFees", address(new LensFees(config.treasury, uint16(config.treasuryFeeBps))), config.factoriesProxyOwner
        );
        _create2("LensNativePaymentHelper", address(new LensNativePaymentHelper()), config.factoriesProxyOwner);
        actionHub = _create2("ActionHub", address(new ActionHub()), config.factoriesProxyOwner);
    }

    function _deployLocks() internal {
        appLock = address(new Lock(config.proxyAdminLockOwner, true));
        accountLock = address(new Lock(config.proxyAdminLockOwner, true));
        feedLock = address(new Lock(config.proxyAdminLockOwner, true));
        graphLock = address(new Lock(config.proxyAdminLockOwner, true));
        groupLock = address(new Lock(config.proxyAdminLockOwner, true));
        namespaceLock = address(new Lock(config.proxyAdminLockOwner, true));
        accessControlLock = address(new Lock(config.accessControlLockOwner, true));
    }

    function _deployImplementationsAndBeacons() internal {
        appBeacon = address(new Beacon(config.beaconOwner, 1, address(new App())));
        accountBeacon = address(
            new Beacon(
                config.beaconOwner,
                1,
                address(new LensAccount({nativeGHO: NATIVE_TOKEN, wrappedGHO: config.wrappedNativeToken}))
            )
        );
        feedBeacon = address(new Beacon(config.beaconOwner, 1, address(new Feed())));
        graphBeacon = address(new Beacon(config.beaconOwner, 1, address(new Graph())));
        groupBeacon = address(new Beacon(config.beaconOwner, 1, address(new Group())));
        namespaceBeacon = address(new Beacon(config.beaconOwner, 1, address(new Namespace())));
    }

    // LensFactory and the primitive factories depend on each other, so LensFactory goes last at its LensCreate2 address.
    function _deployFactories() internal {
        address expectedLensFactory = LENS_CREATE_2.getAddress(_salt("LensFactory"));

        FactoryConstructorParams memory factories;
        factories.accessControlFactory =
            AccessControlFactory(_proxy("AccessControlFactory", address(new AccessControlFactory(accessControlLock))));
        factories.accountFactory =
            AccountFactory(_proxy("AccountFactory", address(new AccountFactory(accountBeacon, accountLock))));
        factories.appFactory = AppFactory(_proxy("AppFactory", address(new AppFactory(appBeacon, appLock))));
        factories.feedFactory =
            FeedFactory(_proxy("FeedFactory", address(new FeedFactory(feedBeacon, feedLock, expectedLensFactory))));
        factories.graphFactory =
            GraphFactory(_proxy("GraphFactory", address(new GraphFactory(graphBeacon, graphLock, expectedLensFactory))));
        factories.groupFactory =
            GroupFactory(_proxy("GroupFactory", address(new GroupFactory(groupBeacon, groupLock, expectedLensFactory))));
        factories.namespaceFactory = NamespaceFactory(
            _proxy(
                "NamespaceFactory", address(new NamespaceFactory(namespaceBeacon, namespaceLock, expectedLensFactory))
            )
        );

        RuleConstructorParams memory rules;
        rules.accountBlockingRule = _deployRule("AccountBlockingRule", address(new AccountBlockingRule()));
        rules.groupGatedFeedRule = _deployRule("GroupGatedFeedRule", address(new GroupGatedFeedRule()));
        rules.usernameSimpleCharsetRule =
            _deployRule("UsernameSimpleCharsetNamespaceRule", address(new UsernameSimpleCharsetNamespaceRule()));
        rules.banMemberGroupRule = _deployRule("BanMemberGroupRule", address(new BanMemberGroupRule()));
        rules.addRemovePidGroupRule =
            _deployRule("AdditionRemovalPidGroupRule", address(new AdditionRemovalPidGroupRule()));
        rules.usernameReservedNamespaceRule =
            _deployRule("UsernameReservedNamespaceRule", address(new UsernameReservedNamespaceRule()));

        lensFactory =
            LensFactory(_create2("LensFactory", address(new LensFactory(factories, rules)), config.factoriesProxyOwner));
        require(address(lensFactory) == expectedLensFactory, "LensFactory deployed at an unexpected address");
    }

    function _deployRules() internal {
        _deployRule("SimplePaymentFeedRule", address(new SimplePaymentFeedRule()));
        _deployRule("TokenGatedFeedRule", address(new TokenGatedFeedRule()));
        _deployRule("FollowersOnlyPostRule", address(new FollowersOnlyPostRule()));
        _deployRule("GroupGatedGraphRule", address(new GroupGatedGraphRule()));
        _deployRule("TokenGatedGraphRule", address(new TokenGatedGraphRule()));
        _deployRule("SimplePaymentFollowRule", address(new SimplePaymentFollowRule()));
        _deployRule("TokenGatedFollowRule", address(new TokenGatedFollowRule()));
        _deployRule("MembershipApprovalGroupRule", address(new MembershipApprovalGroupRule()));
        _deployRule("SimplePaymentGroupRule", address(new SimplePaymentGroupRule()));
        _deployRule("TokenGatedGroupRule", address(new TokenGatedGroupRule()));
        _deployRule("UsernameLengthNamespaceRule", address(new UsernameLengthNamespaceRule()));
        _deployRule("TokenGatedNamespaceRule", address(new TokenGatedNamespaceRule()));
        _deployRule("UsernamePricePerLengthNamespaceRule", address(new UsernamePricePerLengthNamespaceRule()));
    }

    function _deployActions() internal {
        bytes memory initializerCall = abi.encodeWithSignature("initialize(address,string)", config.actionsOwner, "");
        _create2(
            "TippingAccountAction",
            address(new TippingAccountAction(actionHub)),
            config.factoriesProxyOwner,
            initializerCall
        );
        _create2(
            "TippingPostAction", address(new TippingPostAction(actionHub)), config.factoriesProxyOwner, initializerCall
        );
        _create2(
            "SimpleCollectAction",
            address(new SimpleCollectAction(actionHub)),
            config.factoriesProxyOwner,
            initializerCall
        );
    }

    // LensFactory reserves the "lens" namespace (see `_validateNamespaceStrings`), so the global one is not deployed here.
    function _deployGlobalPrimitives() internal {
        address[] memory admins = new address[](0);
        RuleChange[] memory rules = new RuleChange[](0);
        KeyValue[] memory extraData = new KeyValue[](0);
        lensGlobalFeed = lensFactory.deployFeed("", config.primitivesOwner, admins, rules, extraData);
        console.log("LensGlobalFeed:", lensGlobalFeed);
        lensGlobalGraph = lensFactory.deployGraph("", config.primitivesOwner, admins, rules, extraData);
        console.log("LensGlobalGraph:", lensGlobalGraph);
    }

    function _deployRule(string memory name, address implementation) internal returns (address) {
        return _create2(
            name,
            implementation,
            config.rulesProxyOwner,
            abi.encodeWithSignature("initialize(address,string)", config.rulesOwner, "")
        );
    }

    function _create2(string memory name, address implementation, address proxyAdmin) internal returns (address) {
        return _create2(name, implementation, proxyAdmin, "");
    }

    function _create2(string memory name, address implementation, address proxyAdmin, bytes memory initializerCall)
        internal
        returns (address)
    {
        bytes32 salt = _salt(name);
        address proxy = LENS_CREATE_2.createTransparentUpgradeableProxy(
            salt, implementation, proxyAdmin, initializerCall, LENS_CREATE_2.getAddress(salt)
        );
        console.log(string.concat(name, ":"), proxy);
        return proxy;
    }

    function _proxy(string memory name, address implementation) internal returns (address proxy) {
        proxy = address(new TransparentUpgradeableProxy(implementation, config.factoriesProxyOwner, ""));
        console.log(string.concat(name, ":"), proxy);
    }

    // Same salts as the Lens Chain deployment, e.g. keccak256("lens.contract.LensFees") == CONTRACT__LENS_FEES.
    function _salt(string memory name) internal pure returns (bytes32) {
        return keccak256(bytes(string.concat("lens.contract.", name)));
    }
}
