// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {ICartesiDApp, Proof} from "./ICartesiDApp.sol";
import {IConsensus} from "../consensus/IConsensus.sol";
import {IInputBox} from "../inputs/IInputBox.sol";
import {IInputRelay} from "../inputs/IInputRelay.sol";
import {LibOutputValidation, OutputValidityProof} from "../library/LibOutputValidation.sol";
import {Bitmask} from "@cartesi/util/contracts/Bitmask.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder, ERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Cartesi DApp
///
/// @notice This contract acts as the base layer incarnation of a DApp running on the execution layer.
/// The DApp is hereby able to interact with other smart contracts through the execution of vouchers
/// and the validation of notices. These outputs are generated by the DApp backend on the execution
/// layer and can be proven in the base layer thanks to claims submitted by a consensus contract.
///
/// A voucher is a one-time message call to another contract. It can encode asset transfers, approvals,
/// or any other message call that doesn't require Ether to be sent along. A voucher will only be consumed
/// if the underlying message call succeeds (that is, it doesn't revert). Furthermore, the return data of
/// the message call is discarded entirely. As a protective measure against reentrancy attacks, nested
/// voucher executions are prohibited.
///
/// A notice, on the other hand, constitutes an arbitrary piece of data that can be proven any number of times.
/// On their own, they do not trigger any type of contract-to-contract interaction.
/// Rather, they merely serve to attest off-chain results, e.g. which player won a particular chess match.
///
/// Every DApp is subscribed to a consensus contract, and governed by a single address, the owner.
/// The consensus has the power of submitting claims, which, in turn, are used to validate vouchers and notices.
/// Meanwhile, the owner has complete power over the DApp, as it can replace the consensus at any time.
/// Therefore, the users of a DApp must trust both the consensus and the DApp owner.
///
/// The DApp developer can choose whichever ownership and consensus models it wants.
///
/// Examples of DApp ownership models include:
///
/// * no owner (address zero)
/// * individual signer (externally-owned account)
/// * multiple signers (multi-sig)
/// * DAO (decentralized autonomous organization)
/// * self-owned DApp (off-chain governance logic)
///
/// See `IConsensus` for examples of consensus models.
///
/// This contract inherits the following OpenZeppelin contracts.
/// For more information, please consult OpenZeppelin's official documentation.
///
/// * `Ownable`
/// * `ERC721Holder`
/// * `ERC1155Holder`
/// * `ReentrancyGuard`
///
contract CartesiDApp is
    ICartesiDApp,
    Ownable,
    ERC721Holder,
    ERC1155Holder,
    ReentrancyGuard
{
    using Bitmask for mapping(uint256 => uint256);
    using LibOutputValidation for OutputValidityProof;
    using Address for address;

    /// @notice Raised when executing an already executed voucher.
    error VoucherReexecutionNotAllowed();

    /// @notice Raised when the transfer fails.
    error EtherTransferFailed();

    /// @notice Raised when a mehtod is not called by DApp itself.
    error OnlyDApp();

    /// @notice The initial machine state hash.
    /// @dev See the `getTemplateHash` function.
    bytes32 internal immutable templateHash;

    /// @notice The executed voucher bitmask, which keeps track of which vouchers
    ///         were executed already in order to avoid re-execution.
    /// @dev See the `wasVoucherExecuted` function.
    mapping(uint256 => uint256) internal voucherBitmask;

    /// @notice The current consensus contract.
    /// @dev See the `getConsensus` and `migrateToConsensus` functions.
    IConsensus internal consensus;

    /// @notice The input box contract.
    /// @dev See the `getInputBox` function.
    IInputBox internal immutable inputBox;

    /// @notice The input relays.
    /// @dev See the `getInputRelays` function.
    IInputRelay[] internal inputRelays;

    /// @notice Creates a `CartesiDApp` contract.
    /// @param _consensus The initial consensus contract
    /// @param _inputBox The input box contract
    /// @param _inputRelays The input relays
    /// @param _owner The initial DApp owner
    /// @param _templateHash The initial machine state hash
    /// @dev Calls the `join` function on `_consensus`.
    constructor(
        IConsensus _consensus,
        IInputBox _inputBox,
        IInputRelay[] memory _inputRelays,
        address _owner,
        bytes32 _templateHash
    ) {
        transferOwnership(_owner);
        templateHash = _templateHash;
        consensus = _consensus;
        inputBox = _inputBox;
        for (uint256 i; i < _inputRelays.length; ++i) {
            inputRelays.push(_inputRelays[i]);
        }

        _consensus.join();
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC1155Receiver, IERC165) returns (bool) {
        return
            interfaceId == type(ICartesiDApp).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function executeVoucher(
        address _destination,
        bytes calldata _payload,
        Proof calldata _proof
    ) external override nonReentrant {
        bytes32 epochHash;
        uint256 firstInputIndex;
        uint256 lastInputIndex;
        uint256 inputIndex;

        // query the current consensus for the desired claim
        (epochHash, firstInputIndex, lastInputIndex) = getClaim(_proof.context);

        // validate input index range and calculate the input index
        // based on the input index range provided by the consensus
        inputIndex = _proof.validity.validateInputIndexRange(
            firstInputIndex,
            lastInputIndex
        );

        // reverts if proof isn't valid
        _proof.validity.validateVoucher(_destination, _payload, epochHash);

        uint256 voucherPosition = LibOutputValidation.getBitMaskPosition(
            _proof.validity.outputIndexWithinInput,
            inputIndex
        );

        // check if voucher has been executed
        if (_wasVoucherExecuted(voucherPosition)) {
            revert VoucherReexecutionNotAllowed();
        }

        // execute voucher
        _destination.functionCall(_payload);

        // mark it as executed and emit event
        voucherBitmask.setBit(voucherPosition, true);
        emit VoucherExecuted(voucherPosition);
    }

    function wasVoucherExecuted(
        uint256 _inputIndex,
        uint256 _outputIndexWithinInput
    ) external view override returns (bool) {
        uint256 voucherPosition = LibOutputValidation.getBitMaskPosition(
            _outputIndexWithinInput,
            _inputIndex
        );
        return _wasVoucherExecuted(voucherPosition);
    }

    function _wasVoucherExecuted(
        uint256 _voucherPosition
    ) internal view returns (bool) {
        return voucherBitmask.getBit(_voucherPosition);
    }

    function validateNotice(
        bytes calldata _notice,
        Proof calldata _proof
    ) external view override {
        bytes32 epochHash;
        uint256 firstInputIndex;
        uint256 lastInputIndex;

        // query the current consensus for the desired claim
        (epochHash, firstInputIndex, lastInputIndex) = getClaim(_proof.context);

        // validate the epoch input index based on the input index range
        // provided by the consensus
        _proof.validity.validateInputIndexRange(
            firstInputIndex,
            lastInputIndex
        );

        // reverts if proof isn't valid
        _proof.validity.validateNotice(_notice, epochHash);
    }

    /// @notice Retrieve a claim about the DApp from the current consensus.
    ///         The encoding of `_proofContext` might vary depending on the implementation.
    /// @param _proofContext Data for retrieving the desired claim
    /// @return The claimed epoch hash
    /// @return The index of the first input of the epoch in the input box
    /// @return The index of the last input of the epoch in the input box
    function getClaim(
        bytes calldata _proofContext
    ) internal view returns (bytes32, uint256, uint256) {
        return consensus.getClaim(address(this), _proofContext);
    }

    function migrateToConsensus(
        IConsensus _newConsensus
    ) external override onlyOwner {
        consensus = _newConsensus;

        _newConsensus.join();

        emit NewConsensus(_newConsensus);
    }

    function getTemplateHash() external view override returns (bytes32) {
        return templateHash;
    }

    function getConsensus() external view override returns (IConsensus) {
        return consensus;
    }

    function getInputBox() external view override returns (IInputBox) {
        return inputBox;
    }

    function getInputRelays()
        external
        view
        override
        returns (IInputRelay[] memory)
    {
        return inputRelays;
    }

    /// @notice Accept Ether transfers.
    /// @dev If you wish to transfer Ether to a DApp while informing
    ///      the DApp backend of it, then please do so through the Ether portal contract.
    receive() external payable {}

    /// @notice Transfer some amount of Ether to some recipient.
    /// @param _receiver The address which will receive the amount of Ether
    /// @param _value The amount of Ether to be transferred in Wei
    /// @dev This function can only be called by the DApp itself through vouchers.
    ///      If this method is not called by DApp itself, `OnlyDApp` error is raised.
    ///      If the transfer fails, `EtherTransferFailed` error is raised.
    function withdrawEther(address _receiver, uint256 _value) external {
        if (msg.sender != address(this)) {
            revert OnlyDApp();
        }

        (bool sent, ) = _receiver.call{value: _value}("");

        if (!sent) {
            revert EtherTransferFailed();
        }
    }
}
