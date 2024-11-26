// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.25;

import { BetInterface } from "./interfaces/BetInterface.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Library } from "./Library.sol";

contract LotteryBet is BetInterface, Ownable {
    bytes32 public constant LOTTERY = keccak256("LOTTERY");

    uint256 private immutable created;
    uint256 private immutable amount;
    address private immutable game;
    uint256 private immutable tokenId; // tokenId of Lottery{ERC721}

    uint256 private status; // 1 - created, 2 - win, 3 - lose, 4 - refund
    uint256 private result;
    address private player;
    Library.Ticket[] private tickets;

    bool private symbolUnlocked = false;

    event PlayerChanged(address indexed player);

    constructor(address _player, uint256 _amount, address _game, uint256 _tokenId) Ownable(_msgSender()) {
        player = _player;
        amount = _amount;
        status = 1;
        game = _game;
        tokenId = _tokenId;
        created = block.timestamp;
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

    function getTickets() external view returns (bytes[] memory) {
        bytes[] memory _tickets = new bytes[](tickets.length);
        for (uint256 i = 0; i < tickets.length; i++) {
            _tickets[i] = abi.encode(tickets[i]);
        }
        return _tickets;
    }

    function setTickets(Library.Ticket[] memory _tickets) external onlyOwner {
        for (uint256 i = 0; i < _tickets.length; i++) {
            tickets.push(_tickets[i]);
        }
        if (tickets.length >= 3) {
            symbolUnlocked = true;
        }
    }

    function changePlayer(address _player) external onlyOwner {
        player = _player;
        emit PlayerChanged(_player);
    }
}