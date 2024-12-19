// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { Test } from "forge-std/src/Test.sol";
import { Token } from "src/Token.sol";
import { Lottery } from "src/Lottery.sol";
import { Library } from "src/Library.sol";
import { LotteryBet } from "src/LotteryBet.sol";
import { LotteryRound } from "src/LotteryRound.sol";
import { DynamicStaking } from "./DynamicStaking.sol";
import { IVRFSubscriptionV2Plus } from "@chainlink/contracts/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol";
import { console } from "forge-std/src/console.sol";
import { IVRFCoordinatorV2Plus } from "@chainlink/contracts/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

contract LotteryClaimTest is Test {
    Token public token;
    DynamicStaking public dynamicStaking;
    Lottery public lottery;
    LotteryRound public round;

    address public alice = address(1);
    address public bob = address(2);

    address public core = address(777);
    address public coordinator = address(888);

    uint256 public ticketPrice;

    uint256 public reserved;

    function setUp() public virtual {
        token = new Token(address(this));
        dynamicStaking = new DynamicStaking(address(token));
        vm.mockCall(
            address(coordinator),
            abi.encodeWithSelector(IVRFSubscriptionV2Plus.createSubscription.selector),
            abi.encode(5)
        );
        lottery = new Lottery(
            address(dynamicStaking), core, address(this), address(coordinator), bytes32("0x999"), address(this)
        );
        address[] memory consumers = new address[](0);
        vm.mockCall(
            address(coordinator),
            abi.encodeWithSelector(IVRFSubscriptionV2Plus.getSubscription.selector, 5),
            abi.encode(uint96(0), uint96(5 ether), uint64(0), address(lottery), consumers)
        );
        round = LotteryRound(lottery.createRound(block.timestamp + 30 days));
        ticketPrice = round.ticketPrice();
        reserved = ticketPrice * lottery.MAX_SHARES();
        token.transfer(address(dynamicStaking), 20_000_000_000 ether);
        dynamicStaking.grantRole(dynamicStaking.TIMELOCK(), address(this));
        dynamicStaking.addGame(address(lottery));
    }

    function placeBet(address _player, address _round, Library.Ticket[] memory _tickets) internal returns (address) {
        uint256 amount = _tickets.length * ticketPrice;
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
        uint256 amount = _tickets.length * ticketPrice;
        token.transfer(address(lottery), amount);
        bytes memory data = abi.encode(_round, _player, _tickets.length, _tickets);
        vm.prank(core);
        vm.expectRevert(reason);
        return lottery.placeBet(_player, amount, data);
    }

    function fulfill(uint32 n1, uint32 n2, uint32 n3, uint32 n4, uint32 n5, uint8 s, address _round) internal {
        vm.mockCall(
            coordinator, abi.encodeWithSelector(IVRFCoordinatorV2Plus.requestRandomWords.selector), abi.encode(555)
        );
        LotteryRound(_round).requestRandomness();
        uint256[] memory randomWords = new uint256[](6);
        randomWords[0] = n1 - 1;
        randomWords[1] = n2 - 1;
        randomWords[2] = n3 - 1;
        randomWords[3] = n4 - 1;
        randomWords[4] = n5 - 1;
        randomWords[5] = s - 1;
        vm.prank(address(coordinator));
        LotteryRound(_round).rawFulfillRandomWords(555, randomWords);
        assertEq(LotteryRound(_round).getStatus(), 3);
    }

    function testSinglePlayer_5numbers_symbolUnlocked() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](3);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        tickets[1] = Library.Ticket(2, 1984); // 2 and 00000000000000011111000000 = [6,7,8,9,10] & 2
        tickets[2] = Library.Ticket(3, 63_488); // 3 and 00000000001111100000000000 = [11,12,13,14,15] & 3
        placeBet(alice, address(round), tickets);
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 1, 1, 1, address(round));
        round.processJackpot();
        (uint8 symbol, uint32 numbers) = round.winTicket();
        assertEq(symbol, 1);
        assertEq(numbers, 62);
        assertEq(token.balanceOf(address(alice)), ticketPrice * 40_000 + (ticketPrice * 3) * 4 / 100);
    }

    function testSinglePlayer_5numbers_symbolLocked() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);

        fulfill(1, 1, 1, 1, 1, 1, address(round));
        round.processJackpot();

        (uint8 symbol, uint32 numbers) = round.winTicket();
        assertEq(symbol, 1);
        assertEq(numbers, 62);

        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();

        assertEq(token.balanceOf(address(alice)), ticketPrice * 15_000);
    }

    function testSinglePlayer_4numbers_symbolUnlocked() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](3);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        tickets[1] = Library.Ticket(2, 1984); // 2 and 00000000000000011111000000 = [6,7,8,9,10] & 2
        tickets[2] = Library.Ticket(3, 63_488); // 3 and 00000000001111100000000000 = [11,12,13,14,15] & 3
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 1, 5, 1, address(round)); //[1,2,3,4,9] & 1
        (, uint32 numbers) = round.winTicket();
        assertEq(numbers, 542);
        round.processJackpot();
        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();
        assertEq(token.balanceOf(address(alice)), ticketPrice * 400);
    }

    function testSinglePlayer_4numbers_symbolLocked() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 1, 5, 1, address(round)); //[1,2,3,4,9] & 1
        round.processJackpot();

        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();
        assertEq(token.balanceOf(address(alice)), ticketPrice * 50);
    }

    function testSinglePlayer_3numbers_symbolUnlocked() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](3);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        tickets[1] = Library.Ticket(2, 1984); // 2 and 00000000000000011111000000 = [6,7,8,9,10] & 2
        tickets[2] = Library.Ticket(3, 63_488); // 3 and 00000000001111100000000000 = [11,12,13,14,15] & 3
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 10, 11, 1, address(round));
        (, uint32 numbers) = round.winTicket();
        assertEq(numbers, 40_974);
        round.processJackpot();

        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();
        assertEq(token.balanceOf(address(alice)), ticketPrice * 5);
    }

    function testSinglePlayer_3numbers_symbolLocked() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 10, 11, 1, address(round));
        (, uint32 numbers) = round.winTicket();
        assertEq(numbers, 40_974); //[1,2,3,13,15]
        round.processJackpot();
        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();
        assertEq(token.balanceOf(address(alice)), ticketPrice * 1);
    }

    function testSinglePlayer_2numbers_symbolUnlocked() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](3);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        tickets[1] = Library.Ticket(2, 1984); // 2 and 00000000000000011111000000 = [6,7,8,9,10] & 2
        tickets[2] = Library.Ticket(3, 63_488); // 3 and 00000000001111100000000000 = [11,12,13,14,15] & 3
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 10, 15, 20, 1, address(round));
        (, uint32 numbers) = round.winTicket();
        assertEq(numbers, 17_043_462); //[1,2,12,18,24]
        round.processJackpot();
        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();
        assertEq(token.balanceOf(address(alice)), ticketPrice * 1);
    }

    function testSinglePlayer_2numbers_symbolLocked() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 10, 15, 20, 1, address(round));
        (, uint32 numbers) = round.winTicket();
        assertEq(numbers, 17_043_462); //[1,2,12,18,24]
        round.processJackpot();
        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();
        assertEq(token.balanceOf(address(alice)), ticketPrice * 0);
    }

    function testSinglePlayer_complex1() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](3);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        tickets[1] = Library.Ticket(1, 94); // 1 and 00000000000000000001011110 = [1,2,3,4,6] & 1
        tickets[2] = Library.Ticket(2, 158); // 2 and 00000000000000000010011110 = [1,2,3,4,7] & 2
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 1, 1, 2, address(round));
        round.processJackpot();
        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();
        assertEq(token.balanceOf(address(alice)), ticketPrice * (50 + 400 + 15_000)); // 4, 4+1, 5
    }

    function testMultiPlayer_complex1() public {
        // alice
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();

        // bob
        Library.Ticket[] memory tickets1 = new Library.Ticket[](3);
        tickets1[0] = Library.Ticket(2, 62); // 2 and 00000000000000000000111110 = [1,2,3,4,5] & 2
        tickets1[1] = Library.Ticket(3, 62); // 3 and 00000000000000000000111110 = [1,2,3,4,5] & 3
        tickets1[2] = Library.Ticket(4, 62); // 4 and 00000000000000000000111110 = [1,2,3,4,5] & 4
        address _bet1 = placeBet(bob, address(round), tickets1);
        LotteryBet bet1 = LotteryBet(_bet1);
        uint256 tokenId1 = bet1.getTokenId();

        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 1, 1, 1, address(round));
        round.processJackpot();

        // alice
        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();
        assertEq(token.balanceOf(address(alice)), ticketPrice * (15_000)); // 5
        // bob
        vm.startPrank(bob);
        lottery.claim(tokenId1);
        vm.stopPrank();
        assertEq(token.balanceOf(address(bob)), ticketPrice * (15_000 * 3)); // 5,5,5
    }

    function testSinglePlayer_fullTicket() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](9);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        tickets[1] = Library.Ticket(1, 1984); // 1 and 00000000000000011111000000 = [6,7,8,9,10] & 1
        tickets[2] = Library.Ticket(1, 63_488); // 1 and 00000000001111100000000000 = [11,12,13,14,15] & 1
        tickets[3] = Library.Ticket(2, 62); // 2 and 00000000000000000000111110 = [1,2,3,4,5] & 2
        tickets[4] = Library.Ticket(2, 1984); // 2 and 00000000000000011111000000 = [6,7,8,9,10] & 2
        tickets[5] = Library.Ticket(2, 63_488); // 2 and 00000000001111100000000000 = [11,12,13,14,15] & 2
        tickets[6] = Library.Ticket(3, 62); // 3 and 00000000000000000000111110 = [1,2,3,4,5] & 3
        tickets[7] = Library.Ticket(4, 1984); // 3 and 00000000000000011111000000 = [6,7,8,9,10] & 3
        tickets[8] = Library.Ticket(3, 63_488); // 3 and 00000000001111100000000000 = [11,12,13,14,15] & 3

        placeBet(alice, address(round), tickets);
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 1, 1, 1, address(round));
        round.processJackpot();

        assertEq(
            token.balanceOf(address(alice)), ticketPrice * (40_000 + 15_000 + 15_000) + (ticketPrice * 9) * 4 / 100
        );
        assertEq(token.balanceOf(address(round)), 0 ether);
        assertEq(token.balanceOf(address(lottery)), 0);
    }

    function testSinglePlayer_cumulateJackpot() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        address _bet = placeBet(alice, address(round), tickets);

        vm.warp(block.timestamp + 30 days + 30 minutes);

        fulfill(1, 1, 1, 1, 1, 1, address(round));
        round.processJackpot();
        assertEq(token.balanceOf(address(alice)), 0);
        assertEq(token.balanceOf(address(round)), ticketPrice * 96 / 100);
        assertEq(token.balanceOf(address(lottery)), ticketPrice * 4 / 100 + reserved);

        address newRound = lottery.createRound(block.timestamp + 30 days);
        Library.Ticket[] memory newTickets = new Library.Ticket[](3);
        newTickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        newTickets[1] = Library.Ticket(2, 62); // 2 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        newTickets[2] = Library.Ticket(3, 62); // 3 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        placeBet(alice, newRound, newTickets);

        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 1, 1, 1, address(newRound));
        LotteryRound(newRound).processJackpot();
        assertEq(token.balanceOf(address(alice)), ticketPrice * (40_000 + 15_000 + 15_000) + 4 * ticketPrice * 4 / 100);
        assertEq(token.balanceOf(address(newRound)), 0);
        assertEq(token.balanceOf(address(lottery)), reserved);

        lottery.claim(LotteryBet(_bet).getTokenId());
        assertEq(token.balanceOf(address(lottery)), 0);
        assertEq(token.balanceOf(address(round)), 0);
        assertEq(
            token.balanceOf(address(alice)),
            ticketPrice * (40_000 + 15_000 + 15_000 + 15_000) + 4 * ticketPrice * 4 / 100
        );
    }

    function testPreClaimIssue() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](3);
        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        tickets[1] = Library.Ticket(2, 1984); // 2 and 00000000000000011111000000 = [6,7,8,9,10] & 2
        tickets[2] = Library.Ticket(3, 63_488); // 3 and 00000000001111100000000000 = [11,12,13,14,15] & 3
        placeBet(alice, address(round), tickets);

        Library.Ticket[] memory tickets1 = new Library.Ticket[](1);
        tickets1[0] = Library.Ticket(2, 94); // 2 and 00000000000000000001011110 = [1,2,3,4,6] & 2
        address _bet1 = placeBet(bob, address(round), tickets1);
        LotteryBet bet1 = LotteryBet(_bet1);
        bet1.getTokenId();

        vm.expectRevert(bytes("LT12"));
        lottery.claim(1);
        // vm.warp(block.timestamp + 30 days + 30 minutes);
        // fulfill(1, 1, 1, 1, 1, 1, address(round));
        // (uint8 symbol, uint32 numbers) = round.winTicket();
        // assertEq(symbol, 1);
        // assertEq(numbers, 62);
        // assertEq(token.balanceOf(address(alice)), ticketPrice * 40000 + (ticketPrice * 4) * 4 / 100);
    }

    function testRemainingTokensInContract() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(1, 62); // 1 and 0000000000000000000111110 = [1,2,3,4,5] & 1
        address _bet = placeBet(alice, address(round), tickets);
        LotteryBet bet = LotteryBet(_bet);
        uint256 tokenId = bet.getTokenId();
        vm.warp(block.timestamp + 30 days + 30 minutes);

        fulfill(1, 1, 1, 1, 1, 1, address(round));
        round.processJackpot();
        assertEq(token.balanceOf(address(lottery)), ticketPrice * lottery.MAX_SHARES() + ticketPrice * 4 / 100);
        assertEq(token.balanceOf(address(round)), ticketPrice - ticketPrice * 4 / 100);
        console.log("After fulfilling, remaining tokens in LotteryRound contract: ", token.balanceOf(address(round)));
        console.log("After fulfilling, remaining tokens in Lottery contract: ", token.balanceOf(address(lottery)));

        (uint8 symbol, uint32 numbers) = round.winTicket();
        assertEq(symbol, 1);
        assertEq(numbers, 62);

        vm.startPrank(alice);
        lottery.claim(tokenId);
        vm.stopPrank();

        console.log("After claiming, remaining tokens in LotteryRound contract: ", token.balanceOf(address(round)));
        console.log("After claiming, remaining tokens in Lottery contract: ", token.balanceOf(address(lottery)));
        console.log("The value of additionalJackpot is: ", lottery.additionalJackpot());

        assertEq(lottery.additionalJackpot(), token.balanceOf(address(lottery)));

        assertEq(token.balanceOf(address(alice)), ticketPrice * 15_000);
    }

    function testEditTicketsDuringWrongStatus() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(2, 1984); // 2 and 00000000000000011111000000 = [6,7,8,9,10] & 2
        placeBet(alice, address(round), tickets);
        vm.warp(block.timestamp + 30 days + 30 minutes);
        fulfill(1, 1, 1, 1, 1, 1, address(round));

        tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
        vm.prank(alice);
        vm.expectRevert(bytes("LR02"));
        lottery.editTicket(1, tickets);

        // round.processJackpot();

        // lottery.claim(1);

        // (uint8 symbol, uint32 numbers) = round.winTicket();
        // assertEq(symbol, 1);
        // assertEq(numbers, 62);
        // assertEq(token.balanceOf(address(alice)), ticketPrice * 15_000);
    }

    function testEditTicketsWithInvalidTicket() public {
        Library.Ticket[] memory tickets = new Library.Ticket[](1);
        tickets[0] = Library.Ticket(2, 1984); // 2 and 00000000000000011111000000 = [6,7,8,9,10] & 2
        placeBet(alice, address(round), tickets);

        tickets[0] = Library.Ticket(1, 67_108_862); // 1 and 11111111111111111111111110 = [1,2,3,4,5] & 1
        vm.prank(alice);
        vm.expectRevert(bytes("LT07"));
        lottery.editTicket(1, tickets);

        // vm.warp(block.timestamp + 30 days + 30 minutes);
        // fulfill(1, 1, 1, 1, 1, 1, address(round));

        // round.processJackpot();

        // lottery.claim(1);

        // (uint8 symbol, uint32 numbers) = round.winTicket();
        // assertEq(symbol, 1);
        // assertEq(numbers, 62);
        // assertEq(token.balanceOf(address(alice)), ticketPrice * 15_000);
    }

    // function testInvalidTicketGenertedByFulfillRandomNumbers() public {
    //     Library.Ticket[] memory tickets = new Library.Ticket[](1);
    //     tickets[0] = Library.Ticket(1, 62); // 1 and 00000000000000000000111110 = [1,2,3,4,5] & 1
    //     placeBet(alice, address(round), tickets);
    //     vm.warp(block.timestamp + 30 days + 30 minutes);
    //     fulfill(24, 24, 24, 24, 24, 1, address(round));

    //     round.processJackpot();

    //     (uint8 symbol, uint32 numbers) = round.winTicket();
    //     console.log("Symbol: ", symbol);
    //     console.log("Numbers: ", numbers);
    //     assertEq(token.balanceOf(address(alice)), 0);
    // }
}
