// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { GameInterface } from "./interfaces/GameInterface.sol";
import { StakingInterface } from "./interfaces/StakingInterface.sol";
import { LotteryBet } from "./LotteryBet.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { VRFConsumerBaseV2Plus } from "@chainlink/contracts/vrf/dev/VRFConsumerBaseV2Plus.sol";
import { IVRFCoordinatorV2Plus } from "@chainlink/contracts/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import { Lottery } from "./Lottery.sol";
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
    uint256 private finish;
    Lottery private lottery;

    constructor(
        address _lottery,
        uint256 _finish,
        address _coordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash
    )
        VRFConsumerBaseV2Plus(_coordinator)
    {
        require(_finish > block.timestamp, "LR03");
        finish = _finish;
        lottery = Lottery(_lottery);
        subscriptionId = _subscriptionId;
        coordinator = IVRFCoordinatorV2Plus(_coordinator);
        keyHash = bytes32(_keyHash);
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
        // request randomness
        coordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: 3,
                callbackGasLimit: 2_500_000,
                numWords: 6,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({ nativePayment: true }))
            })
        );
    }

    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override { }

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
}
