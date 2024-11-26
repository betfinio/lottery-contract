// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.25;

/**
 * Error Codes:
 * LB01: Invalid ticket
 */
library Library {
    struct Ticket {
        uint8 symbol; // 1-5
        uint32 numbers; // binary representation of selected numbers, must be selected only 5 numbers
    }
    // 10000100001000010000100000 - selected are: [5,10,15,20,25]
    // 00000000000000000000111110 - selected are: [1,2,3,4,5]
    // 0 - not selected, 1 - selected
    // possible numbers: 1-25

    function validate(Ticket calldata ticket) public pure returns (bool) {
        // validate symbol
        if (ticket.symbol == 0 || ticket.symbol >= 6) {
            return false;
        }
        // validate numbers
        if (ticket.numbers == 0) {
            return false; // 00000000000000000000000001 - selected are: [0] - not possible
        }
        // validate positive bits count
        return countBits(ticket.numbers) == 5;
    }

    function encode(Ticket calldata ticket) public pure returns (bytes memory) {
        bytes memory data = abi.encode(ticket.numbers);
        return data;
    }

    function decode(bytes calldata data) public pure returns (Ticket memory) {
        (uint8 symbol, uint32 numbers) = abi.decode(data, (uint8, uint32));
        return Ticket(symbol, numbers);
    }

    function countBits(uint32 x) public pure returns (uint8) {
        uint8 count = 0;
        // Count the number of 1s in x
        while (x != 0) {
            count += uint8(x & 1); // Increment count if the least significant bit is 1
            x >>= 1; // Shift bits to the right
        }
        return count;
    }
}
