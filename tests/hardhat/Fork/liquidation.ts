import { smock } from "@defi-wonderland/smock";
import chai from "chai";
import { BigNumberish, Signer } from "ethers";
import { ethers } from "hardhat";

import { convertToUnit } from "../../../helpers/utils";
import {
  AccessControlManager,
  AccessControlManager__factory,
  ChainlinkOracle,
  ChainlinkOracle__factory,
  Comptroller,
  Comptroller__factory,
  FaucetToken,
  FaucetToken__factory,
  MockToken,
  MockToken__factory,
  VToken,
  VToken__factory,
} from "../../../typechain";
import { initMainnetUser, setForkBlock } from "./utils";

const { expect } = chai;
chai.use(smock.matchers);

const FORK_TESTNET = process.env.FORK_TESTNET === "true";

const ADMIN = "0x2Ce1d0ffD7E869D9DF33e28552b12DdDed326706";
const ORACLE_ADMIN = "0xce10739590001705F7FF231611ba4A48B2820327";
const ACM = "0x45f8a08F534f34A97187626E05d4b6648Eeaa9AA";
const ORACLE = "0xfc4e26B7fD56610E84d33372435F0275A359E8eF";
const acc1 = "0xe70898180a366F204AA529708fB8f5052ea5723c";
const acc2 = "0xA4a04C2D661bB514bB8B478CaCB61145894563ef";

let impersonatedTimelock: Signer;
let impersonatedOracleOwner: Signer;
let accessControlManager: AccessControlManager;
let priceOracle: ChainlinkOracle;
let comptroller: Comptroller;
let vUSDD: VToken;
let vUSDT: VToken;
let usdd: MockToken;
let usdt: FaucetToken;
let acc1Signer: Signer;
let acc2Signer: Signer;

async function configureTimelock() {
  impersonatedTimelock = await initMainnetUser(ADMIN, ethers.utils.parseUnits("2"));
  impersonatedOracleOwner = await initMainnetUser(ORACLE_ADMIN, ethers.utils.parseUnits("2"));
}

async function configureVToken(vTokenAddress: string) {
  const VToken = VToken__factory.connect(vTokenAddress, impersonatedTimelock);
  return VToken;
}

