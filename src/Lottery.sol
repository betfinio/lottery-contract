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
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Library } from "./Library.sol";
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
 */
contract Lottery is GameInterface, AccessControl, ERC721, ERC721Enumerable {
    using SafeERC20 for IERC20;

    bytes32 public constant SERVICE = keccak256("SERVICE");
    bytes32 public constant CORE = keccak256("CORE");

    uint256 public constant TICKET_PRICE = 2500 ether;
    uint256 public constant MAX_TICKETS_PER_BET = 9;

    uint256 public constant BONUS = 500;

    uint256 private immutable created;
    IVRFCoordinatorV2Plus private immutable coordinator;
    bytes32 private immutable keyHash;
    StakingInterface private staking;
    CoreInterface private core;
    ERC20 private token;

    uint256 public subscriptionId;

    mapping(address round => bool exists) private rounds;
    mapping(uint256 tokenId => address bet) private bets;

    event RoundCreated(address indexed round, uint256 indexed timestamp);

    constructor(
        address _staking,
        address _core,
        address _service,
        address _coordinator,
        bytes32 _keyHash
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
        // validate all tickets
        for (uint256 i = 0; i < _count; i++) {
            require(Library.validate(_tickets[i]), "LT07");
        }
        // validate round
        require(rounds[_round], "LT02");
        // validate amount
        require(amount == TICKET_PRICE * _count, "LT03");
        // generate token id
        uint256 tokenId = totalSupply() + 1;
        // create bet contract
        LotteryBet bet = new LotteryBet(_player, amount, address(this), tokenId);
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
        LotteryRound round = new LotteryRound(address(this), _timestamp, address(coordinator), subscriptionId, keyHash);
        // register round
        rounds[address(round)] = true;
        // set round as consumer
        coordinator.addConsumer(subscriptionId, address(round));
        // fetch balance of subscription
        (, uint96 nativeBalance,,,) = coordinator.getSubscription(subscriptionId);
        // check funds on subscription - min 1 POL
        require(nativeBalance > 1 ether, "LT06");
        // emit event
        emit RoundCreated(address(round), _timestamp);
        // return address of the round
        return address(round);
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
        override(ERC721, ERC721Enumerable, AccessControl)
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
}
