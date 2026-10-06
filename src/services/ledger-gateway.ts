export interface SavingsLedgerGateway {
  provisionAccount(input: {
    tenantId: string;
    customerId: string;
    purpose:
      | "WALLET"
      | "ORDINARY_SAVINGS"
      | "TARGET_SAVINGS"
      | "FIXED_DEPOSIT"
      | "SAVINGS_INTEREST_EXPENSE"
      | "SAVINGS_PENALTY_INCOME";
    ownerType?: "CUSTOMER" | "TENANT";
    accountType?: "LIABILITY" | "EXPENSE" | "REVENUE";
    currency: "NGN";
    idempotencyKey: string;
  }): Promise<{ accountId: string; replayed: boolean }>;
  postContribution(input: {
    tenantId: string;
    walletAccountId: string;
    savingsAccountId: string;
    amountMinor: string;
    currency: "NGN";
    reference: string;
    idempotencyKey: string;
  }): Promise<{
    transactionId: string;
    journalId: string;
    replayed: boolean;
  }>;
  postWithdrawal(input: {
    tenantId: string;
    savingsAccountId: string;
    walletAccountId: string;
    amountMinor: string;
    currency: "NGN";
    reference: string;
    idempotencyKey: string;
  }): Promise<{ transactionId: string; journalId: string; replayed: boolean }>;
  postFixedDepositSettlement(input: {
    tenantId: string;
    fixedDepositAccountId: string;
    walletAccountId: string;
    interestExpenseAccountId: string;
    penaltyIncomeAccountId: string;
    principalMinor: string;
    interestMinor: string;
    penaltyMinor: string;
    currency: "NGN";
    reference: string;
    idempotencyKey: string;
  }): Promise<{ transactionId: string; journalId: string; replayed: boolean }>;
  postInterestPayment?(input: {
    tenantId: string;
    interestExpenseAccountId: string;
    savingsAccountId: string;
    amountMinor: string;
    currency: "NGN";
    reference: string;
    idempotencyKey: string;
  }): Promise<{ transactionId: string; journalId: string; replayed: boolean }>;
  getBalance(input: { tenantId: string; accountId: string }): Promise<{
    postedBalanceMinor: string;
    heldBalanceMinor: string;
    availableBalanceMinor: string;
    version: number;
  }>;
}
