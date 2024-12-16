// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.25;

import { BetInterface } from "./interfaces/BetInterface.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Library } from "./Library.sol";

/**
 * Error codes:
 * LB02: address is zero
 */
contract LotteryBet is BetInterface, AccessControl {
    bytes32 public constant LOTTERY = keccak256("LOTTERY");
    bytes32 public constant ROUND = keccak256("ROUND");

    uint256 private immutable created;
    uint256 private immutable amount;
    address private immutable game;
    uint256 private immutable tokenId; // tokenId of Lottery{ERC721}
    address private immutable round;

    uint256 private status; // 1 - created, 2 - win, 3 - lose, 4 - refund
    uint256 private result;
    address private player;

    bool private claimed = false;
    Library.Ticket[] private tickets;
    uint256 private ticketsCount = 0;

    bool private symbolUnlocked = false;

    event PlayerChanged(address indexed player);

    constructor(address _player, uint256 _amount, address _game, uint256 _tokenId, address _round) {
        require(_player != address(0), "LB02");
        require(_round != address(0), "LB02");
        require(_game != address(0), "LB02");
        player = _player;
        amount = _amount;
        status = 1;
        game = _game;
        tokenId = _tokenId;
        created = block.timestamp;
        round = _round;
        _grantRole(LOTTERY, _game);
        _grantRole(ROUND, _round);
    }
    /**
     * @return player - address of player
     */

    function getPlayer() external view override returns (address) {
        return player;
    }

    /**
     * @return amount - amount of bet
     */
    function getAmount() external view override returns (uint256) {
        return amount;
    }

    /**
     * @return result - amount of payout
     */
    function getResult() external view override returns (uint256) {
        return result;
    }

    /**
     * @return status - status of bet
     */
    function getStatus() external view override returns (uint256) {
        return status;
    }

    /**
     * @return game - address of game
     */
    function getGame() external view override returns (address) {
        return game;
    }

    /**
     * @return timestamp - created timestamp of bet
     */
    function getCreated() external view override returns (uint256) {
        return created;
    }

    /**
     * @return data - all data at once (player, game, amount, result, status, created)
     */
    function getBetInfo() external view override returns (address, address, uint256, uint256, uint256, uint256) {
        return (player, game, amount, result, status, created);
    }

    /**
     * @return tokenId - tokenId of Lottery{ERC721}
     */
    function getTokenId() external view returns (uint256) {
        return tokenId;
    }

    function getRound() external view returns (address) {
        return round;
    }

    function getClaimed() external view returns (bool) {
        return claimed;
    }

    function getTickets() external view returns (bytes[] memory) {
        bytes[] memory _tickets = new bytes[](ticketsCount);
        for (uint256 i = 0; i < ticketsCount; i++) {
            _tickets[i] = abi.encode(tickets[i].symbol, tickets[i].numbers);
        }
        return _tickets;
    }

    function setTickets(Library.Ticket[] memory _tickets) external onlyRole(LOTTERY) {
        delete tickets;
        ticketsCount = _tickets.length;
        for (uint256 i = 0; i < ticketsCount; i++) {
            tickets.push(_tickets[i]);
        }
        if (ticketsCount >= 3) {
            symbolUnlocked = true;
        }
    }

    function setResult(uint256 _result) external onlyRole(LOTTERY) {
        result = _result;
        if (result > 0) {
            status = 2;
        } else {
            status = 3;
        }
        claimed = true;
    }

    function refund() external onlyRole(ROUND) {
        require(status == 1, "LB01");
        status = 4;
        claimed = true;
    }

    function calculateResult(Library.Ticket memory _winTicket) external view returns (uint256 coef, bool jackpot) {
        // iterate over tickets and check if any of them is a win
        for (uint256 i = 0; i < ticketsCount; i++) {
            uint256 ticketCoef = Library.compare(tickets[i], _winTicket, symbolUnlocked);
            if (ticketCoef == 33_334) {
                jackpot = true;
            }
            coef += ticketCoef;
        }
        return (coef, jackpot);
    }

    function changePlayer(address _player) external onlyRole(LOTTERY) {
        require(_player != address(0), "LB02");
        player = _player;
        emit PlayerChanged(_player);
    }

    function getTicketsCount() external view returns (uint256) {
        return ticketsCount;
    }

    function isSymbolUnlocked() external view returns (bool) {
        return symbolUnlocked;
    }
}
