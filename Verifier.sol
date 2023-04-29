// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import { VerifRegAPI } from "@zondax/filecoin-solidity/contracts/v0.8/VerifRegAPI.sol";
import { VerifRegTypes } from "@zondax/filecoin-solidity/contracts/v0.8/types/VerifRegTypes.sol";
// import { Client } from "./Client.sol";

contract Verifier {
    
    address public owner;
    CommonTypes.FilAddress addr;
    mapping (address => bool) public addressToStatus;

    
    constructor() {
        owner = msg.sender;
    }

    event verifApplication(
        bytes applicant,
        bool status
    );


    function apply() returns (bytes memory applicant) {
        address memory applicant = bytes(msg.sender);
        return applicant;
        emit verifApplication(applicant, false);
    }

    function verifyClient(bytes memory params) onlyowner {
        bytes memory result = VerifRegAPI.addCustomClient(params);
        if (result != 0) {
            addressToStatus[msg.sender] = true;
        }
        
    }

    function getStatus() returns (bool) {
        bool status = addressToStatus[msg.sender];
        return status;
    }
}

