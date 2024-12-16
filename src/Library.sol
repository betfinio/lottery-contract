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
        // 25 bits set max (2^25 - 1)
        if (ticket.numbers > 0x1FFFFFF) {
            return false;
        }
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

    function countBits(uint32 x) public pure returns (uint8) {
        uint8 count = 0;
        // Count the number of 1s in x
        while (x != 0) {
            count += uint8(x & 1); // Increment count if the least significant bit is 1
            x >>= 1; // Shift bits to the right
        }
        return count;
    }

    /*
    * Function checks if the ticket is a winning ticket
    * @param ticket - ticket to check
    * @param winner - winning ticket
    * @return coefficient of winning
    */
    function compare(Ticket memory ticket, Ticket memory winner, bool symbolUnlocked) external pure returns (uint256) {
        // calculate same bits
        uint256 sameBits = ticket.numbers & winner.numbers;
        // calculate count of same bits
        uint8 count = countBits(uint32(sameBits));

        // 1. check if 5 numbers are same
        if (count == 5) {
            // 1.2. check if symbol is same
            if (ticket.symbol == winner.symbol && symbolUnlocked) {
                return uint256(33_334); // COMBINATION: 5+1
            }
            return uint256(13_334); // COMBINATION: 5
        }
        // 2. check if 4 numbers are same
        if (count == 4) {
            // 2.2. check if symbol is same
            if (ticket.symbol == winner.symbol && symbolUnlocked) {
                return uint256(334); // COMBINATION: 4+1
            }
            return uint256(40); // COMBINATION: 4
        }
        // 3. check if 3 numbers are same
        if (count == 3) {
            // 3.2. check if symbol is same
            if (ticket.symbol == winner.symbol && symbolUnlocked) {
                return uint256(5); // COMBINATION: 3+1
            }
            return uint256(1); // COMBINATION: 3
        }
        // 4. check if 2 numbers are same
        if (count == 2) {
            // 4.2. check if symbol is same
            if (ticket.symbol == winner.symbol && symbolUnlocked) {
                return uint256(1); // COMBINATION: 2+1
            }
        }
        // return 0 if no combination
        return 0;
    }
}
