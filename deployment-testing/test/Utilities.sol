// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/EntryPoint.sol";
import "../src/SimpleAccount.sol";
import "../src/SimpleAccountFactory.sol";

contract Utilities is Test {
    bytes internal constant defaultBytes = bytes("");
    UserOperation internal defaultOp = UserOperation({
        sender: 0x0000000000000000000000000000000000000000,
        nonce: 0,
        initCode: defaultBytes,
        callData: defaultBytes,
        callGasLimit: 200000,
        verificationGasLimit: 100000,
        preVerificationGas: 21000,
        maxFeePerGas: 3000000000,
        maxPriorityFeePerGas: 1,
        paymasterAndData: defaultBytes,
        signature: defaultBytes
    });

    function createAddress(string memory _name) public returns (Account memory) {
        return makeAccount(_name);
    }

    function fillAndSign(UserOperation memory op, Account memory accountOwner, EntryPoint entryPoint, uint256 chainId)
        public
        pure
        returns (UserOperation memory)
    {
        bytes32 userOpHash = keccak256(
            abi.encode(
                op.sender,
                op.nonce,
                op.initCode,
                op.callData,
                op.callGasLimit,
                op.verificationGasLimit,
                op.preVerificationGas,
                op.maxFeePerGas,
                op.maxPriorityFeePerGas,
                op.paymasterAndData
            )
        );

        bytes memory encoded = abi.encode(userOpHash, entryPoint, chainId);
        bytes32 message = bytes32(keccak256(encoded));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountOwner.key, digest);
        op.signature = abi.encodePacked(r, s, v);

        return op;
    }

    function packUserOp(UserOperation memory op) internal pure returns (bytes memory) {
        return abi.encode(
            op.sender,
            op.nonce,
            op.initCode,
            op.callData,
            op.callGasLimit,
            op.verificationGasLimit,
            op.preVerificationGas,
            op.maxFeePerGas,
            op.maxPriorityFeePerGas,
            op.paymasterAndData
        );
    }

    function getUserOpHash(UserOperation memory op, address _entryPoint, uint256 _chainId)
        internal
        pure
        returns (bytes32)
    {
        bytes32 userOpHash = keccak256(packUserOp(op, true));
        bytes memory encoded = abi.encode(userOpHash, _entryPoint, _chainId);
        return bytes32(keccak256(encoded));
    }

    function signUserOp(UserOperation memory op, address _entryPoint, uint256 _chainId)
        internal
        view
        returns (UserOperation memory)
    {
        bytes32 message = getUserOpHash(op, _entryPoint, _chainId);
        op.signature = signMessage(message, _accountKey);
        return op;
    }

    function signMessage(bytes32 message, uint256 privateKey) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", message));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function getAccountInitCode(address accountOwner, SimpleAccountFactory simpleAccountFactory, uint256 salt)
        public
        pure
        returns (bytes memory)
    {
        return hexConcat(
            abi.encodePacked(address(simpleAccountFactory)),
            abi.encodeWithSignature("createAccount(address,uint256)", accountOwner, salt)
        );
    }

    function getAccountAddress(address accountOwner, SimpleAccountFactory simpleAccountFactory, uint256 salt)
        public
        view
        returns (address)
    {
        return simpleAccountFactory.getAddress(accountOwner, salt);
    }

    function getBalance(address account) internal view returns (uint256) {
        return account.balance;
    }

    function isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }

    function hexConcat(bytes memory _a, bytes memory _b) public pure returns (bytes memory) {
        bytes memory combined = new bytes(_a.length + _b.length);
        uint256 i;
        uint256 j;

        for (i = 0; i < _a.length; i++) {
            combined[j++] = _a[i];
        }

        for (i = 0; i < _b.length; i++) {
            combined[j++] = _b[i];
        }

        return combined;
    }

    function getDataFromEncoding(bytes memory encoding) public pure returns (bytes memory data) {
        assembly {
            let totalLength := mload(encoding)
            let targetLength := sub(totalLength, 4)
            data := mload(0x40)

            mstore(data, targetLength)
            mstore(0x40, add(data, add(0x20, targetLength)))
            mstore(add(data, 0x20), shl(0x20, mload(add(encoding, 0x20))))

            for { let i := 0x1C } lt(i, targetLength) { i := add(i, 0x20) } {
                mstore(add(add(data, 0x20), i), mload(add(add(encoding, 0x20), add(i, 0x04))))
            }
        }
    }
}
