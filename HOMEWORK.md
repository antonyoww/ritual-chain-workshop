# Homework: Privacy-Preserving AI Bounty Judge

**Track:** Required (Commit-Reveal) + Advanced design note
**Contract:** [`hardhat/contracts/CommitRevealAIJudge.sol`](hardhat/contracts/CommitRevealAIJudge.sol)
**Tests:** [`hardhat/test/CommitRevealAIJudge.ts`](hardhat/test/CommitRevealAIJudge.ts) — 10 passing
**Deploy module:** [`hardhat/ignition/modules/CommitRevealAIJudge.ts`](hardhat/ignition/modules/CommitRevealAIJudge.ts)

## The problem

The workshop `AIJudge` stores every answer in public on-chain storage the moment it
is submitted. Later participants can read earlier answers, copy the good ideas, and
submit an improved version — unfair when only one person can win.

`CommitRevealAIJudge` fixes this with a **commit-reveal** flow: during the submission
phase only a *commitment hash* is on-chain; the plaintext answer is revealed (and
becomes eligible for judging) only after the submission deadline closes.

## Bounty lifecycle

| Phase | Function | Who | When | What is on-chain |
|-------|----------|-----|------|------------------|
| 1. Create | `createBounty(title, rubric, submissionDeadline, revealDeadline)` (payable) | anyone | — | reward escrowed in contract |
| 2. Commit | `submitCommitment(bountyId, commitment)` | participant | `t < submissionDeadline` | only the hash; **answer hidden** |
| 3. Reveal | `revealAnswer(bountyId, answer, salt)` | participant | `submission ≤ t < reveal` | plaintext answer (after hash check) |
| 4. Judge | `judgeAll(bountyId, llmInput)` | owner | `t ≥ revealDeadline` | one batch LLM call → AI review stored |
| 5. Finalize | `finalizeWinner(bountyId, winnerIndex)` | owner | after judged | reward paid to winner |

### Commitment formula

```solidity
bytes32 commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId));
```

Binding to `msg.sender` **and** `bountyId` means a commitment copied from another
participant's transaction cannot be re-used to reveal their answer under a different
account or in a different bounty.

### Enforced rules

- A participant can submit **one** commitment per bounty, only before `submissionDeadline`.
- Reveals are accepted **only** in `[submissionDeadline, revealDeadline)`.
- A reveal succeeds **only** if `keccak256(answer, salt, sender, bountyId)` equals the stored commitment.
- Unrevealed submissions are **not** eligible — only revealed answers feed the AI and can win.
- The owner can `judgeAll` **only after** `revealDeadline`, and `finalizeWinner` **only after** judging.
- Exactly **one** winner is paid; reward is zeroed before transfer (reentrancy-safe, checks-effects-interactions).

## Ritual-native judging (one batch call)

`judgeAll` makes a **single** async call to the LLM precompile `0x0802` with a
pre-encoded request (`llmInput`) whose prompt embeds *all* revealed answers plus the
rubric — never one LLM call per submission. It reuses the workshop's
`PrecompileConsumer._executePrecompile`, which unwraps the short-running async
envelope `(bytes simmedInput, bytes actualOutput)`. The response envelope
`(bool hasError, bytes completionData, bytes modelMeta, string errorMessage, ConvoHistory)`
is decoded; on `hasError` the call reverts with the model's error string, otherwise the
raw AI review is stored in `bounty.aiReview` for the owner to read off-chain.

The AI only **recommends**. Payout is a separate human step (`finalizeWinner`) — the AI
output is never auto-parsed into a transfer, satisfying the "human-in-the-loop" and
"don't auto-pay from AI output" constraints.

## Test plan / coverage

`hardhat/test/CommitRevealAIJudge.ts` (run: `npx hardhat test test/CommitRevealAIJudge.ts`):

1. Bounty creation escrows the reward.
2. Commitment stored; `getSubmission.answer` is empty pre-reveal (**privacy guarantee**).
3. Second commitment from same participant reverts (`already committed`).
4. Commit after submission deadline reverts (`submissions closed`).
5. Reveal before submission deadline reverts (`reveal not open`).
6. Valid reveal inside the window populates the answer.
7. Invalid reveal — wrong salt **and** tampered answer — reverts (`commitment mismatch`).
8. Reveal after reveal deadline reverts (`reveal closed`).
9. `judgeAll` reverts while reveal is open and for non-owners.
10. `finalizeWinner` before judging reverts (`not judged yet`).

(The on-chain LLM step in `judgeAll` requires the live `0x0802` precompile and a funded
`RitualWallet`, so it is exercised against Ritual Chain, not the local EDR simulator.)

## Advanced track — architecture note: commit-reveal vs Ritual-native private judging

**Commit-reveal (this contract).** Plaintext answers exist only off-chain (in each
participant's wallet) until they reveal; on-chain we store just `keccak256(...)` during
submission. Strength: works on *any* EVM chain, no special infra. Weakness: at judging
time the answers are **public** on-chain — privacy holds only *until* the reveal phase,
not through it. Anyone watching can read all answers once revealed, even before the
owner finalizes.

**Ritual-native (design).** Instead of revealing plaintext, each participant encrypts
their answer to a Ritual TEE executor (ECIES / dKMS), and the contract stores only the
ciphertext or a storage reference + hash. `judgeAll` runs inside the TEE: the executor
decrypts all answers **privately**, sends them to the LLM in one batch, and returns a
ranking. Plaintext is never public on the chain — only the executor sees it, inside the
enclave. The final reveal publishes a `revealedAnswersRef` (e.g. `ipfs://...`) plus a
`revealedAnswersHash` committed on-chain so anyone can verify the bundle the AI judged.
Storage credentials live in `encryptedSecrets`, never plaintext on-chain. This keeps
answers hidden *through* judging, which commit-reveal cannot.

| | Commit-reveal | Ritual-native (TEE) |
|---|---|---|
| Answers public before payout? | Yes, after reveal | No — only the TEE sees them |
| Infra needed | none (any EVM) | Ritual TEE executor + dKMS/encryption |
| On-chain data | hash → plaintext | ciphertext/ref + final bundle hash |
| Trust | math (hash) | TEE attestation |

## Reflection — what is public, hidden, AI vs human

In a fair bounty, the *rules* must be public — the rubric, deadlines, reward, the list of
participants, and the final winner and payout — so the contest is auditable and the
outcome verifiable. The *answers* must stay hidden during the submission phase, because
visible answers let latecomers copy and out-submit earlier honest participants; commit-
reveal hides them until submission closes, and a TEE approach can keep them hidden even
through judging. The AI is well suited to the *labor* of evaluation: reading every
submission together against the rubric and producing a consistent, explainable ranking in
a single batch call. But the AI should only **recommend** — a human (the bounty owner)
makes the *consequential, irreversible* decision of releasing funds, because model output
can be wrong, gamed, or ambiguous, and money should never move on an unaudited parse of
an AI string. So: rules and results public, answers hidden until judging, AI judges,
human pays.

## Deploying to Ritual Chain (chain id 1979)

```bash
cd hardhat
npm install
npx hardhat compile

# Set the deployer key Hardhat reads (hardhat.config.ts -> networks.ritual)
npx hardhat keystore set DEPLOYER_PRIVATE_KEY   # or export DEPLOYER_PRIVATE_KEY=0x...

# Fund the deployer with testnet RITUAL (faucet.ritualfoundation.org), then:
npx hardhat ignition deploy ignition/modules/CommitRevealAIJudge.ts --network ritual
```

Explorer: <https://explorer.ritualfoundation.org>
