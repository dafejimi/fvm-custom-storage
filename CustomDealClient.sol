/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import { MarketAPI } from "../contracts/customized-solidity-fvm-files/MarketAPI.sol";
import { CommonTypes } from "../contracts/customized-solidity-fvm-files/types/CommonTypes.sol";
import { MarketTypes } from "../contracts/customized-solidity-fvm-files/types/MarketTypes.sol";
import { AccountTypes } from "../contracts/customized-solidity-fvm-files/types/AccountTypes.sol";
import { AccountCBOR } from "../contracts/customized-solidity-fvm-files/cbor/AccountCbor.sol";
import { MarketCBOR } from "../contracts/customized-solidity-fvm-files/cbor/MarketCbor.sol";
import { BytesCBOR } from "../contracts/customized-solidity-fvm-files/cbor/BytesCbor.sol";
import { BigNumbers } from "../contracts/customized-solidity-fvm-files/external/BigNumbers.sol";
import { CBOR } from "../contracts/customized-solidity-fvm-files/external/CBOR.sol";
import { Misc } from "../contracts/customized-solidity-fvm-files/utils/Misc.sol";
import { FilAddresses } from "../contracts/customized-solidity-fvm-files/utils/FilAddresses.sol";
// import { MarketDealNotifyParams, deserializeMarketCustomDealNotifyParams, serializeCustomDealProposal, deserializeCustomDealProposal } from "./Types.sol";

