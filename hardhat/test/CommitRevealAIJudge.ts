import { network } from "hardhat";
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { encodePacked, keccak256, parseEther, getAddress } from "viem";

describe("CommitRevealAIJudge", async function () {
  const { viem, networkHelpers } = await network.create();

  const REWARD = parseEther("1");

  // Build the commitment exactly as the contract does:
  // keccak256(abi.encodePacked(answer, salt, submitter, bountyId))
  function commitmentFor(
    answer: string,
    salt: `0x${string}`,
    submitter: `0x${string}`,
    bountyId: bigint,
  ) {
    return keccak256(
      encodePacked(
        ["string", "bytes32", "address", "uint256"],
        [answer, salt, submitter, bountyId],
      ),
    );
  }

  async function deployWithOpenBounty() {
    const judge = await viem.deployContract("CommitRevealAIJudge");
    const [owner, alice, bob] = await viem.getWalletClients();

    const now = BigInt(await networkHelpers.time.latest());
    const submissionDeadline = now + 1_000n;
    const revealDeadline = submissionDeadline + 1_000n;

    await judge.write.createBounty(
      ["Best haiku", "Judge on creativity", submissionDeadline, revealDeadline],
      { value: REWARD },
    );

    return { judge, owner, alice, bob, submissionDeadline, revealDeadline };
  }

  it("creates a bounty and escrows the reward", async function () {
    const { judge } = await networkHelpers.loadFixture(deployWithOpenBounty);
    const publicClient = await viem.getPublicClient();

    const bounty = await judge.read.getBounty([1n]);
    assert.equal(bounty[3], REWARD); // reward
    assert.equal(bounty[6], false); // judged
    assert.equal(bounty[7], false); // finalized

    const held = await publicClient.getBalance({ address: judge.address });
    assert.equal(held, REWARD);
  });

  it("accepts a commitment and keeps the answer private before reveal", async function () {
    const { judge, alice } = await networkHelpers.loadFixture(deployWithOpenBounty);

    const salt = keccak256(encodePacked(["string"], ["alice-salt"]));
    const c = commitmentFor("ocean breeze", salt, getAddress(alice.account.address), 1n);

    await judge.write.submitCommitment([1n, c], { account: alice.account });

    const sub = await judge.read.getSubmission([1n, 0n]);
    assert.equal(getAddress(sub[0]), getAddress(alice.account.address));
    assert.equal(sub[1], c); // commitment stored
    assert.equal(sub[2], false); // revealed
    assert.equal(sub[3], ""); // answer hidden (privacy guarantee)
  });

  it("rejects a second commitment from the same participant", async function () {
    const { judge, alice } = await networkHelpers.loadFixture(deployWithOpenBounty);
    const salt = keccak256(encodePacked(["string"], ["s"]));
    const c = commitmentFor("a", salt, getAddress(alice.account.address), 1n);

    await judge.write.submitCommitment([1n, c], { account: alice.account });
    await viem.assertions.revertWith(
      judge.write.submitCommitment([1n, c], { account: alice.account }),
      "already committed",
    );
  });

  it("rejects commitments after the submission deadline", async function () {
    const { judge, alice, submissionDeadline } =
      await networkHelpers.loadFixture(deployWithOpenBounty);
    const salt = keccak256(encodePacked(["string"], ["s"]));
    const c = commitmentFor("a", salt, getAddress(alice.account.address), 1n);

    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await viem.assertions.revertWith(
      judge.write.submitCommitment([1n, c], { account: alice.account }),
      "submissions closed",
    );
  });

  it("rejects revealing before the submission deadline", async function () {
    const { judge, alice } = await networkHelpers.loadFixture(deployWithOpenBounty);
    const salt = keccak256(encodePacked(["string"], ["s"]));
    const c = commitmentFor("hello world", salt, getAddress(alice.account.address), 1n);
    await judge.write.submitCommitment([1n, c], { account: alice.account });

    await viem.assertions.revertWith(
      judge.write.revealAnswer([1n, "hello world", salt], { account: alice.account }),
      "reveal not open",
    );
  });

  it("accepts a valid reveal in the reveal window", async function () {
    const { judge, alice, submissionDeadline } =
      await networkHelpers.loadFixture(deployWithOpenBounty);
    const salt = keccak256(encodePacked(["string"], ["alice"]));
    const answer = "the quiet pond";
    const c = commitmentFor(answer, salt, getAddress(alice.account.address), 1n);
    await judge.write.submitCommitment([1n, c], { account: alice.account });

    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await judge.write.revealAnswer([1n, answer, salt], { account: alice.account });

    const sub = await judge.read.getSubmission([1n, 0n]);
    assert.equal(sub[2], true); // revealed
    assert.equal(sub[3], answer); // now public
  });

  it("rejects an invalid reveal (wrong salt / answer)", async function () {
    const { judge, alice, submissionDeadline } =
      await networkHelpers.loadFixture(deployWithOpenBounty);
    const salt = keccak256(encodePacked(["string"], ["alice"]));
    const c = commitmentFor("real answer", salt, getAddress(alice.account.address), 1n);
    await judge.write.submitCommitment([1n, c], { account: alice.account });

    await networkHelpers.time.increaseTo(submissionDeadline + 1n);

    const wrongSalt = keccak256(encodePacked(["string"], ["nope"]));
    await viem.assertions.revertWith(
      judge.write.revealAnswer([1n, "real answer", wrongSalt], { account: alice.account }),
      "commitment mismatch",
    );
    await viem.assertions.revertWith(
      judge.write.revealAnswer([1n, "tampered answer", salt], { account: alice.account }),
      "commitment mismatch",
    );
  });

  it("rejects reveals after the reveal deadline", async function () {
    const { judge, alice, submissionDeadline, revealDeadline } =
      await networkHelpers.loadFixture(deployWithOpenBounty);
    const salt = keccak256(encodePacked(["string"], ["alice"]));
    const answer = "too late";
    const c = commitmentFor(answer, salt, getAddress(alice.account.address), 1n);
    await judge.write.submitCommitment([1n, c], { account: alice.account });

    await networkHelpers.time.increaseTo(revealDeadline + 1n);
    await viem.assertions.revertWith(
      judge.write.revealAnswer([1n, answer, salt], { account: alice.account }),
      "reveal closed",
    );
  });

  it("blocks judging before the reveal deadline and from non-owners", async function () {
    const { judge, alice, bob, submissionDeadline, revealDeadline } =
      await networkHelpers.loadFixture(deployWithOpenBounty);
    const salt = keccak256(encodePacked(["string"], ["alice"]));
    const answer = "answer";
    const c = commitmentFor(answer, salt, getAddress(alice.account.address), 1n);
    await judge.write.submitCommitment([1n, c], { account: alice.account });
    await networkHelpers.time.increaseTo(submissionDeadline + 1n);
    await judge.write.revealAnswer([1n, answer, salt], { account: alice.account });

    // Reveal window still open -> cannot judge yet
    await viem.assertions.revertWith(
      judge.write.judgeAll([1n, "0x"]),
      "reveal still open",
    );

    await networkHelpers.time.increaseTo(revealDeadline + 1n);
    // Non-owner cannot judge
    await viem.assertions.revertWith(
      judge.write.judgeAll([1n, "0x"], { account: bob.account }),
      "not bounty owner",
    );
  });

  it("blocks finalize before judging", async function () {
    const { judge } = await networkHelpers.loadFixture(deployWithOpenBounty);
    await viem.assertions.revertWith(
      judge.write.finalizeWinner([1n, 0n]),
      "not judged yet",
    );
  });
});
