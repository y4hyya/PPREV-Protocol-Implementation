import { expect } from "chai";
import { ethers } from "hardhat";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { PPREVSingle, MockNotaryVerifier, ECDSANotaryVerifier } from "../typechain-types";

const FRESHNESS = 300n;
const DEFAULT_LOCK = 60n * 60n * 24n * 7n; // 7 days
const MIN_COLLATERAL = ethers.parseEther("1");
const REQ_ESCROW = ethers.parseEther("0.5");

const POLICY_R = ethers.keccak256(ethers.toUtf8Bytes("policy.ownership"));
const POLICY_A = ethers.keccak256(ethers.toUtf8Bytes("policy.eligibility"));
const POLICY_S = ethers.keccak256(ethers.toUtf8Bytes("policy.settlement"));

const DUMMY_SIG = "0x00";

function computeTxId(txData: string, salt: string): string {
  return ethers.solidityPackedKeccak256(["bytes", "bytes32", "bytes32"], [txData, POLICY_R, salt]);
}

function buildMsgR(
  contractAddr: string,
  txID: string,
  txDataHash: string,
  nonce: string,
  ts: bigint,
): string {
  return ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "address"],
    [txID, txDataHash, POLICY_R, nonce, ts, contractAddr],
  );
}

function buildMsgA(contractAddr: string, txID: string, nonce: string, ts: bigint): string {
  return ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "uint256", "address"],
    [txID, POLICY_A, nonce, ts, contractAddr],
  );
}

function buildMsgS(
  contractAddr: string,
  engId: string,
  txID: string,
  nonce: string,
  ts: bigint,
): string {
  return ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "bytes32", "bytes32", "uint256", "address"],
    [engId, txID, POLICY_S, nonce, ts, contractAddr],
  );
}

