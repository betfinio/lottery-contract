// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { Test } from "forge-std/src/Test.sol";
import { CoreInterface } from "src/interfaces/CoreInterface.sol";
import { PartnerInterface } from "src/interfaces/PartnerInterface.sol";
import { StakingInterface } from "src/interfaces/StakingInterface.sol";
import { PassInterface } from "src/interfaces/PassInterface.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Token } from "src/Token.sol";
import { Lottery } from "src/Lottery.sol";
import { Library } from "src/Library.sol";
import { LotteryBet } from "src/LotteryBet.sol";
import { LotteryRound } from "src/LotteryRound.sol";
import { DynamicStaking } from "./DynamicStaking.sol";
import { IVRFSubscriptionV2Plus } from "@chainlink/contracts/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol";

contract LotteryTest is Test {
    Token public token;
    DynamicStaking public dynamicStaking;
    Lottery public lottery;
    LotteryRound public round;

    address public alice = address(1);
    address public bob = address(2);

    address public core = address(777);
    address public coordinator = address(888);

    function setUp() public virtual {
        token = new Token(address(this));
        dynamicStaking = new DynamicStaking(address(token));
        vm.mockCall(
            address(coordinator),
            abi.encodeWithSelector(IVRFSubscriptionV2Plus.createSubscription.selector),
            abi.encode(5)
        );
        lottery = new Lottery(address(dynamicStaking), core, address(this), address(coordinator), bytes32("0x999"));
        address[] memory consumers = new address[](0);
        vm.mockCall(
            address(coordinator),
            abi.encodeWithSelector(IVRFSubscriptionV2Plus.getSubscription.selector, 5),
            abi.encode(uint96(0), uint96(5 ether), uint64(0), address(lottery), consumers)
        );
        round = LotteryRound(lottery.createRound(block.timestamp + 30 days));
    }

    function placeBet(address _player, address _round, Library.Ticket[] memory _tickets) internal returns (address) {
        uint256 amount = _tickets.length * 2500 ether;
        token.transfer(address(lottery), amount);
        bytes memory data = abi.encode(_round, _player, _tickets.length, _tickets);
        vm.prank(core);
        return lottery.placeBet(_player, amount, data);
    }

    function placeBetFail(
        address _player,
        address _round,
        Library.Ticket[] memory _tickets,
        bytes memory reason
    )
        internal
        returns (address)
    {
        uint256 amount = _tickets.length * 2500 ether;
        token.transfer(address(lottery), amount);
        bytes memory data = abi.encode(_round, _player, _tickets.length, _tickets);
        vm.prank(core);
        vm.expectRevert(reason);
        return lottery.placeBet(_player, amount, data);
    }

    function testPlaceBet_raw() public {
        token.transfer(address(lottery), 2500 ether);
        vm.startPrank(core);
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        bytes memory data = abi.encode(address(round), alice, 1, tickets);
        lottery.placeBet(alice, 2500 ether, data);
        vm.stopPrank();
        assertEq(token.balanceOf(address(lottery)), 0);
        assertEq(token.balanceOf(address(round)), 2500 ether);
        assertEq(round.getBetsCount(), 1);
        assertEq(round.getTicketsCount(), 1);
    }

    function testPlaceBet_oneTicket() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        address bet = placeBet(alice, address(round), tickets);
        assertEq(token.balanceOf(address(lottery)), 0);
        assertEq(token.balanceOf(address(round)), 2500 ether);
        assertEq(round.getBetsCount(), 1);
        assertEq(round.getTicketsCount(), 1);
        assertEq(LotteryBet(bet).getAmount(), 2500 ether);
        assertEq(LotteryBet(bet).getGame(), address(lottery));
        assertEq(LotteryBet(bet).getTokenId(), 1);
    }

    function testPlaceBet_twoTickets() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](2);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        tickets[1] = Library.Ticket(2, 124); // 1 and 00000000000000000001111100
        address bet = placeBet(alice, address(round), tickets);
        assertEq(token.balanceOf(address(lottery)), 0);
        assertEq(token.balanceOf(address(round)), 5000 ether);
        assertEq(round.getBetsCount(), 1);
        assertEq(round.getTicketsCount(), 2);
        assertEq(LotteryBet(bet).getAmount(), 5000 ether);
        assertEq(LotteryBet(bet).getGame(), address(lottery));
        assertEq(LotteryBet(bet).getTokenId(), 1);
    }

    function testPlaceBet_sameTicket() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](2);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        tickets[1] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        placeBetFail(alice, address(round), tickets, bytes("LR01"));
    }

    function testPlaceBet_sameTicket_diffBet() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        placeBet(alice, address(round), tickets);

        assertEq(token.balanceOf(address(lottery)), 0);
        assertEq(token.balanceOf(address(round)), 2500 ether);
        assertEq(round.getBetsCount(), 1);
        assertEq(round.getTicketsCount(), 1);

        placeBetFail(alice, address(round), tickets, bytes("LR01"));
    }

    function testPlaceBet_sameNumbers_diffSymbol() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](2);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        tickets[1] = Library.Ticket(2, 62); // 2 and 00000000000000000000111110
        placeBet(alice, address(round), tickets);

        assertEq(token.balanceOf(address(lottery)), 0);
        assertEq(token.balanceOf(address(round)), 5000 ether);
        assertEq(round.getBetsCount(), 1);
        assertEq(round.getTicketsCount(), 2);
    }

    function testPlaceBet_roundClosed() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        vm.warp(block.timestamp + 31 days);
        placeBetFail(alice, address(round), tickets, bytes("LR02"));
    }

    function testPlaceBet_fuzz(uint8 symbol, uint32 numbers) public {
        vm.assume(symbol >= 1 && symbol <= 5);
        Library.Ticket memory ticket = Library.Ticket(symbol, numbers);
        if (!Library.validate(ticket)) return;
        vm.assume(Library.countBits(numbers) == 5);
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = ticket;
        placeBet(alice, address(round), tickets);
        assertEq(round.getBetsCount(), 1);
        assertEq(round.getTicketsCount(), 1);
    }

    function testTransfer_fails() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.assertEq(lottery.balanceOf(address(alice)), 1);
        vm.assertEq(bet.getPlayer(), alice);
        vm.assertEq(lottery.ownerOf(tokenId), alice);

        vm.startPrank(bob);
        vm.expectRevert();
        lottery.safeTransferFrom(alice, bob, tokenId);
    }

    function testTransfer_success() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.assertEq(lottery.balanceOf(address(alice)), 1);
        vm.assertEq(bet.getPlayer(), alice);
        vm.assertEq(lottery.ownerOf(tokenId), alice);

        vm.startPrank(alice);
        lottery.safeTransferFrom(alice, bob, tokenId);

        vm.assertEq(lottery.balanceOf(address(alice)), 0);
        vm.assertEq(lottery.balanceOf(address(bob)), 1);
        vm.assertEq(bet.getPlayer(), bob);
        vm.assertEq(lottery.ownerOf(tokenId), bob);
    }
}