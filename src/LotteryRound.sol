// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { StakingInterface } from "./interfaces/StakingInterface.sol";
import { LotteryBet } from "./LotteryBet.sol";
import { VRFConsumerBaseV2Plus } from "@chainlink/contracts/vrf/dev/VRFConsumerBaseV2Plus.sol";
import { IVRFCoordinatorV2Plus } from "@chainlink/contracts/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import { Lottery } from "./Lottery.sol";
import { Library } from "./Library.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { VRFV2PlusClient } from "@chainlink/contracts/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * Errors:
 * LR01: Bitmap already registered
 * LR02: Round is closed
 * LR03: Invalid finish
 * LR04: Insufficient balance
 * LR05: Invalid request period
 * LR06: Round is open
 * LR07: Request failed
 * LR08: Request period has passed
 * LR09: Invalid status
 * LR10: Invalid offset or limit
 * LR11: Transfer failed
 * LR12: invalidat round status to request
 * LR13: could not restart request - conditions are not met
 * LR14: could not recover funds - conditions are not met
 */
contract LotteryRound is VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;

    uint256 public constant REQUEST_PERIOD = 1 hours;
    uint256 public constant RECOVER_PERIOD = 36 hours;

    uint256 private immutable subscriptionId;
    bytes32 private immutable keyHash;
    IVRFCoordinatorV2Plus private immutable coordinator;
    Lottery private immutable lottery;
    uint256 public immutable ticketPrice;

    mapping(bytes bitmap => address bet) public bitmaps;

    uint256 private betsCount;
    uint256 private ticketsCount;
    uint256 private betsClaimed;
    uint256 private finish;

    Library.Ticket public winTicket;

    bool public jackpotWon = false;

    address[] private bets;

    /*
    * Status:
    * 1 - betting
    * 2 - pending
    * 3 - done
    * 4 - claiming
    * 5 - waiting for request
    * 6 - refund
    */
    uint8 private status;
    uint256 private requestId;
    uint256 public requestedTime;

    event RoundRequested(uint256 indexed requestId);
    event RoundFinished(Library.Ticket winTicket);
    event TicketClaimed(address indexed bet);
    event TicketSold(address indexed bet, uint256 amount);
    event RefundInitiated();
    event RecoverInitiated();
    event FinishUpdated(uint256 indexed finish);

    constructor(
        address _lottery,
        uint256 _finish,
        address _coordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint256 _ticketPrice
    )
        VRFConsumerBaseV2Plus(_coordinator)
    {
        require(_finish > block.timestamp, "LR03");
        finish = _finish;
        lottery = Lottery(_lottery);
        subscriptionId = _subscriptionId;
        coordinator = IVRFCoordinatorV2Plus(_coordinator);
        keyHash = bytes32(_keyHash);
        status = 1;
        ticketPrice = _ticketPrice;
    }

    function registerBet(address _bet) external onlyOwner {
        // check if the round is still open
        require(isOpen(), "LR02");
        // get bet from address
        LotteryBet bet = LotteryBet(_bet);
        // extract tickets from bet
        bytes[] memory _bitmaps = bet.getTickets();
        // save count for gas cost
        uint256 count = _bitmaps.length;
        // check validity of the tickets
        for (uint256 i = 0; i < count; i++) {
            // validate if ticket is empty
            require(isBitmapEmpty(_bitmaps[i]), "LR01");
            // save bitmap
            bitmaps[_bitmaps[i]] = _bet;
        }
        // update ticket counter
        ticketsCount += count;
        // update bet counter
        betsCount++;
        // push bet to bets
        bets.push(_bet);
        // check balance of round - should not happen, but anyway
        require(IERC20(lottery.getToken()).balanceOf(address(this)) >= ticketsCount * ticketPrice, "LR04");
		// emit event
		emit TicketSold(_bet, ticketsCount * ticketPrice);
    }

    function editTickets(address _bet, Library.Ticket[] memory _tickets) external onlyOwner {
        // check if round is closed
        require(status == 1, "LR02");
        // get bet contract
        LotteryBet bet = LotteryBet(_bet);
        // get old tickets
        bytes[] memory oldTickets = bet.getTickets();
        require(oldTickets.length == _tickets.length, "LR01");
        // remove old bitmaps
        for (uint256 i = 0; i < oldTickets.length; i++) {
            // get bitmap
            bytes memory bitmap = oldTickets[i];
            // check if bitmap is empty
            require(!isBitmapEmpty(bitmap), "LR01");
            // remove bitmap
            delete bitmaps[bitmap];
        }
        // interate over tickets and save new bitmaps
        for (uint256 i = 0; i < _tickets.length; i++) {
            // get bitmap
            bytes memory bitmap = abi.encode(_tickets[i].symbol, _tickets[i].numbers);
            // check if bitmap is empty
            require(isBitmapEmpty(bitmap), "LR01");
            // save bitmap
            bitmaps[bitmap] = _bet;
        }
    }

    function requestRandomness() external {
        require(!StakingInterface(lottery.getStaking()).isCalculation(), "LT10");
        // check if the round is closed
        require(!isOpen(), "LR06");
        // check if the request period has passed
        require(block.timestamp < finish + REQUEST_PERIOD, "LR05");
        // check that round status is correct
        require(getStatus() == 5, "LR12");
        // check if there are bets
        require(betsCount > 0, "LR15");
        // calculate the amount to reserve
        uint256 toReserve = ticketPrice * lottery.MAX_SHARES();
        // reserve funds
        lottery.reserveFunds(toReserve);
        // update status
        status = 2;
        _requestRandomness();
    }

    function _requestRandomness() internal {
        requestedTime = block.timestamp;
        // request randomness
        requestId = coordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: 20,
                callbackGasLimit: 2_500_000,
                numWords: 6,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({ nativePayment: true }))
            })
        );
        // check if request failed
        require(requestId > 0, "LR07");
        // emit event
        emit RoundRequested(requestId);
    }

    function processJackpot() external {
        require(status == 3, "LR09");
        // update status
        status = 4;
        // get jackpot ticket bitmap
        bytes memory winMap = abi.encode(winTicket.symbol, winTicket.numbers);
        // calculate 4% of bets
        uint256 jackpot = ticketsCount * ticketPrice * 4 / 100;
        // send jackpot to lottery
        require(IERC20(lottery.getToken()).transfer(address(lottery), jackpot), "LR11");
        // update jackpot
        lottery.updateJackpot(jackpot);
        // check if jackpot ticket is registered
        if (!isBitmapEmpty(winMap)) {
            // check if jackpot is won - symbol unlocked
            LotteryBet winBet = LotteryBet(bitmaps[winMap]);
            if (winBet.isSymbolUnlocked()) {
                // mark as jackpot won
                jackpotWon = true;
                // claim jackpot
                lottery.claim(LotteryBet(bitmaps[winMap]).getTokenId());
            }
        }
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        // check request id
        require(_requestId == requestId, "LR07");
        // check status
        require(getStatus() == 2, "LR07");
        // update status
        status = 3;

        // Generate an array of numbers from 1 to 25
        uint32[] memory pool = new uint32[](25);
        for (uint32 i = 0; i < 25; i++) {
            pool[i] = i + 1;
        }

        // Shuffle the pool using Fisher-Yates algorithm
        for (uint32 i = 0; i < 5; i++) {
            uint256 randomIndex = uint256(_randomWords[i % _randomWords.length] % (25 - i)) + i;
            // Swap the numbers
            (pool[i], pool[randomIndex]) = (pool[randomIndex], pool[i]);
        }

        // Select the first 5 numbers
        uint32 numbers = 0;
        for (uint256 i = 0; i < 5; i++) {
            numbers |= (uint32(1) << pool[i]);
        }

        uint8 symbol = uint8(_randomWords[5] % 5 + 1);
        winTicket = Library.Ticket({ numbers: numbers, symbol: symbol });
        // emit event
        emit RoundFinished(winTicket);
    }

    function isOpen() public view returns (bool) {
        return block.timestamp < finish;
    }

    function getTicketsCount() external view returns (uint256) {
        return ticketsCount;
    }

    function getBetsCount() external view returns (uint256) {
        return betsCount;
    }

    function getFinish() external view returns (uint256) {
        return finish;
    }

    function getBet(bytes calldata bitmap) external view returns (address) {
        return bitmaps[bitmap];
    }

    function isBitmapEmpty(bytes memory bitmap) public view returns (bool) {
        return bitmaps[bitmap] == address(0);
    }

    function startRefund() external {
        // check if the round is closed
        require(!isOpen(), "LR06");
        // check if the request period has passed
        require(block.timestamp >= finish + REQUEST_PERIOD, "LR08");
        // check if the round is pending
        require(status == 1, "LR06");
        // update status
        status = 6;
        emit RefundInitiated();
    }

    function startRecover() external {
        // check if the round is closed
        require(!isOpen(), "LR06");
        // check if the request period has passed
        require(block.timestamp >= requestedTime + RECOVER_PERIOD, "LR14");
        // check if the round is pending
        require(status == 2, "LR06");
        // update status
        status = 6;
        // return funds to staking
        lottery.refund(ticketPrice * lottery.MAX_SHARES());
        emit RecoverInitiated();
    }

    function refund(uint256 offset, uint256 limit) external {
        // check is round is in refund mode
        require(status == 6, "LR09");
        // check if offset and limit are valid
        require(offset + limit <= betsCount, "LR10");
        // iterate over bets
        for (uint256 i = offset; i < offset + limit; i++) {
            // get bet address
            address bet = bets[i];
            // get bet contract
            LotteryBet betContract = LotteryBet(bet);
            // transfer tokens back to player
            IERC20(lottery.getToken()).transfer(betContract.getPlayer(), ticketPrice * betContract.getTicketsCount());
            // set bet as refunded
            betContract.refund();
        }
    }

    function updateFinish(uint256 _finish) external onlyOwner {
        // check if already finished
        require(isOpen(), "LR02");
        // check if round is open
        require(status == 1, "LR02");
        // new finish must be in future
        require(block.timestamp < _finish, "LR03");
        // new finish must be greater than current finish
        require(_finish > finish, "LR03");
        // update finish
        finish = _finish;
        // emit event
        emit FinishUpdated(_finish);
    }

    function getStatus() public view returns (uint8) {
        if (!isOpen() && status == 1) {
            return 5;
        }
        return status;
    }

    function claim(address _bet) external onlyOwner returns (bool) {
        // update counter
        betsClaimed++;
        // get bet from address
        LotteryBet bet = LotteryBet(_bet);
        // calculate amount to send
        uint256 amountToSend = ticketPrice * bet.getTicketsCount() * 96 / 100;
        // send tokens - 4% to staking
        IERC20(lottery.getToken()).transfer(lottery.getStaking(), amountToSend);
        // emit event
        emit TicketClaimed(_bet);
        // return true if all tickets are claimed
        return betsClaimed == betsCount;
    }
}