describe("PPREVSingle", function () {
  this.timeout(120000); // Hardhat deployment + typechain warmup can be slow on the first test
  let pprev: PPREVSingle;
  let mockNotary: MockNotaryVerifier;
  let admin: HardhatEthersSigner;
  let owner: HardhatEthersSigner;
  let applicant: HardhatEthersSigner;
  let other: HardhatEthersSigner;
  let pprevAddr: string;

  beforeEach(async () => {
    [admin, owner, applicant, other] = await ethers.getSigners();

    const Mock = await ethers.getContractFactory("MockNotaryVerifier", admin);
    mockNotary = (await Mock.deploy()) as unknown as MockNotaryVerifier;

    const PPREV = await ethers.getContractFactory("PPREVSingle", admin);
    pprev = (await PPREV.deploy(
      await mockNotary.getAddress(),
      FRESHNESS,
      DEFAULT_LOCK,
      MIN_COLLATERAL,
    )) as unknown as PPREVSingle;

    pprevAddr = await pprev.getAddress();

    await pprev.connect(admin).whitelistPolicy(POLICY_R, true);
    await pprev.connect(admin).whitelistPolicy(POLICY_A, true);
    await pprev.connect(admin).whitelistPolicy(POLICY_S, true);
  });

  async function now(): Promise<bigint> {
    const block = await ethers.provider.getBlock("latest");
    return BigInt(block!.timestamp);
  }

  async function doRegister(
    signer: HardhatEthersSigner,
    txDataStr: string,
    salt: string,
    nonce: string,
  ): Promise<string> {
    const txData = ethers.toUtf8Bytes(txDataStr);
    const ts = await now();
    const tx = await pprev
      .connect(signer)
      .register(txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, ts, DUMMY_SIG, {
        value: MIN_COLLATERAL,
      });
    await tx.wait();
    return computeTxId(ethers.hexlify(txData), salt);
  }

  async function doApply(
    signer: HardhatEthersSigner,
    txID: string,
    nonce: string,
  ): Promise<string> {
    const ts = await now();
    const tx = await pprev
      .connect(signer)
      .applyTx(txID, nonce, ts, DUMMY_SIG, { value: REQ_ESCROW });
    const rc = await tx.wait();
    const ev = rc!.logs
      .map((l) => {
        try {
          return pprev.interface.parseLog(l as any);
        } catch {
          return null;
        }
      })
      .find((p) => p?.name === "ApplicationCreated");
    return ev!.args[0] as string;
  }

  async function doEngage(
    signer: HardhatEthersSigner,
    appId: string,
    lockWindow: bigint = 0n,
  ): Promise<string> {
    const tx = await pprev.connect(signer).engage(appId, lockWindow);
    const rc = await tx.wait();
    const ev = rc!.logs
      .map((l) => {
        try {
          return pprev.interface.parseLog(l as any);
        } catch {
          return null;
        }
      })
      .find((p) => p?.name === "Engaged");
    return ev!.args[0] as string;
  }

  async function doSettle(signer: HardhatEthersSigner, engId: string, nonce: string) {
    const ts = await now();
    const tx = await pprev.connect(signer).settle(engId, nonce, ts, DUMMY_SIG);
    await tx.wait();
  }

  // ────────────────────────────────────────────────────────────────────────
  //  Constructor & admin
  // ────────────────────────────────────────────────────────────────────────

  describe("Constructor & admin", () => {
    it("stores constructor params", async () => {
      expect(await pprev.admin()).to.equal(await admin.getAddress());
      expect(await pprev.freshnessWindow()).to.equal(FRESHNESS);
      expect(await pprev.defaultLockWindow()).to.equal(DEFAULT_LOCK);
      expect(await pprev.minCollateral()).to.equal(MIN_COLLATERAL);
      expect(await pprev.maxExpirations()).to.equal(5n);
    });

    it("rejects zero notary verifier", async () => {
      const PPREV = await ethers.getContractFactory("PPREVSingle", admin);
      await expect(
        PPREV.deploy(ethers.ZeroAddress, FRESHNESS, DEFAULT_LOCK, MIN_COLLATERAL),
      ).to.be.revertedWithCustomError(pprev, "InvalidVerifierAddress");
    });

    it("admin-only setters", async () => {
      await expect(
        pprev.connect(other).setFreshnessWindow(60n),
      ).to.be.revertedWithCustomError(pprev, "NotAdmin");
      await expect(
        pprev.connect(other).setDefaultLockWindow(60n),
      ).to.be.revertedWithCustomError(pprev, "NotAdmin");
      await expect(
        pprev.connect(other).setMinCollateral(1n),
      ).to.be.revertedWithCustomError(pprev, "NotAdmin");
      await expect(
        pprev.connect(other).setMaxExpirations(1n),
      ).to.be.revertedWithCustomError(pprev, "NotAdmin");
      await expect(
        pprev.connect(other).whitelistPolicy(POLICY_R, false),
      ).to.be.revertedWithCustomError(pprev, "NotAdmin");
    });

    it("admin can update settings", async () => {
      await pprev.connect(admin).setFreshnessWindow(60n);
      expect(await pprev.freshnessWindow()).to.equal(60n);
      await pprev.connect(admin).setMaxExpirations(3n);
      expect(await pprev.maxExpirations()).to.equal(3n);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  //  Register
  // ────────────────────────────────────────────────────────────────────────

  describe("register", () => {
    it("creates a listing", async () => {
      const txID = await doRegister(owner, "tx1", ethers.encodeBytes32String("salt1"), ethers.encodeBytes32String("n1"));
      const l = await pprev.getListing(txID);
      expect(l.owner).to.equal(await owner.getAddress());
      expect(l.policyId_R).to.equal(POLICY_R);
      expect(l.policyId_A).to.equal(POLICY_A);
      expect(l.policyId_S).to.equal(POLICY_S);
      expect(l.state).to.equal(1n); // ACTIVE
    });

    it("emits TxRegistered with all policy IDs", async () => {
      const txData = ethers.toUtf8Bytes("tx2");
      const salt = ethers.encodeBytes32String("s2");
      const nonce = ethers.encodeBytes32String("n2");
      const ts = await now();
      await expect(
        pprev
          .connect(owner)
          .register(txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, ts, DUMMY_SIG, {
            value: MIN_COLLATERAL,
          }),
      )
        .to.emit(pprev, "TxRegistered")
        .withArgs(
          computeTxId(ethers.hexlify(txData), salt),
          await owner.getAddress(),
          POLICY_R,
          POLICY_A,
          POLICY_S,
          REQ_ESCROW,
          MIN_COLLATERAL,
        );
    });

    it("reverts on duplicate txID", async () => {
      const salt = ethers.encodeBytes32String("dup");
      await doRegister(owner, "dup", salt, ethers.encodeBytes32String("n3"));
      const ts = await now();
      await expect(
        pprev.connect(owner).register(
          ethers.toUtf8Bytes("dup"),
          POLICY_R,
          POLICY_A,
          POLICY_S,
          salt,
          REQ_ESCROW,
          ethers.encodeBytes32String("n4"),
          ts,
          DUMMY_SIG,
          { value: MIN_COLLATERAL },
        ),
      ).to.be.revertedWithCustomError(pprev, "TxAlreadyExists");
    });

    it("reverts on non-whitelisted policyId_R", async () => {
      const ts = await now();
      const bad = ethers.keccak256(ethers.toUtf8Bytes("bad-policy"));
      await expect(
        pprev.connect(owner).register(
          ethers.toUtf8Bytes("x"),
          bad,
          POLICY_A,
          POLICY_S,
          ethers.encodeBytes32String("s"),
          REQ_ESCROW,
          ethers.encodeBytes32String("n5"),
          ts,
          DUMMY_SIG,
          { value: MIN_COLLATERAL },
        ),
      ).to.be.revertedWithCustomError(pprev, "PolicyNotWhitelisted");
    });

    it("reverts on insufficient collateral", async () => {
      const ts = await now();
      await expect(
        pprev.connect(owner).register(
          ethers.toUtf8Bytes("x"),
          POLICY_R,
          POLICY_A,
          POLICY_S,
          ethers.encodeBytes32String("s"),
          REQ_ESCROW,
          ethers.encodeBytes32String("n6"),
          ts,
          DUMMY_SIG,
          { value: MIN_COLLATERAL - 1n },
        ),
      ).to.be.revertedWithCustomError(pprev, "InsufficientCollateral");
    });

    it("reverts on zero reqEscrow", async () => {
      const ts = await now();
      await expect(
        pprev.connect(owner).register(
          ethers.toUtf8Bytes("x"),
          POLICY_R,
          POLICY_A,
          POLICY_S,
          ethers.encodeBytes32String("s"),
          0n,
          ethers.encodeBytes32String("n7"),
          ts,
          DUMMY_SIG,
          { value: MIN_COLLATERAL },
        ),
      ).to.be.revertedWithCustomError(pprev, "InvalidEscrowAmount");
    });

    it("reverts on empty txData", async () => {
      const ts = await now();
      await expect(
        pprev.connect(owner).register(
          "0x",
          POLICY_R,
          POLICY_A,
          POLICY_S,
          ethers.encodeBytes32String("s"),
          REQ_ESCROW,
          ethers.encodeBytes32String("n8"),
          ts,
          DUMMY_SIG,
          { value: MIN_COLLATERAL },
        ),
      ).to.be.revertedWithCustomError(pprev, "EmptyTxData");
    });

    it("reverts on reused nonce", async () => {
      const nonce = ethers.encodeBytes32String("n9");
      await doRegister(owner, "first", ethers.encodeBytes32String("a"), nonce);
      const ts = await now();
      await expect(
        pprev.connect(owner).register(
          ethers.toUtf8Bytes("second"),
          POLICY_R,
          POLICY_A,
          POLICY_S,
          ethers.encodeBytes32String("b"),
          REQ_ESCROW,
          nonce,
          ts,
          DUMMY_SIG,
          { value: MIN_COLLATERAL },
        ),
      ).to.be.revertedWithCustomError(pprev, "NonceAlreadyUsed");
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  //  Apply
  // ────────────────────────────────────────────────────────────────────────

  describe("applyTx", () => {
    it("creates a pending application without locking the listing", async () => {
      const txID = await doRegister(owner, "a1", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA"));
      const app = await pprev.getApplication(appId);
      expect(app.applicant).to.equal(await applicant.getAddress());
      expect(app.status).to.equal(1n); // PENDING

      const l = await pprev.getListing(txID);
      expect(l.state).to.equal(1n); // ACTIVE
    });

    it("rejects listing owner applying to own listing", async () => {
      const txID = await doRegister(owner, "a2", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR2"));
      const ts = await now();
      await expect(
        pprev
          .connect(owner)
          .applyTx(txID, ethers.encodeBytes32String("nA2"), ts, DUMMY_SIG, { value: REQ_ESCROW }),
      ).to.be.revertedWithCustomError(pprev, "CannotApplyToOwnListing");
    });

    it("rejects insufficient escrow", async () => {
      const txID = await doRegister(owner, "a3", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR3"));
      const ts = await now();
      await expect(
        pprev
          .connect(applicant)
          .applyTx(txID, ethers.encodeBytes32String("nA3"), ts, DUMMY_SIG, { value: REQ_ESCROW - 1n }),
      ).to.be.revertedWithCustomError(pprev, "InsufficientEscrow");
    });

    it("rejects unknown txID", async () => {
      const fakeId = ethers.encodeBytes32String("nope");
      const ts = await now();
      await expect(
        pprev
          .connect(applicant)
          .applyTx(fakeId, ethers.encodeBytes32String("nA4"), ts, DUMMY_SIG, { value: REQ_ESCROW }),
      ).to.be.revertedWithCustomError(pprev, "TxNotActive");
    });

    it("rejects duplicate pending application by same applicant", async () => {
      const txID = await doRegister(owner, "a5", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR5"));
      await doApply(applicant, txID, ethers.encodeBytes32String("nA5a"));
      const ts = await now();
      await expect(
        pprev
          .connect(applicant)
          .applyTx(txID, ethers.encodeBytes32String("nA5b"), ts, DUMMY_SIG, { value: REQ_ESCROW }),
      ).to.be.revertedWithCustomError(pprev, "DuplicateApplication");
    });

    it("allows two different applicants on the same listing", async () => {
      const txID = await doRegister(owner, "a6", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR6"));
      const app1 = await doApply(applicant, txID, ethers.encodeBytes32String("nA6a"));
      const app2 = await doApply(other, txID, ethers.encodeBytes32String("nA6b"));
      expect(app1).to.not.equal(app2);
      expect((await pprev.getApplication(app1)).status).to.equal(1n);
      expect((await pprev.getApplication(app2)).status).to.equal(1n);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  //  Engage
  // ────────────────────────────────────────────────────────────────────────

  describe("engage", () => {
    it("transitions listing to LOCKED and app to ENGAGED", async () => {
      const txID = await doRegister(owner, "e1", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA"));
      const engId = await doEngage(owner, appId);

      const l = await pprev.getListing(txID);
      const a = await pprev.getApplication(appId);
      const e = await pprev.getEngagement(engId);
      expect(l.state).to.equal(2n); // LOCKED
      expect(a.status).to.equal(2n); // ENGAGED
      expect(e.status).to.equal(1n); // ACTIVE
    });

    it("rejects non-owner caller", async () => {
      const txID = await doRegister(owner, "e2", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR2"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA2"));
      await expect(pprev.connect(other).engage(appId, 0n)).to.be.revertedWithCustomError(
        pprev,
        "CallerNotListingOwner",
      );
    });

    it("respects custom lockWindow", async () => {
      const custom = 12345n;
      const txID = await doRegister(owner, "e3", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR3"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA3"));
      const engId = await doEngage(owner, appId, custom);
      const e = await pprev.getEngagement(engId);
      const expectedExpiresAt = (await now()) + custom;
      // expiresAt was computed at block.timestamp of the engage tx; allow ±2s tolerance
      expect(e.expiresAt).to.be.greaterThanOrEqual(expectedExpiresAt - 2n);
      expect(e.expiresAt).to.be.lessThanOrEqual(expectedExpiresAt + 2n);
    });

    it("rejects engagement on already-engaged application", async () => {
      const txID = await doRegister(owner, "e4", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR4"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA4"));
      await doEngage(owner, appId);
      await expect(pprev.connect(owner).engage(appId, 0n)).to.be.revertedWithCustomError(
        pprev,
        "ApplicationNotPending",
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  //  Settle / Expire / Cancel
  // ────────────────────────────────────────────────────────────────────────

  describe("settle", () => {
    it("transfers escrow + collateral on success", async () => {
      const ownerStart = await ethers.provider.getBalance(await owner.getAddress());
      const txID = await doRegister(owner, "s1", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA"));
      const engId = await doEngage(owner, appId);
      await doSettle(owner, engId, ethers.encodeBytes32String("nS"));

      const l = await pprev.getListing(txID);
      expect(l.state).to.equal(3n); // SETTLED

      const ownerEnd = await ethers.provider.getBalance(await owner.getAddress());
      // Owner net: -collateral + collateral + escrow - gas. Compare to +escrow tolerance for gas.
      expect(ownerEnd).to.be.greaterThan(ownerStart + REQ_ESCROW - ethers.parseEther("0.01"));
    });

    it("rejects non-owner settle", async () => {
      const txID = await doRegister(owner, "s2", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR2"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA2"));
      const engId = await doEngage(owner, appId);
      const ts = await now();
      await expect(
        pprev.connect(other).settle(engId, ethers.encodeBytes32String("nS2"), ts, DUMMY_SIG),
      ).to.be.revertedWithCustomError(pprev, "CallerNotListingOwner");
    });

    it("emits Settled", async () => {
      const txID = await doRegister(owner, "s3", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR3"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA3"));
      const engId = await doEngage(owner, appId);
      const ts = await now();
      await expect(
        pprev.connect(owner).settle(engId, ethers.encodeBytes32String("nS3"), ts, DUMMY_SIG),
      )
        .to.emit(pprev, "Settled")
        .withArgs(engId, txID, await applicant.getAddress(), REQ_ESCROW, MIN_COLLATERAL);
    });
  });

  describe("expire", () => {
    it("returns escrow + 10% slash to applicant", async () => {
      const appBalanceStart = await ethers.provider.getBalance(await applicant.getAddress());

      const txID = await doRegister(owner, "x1", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA"));
      const engId = await doEngage(owner, appId);

      await ethers.provider.send("evm_increaseTime", [Number(DEFAULT_LOCK) + 1]);
      await ethers.provider.send("evm_mine", []);
      await pprev.connect(other).expire(engId);

      const appBalanceEnd = await ethers.provider.getBalance(await applicant.getAddress());
      // applicant paid REQ_ESCROW (apply) + gas, then got back REQ_ESCROW + slash = MIN_COLLATERAL/10
      // Net should be ~ +MIN_COLLATERAL/10 - gas
      expect(appBalanceEnd).to.be.greaterThan(
        appBalanceStart + MIN_COLLATERAL / 10n - ethers.parseEther("0.01"),
      );
    });

    it("rejects expire before timeout", async () => {
      const txID = await doRegister(owner, "x2", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA"));
      const engId = await doEngage(owner, appId);
      await expect(pprev.connect(other).expire(engId)).to.be.revertedWithCustomError(
        pprev,
        "EngagementNotYetExpirable",
      );
    });

    it("returns listing to ACTIVE after a single expiration", async () => {
      const txID = await doRegister(owner, "x3", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA"));
      const engId = await doEngage(owner, appId);
      await ethers.provider.send("evm_increaseTime", [Number(DEFAULT_LOCK) + 1]);
      await ethers.provider.send("evm_mine", []);
      await pprev.connect(other).expire(engId);

      const l = await pprev.getListing(txID);
      expect(l.state).to.equal(1n); // ACTIVE
      expect(l.expirationCount).to.equal(1n);
    });
  });

  describe("cancel", () => {
    it("returns collateral and sets state to CANCELLED", async () => {
      const ownerStart = await ethers.provider.getBalance(await owner.getAddress());
      const txID = await doRegister(owner, "c1", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      await pprev.connect(owner).cancel(txID);

      const l = await pprev.getListing(txID);
      expect(l.state).to.equal(4n); // CANCELLED
      const ownerEnd = await ethers.provider.getBalance(await owner.getAddress());
      // Owner started with collateral deducted then refunded; net is just gas costs
      expect(ownerEnd).to.be.greaterThan(ownerStart - ethers.parseEther("0.01"));
    });

    it("rejects non-owner cancel", async () => {
      const txID = await doRegister(owner, "c2", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      await expect(pprev.connect(other).cancel(txID)).to.be.revertedWithCustomError(
        pprev,
        "CallerNotListingOwner",
      );
    });

    it("rejects cancel after engagement (listing LOCKED)", async () => {
      const txID = await doRegister(owner, "c3", ethers.encodeBytes32String("s"), ethers.encodeBytes32String("nR"));
      const appId = await doApply(applicant, txID, ethers.encodeBytes32String("nA"));
      await doEngage(owner, appId);
      await expect(pprev.connect(owner).cancel(txID)).to.be.revertedWithCustomError(
        pprev,
        "TxNotActive",
      );
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  //  ECDSANotaryVerifier round-trip
  // ────────────────────────────────────────────────────────────────────────

  describe("ECDSANotaryVerifier round-trip", () => {
    let pprev2: PPREVSingle;
    let notarySigner: HardhatEthersSigner;

    beforeEach(async () => {
      // Use the 5th hardhat signer as the notary
      const signers = await ethers.getSigners();
      notarySigner = signers[5];

      const Verifier = await ethers.getContractFactory("ECDSANotaryVerifier", admin);
      const ecdsaVerifier = (await Verifier.deploy(
        await notarySigner.getAddress(),
      )) as unknown as ECDSANotaryVerifier;

      const PPREV = await ethers.getContractFactory("PPREVSingle", admin);
      pprev2 = (await PPREV.deploy(
        await ecdsaVerifier.getAddress(),
        FRESHNESS,
        DEFAULT_LOCK,
        MIN_COLLATERAL,
      )) as unknown as PPREVSingle;
      await pprev2.connect(admin).whitelistPolicy(POLICY_R, true);
      await pprev2.connect(admin).whitelistPolicy(POLICY_A, true);
      await pprev2.connect(admin).whitelistPolicy(POLICY_S, true);
    });

    it("registers with real ECDSA signature", async () => {
      const txData = ethers.toUtf8Bytes("real");
      const salt = ethers.encodeBytes32String("r-salt");
      const nonce = ethers.encodeBytes32String("r-nonce");
      const ts = await now();
      const addr = await pprev2.getAddress();
      const txID = computeTxId(ethers.hexlify(txData), salt);
      const txDataHash = ethers.keccak256(txData);
      const raw = buildMsgR(addr, txID, txDataHash, nonce, ts);
      const sig = await notarySigner.signMessage(ethers.getBytes(raw));

      await pprev2
        .connect(owner)
        .register(txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, ts, sig, {
          value: MIN_COLLATERAL,
        });

      const l = await pprev2.getListing(txID);
      expect(l.state).to.equal(1n);
    });

    it("rejects a signature from the wrong key", async () => {
      const txData = ethers.toUtf8Bytes("realbad");
      const salt = ethers.encodeBytes32String("rb-salt");
      const nonce = ethers.encodeBytes32String("rb-nonce");
      const ts = await now();
      const addr = await pprev2.getAddress();
      const txID = computeTxId(ethers.hexlify(txData), salt);
      const txDataHash = ethers.keccak256(txData);
      const raw = buildMsgR(addr, txID, txDataHash, nonce, ts);
      const sig = await other.signMessage(ethers.getBytes(raw)); // wrong signer

      await expect(
        pprev2
          .connect(owner)
          .register(txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonce, ts, sig, {
            value: MIN_COLLATERAL,
          }),
      ).to.be.revertedWithCustomError(pprev2, "InvalidNotarySignature");
    });

    it("full lifecycle works with real signatures", async () => {
      const txData = ethers.toUtf8Bytes("fl");
      const salt = ethers.encodeBytes32String("fl-salt");
      const addr = await pprev2.getAddress();
      const txID = computeTxId(ethers.hexlify(txData), salt);
      const txDataHash = ethers.keccak256(txData);

      // Register
      const nonceR = ethers.encodeBytes32String("flR");
      const tsR = await now();
      const sigR = await notarySigner.signMessage(
        ethers.getBytes(buildMsgR(addr, txID, txDataHash, nonceR, tsR)),
      );
      await pprev2
        .connect(owner)
        .register(txData, POLICY_R, POLICY_A, POLICY_S, salt, REQ_ESCROW, nonceR, tsR, sigR, {
          value: MIN_COLLATERAL,
        });

      // Apply
      const nonceA = ethers.encodeBytes32String("flA");
      const tsA = await now();
      const sigA = await notarySigner.signMessage(
        ethers.getBytes(buildMsgA(addr, txID, nonceA, tsA)),
      );
      const applyTxR = await pprev2
        .connect(applicant)
        .applyTx(txID, nonceA, tsA, sigA, { value: REQ_ESCROW });
      const rcA = await applyTxR.wait();
      const appId = rcA!.logs
        .map((l) => {
          try {
            return pprev2.interface.parseLog(l as any);
          } catch {
            return null;
          }
        })
        .find((p) => p?.name === "ApplicationCreated")!.args[0] as string;

      // Engage
      const engTxR = await pprev2.connect(owner).engage(appId, 0n);
      const rcE = await engTxR.wait();
      const engId = rcE!.logs
        .map((l) => {
          try {
            return pprev2.interface.parseLog(l as any);
          } catch {
            return null;
          }
        })
        .find((p) => p?.name === "Engaged")!.args[0] as string;

      // Settle
      const nonceS = ethers.encodeBytes32String("flS");
      const tsS = await now();
      const sigS = await notarySigner.signMessage(
        ethers.getBytes(buildMsgS(addr, engId, txID, nonceS, tsS)),
      );
      await pprev2.connect(owner).settle(engId, nonceS, tsS, sigS);

      const l = await pprev2.getListing(txID);
      expect(l.state).to.equal(3n); // SETTLED
    });
  });
});