async function grantPermissions() {
  accessControlManager = AccessControlManager__factory.connect(ACM, impersonatedTimelock);

  let tx = await accessControlManager
    .connect(impersonatedTimelock)
    .giveCallPermission(comptroller.address, "setMarketSupplyCaps(address[],uint256[])", ADMIN);
  await tx.wait();

  tx = await accessControlManager
    .connect(impersonatedTimelock)
    .giveCallPermission(comptroller.address, "setMarketBorrowCaps(address[],uint256[])", ADMIN);
  await tx.wait();

  tx = await accessControlManager
    .connect(impersonatedTimelock)
    .giveCallPermission(ORACLE, "setDirectPrice(address,uint256)", ADMIN);
  await tx.wait();

  tx = await accessControlManager
    .connect(impersonatedTimelock)
    .giveCallPermission(comptroller.address, "setMinLiquidatableCollateral(uint256)", ADMIN);
  await tx.wait();

  tx = await accessControlManager
    .connect(impersonatedTimelock)
    .giveCallPermission(comptroller.address, "setCollateralFactor(address,uint256,uint256)", ADMIN);
}
if (FORK_TESTNET) {
  describe("Liquidation", async () => {
    async function setup() {
      await setForkBlock(30080357);
      await configureTimelock();

      acc1Signer = await initMainnetUser(acc1, ethers.utils.parseUnits("2"));
      acc2Signer = await initMainnetUser(acc2, ethers.utils.parseUnits("2"));

      usdt = FaucetToken__factory.connect("0xA11c8D9DC9b66E209Ef60F0C8D969D3CD988782c", impersonatedTimelock);
      usdd = MockToken__factory.connect("0x2E2466e22FcbE0732Be385ee2FBb9C59a1098382", impersonatedTimelock);
      vUSDT = await configureVToken("0x296da137120562c79b26808c1aa142a59ebf31f4");
      vUSDD = await configureVToken("0xeD7401294EBF0A1b0721562a69031565F4a4Bacd");
      comptroller = Comptroller__factory.connect("0x605AA769d14F6Af2E405295FEC2A4d8Baa623d80", impersonatedTimelock);
      priceOracle = ChainlinkOracle__factory.connect(ORACLE, impersonatedOracleOwner);

      await grantPermissions();

      await comptroller.setMarketSupplyCaps(
        [vUSDT.address, vUSDD.address],
        [convertToUnit(1, 50), convertToUnit(1, 50)],
      );
      await comptroller.setMarketBorrowCaps(
        [vUSDT.address, vUSDD.address],
        [convertToUnit(1, 50), convertToUnit(1, 50)],
      );
      await comptroller.connect(acc1Signer).enterMarkets([vUSDT.address]);
      await comptroller.connect(acc2Signer).enterMarkets([vUSDD.address]);
    }

    describe("Liquidate from VToken", async () => {
      const mintAmount = convertToUnit("1", 17);
      const usdtBorrowAmount = convertToUnit("1", 4);
      beforeEach(async () => {
        await setup();

        await usdt.connect(acc1Signer).allocateTo(acc1, mintAmount);
        await usdt.connect(acc1Signer).approve(vUSDT.address, mintAmount);
        await expect(vUSDT.connect(acc1Signer).mint(mintAmount)).to.emit(vUSDT, "Mint");

        await usdd.connect(acc2Signer).faucet(mintAmount);
        await usdd.connect(acc2Signer).approve(vUSDD.address, mintAmount);
        await expect(vUSDD.connect(acc2Signer).mint(mintAmount)).to.emit(vUSDD, "Mint");

        await expect(vUSDT.connect(acc2Signer).borrow(usdtBorrowAmount)).to.emit(vUSDT, "Borrow");

        await usdt.connect(acc1Signer).allocateTo(acc1, convertToUnit("1", 18));
        await usdt.connect(acc1Signer).approve(vUSDT.address, convertToUnit("1", 18));

        await priceOracle.setDirectPrice(vUSDD.address, "159990000000000000000");
        await priceOracle.setDirectPrice(vUSDT.address, "20800000000000000");
      });

      it("Should revert when liquidation is called through vToken and does not met minCollateral Criteria", async function () {
        await expect(
          vUSDT.connect(acc1Signer).liquidateBorrow(acc2, usdtBorrowAmount, vUSDT.address),
        ).to.be.revertedWithCustomError(comptroller, "MinimalCollateralViolated");
      });

      it("Should revert when liquidation is called through vToken and no shortfall", async function () {
        // Mint and Increase collateral of the user
        const udnerlyingMintAmount = convertToUnit("1", 30);
        await usdd.connect(acc2Signer).faucet(udnerlyingMintAmount);
        await usdd.connect(acc2Signer).approve(vUSDD.address, udnerlyingMintAmount);

        await vUSDD.connect(acc2Signer).mint(udnerlyingMintAmount);

        // Liquidation
        await expect(
          vUSDT.connect(acc1Signer).liquidateBorrow(acc2, usdtBorrowAmount, vUSDT.address),
        ).to.be.revertedWithCustomError(comptroller, "InsufficientShortfall");
      });

      it("Should revert when liquidation is called through vToken and trying to seize more tokens", async function () {
        await comptroller.setMinLiquidatableCollateral(0);
        // Mint and Increase collateral of the user
        await priceOracle.setDirectPrice(usdd.address, convertToUnit("1", 5));
        // Liquidation
        await expect(vUSDT.connect(acc1Signer).liquidateBorrow(acc2, 201, vUSDD.address)).to.be.revertedWith(
          "LIQUIDATE_SEIZE_TOO_MUCH",
        );
      });

      it("Should revert when liquidation is called through vToken and trying to pay too much", async function () {
        // Mint and Incrrease collateral of the user
        await comptroller.setMinLiquidatableCollateral(0);
        const udnerlyingMintAmount = convertToUnit("1", 18);
        await usdd.connect(acc2Signer).faucet(udnerlyingMintAmount);
        await usdd.connect(acc2Signer).approve(vUSDD.address, udnerlyingMintAmount);

        await expect(vUSDD.connect(acc2Signer).mint(udnerlyingMintAmount)).to.emit(vUSDD, "Mint");
        // price manipulation and borrow to overcome insufficient shortfall

        await priceOracle.setDirectPrice(usdd.address, convertToUnit("1", 5));
        // Liquidation
        await expect(
          vUSDT.connect(acc1Signer).liquidateBorrow(acc2, convertToUnit("1", 18), vUSDD.address),
        ).to.be.revertedWithCustomError(comptroller, "TooMuchRepay");
      });

      it("liquidate user", async () => {
        await comptroller.setMinLiquidatableCollateral(0);
        await priceOracle.setDirectPrice(usdd.address, convertToUnit("100", 15));
        const borrowBalance = await vUSDT.borrowBalanceStored(acc2);
        const closeFactor = await comptroller.closeFactorMantissa();
        const maxClose = (borrowBalance * closeFactor) / 1e18;
        const result = vUSDT.connect(acc1Signer).liquidateBorrow(acc2, maxClose.toString(), vUSDD.address);
        await expect(result).to.emit(vUSDT, "LiquidateBorrow");
      });
    });

    describe("Liquidate from Comptroller", async () => {
      const mintAmount: BigNumberish = convertToUnit(1, 15);
      const usdtBorrowAmount: BigNumberish = convertToUnit(1, 15);
      const insufficientLiquidityBorrow: BigNumberish = convertToUnit(3, 18);
      beforeEach(async () => {
        await setup();
        await priceOracle.setDirectPrice(usdd.address, "159990000000000000000");
        await priceOracle.setDirectPrice(usdt.address, "208000");

        await usdt.connect(acc1Signer).allocateTo(acc1, mintAmount);
        await usdt.connect(acc1Signer).approve(vUSDT.address, mintAmount);
        await expect(vUSDT.connect(acc1Signer).mint(mintAmount)).to.emit(vUSDT, "Mint");

        await usdd.connect(acc2Signer).faucet(mintAmount);
        await usdd.connect(acc2Signer).approve(vUSDD.address, mintAmount);
        await expect(vUSDD.connect(acc2Signer).mint(mintAmount)).to.emit(vUSDD, "Mint");
        await expect(vUSDT.connect(acc2Signer).borrow(usdtBorrowAmount)).to.emit(vUSDT, "Borrow");

        // Approve more assets for liquidation
        await usdt.connect(acc1Signer).allocateTo(acc1, insufficientLiquidityBorrow);
        await usdt.connect(acc1Signer).approve(vUSDT.address, insufficientLiquidityBorrow);
      });

      it("Should revert when not enough collateral to seize", async function () {
        await usdd.connect(acc2Signer).faucet(1e10);
        await usdd.connect(acc2Signer).approve(vUSDD.address, 1e10);
        await vUSDD.connect(acc2Signer).mint(1e10);

        // Repay amount does not make borrower principal to zero
        const repayAmount = Number(usdtBorrowAmount) / 2;
        const param = {
          vTokenCollateral: vUSDD.address,
          vTokenBorrowed: vUSDT.address,
          repayAmount: repayAmount,
        };
        await priceOracle.setDirectPrice(usdd.address, convertToUnit("100", 12));
        await expect(comptroller.connect(acc1Signer).liquidateAccount(acc2, [param])).to.be.revertedWithCustomError(
          comptroller,
          "InsufficientCollateral",
        );
      });

      it("Should success on liquidation when repay amount is equal to borrowing", async function () {
        await usdd.connect(acc2Signer).faucet(10900000000);
        await usdd.connect(acc2Signer).approve(vUSDD.address, 10900000000);
        await vUSDD.connect(acc2Signer).mint(10900000000);

        await priceOracle.setDirectPrice(usdd.address, convertToUnit("1", 14)); // 100000000000000
        await priceOracle.setDirectPrice(usdt.address, convertToUnit("1", 2)); // 100000000000000

        const repayAmount = 1000001022346902; // After interest accrual

        const param = {
          vTokenCollateral: vUSDD.address,
          vTokenBorrowed: vUSDT.address,
          repayAmount: repayAmount,
        };
        const result = comptroller.connect(acc1Signer).liquidateAccount(acc2, [param]);
        await expect(result).to.emit(vUSDT, "LiquidateBorrow");
        expect(await vUSDT.borrowBalanceStored(acc2)).equals(0);
      });
    });

    describe("Heal Borrow and Forgive account", () => {
      const mintAmount = convertToUnit("1", 12);
      const usdtBorrowAmount = convertToUnit(1, 4);
      let result;

      beforeEach(async () => {
        await setup();
        await priceOracle.setDirectPrice(usdd.address, "159990000000000000000");
        await priceOracle.setDirectPrice(usdt.address, "208000");

        await usdt.connect(acc1Signer).allocateTo(acc1, mintAmount);
        await usdt.connect(acc1Signer).approve(vUSDT.address, mintAmount);
        await expect(vUSDT.connect(acc1Signer).mint(mintAmount)).to.emit(vUSDT, "Mint");

        await usdd.connect(acc2Signer).faucet(mintAmount);
        await usdd.connect(acc2Signer).approve(vUSDD.address, mintAmount);
        await expect(vUSDD.connect(acc2Signer).mint(mintAmount)).to.emit(vUSDD, "Mint");

        await expect(vUSDT.connect(acc2Signer).borrow(usdtBorrowAmount)).to.emit(vUSDT, "Borrow");
        // Approve more assets for liquidation
        await usdt.connect(acc1Signer).allocateTo(acc1, usdtBorrowAmount);
        await usdt.connect(acc1Signer).approve(vUSDT.address, usdtBorrowAmount);
      });

      it("Should success on healing and forgive borrow account", async function () {
        // Increase price of borrowed underlying tokens to surpass available collateral
        await priceOracle.setDirectPrice(usdt.address, convertToUnit(1, 13)); // 25
        await priceOracle.setDirectPrice(usdd.address, convertToUnit(1, 15)); // 15
        /*
        Calculations
        snapshot.totalCollateral 1e9  // (bnxPrice * mint amount) / mantissa
        snapshot.borrows 1e11    //  (BTCBPrice * BTCBBorrowAmount) / mantissa
        percantage 0.1   (collateral/borrow) * mantissa
        repaymentAmount 1000       percentage*borrowBalance 
        borrowBalance 10000
        */
        const collateralAmount = 1e9;
        const borrowAmount = 1e11;
        const percantageOfRepay = (collateralAmount / borrowAmount) * 1e18;
        const repayAmount = usdtBorrowAmount * (percantageOfRepay / 1e18);
        const badDebt = usdtBorrowAmount - repayAmount;
        result = await comptroller.connect(acc1Signer).healAccount(acc2);
        await expect(result).to.emit(vUSDT, "RepayBorrow");

        // Forgive Account
        result = await vUSDT.connect(acc2Signer).getAccountSnapshot(acc2);
        expect(result.vTokenBalance).to.equal(0);
        expect(result.borrowBalance).to.equal(0);
        const badDebtAfter = await vUSDT.badDebt();
        expect(badDebtAfter).to.closeTo(badDebt, 1);
      });
    });
  });
}
