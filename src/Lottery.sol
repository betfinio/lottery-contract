// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { GameInterface } from "./interfaces/GameInterface.sol";
import { StakingInterface } from "./interfaces/StakingInterface.sol";
import { CoreInterface } from "./interfaces/CoreInterface.sol";
import { LotteryBet } from "./LotteryBet.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { LotteryRound } from "./LotteryRound.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Metadata } from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC721Enumerable } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import { ERC721URIStorage } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Library } from "./Library.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IVRFCoordinatorV2Plus } from "@chainlink/contracts/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/**
 * Errors:
 * LT01: Invalid tickets count
 * LT02: Invalid round
 * LT03: Invalid amount for tickets
 * LT04: Invalid sender,
 * LT05: Transfer failed
 * LT06: Error with chainlink subscription
 * LT07: Invalid ticket
 * LT08: Invalid claimer
 * LT09: Already claimed
 * LT10: Calculation time
 * LT11: Invalid id
 * LT12: Invalid round status to claim
 * LT13: Invalid round status to remove
 */
contract Lottery is GameInterface, AccessControl, ERC721, ERC721Enumerable, ERC721URIStorage {
    using SafeERC20 for IERC20;

    bytes32 public constant SERVICE = keccak256("SERVICE");
    bytes32 public constant ROUND = keccak256("ROUND");
    bytes32 public constant CORE = keccak256("CORE");

    uint256 public constant MAX_TICKETS_PER_BET = 9;
    uint256 public constant MAX_SHARES = 188_500;
    uint256 public ticketPrice = 1500 ether;

    uint256 private immutable created;
    IVRFCoordinatorV2Plus private immutable coordinator;
    bytes32 private immutable keyHash;
    StakingInterface private staking;
    CoreInterface private core;
    ERC20 private token;

    uint256 public additionalJackpot;
    uint256 public subscriptionId;

	string public uri;

    mapping(address round => bool exists) public rounds;
    mapping(uint256 tokenId => address bet) public bets;
    mapping(address round => uint256 claimed) private claimedByRound;

    event RoundCreated(address indexed round, uint256 indexed timestamp);
    event RoundFinished(address indexed round);
    event JackpotWon(address indexed round, uint256 indexed amount);
    event TicketsEdited(uint256 indexed id, address indexed bet);

    constructor(
        address _staking,
        address _core,
        address _service,
        address _coordinator,
        bytes32 _keyHash,
        address admin
    )
        ERC721("Betfin Lottery Ticket", "BLT")
    {
        created = block.timestamp;
        staking = StakingInterface(_staking);
        core = CoreInterface(_core);
        token = ERC20(staking.getToken());
        coordinator = IVRFCoordinatorV2Plus(_coordinator);
        subscriptionId = coordinator.createSubscription();
        keyHash = _keyHash;
        require(subscriptionId > 0, "LT06");
        _grantRole(SERVICE, _service);
        _grantRole(CORE, _core);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function placeBet(
        address,
        uint256 amount,
        bytes calldata data
    )
        external
        override
        onlyRole(CORE)
        returns (address betAddress)
    {
        // parse bet information
        (address _round, address _player, uint256 _count, Library.Ticket[] memory _tickets) =
            abi.decode(data, (address, address, uint256, Library.Ticket[]));
        // validate count
        require(_count == _tickets.length, "LT01");
        // validate tickets count
        require(_count <= MAX_TICKETS_PER_BET, "LT01");
        require(_count > 0, "LT01");
        // validate all tickets
        for (uint256 i = 0; i < _count; i++) {
            require(Library.validate(_tickets[i]), "LT07");
        }
        // validate round
        require(rounds[_round], "LT02");
        // get ticket price from round
        uint256 price = LotteryRound(_round).ticketPrice();
        // validate amount
        require(amount == price * _count, "LT03");
        require(amount > 0, "LT03");
        // generate token id
        uint256 tokenId = totalSupply() + 1;
        // create bet contract
        LotteryBet bet = new LotteryBet(_player, amount, address(this), tokenId, _round);
        // mint nft ticket to player
        _safeMint(_player, tokenId);
        // set tickets
        bet.setTickets(_tickets);
        // map bet to token id
        bets[tokenId] = address(bet);
        // send bet amount to round
        require(token.transfer(_round, amount), "LT05");
        // register bet to round
        LotteryRound(_round).registerBet(address(bet));
        // return bet address
        return address(bet);
    }

    function createRound(uint256 _timestamp) external onlyRole(SERVICE) returns (address) {
        // create new round
        LotteryRound round =
            new LotteryRound(address(this), _timestamp, address(coordinator), subscriptionId, keyHash, ticketPrice);
        // register round
        rounds[address(round)] = true;
        // set round as consumer
        coordinator.addConsumer(subscriptionId, address(round));
        // fetch balance of subscription
        (, uint96 nativeBalance,,,) = coordinator.getSubscription(subscriptionId);
        // check funds on subscription - min 1 POL
        require(nativeBalance > 1 ether, "LT06");
        // add role
        _grantRole(ROUND, address(round));
        // emit event
        emit RoundCreated(address(round), _timestamp);
        // return address of the round
        return address(round);
    }

    function removeConsumer(address _round) external onlyRole(SERVICE) {
        require(rounds[_round], "LT02");
        uint256 status = LotteryRound(_round).getStatus();
        require(status == 4 || status == 6, "LT13");
        coordinator.removeConsumer(subscriptionId, address(_round));
        emit RoundFinished(_round);
    }

    function reserveFunds(uint256 amount) external onlyRole(ROUND) {
        require(!staking.isCalculation(), "LT10");
        staking.reserveFunds(amount);
    }

    function updateFinish(address _round, uint256 _finish) external onlyRole(SERVICE) {
        LotteryRound(_round).updateFinish(_finish);
    }

    function getAddress() external view override returns (address gameAddress) {
        return address(this);
    }

    function getVersion() external view override returns (uint256 version) {
        return created;
    }

    function getToken() external view returns (address) {
        return address(token);
    }

    function getFeeType() external pure override returns (uint256 feeType) {
        return 1;
    }

    function getStaking() external view override returns (address) {
        return address(staking);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(ERC721, ERC721Enumerable, AccessControl, ERC721URIStorage)
        returns (bool)
    {
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC721Metadata).interfaceId
            || interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        address from = super._update(to, tokenId, auth);
        if (from != address(0)) {
            // get bet address
            address betAddress = bets[tokenId];
            // get bet contract
            LotteryBet bet = LotteryBet(betAddress);
            // change player
            bet.changePlayer(to);
            // execute parent update
        }
        // return initial from address
        return from;
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function setTicketPrice(uint256 _price) external onlyRole(SERVICE) {
        ticketPrice = _price;
    }

    function updateJackpot(uint256 _jackpot) external onlyRole(ROUND) {
        additionalJackpot += _jackpot;
    }

    function claim(uint256 id) external {
        _claim(id);
    }

    function refund(uint256 amount) external onlyRole(ROUND) {
        token.transfer(address(staking), amount);
    }

    function claimAll(uint256[] calldata ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            _claim(ids[i]);
        }
    }

    function cancelSubscription() external onlyRole(SERVICE) {
        // Cancel the subscription and send the remaining funds to a wallet address.
        coordinator.cancelSubscription(subscriptionId, _msgSender());
        subscriptionId = 0;
    }

    function editTicket(uint256 id, Library.Ticket[] memory _newTickets) external {
        // get bet address
        address betAddress = bets[id];
        // check if bet exists
        require(betAddress != address(0), "LT11");
        // get bet contract
        LotteryBet bet = LotteryBet(betAddress);
        // get count of tickets
        uint256 count = _newTickets.length;
        // check if claimed
        require(!bet.getClaimed(), "LT09");
        // check count of tickets
        require(count == bet.getTicketsCount(), "LT01");
        // check player
        require(bet.getPlayer() == _msgSender(), "LT04");
        // validate all tickets
        for (uint256 i = 0; i < count; i++) {
            require(Library.validate(_newTickets[i]), "LT07");
        }
        // get round address
        address roundAddress = bet.getRound();
        // get round
        LotteryRound round = LotteryRound(roundAddress);
        // edit tickets in round
        round.editTickets(betAddress, _newTickets);
        // set tickets in bet
        bet.setTickets(_newTickets);
        emit TicketsEdited(id, betAddress);
    }

    function _claim(uint256 id) internal {
        // get bet address
        address betAddress = bets[id];
        require(betAddress != address(0), "LT11");
        // get bet contract
        LotteryBet bet = LotteryBet(betAddress);
        // check if claimed
        require(bet.getClaimed() == false, "LT09");
        // get round address
        address roundAddress = bet.getRound();
        // get round contract
        LotteryRound round = LotteryRound(roundAddress);
        // check that round has ended
        require(round.getStatus() == 4, "LT12");
        // get ticket price
        uint256 amount = round.ticketPrice();
        // parse win ticket
        (uint8 _symbol, uint32 numbers) = round.winTicket();
        // calculate win coef
        (uint256 coef, bool jackpot) = bet.calculateResult(Library.Ticket({ symbol: _symbol, numbers: numbers }));
        // calculate win amount
        uint256 winAmount = amount * coef;
        // check if win amount is greater than 0
        if (winAmount > 0) {
            if (jackpot) {
                // transfer jackpot to player
                token.transfer(bet.getPlayer(), winAmount + additionalJackpot);
                // emit Jackpot event
                emit JackpotWon(roundAddress, additionalJackpot);
                // reset additional jackpot
                additionalJackpot = 0;
            } else {
                // transfer win amount to player
                token.transfer(bet.getPlayer(), winAmount);
            }
        }
        // set bet result and status
        bet.setResult(winAmount);
        // increase claimed amount
        claimedByRound[roundAddress] += winAmount;
        // increment claimed tickets
        bool allClaimed = round.claim(betAddress);
        // check if all tickets are claimed
        if (allClaimed) {
            // transfer back to staking =  initial amount - claimed amount
            uint256 toSend = amount * MAX_SHARES - claimedByRound[roundAddress];
            // transfer to staking
            token.transfer(address(staking), toSend);
        }
    }

	function setURI(string memory _uri) external onlyRole(SERVICE) {
		uri = _uri;
	}

    function tokenURI(uint256 tokenId) public view virtual override(ERC721, ERC721URIStorage) returns (string memory) {
		return string.concat(uri, "/", Strings.toString(tokenId), ".json");
    }
}
