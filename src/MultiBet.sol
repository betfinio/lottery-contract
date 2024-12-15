// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./interfaces/PartnerInterface.sol";
import "./Token.sol";

/**
 * Error codes:
 * MB01 - invalid length of input data
 * MB02 - insuficcient balance to make a bet
 */
contract MultiBet is IERC721Receiver {
    Token public token;
    address public core;

    constructor(address _token, address _core) {
        token = Token(_token);
        core = _core;
    }

    function placeBet(address partner, address game, uint256 amount, bytes memory data) public {
        require(token.transferFrom(msg.sender, address(this), amount));
        token.approve(core, amount);
        PartnerInterface(partner).placeBet(game, amount, data);
    }

    function multiPlaceBet(
        address partner,
        address[] calldata games,
        uint256[] calldata amounts,
        bytes[] calldata datas
    )
        public
    {
        require(games.length == amounts.length, "RL01");
        require(games.length == datas.length, "RL01");
        for (uint256 i = 0; i < games.length; i++) {
            placeBet(partner, games[i], amounts[i], datas[i]);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
