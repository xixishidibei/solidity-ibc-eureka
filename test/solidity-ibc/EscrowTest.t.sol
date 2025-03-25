// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// solhint-disable max-line-length,gas-custom-errors,multiple-sends

import { Test } from "forge-std/Test.sol";

import { IEscrowErrors } from "../../contracts/errors/IEscrowErrors.sol";
import { IRateLimitErrors } from "../../contracts/errors/IRateLimitErrors.sol";
import { IAccessControl } from "@openzeppelin-contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IICS20Transfer } from "../../contracts/interfaces/IICS20Transfer.sol";

import { Escrow } from "../../contracts/utils/Escrow.sol";
import { UpgradeableBeacon } from "@openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";
import { BeaconProxy } from "@openzeppelin-contracts/proxy/beacon/BeaconProxy.sol";

contract EscrowTest is Test {
    address public rateLimiter = makeAddr("rateLimiter");
    Escrow public escrow;

    function setUp() public {
        // setup code here
        address _escrowLogic = address(new Escrow());
        address escrowBeacon = address(new UpgradeableBeacon(_escrowLogic, address(this)));

        BeaconProxy escrowProxy = new BeaconProxy(escrowBeacon, abi.encodeCall(Escrow.initialize, (address(this))));
        escrow = Escrow(address(escrowProxy));
        assert(escrow.ics20() == address(this));

        // Have admin approval for next call
        vm.mockCall(address(this), IICS20Transfer.isTokenOperator.selector, abi.encode(true));
        // Set rate limiter role
        escrow.grantRateLimiterRole(rateLimiter);
        assertTrue(escrow.hasRole(escrow.RATE_LIMITER_ROLE(), rateLimiter));
    }

    function test_success_setRateLimiterRole() public {
        address newRateLimiter = makeAddr("newRateLimiter");

        vm.mockCall(address(this), IICS20Transfer.isTokenOperator.selector, abi.encode(true));
        escrow.grantRateLimiterRole(newRateLimiter);
        assertTrue(escrow.hasRole(escrow.RATE_LIMITER_ROLE(), newRateLimiter));

        vm.mockCall(address(this), IICS20Transfer.isTokenOperator.selector, abi.encode(true));
        escrow.revokeRateLimiterRole(newRateLimiter);
        assertFalse(escrow.hasRole(escrow.RATE_LIMITER_ROLE(), newRateLimiter));
    }

    function test_failure_setRateLimiterRole() public {
        address newRateLimiter = makeAddr("newRateLimiter");

        vm.mockCall(address(this), IICS20Transfer.isTokenOperator.selector, abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(IEscrowErrors.EscrowUnauthorized.selector, address(this)));
        escrow.grantRateLimiterRole(newRateLimiter);

        vm.mockCall(address(this), IICS20Transfer.isTokenOperator.selector, abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(IEscrowErrors.EscrowUnauthorized.selector, address(this)));
        escrow.revokeRateLimiterRole(rateLimiter);
    }

    function test_success_setRateLimit() public {
        address mockToken = makeAddr("mockToken");
        uint256 rateLimit = 10_000;

        vm.prank(rateLimiter);
        escrow.setRateLimit(mockToken, rateLimit);
        assertEq(escrow.getRateLimit(mockToken), rateLimit);
    }

    function test_failure_setRateLimit() public {
        address mockToken = makeAddr("mockToken");
        uint256 rateLimit = 10_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), escrow.RATE_LIMITER_ROLE()
            )
        );
        escrow.setRateLimit(mockToken, rateLimit);
        assertEq(escrow.getRateLimit(mockToken), 0);
    }

    function test_dailyUsage() public {
        address mockToken = makeAddr("mockToken");

        // Daily usage should not be updated if rate limit is 0
        vm.mockCall(mockToken, IERC20.transferFrom.selector, abi.encode(true));
        escrow.send(IERC20(mockToken), address(this), 10_000);
        assertEq(escrow.getDailyUsage(mockToken), 0);

        escrow.recvCallback(mockToken, address(this), 10_000);
        assertEq(escrow.getDailyUsage(mockToken), 0);

        // Set rate limit and check daily usage
        vm.prank(rateLimiter);
        escrow.setRateLimit(mockToken, 100_000);
        assertEq(escrow.getRateLimit(mockToken), 100_000);

        vm.mockCall(mockToken, IERC20.transferFrom.selector, abi.encode(true));
        escrow.send(IERC20(mockToken), address(this), 1020);
        assertEq(escrow.getDailyUsage(mockToken), 1020);

        escrow.recvCallback(mockToken, address(this), 20);
        assertEq(escrow.getDailyUsage(mockToken), 1000);

        // Next day
        vm.warp(block.timestamp + 1 days);
        assertEq(escrow.getDailyUsage(mockToken), 0);

        vm.mockCall(mockToken, IERC20.transferFrom.selector, abi.encode(true));
        escrow.send(IERC20(mockToken), address(this), 100_000);
        assertEq(escrow.getDailyUsage(mockToken), 100_000);

        escrow.recvCallback(mockToken, address(this), 100_000);
        assertEq(escrow.getDailyUsage(mockToken), 0);

        // next day
        vm.warp(block.timestamp + 1 days);
        assertEq(escrow.getDailyUsage(mockToken), 0);

        escrow.recvCallback(mockToken, address(this), 100_000);
        assertEq(escrow.getDailyUsage(mockToken), 0);

        vm.mockCall(mockToken, IERC20.transferFrom.selector, abi.encode(true));
        escrow.send(IERC20(mockToken), address(this), 100_000);
        assertEq(escrow.getDailyUsage(mockToken), 100_000);

        escrow.recvCallback(mockToken, address(this), 150_000);
        assertEq(escrow.getDailyUsage(mockToken), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_rateLimit(uint8 n) public {
        vm.assume(1 < n);

        address mockToken = makeAddr("mockToken");
        uint256 sendAmount = 10_000;
        uint256 rateLimit = sendAmount * n - 1;

        vm.prank(rateLimiter);
        escrow.setRateLimit(mockToken, rateLimit);

        for (uint256 i = 0; i < n - 1; i++) {
            vm.mockCall(mockToken, IERC20.transferFrom.selector, abi.encode(true));
            escrow.send(IERC20(mockToken), address(this), sendAmount);
            assertEq(escrow.getDailyUsage(mockToken), sendAmount * (i + 1));
        }

        vm.mockCall(mockToken, IERC20.transferFrom.selector, abi.encode(true));
        vm.expectRevert(abi.encodeWithSelector(IRateLimitErrors.RateLimitExceeded.selector, rateLimit, sendAmount * n));
        escrow.send(IERC20(mockToken), address(this), sendAmount);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_sendBackAndForth(uint8 n) public {
        vm.assume(1 < n);

        address mockToken = makeAddr("mockToken");
        uint256 sendAmount = 10_000;
        uint256 rateLimit = sendAmount + 1;

        vm.prank(rateLimiter);
        escrow.setRateLimit(mockToken, rateLimit);

        for (uint256 i = 0; i < n; i++) {
            vm.mockCall(mockToken, IERC20.transferFrom.selector, abi.encode(true));
            escrow.send(IERC20(mockToken), address(this), sendAmount);
            assertEq(escrow.getDailyUsage(mockToken), sendAmount);

            escrow.recvCallback(mockToken, address(this), sendAmount);
            assertEq(escrow.getDailyUsage(mockToken), 0);
        }
    }
}
