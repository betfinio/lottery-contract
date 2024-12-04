// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { GameInterface } from "./interfaces/GameInterface.sol";
import { StakingInterface } from "./interfaces/StakingInterface.sol";
import { LotteryBet } from "./LotteryBet.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { VRFConsumerBaseV2Plus } from "@chainlink/contracts/vrf/dev/VRFConsumerBaseV2Plus.sol";
import { IVRFCoordinatorV2Plus } from "@chainlink/contracts/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import { Lottery } from "./Lottery.sol";
import { Library } from "./Library.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { VRFV2PlusClient } from "@chainlink/contracts/vrf/dev/libraries/VRFV2PlusClient.sol";
import { console } from "forge-std/src/console.sol";

/**
 * Errors:
 * LR01: Bitmap already registered
 * LR02: Round is closed
 * LR03: Invalid finish
 * LR04: Insufficient balance
 * LR05: Invalid request period
 * LR06: Round is open
 * LR07: Request failed
 */
contract LotteryRound is VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;

    uint256 public constant REQUEST_PERIOD = 1 hours;

    uint256 private immutable subscriptionId;
    bytes32 private immutable keyHash;
    IVRFCoordinatorV2Plus private immutable coordinator;

    mapping(bytes bitmap => address bet) public bitmaps;

    uint256 private betsCount;
    uint256 private ticketsCount;
    uint256 private betsClaimed;
    uint256 private finish;
    Lottery private lottery;
    uint256 public ticketPrice;

    Library.Ticket public winTicket;

    /*
    * Status:
    * 1 - betting
    * 2 - pending
    * 3 - done
    * 4 - refund
    * 5 - waiting for request
    */
    uint8 private status;

    uint256 private requestId;

    event RoundRequested(uint256 indexed requestId);
    event RoundFinished(Library.Ticket winTicket);
    event TicketClaimed(address indexed bet);

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
        // check validity of the tickets
        for (uint256 i = 0; i < _bitmaps.length; i++) {
            // validate if ticket is empty
            require(isBitmapEmpty(_bitmaps[i]), "LR01");
            // save bitmap
            bitmaps[_bitmaps[i]] = _bet;
            // update ticket counter
            ticketsCount++;
        }
        // update bet counter
        betsCount++;
        // check balance of round - should not happen, but anyway
        require(IERC20(lottery.getToken()).balanceOf(address(this)) >= ticketsCount * lottery.TICKET_PRICE(), "LR04");
    }

    function requestRandomness() external {
        // check if the round is closed
        require(!isOpen(), "LR06");
        // check if the request period has passed
        require(block.timestamp < finish + REQUEST_PERIOD, "LR05");
        // calculate the amount to reserve
        uint256 toReserve = ticketPrice * lottery.MAX_SHARES();
        // reserve funds
        lottery.reserveFunds(toReserve);
        // update status
        status = 2;
        // request randomness
        requestId = coordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: 3,
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

    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        // check requrst id
        require(_requestId == requestId, "LR07");
        // update status
        status = 3;
        // create result
        uint256 number1 = _randomWords[0] % 25 + 1;
        uint256 number2 = _randomWords[1] % 25 + 1;
        uint256 number3 = _randomWords[2] % 25 + 1;
        uint256 number4 = _randomWords[3] % 25 + 1;
        uint256 number5 = _randomWords[4] % 25 + 1;

        uint8 symbol = uint8(_randomWords[5] % 5 + 1);
        uint32 numbers = uint32(2 ** number1 + 2 ** number2 + 2 ** number3 + 2 ** number4 + 2 ** number5);

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

    function updateFinish(uint256 _finish) external onlyOwner {
        // new finish must be in future
        require(block.timestamp < _finish, "LR03");
        // new finish must be greater than current finish
        require(_finish > finish, "LR03");
        // update finish
        finish = _finish;
    }

    function getStatus() external view returns (uint8) {
        if (!isOpen() && status == 1) {
            return 5;
        }
        return status;
    }

    function claim(address _bet) external onlyOwner returns (bool) {
        // update counter
        betsClaimed++;
        // get bet from address¬
        LotteryBet bet = LotteryBet(_bet);
        // send token to staking
        IERC20(lottery.getToken()).transfer(lottery.getStaking(), ticketPrice * bet.getTicketsCount());
        // emit event
        emit TicketClaimed(_bet);
        // return true if all tickets are claimed
        return betsClaimed == betsCount;
    }
}
