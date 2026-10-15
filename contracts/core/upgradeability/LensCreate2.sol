// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.26;

import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "contracts/core/access/Ownable.sol";
import {Errors} from "contracts/core/types/Errors.sol";
import {Initializable} from "contracts/core/upgradeability/Initializable.sol";

// If using the [0] nonce of 0xfe4Ad59637Cab6A5AbAEe896D3d01dA67f418e76 deployer:
address constant LENS_CREATE_2_ADDRESS = 0x52AF9CF29976C310E3DE03C509E108edB6edb8c0;

// EVM chains (e.g. Monad) derive CREATE addresses differently than ZKsync, so LensCreate2 lives at another address there.
// TODO: PLACEHOLDER deployer, nobody holds its key. Replace it with the deployer owning the EVM deployments, and replace
// LENS_CREATE_2_EVM_ADDRESS with its [0] nonce CREATE address (`cast compute-address <deployer> --nonce 0`).
address constant LENS_CREATE_2_EVM_DEPLOYER = 0x000000000000000000000000000000000000dEaD;
// If using the [0] nonce of LENS_CREATE_2_EVM_DEPLOYER:
address constant LENS_CREATE_2_EVM_ADDRESS = 0x9B137463d4E7986D7f535f9B79e28b4EF1938E9b;

// No EVM deployer can reach the ZKsync-derived address (it would take a hash preimage), so code there means ZKsync.
function lensCreate2Address() view returns (address) {
    return LENS_CREATE_2_ADDRESS.code.length != 0 ? LENS_CREATE_2_ADDRESS : LENS_CREATE_2_EVM_ADDRESS;
}

interface ILensCreate2 {
    function getAddress(bytes32 salt) external view returns (address);

    function createTransparentUpgradeableProxy(
        bytes32 salt,
        address implementation,
        address proxyAdmin,
        bytes calldata initializerCall,
        address expectedAddress
    ) external returns (address);
}

contract LensCreate2 is ILensCreate2, Initializable, Ownable {
    bytes32 public immutable PROXY_BYTECODE_HASH;
    bytes32 public immutable SENDER_BYTES;
    bytes32 public immutable CREATE2_PREFIX;
    bytes32 public immutable CONSTRUCTOR_ARGS_HASH;
    bool internal immutable IS_ZKSYNC;

    constructor() {
        address lensCreate2 = lensCreate2Address();
        bool isZkSync = lensCreate2 == LENS_CREATE_2_ADDRESS;
        bytes memory constructorArgs = abi.encode(lensCreate2, lensCreate2, "");
        bytes32 bytecodeHash;
        if (isZkSync) {
            // ZKsync: keccak256(keccak256("zksyncCreate2") ++ sender ++ salt ++ bytecodeHash ++ constructorArgsHash)
            address proxy = address(new TransparentUpgradeableProxy(lensCreate2, lensCreate2, ""));
            assembly {
                bytecodeHash := extcodehash(proxy)
            }
        } else {
            // EVM: keccak256(0xff ++ sender ++ salt ++ keccak256(initCode)), where initCode includes the constructor args
            bytecodeHash = keccak256(bytes.concat(type(TransparentUpgradeableProxy).creationCode, constructorArgs));
        }
        IS_ZKSYNC = isZkSync;
        PROXY_BYTECODE_HASH = bytecodeHash;
        CREATE2_PREFIX = isZkSync ? keccak256("zksyncCreate2") : bytes32(bytes1(0xff));
        SENDER_BYTES = bytes32(uint256(uint160(lensCreate2)));
        CONSTRUCTOR_ARGS_HASH = keccak256(constructorArgs);
        _disableInitializers();
    }

    function initialize(address owner) external initializer {
        _transferOwnership(owner);
    }

    function getAddress(bytes32 salt) external view override returns (address) {
        bytes memory create2Preimage = IS_ZKSYNC
            ? bytes.concat(CREATE2_PREFIX, SENDER_BYTES, salt, PROXY_BYTECODE_HASH, CONSTRUCTOR_ARGS_HASH)
            : bytes.concat(bytes1(CREATE2_PREFIX), bytes20(uint160(uint256(SENDER_BYTES))), salt, PROXY_BYTECODE_HASH);
        return address(uint160(uint256(keccak256(create2Preimage))));
    }

    function createTransparentUpgradeableProxy(
        bytes32 salt,
        address implementation,
        address proxyAdmin,
        bytes calldata initializerCall,
        address expectedAddress
    ) external override onlyOwner returns (address) {
        // Starts pointing to, and administered by, this LensCreate2 proxy, so the address only depends on the salt.
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(
            address(new TransparentUpgradeableProxy{salt: salt}(address(this), address(this), ""))
        );
        require(expectedAddress == address(0) || expectedAddress == address(proxy), Errors.UnexpectedValue());
        if (initializerCall.length > 0) {
            proxy.upgradeToAndCall(implementation, initializerCall);
        } else {
            proxy.upgradeTo(implementation);
        }
        proxy.changeAdmin(proxyAdmin);
        return address(proxy);
    }
}
