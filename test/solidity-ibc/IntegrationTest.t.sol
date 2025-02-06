// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable custom-errors,max-line-length,max-states-count

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { ILightClientMsgs } from "../../contracts/msgs/ILightClientMsgs.sol";
import { IICS02ClientMsgs } from "../../contracts/msgs/IICS02ClientMsgs.sol";
import { IICS26RouterMsgs } from "../../contracts/msgs/IICS26RouterMsgs.sol";
import { IICS20TransferMsgs } from "../../contracts/msgs/IICS20TransferMsgs.sol";

import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IICS26Router } from "../../contracts/interfaces/IICS26Router.sol";
import { IICS26RouterErrors } from "../../contracts/errors/IICS26RouterErrors.sol";

import { ICS20Transfer } from "../../contracts/ICS20Transfer.sol";
import { TestERC20 } from "./mocks/TestERC20.sol";
import { IBCERC20 } from "../../contracts/utils/IBCERC20.sol";
import { ICS26Router } from "../../contracts/ICS26Router.sol";
import { DummyLightClient } from "./mocks/DummyLightClient.sol";
import { ICS20Lib } from "../../contracts/utils/ICS20Lib.sol";
import { ICS24Host } from "../../contracts/utils/ICS24Host.sol";
import { Strings } from "@openzeppelin-contracts/utils/Strings.sol";
import { Bytes } from "@openzeppelin-contracts/utils/Bytes.sol";
import { ERC1967Proxy } from "@openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract IntegrationTest is Test {
    using Strings for string;

    ICS26Router public ics26Router;
    DummyLightClient public lightClient;
    string public clientIdentifier;
    ICS20Transfer public ics20Transfer;
    string public ics20AddressStr;
    TestERC20 public erc20;
    string public erc20AddressStr;
    string public counterpartyId = "42-dummy-01";
    bytes[] public merklePrefix = [bytes("ibc"), bytes("")];
    bytes[] public singleSuccessAck = [ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON];

    address public defaultSender;
    string public defaultSenderStr;
    address public defaultReceiver;
    string public defaultReceiverStr;

    /// @dev the default send amount for sendTransfer
    uint256 public defaultAmount = 1_000_000_000_000_000_000;
    string public defaultNativeDenom;

    function setUp() public {
        // ============ Step 1: Deploy the logic contracts ==============
        lightClient = new DummyLightClient(ILightClientMsgs.UpdateResult.Update, 0, false);
        ICS26Router ics26RouterLogic = new ICS26Router();
        ICS20Transfer ics20TransferLogic = new ICS20Transfer();

        // ============== Step 2: Deploy Transparent Proxies ==============
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(ics26RouterLogic),
            abi.encodeWithSelector(ICS26Router.initialize.selector, address(this), address(this))
        );

        ERC1967Proxy transferProxy = new ERC1967Proxy(
            address(ics20TransferLogic),
            abi.encodeWithSelector(ICS20Transfer.initialize.selector, address(routerProxy), address(0))
        );

        // ============== Step 3: Wire up the contracts ==============
        ics26Router = ICS26Router(address(routerProxy));
        ics20Transfer = ICS20Transfer(address(transferProxy));
        erc20 = new TestERC20();
        erc20AddressStr = Strings.toHexString(address(erc20));

        defaultNativeDenom = erc20AddressStr;

        clientIdentifier = ics26Router.addClient(
            "07-tendermint", IICS02ClientMsgs.CounterpartyInfo(counterpartyId, merklePrefix), address(lightClient)
        );
        ics20AddressStr = Strings.toHexString(address(ics20Transfer));

        vm.expectEmit();
        emit IICS26Router.IBCAppAdded(ICS20Lib.DEFAULT_PORT_ID, address(ics20Transfer));
        ics26Router.addIBCApp(ICS20Lib.DEFAULT_PORT_ID, address(ics20Transfer));

        assertEq(address(ics20Transfer), address(ics26Router.getIBCApp(ICS20Lib.DEFAULT_PORT_ID)));

        defaultSender = makeAddr("sender");
        defaultSenderStr = Strings.toHexString(defaultSender);

        defaultReceiver = makeAddr("receiver");
        defaultReceiverStr = Strings.toHexString(defaultReceiver);
    }

    function test_success_sendICS20PacketDirectlyFromRouter() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);

        uint256 senderBalanceBefore = erc20.balanceOf(defaultSender);
        uint256 contractBalanceBefore = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(senderBalanceBefore, defaultAmount);
        assertEq(contractBalanceBefore, 0);

        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(defaultSenderStr, defaultReceiverStr, address(erc20));

        IICS26RouterMsgs.MsgAckPacket memory ackMsg = IICS26RouterMsgs.MsgAckPacket({
            packet: packet,
            acknowledgement: ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON,
            proofAcked: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });
        ics26Router.ackPacket(ackMsg);
        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        uint256 senderBalanceAfter = erc20.balanceOf(defaultSender);
        uint256 contractBalanceAfter = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(senderBalanceAfter, 0);
        assertEq(contractBalanceAfter, defaultAmount);
    }

    function test_success_sendICS20PacketFromICS20Contract() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.startPrank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);

        uint256 senderBalanceBefore = erc20.balanceOf(defaultSender);
        uint256 contractBalanceBefore = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(senderBalanceBefore, defaultAmount);
        assertEq(contractBalanceBefore, 0);

        IICS20TransferMsgs.SendTransferMsg memory transferMsg = IICS20TransferMsgs.SendTransferMsg({
            denom: address(erc20),
            amount: defaultAmount,
            receiver: defaultReceiverStr,
            sourceClient: clientIdentifier,
            destPort: ICS20Lib.DEFAULT_PORT_ID,
            timeoutTimestamp: uint64(block.timestamp + 1000),
            memo: "memo"
        });

        vm.startPrank(defaultSender);
        uint32 sequence = ics20Transfer.sendTransfer(transferMsg);
        assertEq(sequence, 1);

        IICS20TransferMsgs.FungibleTokenPacketData memory packetData =
            _getPacketData(defaultSenderStr, defaultReceiverStr, defaultNativeDenom);

        IICS26RouterMsgs.Payload[] memory packetPayloads = _getPayloads(abi.encode(packetData));
        IICS26RouterMsgs.Packet memory packet = IICS26RouterMsgs.Packet({
            sequence: sequence,
            sourceClient: transferMsg.sourceClient,
            destClient: counterpartyId, // If we test with something else, we need to add this to the args
            timeoutTimestamp: transferMsg.timeoutTimestamp,
            payloads: packetPayloads
        });

        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(transferMsg.sourceClient, sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, ICS24Host.packetCommitmentBytes32(packet));

        IICS26RouterMsgs.MsgAckPacket memory ackMsg = IICS26RouterMsgs.MsgAckPacket({
            packet: packet,
            acknowledgement: ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON,
            proofAcked: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });

        ics26Router.ackPacket(ackMsg);

        // commitment should be deleted
        storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        uint256 senderBalanceAfter = erc20.balanceOf(defaultSender);
        uint256 contractBalanceAfter = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(senderBalanceAfter, 0);
        assertEq(contractBalanceAfter, defaultAmount);
    }

    function test_success_sendICS20PacketWithLargeAmount() public {
        uint256 largeAmount = 1_000_000_000_000_000_001_000_000_000_000;

        erc20.mint(defaultSender, largeAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), largeAmount);

        uint256 senderBalanceBefore = erc20.balanceOf(defaultSender);
        assertEq(senderBalanceBefore, largeAmount);
        uint256 contractBalanceBefore = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceBefore, 0);

        IICS26RouterMsgs.Packet memory packet = _sendICS20TransferPacket(
            defaultSenderStr, defaultReceiverStr, address(erc20), largeAmount, clientIdentifier
        );

        IICS26RouterMsgs.MsgAckPacket memory ackMsg = IICS26RouterMsgs.MsgAckPacket({
            packet: packet,
            acknowledgement: ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON,
            proofAcked: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });
        ics26Router.ackPacket(ackMsg);
        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        uint256 senderBalanceAfter = erc20.balanceOf(defaultSender);
        uint256 contractBalanceAfter = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(senderBalanceAfter, 0);
        assertEq(contractBalanceAfter, largeAmount);
    }

    function test_failure_sendPacketWithLargeTimeoutDuration() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.startPrank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);

        uint64 timeoutTimestamp = uint64(block.timestamp + 2 days);

        vm.expectRevert(abi.encodeWithSelector(IICS26RouterErrors.IBCInvalidTimeoutDuration.selector, 1 days, 2 days));
        ics20Transfer.sendTransfer(
            IICS20TransferMsgs.SendTransferMsg({
                denom: address(erc20),
                amount: defaultAmount,
                receiver: defaultReceiverStr,
                sourceClient: clientIdentifier,
                destPort: ICS20Lib.DEFAULT_PORT_ID,
                timeoutTimestamp: timeoutTimestamp,
                memo: "memo"
            })
        );
    }

    function test_success_failedCounterpartyAckForICS20Packet() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);

        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(defaultSenderStr, defaultReceiverStr, address(erc20));

        IICS26RouterMsgs.MsgAckPacket memory ackMsg = IICS26RouterMsgs.MsgAckPacket({
            packet: packet,
            acknowledgement: ICS20Lib.FAILED_ACKNOWLEDGEMENT_JSON,
            proofAcked: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });

        ics26Router.ackPacket(ackMsg);
        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        // transfer should be reverted
        uint256 senderBalanceAfterAck = erc20.balanceOf(defaultSender);
        uint256 contractBalanceAfterAck = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(senderBalanceAfterAck, defaultAmount);
        assertEq(contractBalanceAfterAck, 0);
    }

    function test_success_ackNoop() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);

        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(defaultSenderStr, defaultReceiverStr, address(erc20));

        IICS26RouterMsgs.MsgAckPacket memory ackMsg = IICS26RouterMsgs.MsgAckPacket({
            packet: packet,
            acknowledgement: ICS20Lib.FAILED_ACKNOWLEDGEMENT_JSON,
            proofAcked: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });
        ics26Router.ackPacket(ackMsg);
        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        // call ack again, should be noop
        vm.expectEmit();
        emit IICS26Router.Noop();
        ics26Router.ackPacket(ackMsg);
    }

    function test_success_timeoutICS20Packet() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);
        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(defaultSenderStr, defaultReceiverStr, address(erc20));

        // make light client return timestamp that is after our timeout
        lightClient.setMembershipResult(packet.timeoutTimestamp + 1, false);

        IICS26RouterMsgs.MsgTimeoutPacket memory timeoutMsg = IICS26RouterMsgs.MsgTimeoutPacket({
            packet: packet,
            proofTimeout: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });

        ics26Router.timeoutPacket(timeoutMsg);
        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        // transfer should be reverted
        uint256 senderBalanceAfterTimeout = erc20.balanceOf(defaultSender);
        uint256 contractBalanceAfterTimeout = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(senderBalanceAfterTimeout, defaultAmount);
        assertEq(contractBalanceAfterTimeout, 0);
    }

    function test_success_timeoutForeignDenomICS20Packet() public {
        // Receive a foreign denom, then send out and timeout
        string memory foreignDenom = "uatom";

        address receiverOfForeignDenom = makeAddr("receiver_of_foreign_denom");
        string memory receiverOfForeignDenomStr = Strings.toHexString(receiverOfForeignDenom);

        (IERC20 receivedERC20,,) = _receiveICS20Transfer(
            "cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh", receiverOfForeignDenomStr, foreignDenom
        );

        // Send out again
        vm.prank(receiverOfForeignDenom);
        receivedERC20.approve(address(ics20Transfer), defaultAmount);
        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(receiverOfForeignDenomStr, "whatever", address(receivedERC20));

        uint256 senderBalanceBeforeTimeout = receivedERC20.balanceOf(receiverOfForeignDenom);
        assertEq(senderBalanceBeforeTimeout, 0);
        uint256 contractBalanceBeforeTimeout = receivedERC20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceBeforeTimeout, 0); // Burned

        // make light client return timestamp that is after our timeout
        lightClient.setMembershipResult(packet.timeoutTimestamp + 1, false);

        IICS26RouterMsgs.MsgTimeoutPacket memory timeoutMsg = IICS26RouterMsgs.MsgTimeoutPacket({
            packet: packet,
            proofTimeout: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });

        ics26Router.timeoutPacket(timeoutMsg);
        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        // transfer should be reverted
        uint256 senderBalanceAfterTimeout = receivedERC20.balanceOf(receiverOfForeignDenom);
        assertEq(senderBalanceAfterTimeout, defaultAmount); // Minted and returned
        uint256 contractBalanceAfterTimeout = receivedERC20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceAfterTimeout, 0);
    }

    function test_success_timeoutNoop() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);
        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(defaultSenderStr, defaultReceiverStr, address(erc20));

        // make light client return timestamp that is after our timeout
        lightClient.setMembershipResult(packet.timeoutTimestamp + 1, false);

        IICS26RouterMsgs.MsgTimeoutPacket memory timeoutMsg = IICS26RouterMsgs.MsgTimeoutPacket({
            packet: packet,
            proofTimeout: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });
        ics26Router.timeoutPacket(timeoutMsg);
        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        // call timeout again, should be noop
        vm.expectEmit();
        emit IICS26Router.Noop();
        ics26Router.timeoutPacket(timeoutMsg);
    }

    function test_success_receiveICS20PacketWithSourceDenom() public {
        // send out a native token first
        erc20.mint(defaultSender, defaultAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);
        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(defaultSenderStr, defaultReceiverStr, address(erc20));

        IICS26RouterMsgs.MsgAckPacket memory ackMsg = IICS26RouterMsgs.MsgAckPacket({
            packet: packet,
            acknowledgement: ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON,
            proofAcked: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });
        ics26Router.ackPacket(ackMsg);

        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        uint256 senderBalanceBeforeReceive = erc20.balanceOf(defaultSender);
        assertEq(senderBalanceBeforeReceive, 0);
        uint256 contractBalanceBeforeReceive = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceBeforeReceive, defaultAmount); // Escrowed
        uint256 supplyBeforeReceive = erc20.totalSupply();
        assertEq(supplyBeforeReceive, defaultAmount); // Not burned

        // Return the tokens (receive)
        string memory receivedDenom =
            string(abi.encodePacked(packet.payloads[0].destPort, "/", packet.destClient, "/", erc20AddressStr));
        _receiveICS20Transfer(defaultReceiverStr, defaultSenderStr, receivedDenom);

        // check balances after receiving back
        uint256 senderBalanceAfterReceive = erc20.balanceOf(defaultSender);
        assertEq(senderBalanceAfterReceive, defaultAmount);
        uint256 contractBalanceAfterReceive = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceAfterReceive, 0);
        uint256 supplyAfterReceive = erc20.totalSupply();
        assertEq(supplyAfterReceive, defaultAmount);
    }

    function test_success_recvNoop() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);
        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(defaultSenderStr, defaultReceiverStr, address(erc20));

        IICS26RouterMsgs.MsgAckPacket memory ackMsg = IICS26RouterMsgs.MsgAckPacket({
            packet: packet,
            acknowledgement: ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON,
            proofAcked: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });

        ics26Router.ackPacket(ackMsg);

        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        uint256 senderBalanceAfterSend = erc20.balanceOf(defaultSender);
        uint256 contractBalanceAfterSend = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(senderBalanceAfterSend, 0);
        assertEq(contractBalanceAfterSend, defaultAmount);

        // Return the tokens (receive)
        string memory receiverStr = defaultSenderStr;
        string memory receivedDenom =
            string(abi.encodePacked(packet.payloads[0].destPort, "/", packet.destClient, "/", erc20AddressStr));

        (,, IICS26RouterMsgs.Packet memory receivePacket) =
            _receiveICS20Transfer("cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh", receiverStr, receivedDenom);

        // call recvPacket again, should be noop
        vm.expectEmit();
        emit IICS26Router.Noop();
        ics26Router.recvPacket(
            IICS26RouterMsgs.MsgRecvPacket({
                packet: receivePacket,
                proofCommitment: bytes("doesntmatter"), // dummy client will accept
                proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will
                    // accept
             })
        );
    }

    function test_success_receiveICS20PacketWithForeignBaseDenom() public {
        string memory foreignDenom = "uatom";

        address receiver = makeAddr("receiver_of_foreign_denom");

        (IERC20 receivedERC20,,) = _receiveICS20Transfer(
            "cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh", Strings.toHexString(receiver), foreignDenom
        );

        // check balances after receiving
        uint256 senderBalanceAfterReceive = receivedERC20.balanceOf(receiver);
        assertEq(senderBalanceAfterReceive, defaultAmount);
        uint256 contractBalanceAfterReceive = receivedERC20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceAfterReceive, 0);
        uint256 supplyAfterReceive = receivedERC20.totalSupply();
        assertEq(supplyAfterReceive, defaultAmount);

        IBCERC20 ibcERC20 = IBCERC20(address(receivedERC20));

        // Send out again
        address sender = receiver;
        vm.prank(receiver);
        ibcERC20.approve(address(ics20Transfer), defaultAmount);

        _sendICS20TransferPacket(Strings.toHexString(sender), "whatever", address(receivedERC20));

        // check balances after sending out
        uint256 senderBalanceAfterSend = ibcERC20.balanceOf(sender);
        assertEq(senderBalanceAfterSend, 0);
        uint256 contractBalanceAfterSend = ibcERC20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceAfterSend, 0); // Burned
        uint256 supplyAfterSend = ibcERC20.totalSupply();
        assertEq(supplyAfterSend, 0); // Burned
    }

    function test_success_receiveICS20PacketWithLargeAmount() public {
        uint256 largeAmount = 1_000_000_000_000_000_001_000_000_000_000;
        string memory foreignDenom = "uatom";

        address receiver = makeAddr("receiver_of_foreign_denom");

        (IERC20 receivedERC20,,) = _receiveICS20Transfer(
            "cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh",
            Strings.toHexString(receiver),
            foreignDenom,
            largeAmount,
            clientIdentifier
        );

        // check balances after receiving
        uint256 senderBalanceAfterReceive = receivedERC20.balanceOf(receiver);
        assertEq(senderBalanceAfterReceive, largeAmount);
        uint256 contractBalanceAfterReceive = receivedERC20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceAfterReceive, 0);
        uint256 supplyAfterReceive = receivedERC20.totalSupply();
        assertEq(supplyAfterReceive, largeAmount);

        IBCERC20 ibcERC20 = IBCERC20(address(receivedERC20));

        // Send out again
        address sender = receiver;
        vm.prank(receiver);
        ibcERC20.approve(address(ics20Transfer), largeAmount);

        _sendICS20TransferPacket(
            Strings.toHexString(sender), "whatever", address(receivedERC20), largeAmount, clientIdentifier
        );

        // check balances after sending out
        uint256 senderBalanceAfterSend = ibcERC20.balanceOf(sender);
        assertEq(senderBalanceAfterSend, 0);
        uint256 contractBalanceAfterSend = ibcERC20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceAfterSend, 0); // Burned
        uint256 supplyAfterSend = ibcERC20.totalSupply();
        assertEq(supplyAfterSend, 0); // Burned
    }

    function test_success_receiveMultiPacketWithForeignBaseDenom() public {
        string memory foreignDenom = "uatom";

        string memory senderStr = "cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh";
        address receiver = makeAddr("receiver_of_foreign_denom");
        string memory receiverStr = Strings.toHexString(receiver);

        // First packet
        IICS20TransferMsgs.FungibleTokenPacketData memory packetData =
            _getPacketData(senderStr, receiverStr, foreignDenom);
        IICS26RouterMsgs.Payload[] memory payloads1 = _getPayloads(abi.encode(packetData));
        IICS26RouterMsgs.Packet memory receivePacket = IICS26RouterMsgs.Packet({
            sequence: 1,
            sourceClient: counterpartyId,
            destClient: clientIdentifier,
            timeoutTimestamp: uint64(block.timestamp + 1000),
            payloads: payloads1
        });

        // Second packet
        IICS26RouterMsgs.Payload[] memory payloads2 = _getPayloads(abi.encode(packetData));
        IICS26RouterMsgs.Packet memory receivePacket2 = IICS26RouterMsgs.Packet({
            sequence: 2,
            sourceClient: counterpartyId,
            destClient: clientIdentifier,
            timeoutTimestamp: uint64(block.timestamp + 1000),
            payloads: payloads2
        });

        bytes[] memory multicallData = new bytes[](2);
        multicallData[0] = abi.encodeCall(
            IICS26Router.recvPacket,
            IICS26RouterMsgs.MsgRecvPacket({
                packet: receivePacket,
                proofCommitment: bytes("doesntmatter"), // dummy client will accept
                proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // will accept
             })
        );
        multicallData[1] = abi.encodeCall(
            IICS26Router.recvPacket,
            IICS26RouterMsgs.MsgRecvPacket({
                packet: receivePacket2,
                proofCommitment: bytes("doesntmatter"), // dummy client will accept
                proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // will accept
             })
        );

        ics26Router.multicall(multicallData);

        // Check that the ack is written
        bytes32 storedAck = ics26Router.getCommitment(
            ICS24Host.packetAcknowledgementCommitmentKeyCalldata(receivePacket.destClient, receivePacket.sequence)
        );
        assertEq(storedAck, ICS24Host.packetAcknowledgementCommitmentBytes32(singleSuccessAck));
        bytes32 storedAck2 = ics26Router.getCommitment(
            ICS24Host.packetAcknowledgementCommitmentKeyCalldata(receivePacket2.destClient, receivePacket2.sequence)
        );
        assertEq(storedAck2, ICS24Host.packetAcknowledgementCommitmentBytes32(singleSuccessAck));
    }

    function test_failure_receiveMultiPacketWithForeignBaseDenom() public {
        string memory foreignDenom = "uatom";

        string memory senderStr = "cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh";
        address receiver = makeAddr("receiver_of_foreign_denom");
        string memory receiverStr = Strings.toHexString(receiver);

        // First packet
        // First packet
        IICS20TransferMsgs.FungibleTokenPacketData memory packetData =
            _getPacketData(senderStr, receiverStr, foreignDenom);
        IICS26RouterMsgs.Payload[] memory payloads1 = _getPayloads(abi.encode(packetData));
        IICS26RouterMsgs.Packet memory receivePacket = IICS26RouterMsgs.Packet({
            sequence: 1,
            sourceClient: counterpartyId,
            destClient: clientIdentifier,
            timeoutTimestamp: uint64(block.timestamp + 1000),
            payloads: payloads1
        });

        // Second packet
        IICS26RouterMsgs.Payload[] memory payloads2 = _getPayloads(abi.encode(packetData));
        payloads2[0].destPort = "invalid-port";
        IICS26RouterMsgs.Packet memory invalidPacket = IICS26RouterMsgs.Packet({
            sequence: 2,
            sourceClient: counterpartyId,
            destClient: clientIdentifier,
            timeoutTimestamp: uint64(block.timestamp + 1000),
            payloads: payloads2
        });

        bytes[] memory multicallData = new bytes[](2);
        multicallData[0] = abi.encodeCall(
            IICS26Router.recvPacket,
            IICS26RouterMsgs.MsgRecvPacket({
                packet: receivePacket,
                proofCommitment: bytes("doesntmatter"), // dummy client will accept
                proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // will accept
             })
        );
        multicallData[1] = abi.encodeCall(
            IICS26Router.recvPacket,
            IICS26RouterMsgs.MsgRecvPacket({
                packet: invalidPacket,
                proofCommitment: bytes("doesntmatter"), // dummy client will accept
                proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // will accept
             })
        );

        vm.expectRevert(
            abi.encodeWithSelector(IICS26RouterErrors.IBCAppNotFound.selector, invalidPacket.payloads[0].destPort)
        );
        ics26Router.multicall(multicallData);
    }

    function test_success_receiveICS20PacketWithForeignIBCDenom() public {
        string memory foreignDenom = "transfer/channel-42/uatom";

        string memory senderStr = "cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh";
        address receiver = makeAddr("receiver_of_foreign_denom");
        string memory receiverStr = Strings.toHexString(receiver);

        (IERC20 receivedERC20, string memory receivedDenom,) =
            _receiveICS20Transfer(senderStr, receiverStr, foreignDenom);

        assertEq(receivedDenom, "transfer/07-tendermint-0/transfer/channel-42/uatom");

        IBCERC20 ibcERC20 = IBCERC20(address(receivedERC20));
        assertEq(ibcERC20.fullDenomPath(), receivedDenom);
        assertEq(ibcERC20.name(), receivedDenom);
        assertEq(ibcERC20.symbol(), "transfer/channel-42/uatom");
        assertEq(ibcERC20.totalSupply(), defaultAmount);
        assertEq(ibcERC20.balanceOf(receiver), defaultAmount);

        // Send out again
        address sender = receiver;
        {
            string memory tmpSenderStr = senderStr;
            senderStr = receiverStr;
            receiverStr = tmpSenderStr;
        }

        vm.prank(sender);
        ibcERC20.approve(address(ics20Transfer), defaultAmount);

        _sendICS20TransferPacket(senderStr, receiverStr, address(receivedERC20));

        assertEq(ibcERC20.totalSupply(), 0);
        assertEq(ibcERC20.balanceOf(sender), 0);
    }

    function test_success_receiveICS20PacketAsAMiddleChain() public {
        // Receive a foreign denom, send out, receive back
        // There are three chains in this scenario: A -> B -> C with B being us

        // Create a secondary client to send out to a different chain
        string memory chainCClientID = ics26Router.addClient(
            "07-tendermint", IICS02ClientMsgs.CounterpartyInfo(counterpartyId, merklePrefix), address(lightClient)
        );

        string memory foreignDenom = "uatom";

        address middleReceiver = makeAddr("middle_receiver");
        string memory middleReceiverStr = Strings.toHexString(middleReceiver);

        // Receive
        (IERC20 receivedERC20, string memory receivedDenom,) =
            _receiveICS20Transfer("chain_a_sender", middleReceiverStr, foreignDenom);

        // Send out
        vm.prank(middleReceiver);
        receivedERC20.approve(address(ics20Transfer), defaultAmount);

        IICS26RouterMsgs.Packet memory outboundPacket = _sendICS20TransferPacket(
            middleReceiverStr, "whatever", address(receivedERC20), defaultAmount, chainCClientID
        );
        assertEq(outboundPacket.sourceClient, chainCClientID);
        assertEq(receivedERC20.balanceOf(middleReceiver), 0);
        assertEq(receivedERC20.balanceOf(ics20Transfer.escrow()), defaultAmount);

        // Receive back
        string memory returningDenom = string(
            abi.encodePacked(outboundPacket.payloads[0].destPort, "/", outboundPacket.destClient, "/", receivedDenom)
        );

        (IERC20 returnedERC20, string memory returnedDenom,) =
            _receiveICS20Transfer("chain_c_sender", middleReceiverStr, returningDenom, defaultAmount, chainCClientID);
        assertEq(returnedDenom, receivedDenom);
        assertEq(address(returnedERC20), address(receivedERC20));
        assertEq(returnedERC20.totalSupply(), defaultAmount);
        assertEq(returnedERC20.balanceOf(middleReceiver), defaultAmount);
    }

    function test_success_receiveICS20PacketAsMiddleChainWithAnAddressAsBaseDenom() public {
        // The scenario we are testing is where another chain sends us a token with an address as the base denom
        // We want to make sure we create a new IBCERC20 token, and when sending out, we pick the correct contract
        // address
        string memory someRandomERC20Str = Strings.toHexString(address(new TestERC20()));

        // Create a secondary client to send out to a different chain
        string memory chainCClientID = ics26Router.addClient(
            "07-tendermint", IICS02ClientMsgs.CounterpartyInfo(counterpartyId, merklePrefix), address(lightClient)
        );

        string memory foreignDenom = someRandomERC20Str;

        address middleReceiver = makeAddr("middle_receiver");
        string memory middleReceiverStr = Strings.toHexString(middleReceiver);

        // Receive
        (IERC20 receivedERC20, string memory receivedDenom,) =
            _receiveICS20Transfer("chain_a_sender", middleReceiverStr, foreignDenom);

        // Send out
        vm.prank(middleReceiver);
        receivedERC20.approve(address(ics20Transfer), defaultAmount);

        IICS26RouterMsgs.Packet memory outboundPacket = _sendICS20TransferPacket(
            middleReceiverStr, "chain_c_receiver", address(receivedERC20), defaultAmount, chainCClientID
        );
        assertEq(outboundPacket.sourceClient, chainCClientID);
        assertEq(receivedERC20.balanceOf(middleReceiver), 0);
        assertEq(receivedERC20.balanceOf(ics20Transfer.escrow()), defaultAmount);

        // Receive back
        string memory returningDenom = string(
            abi.encodePacked(outboundPacket.payloads[0].destPort, "/", outboundPacket.destClient, "/", receivedDenom)
        );

        (IERC20 returnedERC20, string memory returnedDenom,) =
            _receiveICS20Transfer("chain_c_sender", middleReceiverStr, returningDenom, defaultAmount, chainCClientID);
        assertEq(returnedDenom, receivedDenom);
        assertEq(address(returnedERC20), address(receivedERC20));
        assertEq(returnedERC20.totalSupply(), defaultAmount);
        assertEq(returnedERC20.balanceOf(middleReceiver), defaultAmount);
    }

    function test_failure_receiveICS20PacketHasTimedOut() public {
        erc20.mint(defaultSender, defaultAmount);
        vm.prank(defaultSender);
        erc20.approve(address(ics20Transfer), defaultAmount);

        IICS26RouterMsgs.Packet memory packet =
            _sendICS20TransferPacket(defaultSenderStr, defaultReceiverStr, address(erc20));

        IICS26RouterMsgs.MsgAckPacket memory ackMsg = IICS26RouterMsgs.MsgAckPacket({
            packet: packet,
            acknowledgement: ICS20Lib.SUCCESSFUL_ACKNOWLEDGEMENT_JSON,
            proofAcked: bytes("doesntmatter"), // dummy client will accept
            proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // dummy client will accept
         });

        ics26Router.ackPacket(ackMsg);

        // commitment should be deleted
        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(packet.sourceClient, packet.sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, 0);

        uint256 senderBalanceAfterSend = erc20.balanceOf(defaultSender);
        assertEq(senderBalanceAfterSend, 0);
        uint256 contractBalanceAfterSend = erc20.balanceOf(ics20Transfer.escrow());
        assertEq(contractBalanceAfterSend, defaultAmount);

        // Send back
        string memory receiverStr = defaultSenderStr;

        string memory denom =
            string(abi.encodePacked(packet.payloads[0].destPort, "/", packet.destClient, "/", erc20AddressStr));

        IICS20TransferMsgs.FungibleTokenPacketData memory receivePacketData =
            _getPacketData("cosmos1mhmwgrfrcrdex5gnr0vcqt90wknunsxej63feh", receiverStr, denom);
        uint64 timeoutTimestamp = uint64(block.timestamp - 1);
        IICS26RouterMsgs.Payload[] memory payloads = _getPayloads(abi.encode(receivePacketData));
        packet = IICS26RouterMsgs.Packet({
            sequence: 1,
            sourceClient: counterpartyId,
            destClient: clientIdentifier,
            timeoutTimestamp: timeoutTimestamp,
            payloads: payloads
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IICS26RouterErrors.IBCInvalidTimeoutTimestamp.selector, packet.timeoutTimestamp, block.timestamp
            )
        );
        ics26Router.recvPacket(
            IICS26RouterMsgs.MsgRecvPacket({
                packet: packet,
                proofCommitment: bytes("doesntmatter"), // dummy client will accept
                proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // will accept
             })
        );
    }

    function _sendICS20TransferPacket(
        string memory sender,
        string memory receiver,
        address denom
    )
        internal
        returns (IICS26RouterMsgs.Packet memory)
    {
        return _sendICS20TransferPacket(sender, receiver, denom, defaultAmount, clientIdentifier);
    }

    function _sendICS20TransferPacket(
        string memory sender,
        string memory receiver,
        address denom,
        uint256 amount,
        string memory sourceClient
    )
        internal
        returns (IICS26RouterMsgs.Packet memory)
    {
        uint64 timeoutTimestamp = uint64(block.timestamp + 1000);

        IICS20TransferMsgs.SendTransferMsg memory msgSendTransfer = IICS20TransferMsgs.SendTransferMsg({
            denom: denom,
            amount: amount,
            receiver: receiver,
            sourceClient: sourceClient,
            destPort: ICS20Lib.DEFAULT_PORT_ID,
            timeoutTimestamp: timeoutTimestamp,
            memo: "memo"
        });

        vm.recordLogs();
        vm.prank(ICS20Lib.mustHexStringToAddress(sender));
        uint32 sequence = ics20Transfer.sendTransfer(msgSendTransfer);

        IICS26RouterMsgs.Packet memory packet = _getPacketFromSendEvent();

        bytes32 path = ICS24Host.packetCommitmentKeyCalldata(sourceClient, sequence);
        bytes32 storedCommitment = ics26Router.getCommitment(path);
        assertEq(storedCommitment, ICS24Host.packetCommitmentBytes32(packet));

        return packet;
    }

    function _getPacketData(
        string memory sender,
        string memory receiver,
        string memory denom
    )
        internal
        view
        returns (IICS20TransferMsgs.FungibleTokenPacketData memory)
    {
        return _getPacketData(sender, receiver, denom, defaultAmount);
    }

    function _getPacketData(
        string memory sender,
        string memory receiver,
        string memory denom,
        uint256 amount
    )
        internal
        pure
        returns (IICS20TransferMsgs.FungibleTokenPacketData memory)
    {
        return IICS20TransferMsgs.FungibleTokenPacketData({
            denom: denom,
            amount: amount,
            sender: sender,
            receiver: receiver,
            memo: "memo"
        });
    }

    function _receiveICS20Transfer(
        string memory sender,
        string memory receiver,
        string memory denom
    )
        internal
        returns (IERC20 receivedERC20, string memory receivedDenom, IICS26RouterMsgs.Packet memory receivePacket)
    {
        return _receiveICS20Transfer(sender, receiver, denom, defaultAmount, clientIdentifier);
    }

    function _receiveICS20Transfer(
        string memory sender,
        string memory receiver,
        string memory denom,
        uint256 amount,
        string memory destClient
    )
        internal
        returns (IERC20 receivedERC20, string memory receivedDenom, IICS26RouterMsgs.Packet memory receivePacket)
    {
        IICS20TransferMsgs.FungibleTokenPacketData memory receivePacketData = IICS20TransferMsgs.FungibleTokenPacketData({
            denom: denom,
            amount: amount,
            sender: sender,
            receiver: receiver,
            memo: "memo"
        });

        IICS26RouterMsgs.Payload[] memory payloads = _getPayloads(abi.encode(receivePacketData));
        receivePacket = IICS26RouterMsgs.Packet({
            sequence: 1,
            sourceClient: counterpartyId,
            destClient: destClient,
            timeoutTimestamp: uint64(block.timestamp + 1000),
            payloads: payloads
        });

        bytes memory denomBz = bytes(denom);
        bytes memory prefix = abi.encodePacked(payloads[0].sourcePort, "/", receivePacket.sourceClient, "/");
        string memory expectedDenom;
        if (ICS20Lib.hasPrefix(denomBz, prefix)) {
            expectedDenom = string(Bytes.slice(denomBz, prefix.length));
        } else {
            bytes memory newDenomPrefix = abi.encodePacked(payloads[0].destPort, "/", receivePacket.destClient, "/");
            expectedDenom = string(abi.encodePacked(newDenomPrefix, denomBz));
        }

        vm.expectEmit();
        emit IICS26Router.RecvPacket(receivePacket);

        ics26Router.recvPacket(
            IICS26RouterMsgs.MsgRecvPacket({
                packet: receivePacket,
                proofCommitment: bytes("doesntmatter"), // dummy client will accept
                proofHeight: IICS02ClientMsgs.Height({ revisionNumber: 1, revisionHeight: 42 }) // will accept
             })
        );

        // Check that the ack is written
        bytes32 storedAck = ics26Router.getCommitment(
            ICS24Host.packetAcknowledgementCommitmentKeyCalldata(receivePacket.destClient, receivePacket.sequence)
        );
        assertEq(storedAck, ICS24Host.packetAcknowledgementCommitmentBytes32(singleSuccessAck));

        try ics20Transfer.ibcERC20Contract(expectedDenom) returns (address ibcERC20Addres) {
            receivedERC20 = IERC20(ibcERC20Addres);

            IBCERC20 ibcERC20 = IBCERC20(ibcERC20Addres);
            string memory actualDenom = ibcERC20.fullDenomPath();
            assertEq(actualDenom, expectedDenom);
        } catch {
            // base must be an erc20 address then
            receivedERC20 = IERC20(ICS20Lib.mustHexStringToAddress(expectedDenom));
        }
        receivedDenom = expectedDenom;

        return (receivedERC20, receivedDenom, receivePacket);
    }

    function _getPayloads(bytes memory data) internal pure returns (IICS26RouterMsgs.Payload[] memory) {
        IICS26RouterMsgs.Payload[] memory payloads = new IICS26RouterMsgs.Payload[](1);
        payloads[0] = IICS26RouterMsgs.Payload({
            sourcePort: ICS20Lib.DEFAULT_PORT_ID,
            destPort: ICS20Lib.DEFAULT_PORT_ID,
            version: ICS20Lib.ICS20_VERSION,
            encoding: ICS20Lib.ICS20_ENCODING,
            value: data
        });
        return payloads;
    }

    function _getPacketFromSendEvent() internal returns (IICS26RouterMsgs.Packet memory) {
        Vm.Log[] memory sendEvent = vm.getRecordedLogs();
        for (uint256 i = 0; i < sendEvent.length; i++) {
            Vm.Log memory log = sendEvent[i];
            for (uint256 j = 0; j < log.topics.length; j++) {
                if (log.topics[j] == IICS26Router.SendPacket.selector) {
                    return abi.decode(log.data, (IICS26RouterMsgs.Packet));
                }
            }
        }
        // solhint-disable-next-line gas-custom-errors
        revert("SendPacket event not found");
    }
}