contract CustomDealClient {
    using AccountCBOR for *;
    using MarketCBOR for *;

    uint64 constant public AUTHENTICATE_MESSAGE_METHOD_NUM = 2643134072;
    uint64 constant public DATACAP_RECEIVER_HOOK_METHOD_NUM = 3726118371;
    uint64 constant public MARKET_NOTIFY_DEAL_METHOD_NUM = 4186741094;

    mapping(bytes32 => ProposalIdx) public dealProposals; // contract deal id -> deal index
    mapping(bytes => ProposalIdSet) public pieceToProposal; // commP -> dealProposalID
    mapping(bytes => ProviderSet) public pieceProviders; // commP -> provider
    mapping(bytes => uint64) public pieceDeals; // commP -> deal ID
    CustomDealRequest[] deals;

    event DealProposalCreate(bytes32 indexed id, uint64 size, bool indexed verified, uint256 price);

    address public owner;

    struct ProposalIdSet {
        bytes32 proposalId;
        bool valid;
    }

    struct ProposalIdx {
        uint256 idx;
        bool valid;
    }

    struct ProviderSet {
        bytes provider;
        bool valid;
    }

    // User request for this contract to make a deal. This structure is modelled after Filecoin's Deal
    // Proposal, but leaves out the provider, since any provider can pick up a deal broadcast by this
    // contract.
    struct CustomDealRequest {
        // To be cast to a CommonTypes.Cid
        bytes piece_cid;
        uint64 piece_size;
        bool verified_deal;
        // To be cast to a CommonTypes.FilAddress
        bytes client_addr;
        CommonTypes.FilAddress provider;
        string label;
        int64 start_epoch;
        int64 end_epoch;
        uint256 storage_price_per_epoch;
        uint256 provider_collateral;
        uint256 client_collateral;
        uint64 extra_params_version;
        CustomOptions options;
        ExtraParamsV1 extra_params;
    }

    // Extra parameters associated with the deal request. These are off-protocol flags that
    // the storage provider will need.
    struct ExtraParamsV1 {
        string location_ref;
        uint64 car_size;
        bool skip_ipni_announce;
        bool remove_unsealed_copy;
    }

    struct CustomOptions {
        CommonTypes.ChainEpoch termination_epoch;
        uint64 share_percentage;
        bool compute_req;
    }

    constructor() {
        owner = msg.sender;
    }

    function makeDealProposal(
        CustomDealRequest calldata deal
    ) public returns (bytes32) {
        // TODO: length check on byte fields
        require(msg.sender == owner);

        uint256 index = deals.length;
        deals.push(deal);

        // creates a unique ID for the deal proposal -- there are many ways to do this
        bytes32 id = keccak256(
            abi.encodePacked(block.timestamp, msg.sender, index)
        );
        dealProposals[id] = ProposalIdx(index, true);

        pieceToProposal[deal.piece_cid] = ProposalIdSet(id, true);

        // writes the proposal metadata to the event log
        emit DealProposalCreate(
            id,
            deal.piece_size,
            deal.verified_deal,
            deal.storage_price_per_epoch
        );

        return id;
    }

    // Returns a CBOR-encoded DealProposal.
    function getDealProposal(bytes32 proposalId) view public returns (bytes memory) {
        // TODO make these array accesses safe.
        DealRequest memory deal = getDealRequest(proposalId);

        MarketTypes.CustomDealProposal memory ret;
        ret.piece_cid = CommonTypes.Cid(deal.piece_cid);
        ret.piece_size = deal.piece_size;
        ret.verified_deal = deal.verified_deal;
        ret.client = getDelegatedAddress(address(this));
        // Set a dummy provider. The provider that picks up this deal will need to set its own address.
        ret.provider = FilAddresses.fromActorID(0);
        ret.label = deal.label;
        ret.start_epoch = deal.start_epoch;
        ret.end_epoch = deal.end_epoch;
        ret.storage_price_per_epoch = uintToBigInt(deal.storage_price_per_epoch);
        ret.provider_collateral = uintToBigInt(deal.provider_collateral);
        ret.client_collateral = uintToBigInt(deal.client_collateral);
        ret.CustomOptions.termination_epoch = deal.CustomOptions.termination_epoch;
        ret.CustomOptions.share_percentage = deal.CustomOptions.share_percentage;
        ret.CustomOptions.compute_req = deal.CustomOptions.compute_req;

        return serializeCustomDealProposal(ret);
    }

    // TODO fix in filecoin-solidity. They're using the wrong hex value.
    function getDelegatedAddress(address addr) internal pure returns (CommonTypes.FilAddress memory) {
        return CommonTypes.FilAddress(abi.encodePacked(hex"040a", addr));
    }

    function getExtraParams(
        bytes32 proposalId
    ) public view returns (bytes memory extra_params) {
        DealRequest memory deal = getDealRequest(proposalId);
        extra_params = serializeExtraParamsV1(deal.extra_params);
        return extra_params;
    }

        // helper function to get deal request based from id
    function getDealRequest(
        bytes32 proposalId
    ) internal view returns (DealRequest memory) {
        ProposalIdx memory pi = dealProposals[proposalId];
        require(pi.valid, "proposalId not available");

        return deals[pi.idx];
    }

    function serializeExtraParamsV1(ExtraParamsV1 memory params) pure returns (bytes memory) {
        CBOR.CBORBuffer memory buf = CBOR.create(64);
        buf.startFixedArray(4);
        buf.writeString(params.location_ref);
        buf.writeUInt64(params.car_size);
        buf.writeBool(params.skip_ipni_announce);
        buf.writeBool(params.remove_unsealed_copy);
        return buf.data();
    }

    function authenticateMessage(bytes memory params) view internal {
        AccountTypes.AuthenticateMessageParams memory amp = params.deserializeAuthenticateMessageParams();
        MarketTypes.DealProposal memory proposal = deserializeDealProposal(amp.message);

        require(pieceToProposal[proposal.piece_cid.data].valid, "piece cid must be added before authorizing");
        require(!pieceProviders[proposal.piece_cid.data].valid, "deal failed policy check: provider already claimed this cid");
    }

    function dealNotify(bytes memory params) internal {
        MarketCustomDealNotifyParams memory mcdnp = deserializeMarketCustomDealNotifyParams(params);
        MarketTypes.CustomDealProposal memory proposal = deserializeCustomDealProposal(mcdnp.customDealProposal);

        require(pieceToProposal[proposal.piece_cid.data].valid, "piece cid must be added before authorizing");
        require(!pieceProviders[proposal.piece_cid.data].valid, "deal failed policy check: provider already claimed this cid");

        pieceProviders[proposal.piece_cid.data] = ProviderSet(proposal.provider.data, true);
        pieceDeals[proposal.piece_cid.data] = mcdnp.dealId;
    }

    // client - filecoin address byte format
    function addBalance(CommonTypes.FilAddress memory client, uint256 value) public {
        require(msg.sender == owner);

        // TODO:: remove first arg
        // change to ethAddr -> actorId and use that in the below API

        MarketAPI.addBalance(client, value);
    }

    // Below 2 funcs need to go to filecoin.sol
    function uintToBigInt(uint256 value) internal view returns(CommonTypes.BigInt memory) {
        BigNumbers.BigNumber memory bigNumVal = BigNumbers.init(value, false);
        CommonTypes.BigInt memory bigIntVal = CommonTypes.BigInt(bigNumVal.val, bigNumVal.neg);
        return bigIntVal;
    }

    function bigIntToUint(CommonTypes.BigInt memory bigInt) internal view returns (uint256) {
        BigNumbers.BigNumber memory bigNumUint = BigNumbers.init(bigInt.val, bigInt.neg);
        uint256 bigNumExtractedUint = uint256(bytes32(bigNumUint.val));
        return bigNumExtractedUint;
    }


    function withdrawBalance(CommonTypes.FilAddress memory client, uint256 value) public returns(uint) {
        // TODO:: remove first arg
        // change to ethAddr -> actorId and use that in the below API

        require(msg.sender == owner);

        MarketTypes.WithdrawBalanceParams memory params = MarketTypes.WithdrawBalanceParams(client, uintToBigInt(value));
        CommonTypes.BigInt memory ret = MarketAPI.withdrawBalance(params);

        return bigIntToUint(ret);
    }

    function handle_filecoin_method(
        uint64 method,
        uint64,
        bytes memory params
    )
        public
        returns (
            uint32,
            uint64,
            bytes memory
        )
    {
        bytes memory ret;
        uint64 codec;
        // dispatch methods
        if (method == AUTHENTICATE_MESSAGE_METHOD_NUM) {
            authenticateMessage(params);
            // If we haven't reverted, we should return a CBOR true to indicate that verification passed.
            CBOR.CBORBuffer memory buf = CBOR.create(1);
            buf.writeBool(true);
            ret = buf.data();
            codec = Misc.CBOR_CODEC;
        } else if (method == MARKET_NOTIFY_DEAL_METHOD_NUM) {
            dealNotify(params);
        } else {
            revert("the filecoin method that was called is not handled");
        }
        return (0, codec, ret);
    }
}
