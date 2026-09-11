# Savings service instructions

## Ownership

Own savings product versions, customer savings accounts/goals, mandates/instructions, deposits and withdrawal intent, interest configuration/accrual, fixed deposits, maturity instructions, penalties and savings inbox/outbox state. Own only the `parc_savings` database.

## Domain rules

- Savings product terms are versioned; existing accounts/fixed deposits retain the agreed version unless an explicit migration is approved.
- Treat ledger balances as financial truth. Local balances/projections, if present, are clearly labeled and reconcilable.
- Deposit and withdrawal flows are idempotent state machines coordinated through payment and ledger contracts.
- Interest, penalties and maturity values use exact arithmetic with documented rounding, compounding and day-count rules.
- Fixed-deposit principal and terms become immutable after activation; early liquidation follows an explicit auditable policy.
- Do not claim funds are available until the authoritative payment/ledger outcome is known.

## Database and delivery

- Canonical migrations: `db/migrations/`; generated snapshot: `db/schema/current.sql`.
- Test maturity boundaries, leap dates/time zones, rounding, partial failures, duplicate events, early liquidation, reconciliation and tenant isolation.
- Calculation changes require golden examples and impact analysis for active savings accounts and deposits.
