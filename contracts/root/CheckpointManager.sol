// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/Arrays.sol";
import "../interfaces/IBLS.sol";

interface IBN256G2 {
    function ecTwistAdd(
        uint256 pt1xx,
        uint256 pt1xy,
        uint256 pt1yx,
        uint256 pt1yy,
        uint256 pt2xx,
        uint256 pt2xy,
        uint256 pt2yx,
        uint256 pt2yy
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        );
}

/**
    @title CheckpointManager
    @author Polygon Technology
    @notice Checkpoint manager contract used by validators to submit signed checkpoints as proof of canonical chain.
    @dev The contract is used to submit checkpoints and verify that they have been signed as expected.
    */
contract CheckpointManager is Initializable {
    struct Checkpoint {
        uint256 endBlock;
        bytes32 eventRoot;
    }

    struct CheckpointMetadata {
        uint256 id;
        uint256 round;
        bytes32 blockHash;
    }

    struct Validator {
        address _address;
        uint256[4] blsKey;
        uint256 votingPower;
    }

    uint256 public currentCheckpointId;
    uint256 public currentValidatorSetLength;
    bytes32 public domain;
    IBLS public bls;
    IBN256G2 public bn256G2;

    mapping(uint256 => Checkpoint) public checkpoints;
    mapping(uint256 => Validator) public currentValidatorSet;
    uint256[] public checkpointEndBlocks;

    /**
     * @notice Initialization function for CheckpointManager
     * @dev Contract can only be initialized once
     * @param newBls Address of the BLS library contract
     * @param newBn256G2 Address of the BLS library contract
     * @param newDomain Domain to use when hashing messages to a point
     */
    function initialize(
        IBLS newBls,
        IBN256G2 newBn256G2,
        bytes32 newDomain,
        Validator[] calldata newValidatorSet
    ) external initializer {
        bls = newBls;
        bn256G2 = newBn256G2;
        domain = newDomain;
        currentValidatorSetLength = newValidatorSet.length;
        _setNewValidatorSet(newValidatorSet);
    }

    /**
     * @notice Function to submit a single checkpoint to CheckpointManager
     * @dev Contract internally verifies provided signature against stored validator set
     * @param chainId The chain ID of the checkpoint being signed
     * @param checkpointMetadata The checkpoint metadata to verify with the signature
     * @param checkpoint The checkpoint to store
     * @param signature The aggregated signature submitted by the proposer
     * @param newValidatorSet The new validator set to store
     * @param bitmap The bitmap of the old valdiator set that signed the message
     */
    function submit(
        uint256 chainId,
        CheckpointMetadata calldata checkpointMetadata,
        Checkpoint calldata checkpoint,
        uint256[2] calldata signature,
        Validator[] calldata newValidatorSet,
        bytes calldata bitmap
    ) external {
        bytes memory hash = abi.encode(keccak256(abi.encode(chainId, checkpointMetadata, checkpoint, newValidatorSet)));

        // slither-disable-next-line reentrancy-benign
        require(_verifySignature(bls.hashToPoint(domain, hash), signature, bitmap), "SIGNATURE_VERIFICATION_FAILED");

        _verifyCheckpoint(currentCheckpointId, checkpointMetadata.id, checkpoint);

        checkpoints[++currentCheckpointId] = checkpoint;
        checkpointEndBlocks.push(checkpoint.endBlock);
        _setNewValidatorSet(newValidatorSet);
    }

    /**
     * @notice Function to submit a batch of checkpoints to CheckpointManager
     * @dev Contract internally verifies provided signature against stored validator set
     * @param chainId The chain ID of the checkpoint being signed
     * @param checkpointMetadata The checkpoint metadata to verify with the signature
     * @param checkpointBatch The checkpoint batch to store
     * @param signature The aggregated signature submitted by the proposer
     * @param newValidatorSet The new validator set to store
     * @param bitmap The bitmap of the old valdiator set that signed the message
     */
    function submitBatch(
        uint256 chainId,
        CheckpointMetadata[] calldata checkpointMetadata,
        Checkpoint[] calldata checkpointBatch,
        uint256[2] calldata signature,
        Validator[] calldata newValidatorSet,
        bytes calldata bitmap
    ) external {
        bytes memory hash = abi.encode(
            keccak256(abi.encode(chainId, checkpointMetadata, checkpointBatch, newValidatorSet))
        );

        uint256[2] memory message = bls.hashToPoint(domain, hash);

        // slither-disable-next-line reentrancy-benign
        require(_verifySignature(message, signature, bitmap), "SIGNATURE_VERIFICATION_FAILED");

        uint256 prevId = currentCheckpointId;

        for (uint256 i = 0; i < checkpointBatch.length; ) {
            _verifyCheckpoint(prevId++, checkpointMetadata[i].id, checkpointBatch[i]);
            checkpoints[checkpointMetadata[i].id] = checkpointBatch[i];
            checkpointEndBlocks.push(checkpointBatch[i].endBlock);
            unchecked {
                ++i;
            }
        }

        currentCheckpointId = prevId;
        _setNewValidatorSet(newValidatorSet);
    }

    function _setNewValidatorSet(Validator[] calldata newValidatorSet) private {
        uint256 length = newValidatorSet.length;
        currentValidatorSetLength = length;
        for (uint256 i = 0; i < length; ++i) {
            currentValidatorSet[i] = newValidatorSet[i];
        }
    }

    /**
     * @notice Internal function that performs checks on the checkpoint
     * @param prevId Current checkpoint ID
     * @param id ID of the checkpoint
     * @param checkpoint The checkpoint to store
     */
    function _verifyCheckpoint(
        uint256 prevId,
        uint256 id,
        Checkpoint calldata checkpoint
    ) internal view {
        require(id == prevId + 1, "ID_NOT_SEQUENTIAL");
        Checkpoint memory oldCheckpoint = checkpoints[prevId];
        require(checkpoint.endBlock > oldCheckpoint.endBlock, "EMPTY_CHECKPOINT");
    }

    /**
     * @notice Internal function that asserts that the signature is valid and that the required threshold is met
     * @param message The message that was signed by validators (i.e. checkpoint hash)
     * @param signature The aggregated signature submitted by the proposer
     */
    function _verifySignature(
        uint256[2] memory message,
        uint256[2] calldata signature,
        bytes calldata bitmap
    ) private view returns (bool) {
        uint256 length = currentValidatorSetLength;
        uint256[4] memory aggPubkey;
        uint256 firstIndex = 0;
        bool flag = false;
        for (uint256 i = 0; i < length; ++i) {
            if (_getValueFromBitmap(bitmap, i)) {
                aggPubkey = currentValidatorSet[i].blsKey;
                firstIndex = i;
                flag = false;
                break;
            }
        }
        require(flag, "BITMAP_IS_EMPTY");
        uint256 aggVotingPower = 0;
        flag = false;
        for (uint256 i = firstIndex + 1; i < length; ++i) {
            if (_getValueFromBitmap(bitmap, i)) {
                uint256[4] memory blsKey = currentValidatorSet[i].blsKey;
                // slither-disable-next-line calls-loop
                (aggPubkey[0], aggPubkey[1], aggPubkey[2], aggPubkey[3]) = bn256G2.ecTwistAdd(
                    aggPubkey[0],
                    aggPubkey[1],
                    aggPubkey[2],
                    aggPubkey[3],
                    blsKey[0],
                    blsKey[1],
                    blsKey[2],
                    blsKey[3]
                );
                aggVotingPower += currentValidatorSet[i].votingPower;
            } else {
                continue;
            }
            if ((aggVotingPower * 100) > 6666) {
                flag = true;
                break;
            }
        }

        require(flag, "VOTING_POWER_IS_INSUFFICIENT");

        (bool callSuccess, bool result) = bls.verifySingle(signature, aggPubkey, message);

        return callSuccess && result;
    }

    function _getValueFromBitmap(bytes calldata bitmap, uint256 index) private pure returns (bool) {
        uint256 byteNumber = index / 8;
        uint8 bitNumber = uint8(index % 8);

        if (byteNumber >= bitmap.length) {
            return false;
        }

        // Get the value of the bit at the given 'index' in a byte.
        return uint8(bitmap[byteNumber]) & (1 << bitNumber) > 0;
    }
}
