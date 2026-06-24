// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

/// @title CommitRevealAIJudge
/// @notice Privacy-preserving version of the workshop AIJudge. Fixes the original
///         weakness — public answers — by hiding submissions behind a commitment
///         hash during the submission phase. Answers are revealed only after the
///         submission deadline, so later participants cannot copy earlier answers.
///
///         Lifecycle:
///           1. createBounty(reward, submissionDeadline, revealDeadline)
///           2. submitCommitment(bountyId, commitment)   [t < submissionDeadline]
///           3. revealAnswer(bountyId, answer, salt)      [submission < t < reveal]
///           4. judgeAll(bountyId, llmInput)              [t >= revealDeadline, owner]
///              -> single batch LLM call to 0x0802 over all revealed answers
///           5. finalizeWinner(bountyId, winnerIndex)     [owner, human-in-the-loop]
///
///         commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
///         Binding to msg.sender and bountyId prevents commitment replay/copying.
contract CommitRevealAIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    struct Submission {
        address submitter;
        bytes32 commitment;
        bool revealed;
        string answer; // empty until a valid reveal
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        Submission[] submissions;
    }

    /// @dev Same shape the LLM precompile (0x0802) returns for updatedConvoHistory.
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;
    // bountyId => submitter => index+1 into submissions (0 == has not committed)
    mapping(uint256 => mapping(address => uint256)) private commitIndexPlusOne;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    /// @notice Create a bounty with a reward escrowed in the contract.
    /// @param submissionDeadline commitments accepted while block.timestamp < this.
    /// @param revealDeadline     reveals accepted while submission <= timestamp < this.
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(submissionDeadline > block.timestamp, "submission deadline in past");
        require(revealDeadline > submissionDeadline, "reveal must follow submission");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];
        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    /// @notice Phase 1 — submit ONLY a commitment hash. The real answer stays private.
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submissionDeadline, "submissions closed");
        require(!bounty.judged, "already judged");
        require(commitIndexPlusOne[bountyId][msg.sender] == 0, "already committed");
        require(
            bounty.submissions.length < MAX_SUBMISSIONS,
            "too many submissions"
        );

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                revealed: false,
                answer: ""
            })
        );
        uint256 index = bounty.submissions.length - 1;
        commitIndexPlusOne[bountyId][msg.sender] = index + 1;

        emit CommitmentSubmitted(bountyId, index, msg.sender, commitment);
    }

    /// @notice Phase 2 — reveal the answer + salt. Valid only if the hash matches.
    ///         Only revealed answers are eligible for judging.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submissionDeadline, "reveal not open");
        require(block.timestamp < bounty.revealDeadline, "reveal closed");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 idxPlusOne = commitIndexPlusOne[bountyId][msg.sender];
        require(idxPlusOne != 0, "no commitment");

        Submission storage submission = bounty.submissions[idxPlusOne - 1];
        require(!submission.revealed, "already revealed");

        bytes32 expected = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(expected == submission.commitment, "commitment mismatch");

        submission.revealed = true;
        submission.answer = answer;

        emit AnswerRevealed(bountyId, idxPlusOne - 1, msg.sender);
    }

    /// @notice Phase 3 — owner triggers a SINGLE batch AI judging call after the
    ///         reveal deadline. `llmInput` is the fully ABI-encoded 0x0802 request
    ///         whose prompt embeds every revealed answer (one LLM call, not a loop).
    ///         Stores the AI review; it does NOT pay anyone (see finalizeWinner).
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal still open");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(_revealedCount(bounty) > 0, "no revealed answers");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /// @notice Phase 4 — human-in-the-loop finalization. Owner reviews the AI review
    ///         off-chain and selects the winning index. Only a revealed submission
    ///         can win. Pays the escrowed reward to that participant.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid index");

        Submission storage winnerSub = bounty.submissions[winnerIndex];
        require(winnerSub.revealed, "winner not revealed");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = winnerSub.submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0; // effects before interaction

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ----------------------------------------------------------------- views

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 submissionDeadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];
        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.submissionDeadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    /// @notice Submission view. `answer` is empty until the participant reveals,
    ///         which is what guarantees pre-judging privacy on-chain.
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            bool revealed,
            string memory answer
        )
    {
        Bounty storage bounty = bounties[bountyId];
        require(index < bounty.submissions.length, "invalid index");
        Submission storage s = bounty.submissions[index];
        return (s.submitter, s.commitment, s.revealed, s.answer);
    }

    /// @notice Helper so off-chain code / participants can mirror the hash exactly.
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }

    function _revealedCount(
        Bounty storage bounty
    ) internal view returns (uint256 count) {
        uint256 len = bounty.submissions.length;
        for (uint256 i = 0; i < len; i++) {
            if (bounty.submissions[i].revealed) count++;
        }
    }
}
