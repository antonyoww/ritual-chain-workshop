import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("CommitRevealAIJudgeModule", (m) => {
  const commitRevealAIJudge = m.contract("CommitRevealAIJudge");

  return { commitRevealAIJudge };
});
