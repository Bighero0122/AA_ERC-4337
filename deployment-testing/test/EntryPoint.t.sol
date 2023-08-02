// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestHelper.sol";
import "../src/EntryPoint.sol";
import "../src/SimpleAccount.sol";
import "../src/SimpleAccountFactory.sol";
import "../src/test/TestWarmColdAccount.sol";
import "../src/test/TestPaymasterAcceptAll.sol";
import "../src/test/TestRevertAccount.sol";
import "../src/test/TestCounter.sol";

//Utils
import {Utilities} from "./Utilities.sol";

struct ReturnInfo {
    uint256 preOpGas;
    uint256 prefund;
    bool sigFailed;
    uint48 validAfter;
    uint48 validUntil;
    bytes paymasterContext;
}

struct StakeInfo {
    uint256 stake;
    uint256 unstakeDelaySec;
}

contract EntryPointTest is TestHelper {
    UserOperation[] internal ops;
    Utilities internal utils;

    function setUp() public {
        utils = new Utilities();
        accountOwner = utils.createAccountOwner("accountOwner");
        entryPoint = utils.deployEntryPoint(1234);
        entryPointAddress = address(entryPoint);
        (account, simpleAccountFactory) =
            utils.createAccountWithEntryPoint(accountOwner.addr, entryPoint, simpleAccountFactory);
        accountAddress = address(account);

        vm.deal(address(account), 1 ether);
    }

    // Stake Management testing
    // Should deposit for transfer into EntryPoint
    function test_Deposit(address signerAddress) public {
        entryPoint.depositTo{value: 1 ether}(signerAddress);

        assertEq(entryPoint.balanceOf(signerAddress), 1 ether);

        assertEq(entryPoint.getDepositInfo(signerAddress).deposit, 1 ether);
        assertEq(entryPoint.getDepositInfo(signerAddress).staked, false);
        assertEq(entryPoint.getDepositInfo(signerAddress).stake, 0);
        assertEq(entryPoint.getDepositInfo(signerAddress).unstakeDelaySec, 0);
        assertEq(entryPoint.getDepositInfo(signerAddress).withdrawTime, 0);
    }

    // Without stake
    // Should fail to stake without value
    function test_NoStakeSpecified(uint32 unstakeDelaySec) public {
        if (unstakeDelaySec > 0) {
            vm.expectRevert(bytes("no stake specified"));
            entryPoint.addStake(unstakeDelaySec);
        }
    }

    // Should fail to stake without delay
    function test_NoDelaySpecified() public {
        vm.expectRevert(bytes("must specify unstake delay"));
        entryPoint.addStake{value: 1 ether}(0);
    }

    // Should fail to unlock
    function test_NoStakeUnlock() public {
        vm.expectRevert(bytes("not staked"));
        entryPoint.unlockStake();
    }

    // With stake of 2 eth
    // Should report "staked" state
    function test_StakedState(address signerAddress) public {
        // add balance to temp address
        vm.deal(signerAddress, 3 ether);
        // set msg.sender to specific address
        vm.prank(signerAddress);
        entryPoint.addStake{value: 2 ether}(2);

        assertEq(entryPoint.getDepositInfo(signerAddress).deposit, 0);
        assertEq(entryPoint.getDepositInfo(signerAddress).staked, true);
        assertEq(entryPoint.getDepositInfo(signerAddress).stake, 2 ether);
        assertEq(entryPoint.getDepositInfo(signerAddress).unstakeDelaySec, 2);
        assertEq(entryPoint.getDepositInfo(signerAddress).withdrawTime, 0);
    }

    // With deposit
    // Should be able to withdraw
    function test_WithdrawDeposit() public {
        account.addDeposit{value: 1 ether}();

        assertEq(getAccountBalance(), 0);
        assertEq(account.getDeposit(), 1 ether);

        vm.prank(accountOwner.addr);
        account.withdrawDepositTo(payable(accountAddress), 1 ether);

        assertEq(getAccountBalance(), 1 ether);
        assertEq(account.getDeposit(), 0);
    }

    //simulationValidation
    /// @notice 1. Should fail if validateUserOp fails
    function test_FailureOnValidateOpFailure() public {
        UserOperation memory op;
        op.sender = address(account);
        op.nonce = 1234;
        op.callData = defaultBytes;
        op.initCode = defaultBytes;
        op.callGasLimit = 200000;
        op.verificationGasLimit = 100000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 3000000000;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        UserOperation memory op1 = utils.fillAndSign(op, accountOwner, entryPoint, chainId);
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA25 invalid account nonce"));
        entryPoint.simulateValidation(op1);
    }

    /// @notice 2. Should report signature failure without revert
    function test_reportSignatureFailureWithoutRevert() public {
        IEntryPoint.ReturnInfo memory returnInfo;
        SimpleAccount account1;
        Account memory accountOwner1 = utils.createAccountOwner("accountOwner1");
        (account1,) = utils.createAccountWithEntryPoint(accountOwner1.addr, entryPoint, simpleAccountFactory);

        UserOperation memory op;
        op.sender = address(account1);
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = defaultBytes;
        op.callGasLimit = 200000;
        op.verificationGasLimit = 100000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 0;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        UserOperation memory op1 = utils.fillAndSign(op, accountOwner, entryPoint, chainId);

        try entryPoint.simulateValidation(op1) {}
        catch (bytes memory revertReason) {
            bytes memory data = utils.getDataFromEncoding(revertReason);
            (returnInfo,,,) = abi.decode(
                data,
                (IEntryPoint.ReturnInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo)
            );
        }

        assertEq(returnInfo.sigFailed, true);
    }

    /// @notice  3. Should revert if wallet not deployed (and no initCode)
    function test_shouldRevertIfWalletNotDeployed() public {
        UserOperation memory op;
        op.sender = utils.createAccountOwner("randomAccount").addr;
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = defaultBytes;
        op.callGasLimit = 1000;
        op.verificationGasLimit = 100000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 0;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        UserOperation memory op1 = utils.fillAndSign(op, accountOwner, entryPoint, chainId);
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA20 account not deployed"));
        entryPoint.simulateValidation(op1);
    }

    /// @notice  4. Should revert on OOG if not enough verificationGas
    function test_shouldRevertIfNotEnoughGas() public {
        UserOperation memory op;
        op.sender = address(account);
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = defaultBytes;
        op.callGasLimit = 1000;
        op.verificationGasLimit = 1000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 0;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        UserOperation memory op1 = utils.fillAndSign(op, accountOwner, entryPoint, chainId);
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA23 reverted (or OOG)"));
        entryPoint.simulateValidation(op1);
    }

    /// @notice 5. Should succeed if validUserOp succeeds: TBD
    function test_shouldSucceedifUserOpSucceeds() public {
        IEntryPoint.ReturnInfo memory returnInfo;
        SimpleAccount account1;
        Account memory accountOwner1 = utils.createAccountOwner("accountOwner1");
        (account1,) = utils.createAccountWithEntryPoint(accountOwner1.addr, entryPoint, simpleAccountFactory);

        UserOperation memory op;
        op.sender = address(account1);
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = defaultBytes;
        op.callGasLimit = 0;
        op.verificationGasLimit = 150000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 1381937087;
        op.maxPriorityFeePerGas = 1000000000;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        vm.deal(address(account1), 1 ether);
        UserOperation memory op1 = utils.fillAndSign(op, accountOwner1, entryPoint, chainId);
        try entryPoint.simulateValidation(op1) {}
        catch (bytes memory revertReason) {
            bytes memory data = utils.getDataFromEncoding(revertReason);
            (returnInfo,,,) = abi.decode(
                data,
                (IEntryPoint.ReturnInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo)
            );
        }
    }

    /// @notice 6. Should return empty context if no Paymaster
    function test_shouldReturnEmptyContextIfNoPaymaster() public {
        IEntryPoint.ReturnInfo memory returnInfo;
        UserOperation memory op;
        op.sender = address(account);
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = defaultBytes;
        op.callGasLimit = 0;
        op.verificationGasLimit = 150000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 0;
        op.maxPriorityFeePerGas = 1000000000;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        UserOperation memory op1 = utils.fillAndSign(op, accountOwner, entryPoint, chainId);
        try entryPoint.simulateValidation(op1) {}
        catch (bytes memory revertReason) {
            bytes memory data = utils.getDataFromEncoding(revertReason);
            (returnInfo,,,) = abi.decode(
                data,
                (IEntryPoint.ReturnInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo)
            );
        }
        assertEq(returnInfo.paymasterContext, defaultBytes);
    }

    /// @notice 7. Should return stake of sender
    function test_shouldReturnSendersStake() public {
        IStakeManager.StakeInfo memory senderInfo;
        uint256 stakeValue = 123;
        uint32 unstakeDelay = 3;
        SimpleAccount account2;
        Account memory accountOwner2 = utils.createAccountOwner("accountOwner2");
        (account2,) = utils.createAccountWithEntryPoint(accountOwner2.addr, entryPoint, simpleAccountFactory);
        vm.deal(address(account2), 1 ether);
        vm.prank(address(accountOwner2.addr));
        account2.execute(address(entryPoint), stakeValue, abi.encodeWithSignature("addStake(uint32)", unstakeDelay));

        UserOperation memory op;
        op.sender = address(account2);
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = defaultBytes;
        op.callGasLimit = 200000;
        op.verificationGasLimit = 100000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 0;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        UserOperation memory op1 = utils.fillAndSign(op, accountOwner2, entryPoint, chainId);
        try entryPoint.simulateValidation(op1) {}
        catch (bytes memory revertReason) {
            bytes memory data = utils.getDataFromEncoding(revertReason);
            (, senderInfo,,) = abi.decode(
                data,
                (IEntryPoint.ReturnInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo)
            );
        }

        assertEq(senderInfo.stake, 123);
        assertEq(senderInfo.unstakeDelaySec, 3);
    }

    /// @notice 8. Should prevent overflows: fail if any numeric value is more than 120 bits
    function test_shouldPreventOverflows() public {
        UserOperation memory op;
        op.sender = address(account);
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = defaultBytes;
        op.callGasLimit = 0;
        op.verificationGasLimit = 150000;
        op.preVerificationGas = 2 ** 130;
        op.maxFeePerGas = 0;
        op.maxPriorityFeePerGas = 1000000000;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        vm.expectRevert("AA94 gas values overflow");
        entryPoint.simulateValidation(op);
    }

    /// @notice 9. Should fail creation for wrong sender
    function test_shouldFailCreationOnWrongSender() public {
        UserOperation memory op;
        op.sender = 0x1111111111111111111111111111111111111111;
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = utils.getAccountInitCode(accountOwner.addr, simpleAccountFactory, 0);
        op.callGasLimit = 0;
        op.verificationGasLimit = 3000000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 1381937087;
        op.maxPriorityFeePerGas = 1000000000;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        UserOperation memory op1 = utils.fillAndSign(op, accountOwner, entryPoint, chainId);
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA14 initCode must return sender"));
        entryPoint.simulateValidation(op1);
    }

    /// @notice 10. Should report failure on insufficient verificationGas for creation
    function test_shouldReportFailureOnInsufficentVerificationGas() public {
        Account memory accountOwner1 = utils.createAccountOwner("accountOwner1");
        address addr;
        bytes memory initCode = utils.getAccountInitCode(accountOwner1.addr, simpleAccountFactory, 0);

        try entryPoint.getSenderAddress(initCode) {}
        catch (bytes memory reason) {
            require(reason.length >= 4);
            bytes memory data = utils.getDataFromEncoding(reason);
            assembly {
                addr := mload(add(data, 0x20))
            }
        }
        UserOperation memory op;
        op.sender = addr;
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = initCode;
        op.callGasLimit = 0;
        op.verificationGasLimit = 500000;
        op.preVerificationGas = 0;
        op.maxFeePerGas = 0;
        op.maxPriorityFeePerGas = 1000000000;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;

        UserOperation memory op1 = utils.fillAndSign(op, accountOwner1, entryPoint, chainId);
        try entryPoint.simulateValidation{gas: 1e6}(op1) {}
        catch (bytes memory errorReason) {
            bytes4 reason;
            assembly {
                reason := mload(add(errorReason, 32))
            }
            assertEq(
                reason,
                bytes4(
                    keccak256(
                        "ValidationResult((uint256,uint256,bool,uint48,uint48,bytes),(uint256,uint256),(uint256,uint256),(uint256,uint256))"
                    )
                )
            );
        }

        op1.verificationGasLimit = 1e5;
        UserOperation memory op2 = utils.fillAndSign(op1, accountOwner1, entryPoint, chainId);
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA13 initCode failed or OOG"));
        entryPoint.simulateValidation(op2);
    }

    /// @notice 11. Should succeed for creating an account
    function test_shouldSucceedCreatingAccount() public {
        IEntryPoint.ReturnInfo memory returnInfo;
        Account memory accountOwner1 = utils.createAccountOwner("accountOwner1");
        address sender = utils.getAccountAddress(accountOwner1.addr, simpleAccountFactory, 0);

        UserOperation memory op;
        op.sender = sender;
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = utils.getAccountInitCode(accountOwner1.addr, simpleAccountFactory, 0);
        op.callGasLimit = 0;
        op.verificationGasLimit = 3000000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 1381937087;
        op.maxPriorityFeePerGas = 1000000000;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;
        UserOperation memory op1 = utils.fillAndSign(op, accountOwner1, entryPoint, chainId);

        vm.deal(op1.sender, 1 ether);
        try entryPoint.simulateValidation(op1) {}
        catch (bytes memory revertReason) {
            bytes memory data = utils.getDataFromEncoding(revertReason);
            (returnInfo,,,) = abi.decode(
                data,
                (IEntryPoint.ReturnInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo, IStakeManager.StakeInfo)
            );
        }
    }

    //    12. Should not call initCode from EntryPoint
    function test_shouldNotCallInitCodeFromEntryPoint() public {
        SimpleAccount account1;
        Account memory sender = utils.createAccountOwner("accountOwner1");
        (account1,) = utils.createAccountWithEntryPoint(accountOwner.addr, entryPoint, simpleAccountFactory);
        bytes memory initCode = utils.hexConcat(
            abi.encodePacked(account1), abi.encodeWithSignature("execute(address,uint,bytes)", sender, 0, "0x")
        );
        UserOperation memory op;
        op.sender = sender.addr;
        op.nonce = 0;
        op.callData = defaultBytes;
        op.initCode = initCode;
        op.callGasLimit = 0;
        op.verificationGasLimit = 3000000;
        op.preVerificationGas = 21000;
        op.maxFeePerGas = 1381937087;
        op.maxPriorityFeePerGas = 1000000000;
        op.paymasterAndData = defaultBytes;
        op.signature = defaultBytes;
        UserOperation memory op1 = utils.fillAndSign(op, accountOwner, entryPoint, chainId);
        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA13 initCode failed or OOG"));
        entryPoint.simulateValidation(op1);
    }

    //    13. Should not use banned ops during simulateValidation
    function test_shouldNotUseBannedOps() public {}

    // 2d nonces
    // Should fail nonce with new key and seq!=0
    function test_FailNonce() public {
        (Account memory beneficiary,, uint256 keyShifed, address _accountAddress) = _2dNonceSetup(false);

        UserOperation memory op = _defaultOp;
        op.sender = _accountAddress;
        op.nonce = keyShifed + 1;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);

        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA25 invalid account nonce"));
        entryPoint.handleOps(ops, payable(beneficiary.addr));
    }

    // With key=1, seq=1
    // should get next nonce value by getNonce
    function test_GetNonce() public {
        (, uint256 key, uint256 keyShifed, address _accountAddress) = _2dNonceSetup(true);

        uint256 nonce = entryPoint.getNonce(_accountAddress, uint192(key));
        assertEq(nonce, keyShifed + 1);
    }

    // Should allow to increment nonce of different key
    function test_IncrementNonce() public {
        (Account memory beneficiary, uint256 key,, address _accountAddress) = _2dNonceSetup(true);

        UserOperation memory op2 = _defaultOp;
        op2.sender = _accountAddress;
        op2.nonce = entryPoint.getNonce(_accountAddress, uint192(key));
        op2 = signUserOp(op2, entryPointAddress, chainId);
        ops[0] = op2;

        entryPoint.handleOps(ops, payable(beneficiary.addr));
    }

    // should allow manual nonce increment
    function test_ManualNonceIncrement() public {
        (Account memory beneficiary, uint256 key,, address _accountAddress) = _2dNonceSetup(true);

        uint192 incNonceKey = 5;
        bytes memory increment = abi.encodeWithSignature("incrementNonce(uint192)", incNonceKey);
        bytes memory callData =
            abi.encodeWithSignature("execute(address,uint256,bytes)", entryPointAddress, 0, increment);

        UserOperation memory op2 = _defaultOp;
        op2.sender = _accountAddress;
        op2.callData = callData;
        op2.nonce = entryPoint.getNonce(_accountAddress, uint192(key));
        op2 = signUserOp(op2, entryPointAddress, chainId);
        ops[0] = op2;

        entryPoint.handleOps(ops, payable(beneficiary.addr));

        uint256 nonce = entryPoint.getNonce(_accountAddress, incNonceKey);
        assertEq(nonce, (incNonceKey * 2 ** 64) + 1);
    }

    // Should fail with nonsequential seq
    function test_NonsequentialNonce() public {
        (Account memory beneficiary,, uint256 keyShifed, address _accountAddress) = _2dNonceSetup(true);

        UserOperation memory op2 = _defaultOp;
        op2.sender = _accountAddress;
        op2.nonce = keyShifed + 3;
        op2 = signUserOp(op2, entryPointAddress, chainId);
        ops[0] = op2;

        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA25 invalid account nonce"));
        entryPoint.handleOps(ops, payable(beneficiary.addr));
    }

    // Flickering account validation
    // Should prevent leakage of basefee
    // Note: Not completing this test cases as it includes RPC calls
    function test_BaseFeeLeakage() public {
        /**
         * Create a malicious account
         * Take snapshot
         * RPC call 'evm_mine'
         * Get latest block
         * RPC call 'evm_revert'
         * Validate block baseFeePerGas and expect failure
         * Generate UserOp
         * Trigger Simulate validation
         * Handle revert
         * RPC call 'evm_mine'
         * Trigger Simulate validation
         * Handle revert
         * Expect failures with error messages
         */
    }

    // Should limit revert reason length before emitting it
    function test_RevertReasonLength() public {
        (uint256 revertLength, uint256 REVERT_REASON_MAX_LENGTH) = (1e5, 2048);
        vm.deal(entryPointAddress, 1 ether);
        TestRevertAccount testAccount = new TestRevertAccount(entryPoint);
        bytes memory revertCallData = abi.encodeWithSignature("revertLong(uint256)", revertLength + 1);
        UserOperation memory badOp = _defaultOp;
        badOp.sender = address(testAccount);
        badOp.callGasLimit = 1e5;
        badOp.maxFeePerGas = 1;
        badOp.nonce = entryPoint.getNonce(address(testAccount), 0);
        badOp.verificationGasLimit = 1e5;
        badOp.callData = revertCallData;
        badOp.maxPriorityFeePerGas = 1e9;

        vm.deal(address(testAccount), 0.01 ether);
        Account memory beneficiary = createAddress("beneficiary");
        try entryPoint.simulateValidation{gas: 3e5}(badOp) {}
        catch (bytes memory errorReason) {
            bytes4 reason;
            assembly {
                reason := mload(add(errorReason, 32))
            }
            assertEq(
                reason,
                bytes4(
                    keccak256(
                        "ValidationResult((uint256,uint256,bool,uint48,uint48,bytes),(uint256,uint256),(uint256,uint256),(uint256,uint256))"
                    )
                )
            );
        }
        ops.push(badOp);
        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary.addr));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[2].topics[0], keccak256("UserOperationRevertReason(bytes32,address,uint256,bytes)"));
        (, bytes memory revertReason) = abi.decode(logs[2].data, (uint256, bytes));
        assertEq(revertReason.length, REVERT_REASON_MAX_LENGTH);
    }

    // Warm/cold storage detection in simulation vs execution
    // Should prevent detection through getAggregator()
    function test_DetectionThroughGetAggregator() public {
        uint256 TOUCH_GET_AGGREGATOR = 1;
        TestWarmColdAccount testAccount = new TestWarmColdAccount(entryPoint);
        UserOperation memory badOp = _defaultOp;
        badOp.nonce = TOUCH_GET_AGGREGATOR;
        badOp.sender = address(testAccount);

        Account memory beneficiary = createAddress("beneficiary");

        try entryPoint.simulateValidation{gas: 1e6}(badOp) {}
        catch (bytes memory revertReason) {
            bytes4 reason;
            assembly {
                reason := mload(add(revertReason, 32))
            }
            if (
                reason
                    == bytes4(
                        keccak256(
                            "ValidationResult((uint256,uint256,bool,uint48,uint48,bytes),(uint256,uint256),(uint256,uint256),(uint256,uint256))"
                        )
                    )
            ) {
                ops.push(badOp);
                entryPoint.handleOps{gas: 1e6}(ops, payable(beneficiary.addr));
            } else {
                bytes memory failedOp = abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA23 reverted (or OOG)");
                assertEq(revertReason, failedOp);
            }
        }
    }

    // Should prevent detection through paymaster.code.length
    function test_DetectionThroughPaymasterCodeLength() public {
        uint256 TOUCH_PAYMASTER = 2;
        TestWarmColdAccount testAccount = new TestWarmColdAccount(entryPoint);
        TestPaymasterAcceptAll paymaster = new TestPaymasterAcceptAll(entryPoint);
        paymaster.deposit{value: 1 ether}();

        UserOperation memory badOp = _defaultOp;
        badOp.nonce = TOUCH_PAYMASTER;
        badOp.sender = address(testAccount);
        badOp.paymasterAndData = abi.encodePacked(address(paymaster));
        badOp.verificationGasLimit = 1000;

        Account memory beneficiary = createAddress("beneficiary");

        try entryPoint.simulateValidation{gas: 1e6}(badOp) {}
        catch (bytes memory revertReason) {
            bytes4 reason;
            assembly {
                reason := mload(add(revertReason, 32))
            }
            if (
                reason
                    == bytes4(
                        keccak256(
                            "ValidationResult((uint256,uint256,bool,uint48,uint48,bytes),(uint256,uint256),(uint256,uint256),(uint256,uint256))"
                        )
                    )
            ) {
                ops.push(badOp);
                entryPoint.handleOps{gas: 1e6}(ops, payable(beneficiary.addr));
            } else {
                bytes memory failedOp = abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA23 reverted (or OOG)");
                assertEq(revertReason, failedOp);
            }
        }
    }

    function _2dNonceSetup(bool triggerHandelOps) internal returns (Account memory, uint256, uint256, address) {
        Account memory beneficiary = createAddress("beneficiary");
        uint256 key = 1;
        uint256 keyShifted = key * 2 ** 64;

        (, address _accountAddress) = createAccountWithFactory(123422);
        vm.deal(_accountAddress, 1 ether);

        if (!triggerHandelOps) {
            return (beneficiary, key, keyShifted, _accountAddress);
        }
        UserOperation memory op = _defaultOp;
        op.sender = _accountAddress;
        op.nonce = keyShifted;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);

        entryPoint.handleOps(ops, payable(beneficiary.addr));
        return (beneficiary, key, keyShifted, _accountAddress);
    }

    //without paymaster (account pays in eth)
    //#handleOps
    function _handleOpsSetUp() public returns (TestCounter counter, bytes memory accountExecFromEntryPoint) {
        counter = new TestCounter{salt: '123'}();
        bytes memory count = abi.encodeCall(counter.count, ());
        accountExecFromEntryPoint = abi.encodeCall(account.execute, (address(counter), 0, count));
    }

    //should revert on signature failure
    function test_RevertOnSignatureFailure() public {
        Account memory wrong_owner = createAddress("wrong_owner");
        UserOperation memory op = _defaultOp;
        op.sender = accountAddress;
        op = signUserOp(op, entryPointAddress, chainId, wrong_owner.key);
        ops.push(op);
        address payable beneficiary = payable(makeAddr("beneficiary"));

        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA24 signature error"));
        entryPoint.handleOps(ops, beneficiary);
    }

    //account should pay for transaction
    function test_PayForTransaction() public {
        (TestCounter counter, bytes memory accountExecFromEntryPoint) = _handleOpsSetUp();

        UserOperation memory op = _defaultOp;
        op.sender = accountAddress;
        op.callData = accountExecFromEntryPoint;
        op.verificationGasLimit = 1e6;
        op.callGasLimit = 1e6;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);
        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 countBefore = counter.counters(accountAddress);

        vm.recordLogs();
        entryPoint.handleOps{gas: 1e7}(ops, beneficiary);

        uint256 countAfter = counter.counters(accountAddress);
        assertEq(countAfter, countBefore + 1);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,, uint256 actualGasCost,) = abi.decode(entries[2].data, (uint256, bool, uint256, uint256));
        assertEq(beneficiary.balance, actualGasCost);
    }

    //account should pay for high gas usage tx
    function test_PayForHighGasUse() public {
        (TestCounter counter,) = _handleOpsSetUp();
        uint256 iterations = 45;
        bytes memory countData = abi.encodeCall(counter.gasWaster, (iterations, ""));
        bytes memory accountExec = abi.encodeCall(account.execute, (address(counter), 0, countData));

        UserOperation memory op = _defaultOp;
        op.sender = accountAddress;
        op.callData = accountExec;
        op.verificationGasLimit = 1e5;
        op.callGasLimit = 11e5;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);
        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 offsetBefore = counter.offset();

        vm.recordLogs();
        entryPoint.handleOps{gas: 13e6}(ops, beneficiary);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,, uint256 actualGasCost,) = abi.decode(entries[2].data, (uint256, bool, uint256, uint256));
        assertEq(beneficiary.balance, actualGasCost);

        assertEq(counter.offset(), offsetBefore + iterations);
    }

    //account should not pay if too low gas limit was set
    function test_DontPayForLowGasLimit() public {
        (TestCounter counter,) = _handleOpsSetUp();
        uint256 iterations = 45;
        bytes memory countData = abi.encodeCall(counter.gasWaster, (iterations, ""));
        bytes memory accountExec = abi.encodeCall(account.execute, (address(counter), 0, countData));

        UserOperation memory op = _defaultOp;
        op.sender = accountAddress;
        op.callData = accountExec;
        op.verificationGasLimit = 1e5;
        op.callGasLimit = 11e5;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);
        uint256 initialAccountBalance = accountAddress.balance;
        address payable beneficiary = payable(makeAddr("beneficiary"));
        uint256 offsetBefore = counter.offset();

        vm.expectRevert(abi.encodeWithSignature("FailedOp(uint256,string)", 0, "AA95 out of gas"));
        entryPoint.handleOps{gas: 12e5}(ops, beneficiary);

        assertEq(accountAddress.balance, initialAccountBalance);
        assertEq(counter.offset(), offsetBefore);
    }

    //if account has a deposit, it should use it to pay
    function test_PayFromDeposit() public {
        (TestCounter counter, bytes memory accountExecFromEntryPoint) = _handleOpsSetUp();
        account.addDeposit{value: 1 ether}();

        UserOperation memory op = _defaultOp;
        op.sender = accountAddress;
        op.callData = accountExecFromEntryPoint;
        op.verificationGasLimit = 1e6;
        op.callGasLimit = 1e6;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);
        address payable beneficiary = payable(makeAddr("beneficiary"));

        uint256 countBefore = counter.counters(op.sender);
        uint256 balBefore = op.sender.balance;
        uint256 depositBefore = entryPoint.balanceOf(accountAddress);

        vm.recordLogs();
        entryPoint.handleOps{gas: 1e7}(ops, beneficiary);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        uint256 countAfter = counter.counters(op.sender);
        assertEq(countAfter, countBefore + 1);

        uint256 balAfter = op.sender.balance;
        uint256 depositAfter = entryPoint.balanceOf(accountAddress);
        assertEq(balAfter, balBefore, "should pay from stake, not balance");
        uint256 depositUsed = depositBefore - depositAfter;
        assertEq(beneficiary.balance, depositUsed);

        (,, uint256 actualGasCost,) = abi.decode(entries[1].data, (uint256, bool, uint256, uint256));
        assertEq(beneficiary.balance, actualGasCost);
    }

    //should pay for reverted tx
    function test_PayForRevertedTx() public {
        UserOperation memory op = _defaultOp;
        op.sender = accountAddress;
        op.callData = "0xdeadface";
        op.verificationGasLimit = 1e6;
        op.callGasLimit = 1e6;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);
        address payable beneficiary = payable(makeAddr("beneficiary"));

        vm.recordLogs();
        entryPoint.handleOps{gas: 1e7}(ops, beneficiary);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, bool success,,) = abi.decode(entries[2].data, (uint256, bool, uint256, uint256));
        assertFalse(success);
        bool balanceGt1 = (beneficiary.balance > 1);
        assertEq(balanceGt1, true);
    }

    //#handleOp (single)
    function test_SingleOp() public {
        (TestCounter counter, bytes memory accountExecFromEntryPoint) = _handleOpsSetUp();
        address payable beneficiary = payable(makeAddr("beneficiary"));

        UserOperation memory op = _defaultOp;
        op.sender = accountAddress;
        op.callData = accountExecFromEntryPoint;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);
        uint256 countBefore = counter.counters(accountAddress);

        assertEq(ops.length, 1);
        vm.recordLogs();
        entryPoint.handleOps(ops, beneficiary);

        uint256 countAfter = counter.counters(accountAddress);
        assertEq(countAfter, countBefore + 1);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,, uint256 actualGasCost,) = abi.decode(entries[2].data, (uint256, bool, uint256, uint256));
        assertEq(beneficiary.balance, actualGasCost);
    }

    //should fail to call recursively into handleOps
    function test_RecursiveCallToHandleOps() public {
        address payable beneficiary = payable(makeAddr("beneficiary"));

        UserOperation[] memory _ops;
        bytes memory callHandleOps = abi.encodeCall(entryPoint.handleOps, (_ops, beneficiary));
        bytes memory execHandlePost = abi.encodeCall(account.execute, (entryPointAddress, 0, callHandleOps));

        UserOperation memory op = _defaultOp;
        op.sender = accountAddress;
        op.callData = execHandlePost;
        op = signUserOp(op, entryPointAddress, chainId);
        ops.push(op);

        vm.recordLogs();
        entryPoint.handleOps(ops, beneficiary);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (, bytes memory revertReason) = abi.decode(entries[2].data, (uint256, bytes));
        assertEq(
            revertReason,
            abi.encodeWithSignature("Error(string)", "ReentrancyGuard: reentrant call"),
            "execution of handleOps inside a UserOp should revert"
        );
    }
}
