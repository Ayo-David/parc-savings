--
-- PostgreSQL database dump
--

-- Dumped from database version 14.18 (Homebrew)
-- Dumped by pg_dump version 14.18 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: adjustment_type_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.adjustment_type_enum AS ENUM (
    'INTEREST_CREDIT',
    'INTEREST_REVERSAL',
    'FEE_WAIVER',
    'FEE_ADJUSTMENT',
    'PRINCIPAL_ADJUSTMENT',
    'OTHER'
);


--
-- Name: fixed_deposit_payout_method_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.fixed_deposit_payout_method_enum AS ENUM (
    'UPFRONT',
    'MONTHLY',
    'AT_MATURITY'
);


--
-- Name: fixed_deposit_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.fixed_deposit_status_enum AS ENUM (
    'PENDING',
    'ACTIVE',
    'MATURED',
    'WITHDRAWN',
    'RENEWED',
    'CANCELLED',
    'LIQUIDATED'
);


--
-- Name: interest_calculation_method_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.interest_calculation_method_enum AS ENUM (
    'DAILY_BALANCE',
    'AVERAGE_DAILY_BALANCE',
    'FIXED'
);


--
-- Name: interest_payment_frequency_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.interest_payment_frequency_enum AS ENUM (
    'DAILY',
    'MONTHLY',
    'QUARTERLY',
    'ANNUALLY',
    'AT_MATURITY'
);


--
-- Name: milestone_type_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.milestone_type_enum AS ENUM (
    'PERCENTAGE',
    'AMOUNT',
    'DATE'
);


--
-- Name: recurring_frequency_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.recurring_frequency_enum AS ENUM (
    'DAILY',
    'WEEKLY',
    'BIWEEKLY',
    'MONTHLY',
    'QUARTERLY'
);


--
-- Name: savings_account_holder_role_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.savings_account_holder_role_enum AS ENUM (
    'PRIMARY',
    'JOINT',
    'BENEFICIARY'
);


--
-- Name: savings_account_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.savings_account_status_enum AS ENUM (
    'PENDING',
    'ACTIVE',
    'SUSPENDED',
    'FROZEN',
    'CLOSED'
);


--
-- Name: savings_account_transaction_direction_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.savings_account_transaction_direction_enum AS ENUM (
    'CREDIT',
    'DEBIT'
);


--
-- Name: savings_account_transaction_type_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.savings_account_transaction_type_enum AS ENUM (
    'DEPOSIT',
    'WITHDRAWAL',
    'TRANSFER_IN',
    'TRANSFER_OUT',
    'GOAL_CONTRIBUTION',
    'GOAL_WITHDRAWAL',
    'INTEREST_ACCRUAL',
    'INTEREST_PAYMENT',
    'INTEREST_REVERSAL',
    'FEE',
    'FEE_REVERSAL',
    'FIXED_DEPOSIT_PLACEMENT',
    'FIXED_DEPOSIT_MATURITY',
    'FIXED_DEPOSIT_WITHDRAWAL',
    'FIXED_DEPOSIT_RENEWAL',
    'ADJUSTMENT',
    'REVERSAL'
);


--
-- Name: savings_goal_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.savings_goal_status_enum AS ENUM (
    'ACTIVE',
    'PAUSED',
    'COMPLETED',
    'CANCELLED',
    'EXPIRED'
);


--
-- Name: savings_product_type_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.savings_product_type_enum AS ENUM (
    'REGULAR',
    'TARGET',
    'FIXED_DEPOSIT',
    'PREMIUM_YIELD',
    'ORDINARY',
    'RECURRING'
);


--
-- Name: savings_transaction_channel_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.savings_transaction_channel_enum AS ENUM (
    'BANK_TRANSFER',
    'INTERNAL_TRANSFER',
    'CARD',
    'DIRECT_DEBIT',
    'CASH',
    'USSD',
    'ADMIN',
    'SYSTEM'
);


--
-- Name: savings_transaction_status_enum; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.savings_transaction_status_enum AS ENUM (
    'PENDING',
    'PROCESSING',
    'SUCCESSFUL',
    'FAILED',
    'REVERSED',
    'CANCELLED'
);


--
-- Name: savings_apply_hold(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_apply_hold() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE a savings_accounts%ROWTYPE; delta NUMERIC(20,2); w savings_withdrawals%ROWTYPE; t savings_transfer_requests%ROWTYPE;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Holds cannot be deleted'; END IF;
 SELECT * INTO a FROM savings_accounts WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id FOR UPDATE;
 IF NOT FOUND OR a.currency<>NEW.currency THEN RAISE EXCEPTION 'Hold account/currency mismatch'; END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.status<>'ACTIVE' THEN RAISE EXCEPTION 'New hold must be ACTIVE'; END IF;
  IF NEW.withdrawal_id IS NOT NULL THEN
   SELECT * INTO w FROM savings_withdrawals WHERE tenant_id=NEW.tenant_id AND id=NEW.withdrawal_id;
   IF NOT FOUND OR w.savings_account_id<>NEW.savings_account_id OR w.amount+w.fee_amount<>NEW.amount OR w.operation_id<>NEW.operation_id
      OR NEW.hold_type<>'WITHDRAWAL' THEN RAISE EXCEPTION 'Hold does not match withdrawal'; END IF;
  ELSIF NEW.transfer_request_id IS NOT NULL THEN
   SELECT * INTO t FROM savings_transfer_requests WHERE tenant_id=NEW.tenant_id AND id=NEW.transfer_request_id;
   IF NOT FOUND OR t.source_savings_account_id<>NEW.savings_account_id OR t.amount<>NEW.amount OR t.operation_id<>NEW.operation_id
      OR NEW.hold_type<>'TRANSFER' THEN RAISE EXCEPTION 'Hold does not match transfer'; END IF;
  END IF;
  IF a.status<>'ACTIVE' AND NEW.hold_type NOT IN ('COMPLIANCE','ADMIN') THEN RAISE EXCEPTION 'Account not active'; END IF;
  IF EXISTS (SELECT 1 FROM savings_account_restrictions r WHERE r.tenant_id=NEW.tenant_id AND r.savings_account_id=NEW.savings_account_id
     AND r.restriction_type IN ('NO_DEBIT','FROZEN') AND r.released_at IS NULL AND r.starts_at<=now() AND (r.ends_at IS NULL OR r.ends_at>now()))
     AND NEW.hold_type NOT IN ('COMPLIANCE','ADMIN') THEN RAISE EXCEPTION 'Account debit restricted'; END IF;
  delta=NEW.amount;
 ELSE
  IF OLD.status<>'ACTIVE' THEN RAISE EXCEPTION 'Resolved hold is immutable'; END IF;
  IF (to_jsonb(NEW)-ARRAY['status','resolved_at','resolution_evidence','ledger_capture_transaction_id']) IS DISTINCT FROM
     (to_jsonb(OLD)-ARRAY['status','resolved_at','resolution_evidence','ledger_capture_transaction_id']) THEN
   RAISE EXCEPTION 'Only hold resolution fields may change'; END IF;
  IF NEW.status='ACTIVE' THEN RAISE EXCEPTION 'Update must resolve hold'; END IF;
  delta=-OLD.amount;
 END IF;
 IF delta>0 AND a.available_balance<delta THEN RAISE EXCEPTION 'Insufficient available balance'; END IF;
 UPDATE savings_accounts SET held_balance=held_balance+delta WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id;
 RETURN NEW;
END $$;


--
-- Name: savings_check_capture(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_check_capture() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE total NUMERIC(20,2);
BEGIN
 IF NEW.status='CAPTURED' THEN
  SELECT COALESCE(sum(amount),0) INTO total FROM savings_account_transactions
   WHERE tenant_id=NEW.tenant_id AND savings_account_id=NEW.savings_account_id AND operation_id=NEW.operation_id
     AND ledger_transaction_id=NEW.ledger_capture_transaction_id AND direction='DEBIT' AND transaction_type<>'INTEREST_ACCRUAL';
  IF total<>NEW.amount THEN RAISE EXCEPTION 'Captured hold must match debit journal legs in the same transaction'; END IF;
 END IF;
 RETURN NULL;
END $$;


--
-- Name: savings_check_interest_total(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_check_interest_total() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE total bigint;
    BEGIN
      IF NEW.status='SUCCESSFUL' AND NEW.settlement_basis='ACCRUED' THEN
        SELECT sum(allocated_minor) INTO total FROM savings_interest_payment_accruals WHERE tenant_id=NEW.tenant_id AND interest_payment_id=NEW.id;
        IF total IS NULL OR total+NEW.rounding_adjustment<>NEW.amount THEN RAISE EXCEPTION 'Allocated minor units plus residual must equal posted interest'; END IF;
      END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_project_journal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_project_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
 UPDATE savings_accounts SET current_balance=NEW.balance_after,last_ledger_sequence=NEW.ledger_sequence,ledger_synced_at=now()
 WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id;
 RETURN NEW;
END $$;


--
-- Name: savings_protect_accrual(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_accrual() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Accruals cannot be deleted'; END IF;
 IF OLD.posted THEN RAISE EXCEPTION 'Posted accrual is immutable; use correction table'; END IF;
 IF (to_jsonb(NEW)-ARRAY['posted','posted_at','ledger_transaction_id']) IS DISTINCT FROM
    (to_jsonb(OLD)-ARRAY['posted','posted_at','ledger_transaction_id']) THEN
  RAISE EXCEPTION 'Calculated accrual data is immutable'; END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_protect_deposit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_deposit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Savings deposits cannot be deleted'; END IF;
      IF OLD.status='SUCCESSFUL' THEN RAISE EXCEPTION 'Successful savings deposits are immutable'; END IF;
      IF (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.amount,NEW.currency,NEW.operation_id,NEW.idempotency_key,NEW.request_hash)
         IS DISTINCT FROM
         (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.amount,OLD.currency,OLD.operation_id,OLD.idempotency_key,OLD.request_hash)
      THEN RAISE EXCEPTION 'Savings deposit command identity is immutable'; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_protect_fd_instruction(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_fd_instruction() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Fixed-deposit instructions cannot be deleted'; END IF;
      IF (to_jsonb(NEW)-ARRAY['superseded_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['superseded_at']) OR OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL
      THEN RAISE EXCEPTION 'Fixed-deposit instruction is immutable except for one-time supersession'; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_protect_fixed_deposit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_fixed_deposit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Fixed deposits cannot be deleted'; END IF;
      IF OLD.status IN ('ACTIVE','MATURED','LIQUIDATED','RENEWED') AND
        (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.principal_amount,NEW.currency,NEW.interest_rate,NEW.tenure_days,NEW.start_date,NEW.maturity_date,NEW.product_version_id,NEW.fixed_deposit_rate_id,NEW.contract_reference,NEW.accepted_at,NEW.accepted_terms_hash,NEW.terms_snapshot,NEW.day_count_basis,NEW.compounding_method,NEW.early_liquidation_allowed,NEW.early_liquidation_penalty_rate,NEW.maturity_instruction_cutoff_days,NEW.placement_idempotency_key,NEW.placement_request_hash)
        IS DISTINCT FROM
        (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.principal_amount,OLD.currency,OLD.interest_rate,OLD.tenure_days,OLD.start_date,OLD.maturity_date,OLD.product_version_id,OLD.fixed_deposit_rate_id,OLD.contract_reference,OLD.accepted_at,OLD.accepted_terms_hash,OLD.terms_snapshot,OLD.day_count_basis,OLD.compounding_method,OLD.early_liquidation_allowed,OLD.early_liquidation_penalty_rate,OLD.maturity_instruction_cutoff_days,OLD.placement_idempotency_key,OLD.placement_request_hash)
      THEN RAISE EXCEPTION 'Active fixed-deposit contract is immutable'; END IF;
      IF OLD.status IN ('MATURED','LIQUIDATED','RENEWED','CANCELLED','WITHDRAWN') AND NEW.status<>OLD.status THEN RAISE EXCEPTION 'Terminal fixed-deposit status is immutable'; END IF;
      IF NEW.status<>OLD.status AND NOT ((OLD.status='PENDING' AND NEW.status IN ('ACTIVE','CANCELLED')) OR (OLD.status='ACTIVE' AND NEW.status IN ('MATURED','LIQUIDATED','RENEWED','CANCELLED'))) THEN RAISE EXCEPTION 'Invalid fixed-deposit transition'; END IF;
      IF NEW.aggregate_version<=OLD.aggregate_version THEN NEW.aggregate_version=OLD.aggregate_version+1; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_protect_goal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_goal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Savings goals cannot be deleted'; END IF;
      IF (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.target_amount,NEW.currency,NEW.target_date,NEW.product_terms_hash,NEW.partial_withdrawal_limit_rate,NEW.partial_withdrawal_limit_count,NEW.withdrawn_interest_forfeiture,NEW.break_forfeits_all_interest,NEW.creation_idempotency_key,NEW.creation_request_hash)
         IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.target_amount,OLD.currency,OLD.target_date,OLD.product_terms_hash,OLD.partial_withdrawal_limit_rate,OLD.partial_withdrawal_limit_count,OLD.withdrawn_interest_forfeiture,OLD.break_forfeits_all_interest,OLD.creation_idempotency_key,OLD.creation_request_hash)
      THEN RAISE EXCEPTION 'Savings goal contract is immutable'; END IF;
      IF OLD.status<>'ACTIVE' AND NEW.status<>OLD.status THEN RAISE EXCEPTION 'Terminal savings goal status is immutable'; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_protect_goal_final(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_goal_final() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Final goal operations cannot be deleted'; END IF;
      IF OLD.status='SUCCESSFUL' THEN RAISE EXCEPTION 'Successful goal operations are immutable'; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_protect_success(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_success() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE k TEXT;
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Financial workflow rows cannot be deleted'; END IF;
 IF OLD.status::text IN ('SUCCESSFUL','REVERSED','CANCELLED') THEN
  RAISE EXCEPTION 'Final financial row is immutable: %',TG_TABLE_NAME;
 END IF;
 IF NEW.tenant_id<>OLD.tenant_id OR NEW.id<>OLD.id THEN RAISE EXCEPTION 'Identity is immutable'; END IF;
 FOREACH k IN ARRAY ARRAY['amount','fee_amount','currency','customer_id','savings_account_id',
 'source_savings_account_id','destination_savings_account_id','destination_account_id',
 'goal_id','withdrawal_id','fixed_deposit_id','recurring_plan_id',
 'operation_id','idempotency_key','created_by','direction','adjustment_type',
 'principal_amount','interest_due','interest_clawback','penalty_amount','tax_amount',
 'payment_period_start','payment_period_end','rounding_adjustment','unpaid_interest','settlement_basis'] LOOP
  IF to_jsonb(NEW)->k IS DISTINCT FROM to_jsonb(OLD)->k THEN RAISE EXCEPTION 'Financial request field % is immutable',k; END IF;
 END LOOP;
 IF to_jsonb(OLD)->>'deposit_id' IS NOT NULL AND to_jsonb(NEW)->'deposit_id' IS DISTINCT FROM to_jsonb(OLD)->'deposit_id' THEN
  RAISE EXCEPTION 'Linked deposit is immutable once assigned'; END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_protect_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_version() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Savings product versions cannot be deleted'; END IF;
      IF OLD.status IN ('PUBLISHED','RETIRED') AND NOT (OLD.status='PUBLISHED' AND NEW.status='RETIRED' AND NEW.is_current=false AND (to_jsonb(NEW)-ARRAY['status','is_current','effective_to','updated_at']::text[])=(to_jsonb(OLD)-ARRAY['status','is_current','effective_to','updated_at']::text[])) THEN RAISE EXCEPTION 'Published savings product versions are immutable'; END IF;
      IF (NEW.tenant_id,NEW.id,NEW.savings_product_id,NEW.version_number) IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.savings_product_id,OLD.version_number) THEN RAISE EXCEPTION 'Version identity is immutable'; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_protect_version_child(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_version_child() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v savings_product_versions%ROWTYPE;
BEGIN
 IF TG_OP='DELETE' THEN
  SELECT * INTO v FROM savings_product_versions WHERE tenant_id=OLD.tenant_id AND id=OLD.product_version_id FOR UPDATE;
 ELSE
  IF TG_OP='UPDATE' AND (NEW.product_version_id<>OLD.product_version_id OR NEW.tenant_id<>OLD.tenant_id) THEN
   RAISE EXCEPTION 'Version membership cannot change';
  END IF;
  SELECT * INTO v FROM savings_product_versions WHERE tenant_id=NEW.tenant_id AND id=NEW.product_version_id FOR UPDATE;
 END IF;
 IF NOT FOUND OR v.status <> 'DRAFT' THEN RAISE EXCEPTION 'Only draft version children may change'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_protect_withdrawal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_protect_withdrawal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Savings withdrawals cannot be deleted'; END IF;
      IF OLD.status='SUCCESSFUL' THEN RAISE EXCEPTION 'Successful savings withdrawals are immutable'; END IF;
      IF (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.amount,NEW.currency,NEW.operation_id,NEW.idempotency_key,NEW.request_hash)
         IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.amount,OLD.currency,OLD.operation_id,OLD.idempotency_key,OLD.request_hash)
      THEN RAISE EXCEPTION 'Savings withdrawal command identity is immutable'; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_reject_mutation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_reject_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION '% is append-only; use a linked correction/reversal',TG_TABLE_NAME; END $$;


--
-- Name: savings_require_account_setup(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_require_account_setup() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE a savings_accounts%ROWTYPE; aid UUID; tid UUID;
BEGIN
 IF TG_TABLE_NAME='savings_accounts' THEN aid=NEW.id; tid=NEW.tenant_id;
 ELSIF TG_OP='DELETE' THEN aid=OLD.savings_account_id; tid=OLD.tenant_id;
 ELSE aid=NEW.savings_account_id; tid=NEW.tenant_id; END IF;
 SELECT * INTO a FROM savings_accounts WHERE tenant_id=tid AND id=aid;
 IF FOUND AND a.status IN ('ACTIVE','FROZEN','SUSPENDED') THEN
  IF NOT EXISTS(SELECT 1 FROM savings_account_contracts c WHERE c.tenant_id=tid AND c.savings_account_id=aid) OR
     NOT EXISTS(SELECT 1 FROM savings_account_holders h WHERE h.tenant_id=tid AND h.savings_account_id=aid AND h.customer_id=a.customer_id AND h.role='PRIMARY' AND h.revoked_at IS NULL) THEN
   RAISE EXCEPTION 'Account activation requires accepted contract and primary holder'; END IF;
 END IF;
 RETURN NULL;
END $$;


--
-- Name: savings_validate_account(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_account() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE v savings_product_versions%ROWTYPE;
    BEGIN
      IF TG_OP='UPDATE' THEN
        IF (NEW.tenant_id,NEW.id,NEW.customer_id,NEW.currency,NEW.savings_product_id,NEW.product_version_id,NEW.product_type,NEW.ledger_entity_id,NEW.ledger_book_id,NEW.ledger_account_id,NEW.opening_sequence,NEW.opening_idempotency_key,NEW.opening_request_hash)
           IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.customer_id,OLD.currency,OLD.savings_product_id,OLD.product_version_id,OLD.product_type,OLD.ledger_entity_id,OLD.ledger_book_id,OLD.ledger_account_id,OLD.opening_sequence,OLD.opening_idempotency_key,OLD.opening_request_hash)
        THEN RAISE EXCEPTION 'Account identity/contract/ledger binding is immutable'; END IF;
        NEW.version=OLD.version+1;
      ELSE
        SELECT * INTO v FROM savings_product_versions WHERE tenant_id=NEW.tenant_id AND id=NEW.product_version_id FOR SHARE;
        IF NOT FOUND OR v.savings_product_id<>NEW.savings_product_id OR v.product_type NOT IN ('ORDINARY','TARGET','FIXED_DEPOSIT') OR v.currency<>NEW.currency OR v.status<>'PUBLISHED' OR NOT v.is_current OR now()<v.effective_from OR (v.effective_to IS NOT NULL AND now()>=v.effective_to)
        THEN RAISE EXCEPTION 'Account needs a current published supported savings product version'; END IF;
        IF NEW.held_balance<>0 OR NEW.current_balance<>0 THEN RAISE EXCEPTION 'Initial account balances must be zero'; END IF;
        IF NEW.product_type<>v.product_type THEN RAISE EXCEPTION 'Account product type must match its version'; END IF;
      END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_validate_accrual_context(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_accrual_context() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE a savings_accounts%ROWTYPE; r savings_product_rates%ROWTYPE; f fixed_deposits%ROWTYPE; b savings_interest_accrual_batches%ROWTYPE;
BEGIN
 SELECT * INTO a FROM savings_accounts WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id;
 SELECT * INTO b FROM savings_interest_accrual_batches WHERE tenant_id=NEW.tenant_id AND id=NEW.accrual_batch_id;
 IF a.id IS NULL OR b.id IS NULL OR a.product_version_id<>NEW.product_version_id OR a.currency<>NEW.currency
    OR b.currency<>NEW.currency OR b.accrual_date<>NEW.accrual_date THEN RAISE EXCEPTION 'Accrual account/version/batch mismatch'; END IF;
 IF NEW.fixed_deposit_id IS NOT NULL THEN
  SELECT * INTO f FROM fixed_deposits WHERE tenant_id=NEW.tenant_id AND id=NEW.fixed_deposit_id;
  IF NOT FOUND OR f.savings_account_id<>NEW.savings_account_id OR f.fixed_deposit_rate_id<>NEW.fixed_deposit_rate_id OR f.interest_rate<>NEW.applicable_rate
     OR NEW.accrual_date<f.start_date OR NEW.accrual_date>=f.maturity_date THEN RAISE EXCEPTION 'FD accrual terms mismatch'; END IF;
 ELSE
  SELECT * INTO r FROM savings_product_rates WHERE tenant_id=NEW.tenant_id AND id=NEW.product_rate_id;
  IF NOT FOUND OR r.interest_rate<>NEW.applicable_rate OR NEW.calculation_basis_amount<COALESCE(r.minimum_balance,0)
     OR (r.maximum_balance IS NOT NULL AND NEW.calculation_basis_amount>=r.maximum_balance) THEN RAISE EXCEPTION 'Savings accrual rate/band mismatch'; END IF;
 END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_validate_allocation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_allocation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE p savings_interest_payments%ROWTYPE; a savings_interest_accruals%ROWTYPE;
    BEGIN
      SELECT * INTO p FROM savings_interest_payments WHERE tenant_id=NEW.tenant_id AND id=NEW.interest_payment_id FOR UPDATE;
      SELECT * INTO a FROM savings_interest_accruals WHERE tenant_id=NEW.tenant_id AND id=NEW.interest_accrual_id FOR UPDATE;
      IF p.id IS NULL OR a.id IS NULL OR p.settlement_basis<>'ACCRUED' OR p.status IN ('SUCCESSFUL','REVERSED','CANCELLED') OR a.posted
        OR a.savings_account_id<>p.savings_account_id OR a.currency<>p.currency OR a.accrual_date<p.payment_period_start OR a.accrual_date>p.payment_period_end
        OR NEW.allocated_unrounded<>a.interest_amount OR NEW.allocated_minor<>(CASE WHEN a.interest_amount-floor(a.interest_amount)=0.5 THEN floor(a.interest_amount)+mod(floor(a.interest_amount),2) ELSE round(a.interest_amount) END)::bigint
      THEN RAISE EXCEPTION 'Interest allocation does not match eligible accrual'; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_validate_fd_interest(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_fd_interest() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE f fixed_deposits%ROWTYPE; p savings_interest_payments%ROWTYPE;
BEGIN
 SELECT * INTO f FROM fixed_deposits WHERE tenant_id=NEW.tenant_id AND id=NEW.fixed_deposit_id;
 SELECT * INTO p FROM savings_interest_payments WHERE tenant_id=NEW.tenant_id AND id=NEW.interest_payment_id;
 IF f.id IS NULL OR p.id IS NULL OR f.savings_account_id<>p.savings_account_id OR NEW.amount<>p.amount OR NEW.currency<>p.currency
    OR NEW.status<>p.status OR NEW.payment_period_start<>p.payment_period_start OR NEW.payment_period_end<>p.payment_period_end
    OR NEW.ledger_transaction_id IS DISTINCT FROM p.ledger_transaction_id THEN RAISE EXCEPTION 'FD interest must classify the same savings interest payment'; END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_validate_fixed_deposit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_fixed_deposit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE a savings_accounts%ROWTYPE; v savings_product_versions%ROWTYPE; r fixed_deposit_rates%ROWTYPE;
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'FD contracts cannot be deleted'; END IF;
      IF TG_OP='UPDATE' THEN
        IF (to_jsonb(NEW)-ARRAY['status','interest_amount','maturity_amount','ledger_transaction_id','ledger_journal_id','ledger_request_hash','ledger_posted_at','matured_at','withdrawn_at','updated_at','updated_by','aggregate_version']) IS DISTINCT FROM
           (to_jsonb(OLD)-ARRAY['status','interest_amount','maturity_amount','ledger_transaction_id','ledger_journal_id','ledger_request_hash','ledger_posted_at','matured_at','withdrawn_at','updated_at','updated_by','aggregate_version'])
        THEN RAISE EXCEPTION 'FD contract terms are immutable'; END IF;
        IF OLD.status IN ('WITHDRAWN','RENEWED','CANCELLED','LIQUIDATED','MATURED') THEN RAISE EXCEPTION 'Terminal FD cannot change'; END IF;
      ELSE
        SELECT * INTO a FROM savings_accounts WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id;
        SELECT * INTO v FROM savings_product_versions WHERE tenant_id=NEW.tenant_id AND id=NEW.product_version_id;
        SELECT * INTO r FROM fixed_deposit_rates WHERE tenant_id=NEW.tenant_id AND id=NEW.fixed_deposit_rate_id;
        IF a.id IS NULL OR v.id IS NULL OR r.id IS NULL OR a.product_version_id<>NEW.product_version_id OR v.product_type<>'FIXED_DEPOSIT'
           OR r.product_version_id<>NEW.product_version_id OR r.interest_rate<>NEW.interest_rate
           OR NEW.tenure_days<(v.terms->>'minimumTenureDays')::integer OR NEW.tenure_days>(v.terms->>'maximumTenureDays')::integer
           OR NEW.principal_amount<r.minimum_amount OR (r.maximum_amount IS NOT NULL AND NEW.principal_amount>r.maximum_amount)
           OR NEW.accepted_at<r.effective_from OR (r.effective_to IS NOT NULL AND NEW.accepted_at>=r.effective_to)
        THEN RAISE EXCEPTION 'FD contract does not match account/product/rate/tenure/amount/effective period'; END IF;
      END IF;
      IF NEW.status NOT IN ('PENDING','CANCELLED') AND NEW.ledger_transaction_id IS NULL THEN RAISE EXCEPTION 'Funded FD requires ledger posting'; END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_validate_goal_classification(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_goal_classification() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE g savings_goals%ROWTYPE; r JSONB;
BEGIN
 SELECT * INTO g FROM savings_goals WHERE tenant_id=NEW.tenant_id AND id=NEW.goal_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Goal not visible'; END IF;
 IF TG_TABLE_NAME='savings_goal_contributions' THEN
  SELECT to_jsonb(d) INTO r FROM savings_deposits d WHERE tenant_id=NEW.tenant_id AND id=NEW.deposit_id;
 ELSE
  SELECT to_jsonb(w) INTO r FROM savings_withdrawals w WHERE tenant_id=NEW.tenant_id AND id=NEW.withdrawal_id;
 END IF;
 IF r IS NULL OR (r->>'savings_account_id')::uuid<>g.savings_account_id OR (r->>'amount')::numeric<>NEW.amount
   OR r->>'currency'<>NEW.currency OR r->>'status'<>NEW.status::text
   OR (r->>'ledger_transaction_id')::uuid IS DISTINCT FROM NEW.ledger_transaction_id THEN
  RAISE EXCEPTION 'Goal classification must match its deposit/withdrawal'; END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_validate_holder_contract(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_holder_contract() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE a savings_accounts%ROWTYPE;
BEGIN
 SELECT * INTO a FROM savings_accounts WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Account not visible'; END IF;
 IF TG_TABLE_NAME='savings_account_contracts' THEN
  IF (NEW.customer_id,NEW.product_version_id) IS DISTINCT FROM (a.customer_id,a.product_version_id) THEN
   RAISE EXCEPTION 'Contract must match account customer and version'; END IF;
 ELSE
  IF TG_OP='UPDATE' AND (NEW.tenant_id,NEW.savings_account_id,NEW.customer_id) IS DISTINCT FROM (OLD.tenant_id,OLD.savings_account_id,OLD.customer_id) THEN
   RAISE EXCEPTION 'Holder membership is immutable'; END IF;
  IF NEW.role='PRIMARY' AND NEW.customer_id<>a.customer_id THEN RAISE EXCEPTION 'Primary holder must match customer_id'; END IF;
 END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_validate_journal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_journal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE a savings_accounts%ROWTYPE; original savings_account_transactions%ROWTYPE; used NUMERIC(20,2); expected NUMERIC(20,2);
BEGIN
 SELECT * INTO a FROM savings_accounts WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Journal account not visible'; END IF;
 -- Sequence is per savings ledger account, not a globally gapless counter.
 IF NEW.ledger_sequence<=a.last_ledger_sequence THEN RAISE EXCEPTION 'Stale/duplicate ledger sequence'; END IF;
 IF NEW.balance_before<>a.current_balance THEN RAISE EXCEPTION 'Journal opening balance does not match projection'; END IF;
 -- Accrual affects interest receivable/payable, not spendable principal.
 IF NEW.transaction_type='INTEREST_ACCRUAL' THEN expected=NEW.balance_before;
 ELSE expected=NEW.balance_before+CASE WHEN NEW.direction='CREDIT' THEN NEW.amount ELSE -NEW.amount END; END IF;
 IF NEW.balance_after<>expected THEN RAISE EXCEPTION 'Journal balance arithmetic mismatch'; END IF;
 IF NEW.available_balance_before<>NEW.balance_before-a.held_balance OR NEW.available_balance_after<>NEW.balance_after-a.held_balance THEN
  RAISE EXCEPTION 'Journal available balance must reflect holds at posting time'; END IF;
 IF NEW.reversed_transaction_id IS NOT NULL THEN
  SELECT * INTO original FROM savings_account_transactions WHERE tenant_id=NEW.tenant_id AND id=NEW.reversed_transaction_id FOR UPDATE;
  IF NOT FOUND OR original.savings_account_id<>NEW.savings_account_id OR original.currency<>NEW.currency
     OR original.direction=NEW.direction OR original.reversed_transaction_id IS NOT NULL OR original.transaction_type='INTEREST_ACCRUAL' THEN
   RAISE EXCEPTION 'Invalid reversal target; accrual corrections use dedicated records'; END IF;
  SELECT COALESCE(sum(amount),0) INTO used FROM savings_account_transactions WHERE tenant_id=NEW.tenant_id AND reversed_transaction_id=original.id;
  IF used+NEW.amount>original.amount THEN RAISE EXCEPTION 'Reversal exceeds unreversed amount'; END IF;
 END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_validate_maturity_claim(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_maturity_claim() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE f fixed_deposits%ROWTYPE; i fixed_deposit_instructions%ROWTYPE;
BEGIN
 SELECT * INTO f FROM fixed_deposits WHERE tenant_id=NEW.tenant_id AND id=NEW.fixed_deposit_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Fixed deposit not visible'; END IF;
 IF TG_TABLE_NAME='fixed_deposit_maturities' THEN
  SELECT * INTO i FROM fixed_deposit_instructions WHERE tenant_id=NEW.tenant_id AND id=NEW.instruction_id;
  IF NOT FOUND OR i.fixed_deposit_id<>f.id THEN RAISE EXCEPTION 'Maturity instruction mismatch'; END IF;
  IF EXISTS(SELECT 1 FROM fixed_deposit_liquidations l WHERE l.tenant_id=NEW.tenant_id AND l.fixed_deposit_id=f.id AND l.status NOT IN ('REJECTED','CANCELLED')) THEN
   RAISE EXCEPTION 'Fixed deposit already claimed for liquidation'; END IF;
 ELSE
  IF EXISTS(SELECT 1 FROM fixed_deposit_maturities m WHERE m.tenant_id=NEW.tenant_id AND m.fixed_deposit_id=f.id AND m.status<>'CANCELLED') THEN
   RAISE EXCEPTION 'Fixed deposit already claimed for maturity'; END IF;
 END IF;
 IF NEW.principal_amount<>f.principal_amount THEN RAISE EXCEPTION 'Settlement principal differs from fixed deposit'; END IF;
 RETURN NEW;
END $$;


--
-- Name: savings_validate_recurring_execution(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_recurring_execution() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE p savings_recurring_plans%ROWTYPE; d savings_deposits%ROWTYPE;
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Recurring executions cannot be deleted'; END IF;
      SELECT * INTO p FROM savings_recurring_plans WHERE tenant_id=NEW.tenant_id AND id=NEW.recurring_plan_id;
      IF NOT FOUND OR NEW.amount<>p.amount THEN RAISE EXCEPTION 'Execution must match recurring plan'; END IF;
      IF NEW.deposit_id IS NOT NULL THEN
        SELECT * INTO d FROM savings_deposits WHERE tenant_id=NEW.tenant_id AND id=NEW.deposit_id;
        IF NOT FOUND OR d.savings_account_id<>p.savings_account_id OR d.customer_id<>p.customer_id OR d.amount<>NEW.amount OR d.currency<>p.currency OR d.ledger_transaction_id IS DISTINCT FROM NEW.ledger_transaction_id
        THEN RAISE EXCEPTION 'Recurring execution deposit evidence mismatch'; END IF;
      END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_validate_recurring_plan(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_recurring_plan() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE a savings_accounts%ROWTYPE; g savings_goals%ROWTYPE;
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Recurring plans cannot be deleted'; END IF;
      IF TG_OP='INSERT' OR (NEW.status='ACTIVE' AND OLD.status<>'ACTIVE') THEN
        SELECT * INTO a FROM savings_accounts WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id;
        IF NOT FOUND OR a.customer_id<>NEW.customer_id OR a.currency<>NEW.currency OR a.status<>'ACTIVE' OR a.product_type NOT IN ('ORDINARY','TARGET')
        THEN RAISE EXCEPTION 'Recurring plan requires an active customer-owned savings account'; END IF;
        IF (a.product_type='TARGET')<>(NEW.goal_id IS NOT NULL) THEN RAISE EXCEPTION 'Target recurring plan requires goal'; END IF;
        IF NEW.goal_id IS NOT NULL THEN
          SELECT * INTO g FROM savings_goals WHERE tenant_id=NEW.tenant_id AND id=NEW.goal_id;
          IF NOT FOUND OR g.savings_account_id<>NEW.savings_account_id OR g.customer_id<>NEW.customer_id OR g.status<>'ACTIVE'
          THEN RAISE EXCEPTION 'Recurring goal must be active and match account/customer'; END IF;
        END IF;
      END IF;
      IF TG_OP='UPDATE' THEN
        IF (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.goal_id,NEW.amount,NEW.currency,NEW.frequency,NEW.start_date,NEW.end_date,NEW.max_executions,NEW.source_account_id,NEW.funding_source,NEW.timezone_name,NEW.execution_time,NEW.retry_limit,NEW.creation_idempotency_key,NEW.creation_request_hash,NEW.consent_reference,NEW.schedule_snapshot)
          IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.goal_id,OLD.amount,OLD.currency,OLD.frequency,OLD.start_date,OLD.end_date,OLD.max_executions,OLD.source_account_id,OLD.funding_source,OLD.timezone_name,OLD.execution_time,OLD.retry_limit,OLD.creation_idempotency_key,OLD.creation_request_hash,OLD.consent_reference,OLD.schedule_snapshot)
        THEN RAISE EXCEPTION 'Recurring plan configuration is immutable'; END IF;
        IF OLD.status IN ('COMPLETED','CANCELLED','EXHAUSTED') AND NEW.status<>OLD.status THEN RAISE EXCEPTION 'Terminal recurring plan is immutable'; END IF;
        IF NEW.status<>OLD.status AND NOT ((OLD.status='ACTIVE' AND NEW.status IN ('PAUSED','COMPLETED','CANCELLED','EXHAUSTED')) OR (OLD.status='PAUSED' AND NEW.status IN ('ACTIVE','CANCELLED'))) THEN RAISE EXCEPTION 'Invalid recurring plan transition'; END IF;
        NEW.aggregate_version=OLD.aggregate_version+1;
      END IF;
      RETURN NEW;
    END $$;


--
-- Name: savings_validate_renewal(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.savings_validate_renewal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE old_fd fixed_deposits%ROWTYPE; new_fd fixed_deposits%ROWTYPE; ins fixed_deposit_instructions%ROWTYPE;
BEGIN
 SELECT * INTO old_fd FROM fixed_deposits WHERE tenant_id=NEW.tenant_id AND id=NEW.fixed_deposit_id FOR UPDATE;
 SELECT * INTO new_fd FROM fixed_deposits WHERE tenant_id=NEW.tenant_id AND id=NEW.renewed_fixed_deposit_id;
 SELECT * INTO ins FROM fixed_deposit_instructions WHERE tenant_id=NEW.tenant_id AND id=NEW.renewal_instruction_id;
 IF old_fd.id IS NULL OR new_fd.id IS NULL OR ins.id IS NULL OR ins.fixed_deposit_id<>old_fd.id OR ins.maturity_action='PAYOUT_ALL'
    OR new_fd.previous_fixed_deposit_id IS DISTINCT FROM old_fd.id OR new_fd.customer_id<>old_fd.customer_id OR new_fd.currency<>old_fd.currency
    OR NEW.previous_maturity_date<>old_fd.maturity_date OR NEW.new_start_date<>new_fd.start_date OR NEW.new_maturity_date<>new_fd.maturity_date
    OR NEW.principal_amount<>new_fd.principal_amount OR NEW.interest_rate<>new_fd.interest_rate OR NEW.tenure_days<>new_fd.tenure_days THEN
  RAISE EXCEPTION 'Renewal chain/consent/terms mismatch'; END IF;
 RETURN NEW;
END $$;


--
-- Name: set_savings_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_savings_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: fixed_deposit_instructions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposit_instructions (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    fixed_deposit_id uuid NOT NULL,
    instruction_number integer NOT NULL,
    maturity_action text NOT NULL,
    renewal_tenure_days integer,
    destination_account_id uuid,
    accepted_at timestamp with time zone NOT NULL,
    consent_reference text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    idempotency_key character varying(255),
    request_hash character(64),
    correlation_id uuid,
    superseded_at timestamp with time zone,
    CONSTRAINT fixed_deposit_instruction_hash CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT fixed_deposit_instructions_check CHECK (((maturity_action = 'PAYOUT_ALL'::text) OR (renewal_tenure_days IS NOT NULL))),
    CONSTRAINT fixed_deposit_instructions_check1 CHECK (((maturity_action <> 'PAYOUT_ALL'::text) OR (destination_account_id IS NOT NULL))),
    CONSTRAINT fixed_deposit_instructions_instruction_number_check CHECK ((instruction_number > 0)),
    CONSTRAINT fixed_deposit_instructions_maturity_action_check CHECK ((maturity_action = ANY (ARRAY['PAYOUT_ALL'::text, 'RENEW_PRINCIPAL'::text, 'RENEW_PRINCIPAL_AND_INTEREST'::text]))),
    CONSTRAINT fixed_deposit_instructions_renewal_tenure_days_check CHECK ((renewal_tenure_days > 0))
);

ALTER TABLE ONLY public.fixed_deposit_instructions FORCE ROW LEVEL SECURITY;


--
-- Name: fixed_deposit_interest_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposit_interest_payments (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    fixed_deposit_id uuid NOT NULL,
    payment_reference character varying(100) NOT NULL,
    amount bigint NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    payment_date date NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    ledger_transaction_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    payment_period_start date NOT NULL,
    payment_period_end date NOT NULL,
    interest_payment_id uuid NOT NULL,
    paid_at timestamp with time zone,
    destination_account_id uuid,
    failure_reason text,
    operation_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    request_id text,
    failure_code text,
    CONSTRAINT chk_fixed_deposit_interest_amount CHECK (((amount)::numeric >= (0)::numeric)),
    CONSTRAINT fixed_deposit_interest_payments_check CHECK ((payment_period_end >= payment_period_start)),
    CONSTRAINT fixed_deposit_interest_payments_check1 CHECK ((((status)::text <> 'SUCCESSFUL'::text) OR (ledger_transaction_id IS NOT NULL)))
);

ALTER TABLE ONLY public.fixed_deposit_interest_payments FORCE ROW LEVEL SECURITY;


--
-- Name: fixed_deposit_liquidations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposit_liquidations (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    fixed_deposit_id uuid NOT NULL,
    liquidation_reference text NOT NULL,
    status text DEFAULT 'REQUESTED'::text NOT NULL,
    principal_amount bigint NOT NULL,
    interest_due bigint NOT NULL,
    interest_clawback bigint DEFAULT 0 NOT NULL,
    penalty_amount bigint DEFAULT 0 NOT NULL,
    tax_amount bigint DEFAULT 0 NOT NULL,
    calculation_snapshot jsonb NOT NULL,
    destination_account_id uuid NOT NULL,
    payment_transaction_id uuid,
    ledger_transaction_id uuid,
    created_by uuid NOT NULL,
    approved_by uuid,
    approved_at timestamp with time zone,
    processed_at timestamp with time zone,
    failure_reason text,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    net_payout bigint GENERATED ALWAYS AS (((((principal_amount + interest_due) - interest_clawback) - penalty_amount) - tax_amount)) STORED,
    request_hash character(64),
    quote_id uuid,
    quote_hash character(64),
    quote_expires_at timestamp with time zone,
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    authority_type text DEFAULT 'PRODUCT_POLICY'::text NOT NULL,
    approval_id uuid,
    CONSTRAINT fixed_deposit_liquidation_approval CHECK (((authority_type <> 'TENANT_APPROVAL'::text) OR (approval_id IS NOT NULL))),
    CONSTRAINT fixed_deposit_liquidation_authority CHECK ((authority_type = ANY (ARRAY['PRODUCT_POLICY'::text, 'TENANT_APPROVAL'::text]))),
    CONSTRAINT fixed_deposit_liquidation_authority_evidence CHECK (((status <> ALL (ARRAY['APPROVED'::text, 'POSTING'::text, 'SUCCESSFUL'::text])) OR (authority_type = 'PRODUCT_POLICY'::text) OR ((approved_by IS NOT NULL) AND (approved_at IS NOT NULL)))),
    CONSTRAINT fixed_deposit_liquidation_maker_checker CHECK (((approved_by IS NULL) OR (approved_by <> created_by))),
    CONSTRAINT fixed_deposit_liquidation_quote_hash CHECK (((quote_hash IS NULL) OR (quote_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT fixed_deposit_liquidation_request_hash CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT fixed_deposit_liquidation_success_evidence CHECK (((status <> 'SUCCESSFUL'::text) OR ((ledger_transaction_id IS NOT NULL) AND (ledger_journal_id IS NOT NULL) AND (ledger_request_hash IS NOT NULL) AND (ledger_posted_at IS NOT NULL) AND (processed_at IS NOT NULL)))),
    CONSTRAINT fixed_deposit_liquidations_check2 CHECK (((status <> 'SUCCESSFUL'::text) OR ((ledger_transaction_id IS NOT NULL) AND (processed_at IS NOT NULL)))),
    CONSTRAINT fixed_deposit_liquidations_interest_clawback_check CHECK (((interest_clawback)::numeric >= (0)::numeric)),
    CONSTRAINT fixed_deposit_liquidations_interest_due_check CHECK (((interest_due)::numeric >= (0)::numeric)),
    CONSTRAINT fixed_deposit_liquidations_penalty_amount_check CHECK (((penalty_amount)::numeric >= (0)::numeric)),
    CONSTRAINT fixed_deposit_liquidations_principal_amount_check CHECK (((principal_amount)::numeric > (0)::numeric)),
    CONSTRAINT fixed_deposit_liquidations_status_check CHECK ((status = ANY (ARRAY['REQUESTED'::text, 'APPROVED'::text, 'POSTING'::text, 'SUCCESSFUL'::text, 'FAILED'::text, 'REJECTED'::text, 'CANCELLED'::text]))),
    CONSTRAINT fixed_deposit_liquidations_tax_amount_check CHECK (((tax_amount)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY public.fixed_deposit_liquidations FORCE ROW LEVEL SECURITY;


--
-- Name: fixed_deposit_maturities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposit_maturities (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    fixed_deposit_id uuid NOT NULL,
    instruction_id uuid NOT NULL,
    maturity_reference text NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    principal_amount bigint NOT NULL,
    unpaid_interest bigint NOT NULL,
    tax_amount bigint DEFAULT 0 NOT NULL,
    ledger_transaction_id uuid,
    payment_transaction_id uuid,
    processed_at timestamp with time zone,
    failure_reason text,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    net_amount bigint GENERATED ALWAYS AS (((principal_amount + unpaid_interest) - tax_amount)) STORED,
    request_hash character(64),
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    system_authority text DEFAULT 'SCHEDULED_MATURITY'::text NOT NULL,
    CONSTRAINT fixed_deposit_maturities_check CHECK ((tax_amount <= unpaid_interest)),
    CONSTRAINT fixed_deposit_maturities_check1 CHECK (((status <> 'SUCCESSFUL'::public.savings_transaction_status_enum) OR ((ledger_transaction_id IS NOT NULL) AND (processed_at IS NOT NULL)))),
    CONSTRAINT fixed_deposit_maturities_principal_amount_check CHECK (((principal_amount)::numeric > (0)::numeric)),
    CONSTRAINT fixed_deposit_maturities_tax_amount_check CHECK (((tax_amount)::numeric >= (0)::numeric)),
    CONSTRAINT fixed_deposit_maturities_unpaid_interest_check CHECK (((unpaid_interest)::numeric >= (0)::numeric)),
    CONSTRAINT fixed_deposit_maturity_authority CHECK ((system_authority = 'SCHEDULED_MATURITY'::text)),
    CONSTRAINT fixed_deposit_maturity_request_hash CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT fixed_deposit_maturity_success_evidence CHECK (((status <> 'SUCCESSFUL'::public.savings_transaction_status_enum) OR ((ledger_transaction_id IS NOT NULL) AND (ledger_journal_id IS NOT NULL) AND (ledger_request_hash IS NOT NULL) AND (ledger_posted_at IS NOT NULL) AND (processed_at IS NOT NULL))))
);

ALTER TABLE ONLY public.fixed_deposit_maturities FORCE ROW LEVEL SECURITY;


--
-- Name: fixed_deposit_quotes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposit_quotes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    quote_type text NOT NULL,
    fixed_deposit_id uuid,
    product_version_id uuid NOT NULL,
    principal_minor bigint NOT NULL,
    currency character(3) NOT NULL,
    tenure_days integer NOT NULL,
    interest_rate numeric(18,10) NOT NULL,
    expected_interest_unrounded numeric(30,12) NOT NULL,
    expected_interest_minor bigint NOT NULL,
    penalty_minor bigint DEFAULT 0 NOT NULL,
    payout_minor bigint NOT NULL,
    calculation_snapshot jsonb NOT NULL,
    quote_hash character(64) NOT NULL,
    request_hash character(64) NOT NULL,
    idempotency_key character varying(255) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    correlation_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT fixed_deposit_quotes_calculation_snapshot_check CHECK ((jsonb_typeof(calculation_snapshot) = 'object'::text)),
    CONSTRAINT fixed_deposit_quotes_check CHECK ((((quote_type = 'PLACEMENT'::text) AND (fixed_deposit_id IS NULL)) OR ((quote_type = 'LIQUIDATION'::text) AND (fixed_deposit_id IS NOT NULL)))),
    CONSTRAINT fixed_deposit_quotes_check1 CHECK ((expires_at > created_at)),
    CONSTRAINT fixed_deposit_quotes_check2 CHECK (((consumed_at IS NULL) OR (consumed_at >= created_at))),
    CONSTRAINT fixed_deposit_quotes_currency_check CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT fixed_deposit_quotes_expected_interest_minor_check CHECK ((expected_interest_minor >= 0)),
    CONSTRAINT fixed_deposit_quotes_expected_interest_unrounded_check CHECK ((expected_interest_unrounded >= (0)::numeric)),
    CONSTRAINT fixed_deposit_quotes_interest_rate_check CHECK ((interest_rate >= (0)::numeric)),
    CONSTRAINT fixed_deposit_quotes_payout_minor_check CHECK ((payout_minor >= 0)),
    CONSTRAINT fixed_deposit_quotes_penalty_minor_check CHECK ((penalty_minor >= 0)),
    CONSTRAINT fixed_deposit_quotes_principal_minor_check CHECK ((principal_minor > 0)),
    CONSTRAINT fixed_deposit_quotes_quote_hash_check CHECK ((quote_hash ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT fixed_deposit_quotes_quote_type_check CHECK ((quote_type = ANY (ARRAY['PLACEMENT'::text, 'LIQUIDATION'::text]))),
    CONSTRAINT fixed_deposit_quotes_request_hash_check CHECK ((request_hash ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT fixed_deposit_quotes_tenure_days_check CHECK ((tenure_days > 0))
);

ALTER TABLE ONLY public.fixed_deposit_quotes FORCE ROW LEVEL SECURITY;


--
-- Name: fixed_deposit_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposit_rates (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_product_id uuid NOT NULL,
    tenure_days integer NOT NULL,
    interest_rate numeric(18,10) NOT NULL,
    minimum_amount bigint DEFAULT 0 NOT NULL,
    maximum_amount bigint,
    effective_from timestamp with time zone NOT NULL,
    effective_to timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    product_version_id uuid NOT NULL,
    CONSTRAINT chk_fixed_deposit_rate CHECK ((interest_rate >= (0)::numeric)),
    CONSTRAINT chk_fixed_deposit_rate_amount CHECK (((maximum_amount IS NULL) OR (maximum_amount >= minimum_amount))),
    CONSTRAINT chk_fixed_deposit_rate_dates CHECK (((effective_to IS NULL) OR (effective_to > effective_from))),
    CONSTRAINT chk_fixed_deposit_rate_tenure CHECK ((tenure_days > 0)),
    CONSTRAINT fixed_deposit_rates_check CHECK (((maximum_amount IS NULL) OR (maximum_amount > minimum_amount))),
    CONSTRAINT fixed_deposit_rates_minimum_amount_check CHECK (((minimum_amount)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY public.fixed_deposit_rates FORCE ROW LEVEL SECURITY;


--
-- Name: fixed_deposit_renewals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposit_renewals (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    fixed_deposit_id uuid NOT NULL,
    previous_maturity_date date NOT NULL,
    new_start_date date NOT NULL,
    new_maturity_date date NOT NULL,
    principal_amount bigint NOT NULL,
    interest_amount bigint DEFAULT 0 NOT NULL,
    interest_rate numeric(18,10) NOT NULL,
    tenure_days integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    renewed_fixed_deposit_id uuid NOT NULL,
    renewal_instruction_id uuid NOT NULL,
    ledger_transaction_id uuid NOT NULL,
    CONSTRAINT chk_fixed_deposit_renewal_amount CHECK (((principal_amount)::numeric > (0)::numeric)),
    CONSTRAINT chk_fixed_deposit_renewal_dates CHECK ((new_maturity_date > new_start_date)),
    CONSTRAINT chk_fixed_deposit_renewal_rate CHECK ((interest_rate >= (0)::numeric)),
    CONSTRAINT fixed_deposit_renewals_check CHECK (((tenure_days > 0) AND ((interest_amount)::numeric >= (0)::numeric))),
    CONSTRAINT fixed_deposit_renewals_check1 CHECK ((new_maturity_date = (new_start_date + tenure_days))),
    CONSTRAINT fixed_deposit_renewals_check2 CHECK ((new_start_date >= previous_maturity_date)),
    CONSTRAINT fixed_deposit_renewals_check3 CHECK ((renewed_fixed_deposit_id <> fixed_deposit_id))
);

ALTER TABLE ONLY public.fixed_deposit_renewals FORCE ROW LEVEL SECURITY;


--
-- Name: fixed_deposits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fixed_deposits (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    deposit_reference character varying(100) NOT NULL,
    principal_amount bigint NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    interest_rate numeric(18,10) NOT NULL,
    tenure_days integer NOT NULL,
    start_date date NOT NULL,
    maturity_date date NOT NULL,
    interest_amount numeric(30,12) DEFAULT 0 NOT NULL,
    maturity_amount bigint NOT NULL,
    payout_method public.fixed_deposit_payout_method_enum DEFAULT 'AT_MATURITY'::public.fixed_deposit_payout_method_enum NOT NULL,
    status public.fixed_deposit_status_enum DEFAULT 'PENDING'::public.fixed_deposit_status_enum NOT NULL,
    source_account_id uuid,
    destination_account_id uuid,
    ledger_transaction_id uuid,
    matured_at timestamp with time zone,
    withdrawn_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_by uuid,
    deleted_at timestamp with time zone,
    product_version_id uuid NOT NULL,
    fixed_deposit_rate_id uuid NOT NULL,
    funding_deposit_id uuid,
    previous_fixed_deposit_id uuid,
    contract_reference text NOT NULL,
    accepted_at timestamp with time zone NOT NULL,
    accepted_terms_hash text NOT NULL,
    terms_snapshot jsonb NOT NULL,
    day_count_basis text NOT NULL,
    compounding_method text NOT NULL,
    placement_idempotency_key character varying(255),
    placement_request_hash character(64),
    correlation_id uuid,
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    quote_id uuid,
    quote_hash character(64),
    quote_expires_at timestamp with time zone,
    early_liquidation_allowed boolean DEFAULT true NOT NULL,
    early_liquidation_penalty_rate numeric(18,10) DEFAULT 0 NOT NULL,
    maturity_instruction_cutoff_days integer DEFAULT 1 NOT NULL,
    aggregate_version bigint DEFAULT 1 NOT NULL,
    CONSTRAINT chk_fixed_deposit_dates CHECK ((maturity_date > start_date)),
    CONSTRAINT chk_fixed_deposit_interest CHECK ((interest_rate >= (0)::numeric)),
    CONSTRAINT chk_fixed_deposit_tenure CHECK ((tenure_days > 0)),
    CONSTRAINT fixed_deposit_activation_evidence CHECK (((status <> 'ACTIVE'::public.fixed_deposit_status_enum) OR ((placement_idempotency_key IS NOT NULL) AND (placement_request_hash IS NOT NULL) AND (correlation_id IS NOT NULL) AND (ledger_transaction_id IS NOT NULL) AND (ledger_journal_id IS NOT NULL) AND (ledger_request_hash IS NOT NULL) AND (ledger_posted_at IS NOT NULL)))),
    CONSTRAINT fixed_deposit_aggregate_version CHECK ((aggregate_version > 0)),
    CONSTRAINT fixed_deposit_cutoff CHECK ((maturity_instruction_cutoff_days >= 0)),
    CONSTRAINT fixed_deposit_ledger_hash CHECK (((ledger_request_hash IS NULL) OR (ledger_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT fixed_deposit_liquidation_policy CHECK (((early_liquidation_penalty_rate >= (0)::numeric) AND (early_liquidation_penalty_rate <= (100)::numeric))),
    CONSTRAINT fixed_deposit_maturity_minor CHECK ((maturity_amount >= principal_amount)),
    CONSTRAINT fixed_deposit_placement_hash CHECK (((placement_request_hash IS NULL) OR (placement_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT fixed_deposit_principal_minor CHECK ((principal_amount > 0)),
    CONSTRAINT fixed_deposit_quote_evidence CHECK (((quote_id IS NULL) OR ((quote_hash IS NOT NULL) AND (quote_expires_at IS NOT NULL)))),
    CONSTRAINT fixed_deposit_quote_hash CHECK (((quote_hash IS NULL) OR (quote_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT fixed_deposit_unposted_interest CHECK ((interest_amount >= (0)::numeric)),
    CONSTRAINT fixed_deposits_check CHECK ((maturity_date = (start_date + tenure_days))),
    CONSTRAINT fixed_deposits_check1 CHECK (((previous_fixed_deposit_id IS NULL) OR (previous_fixed_deposit_id <> id))),
    CONSTRAINT fixed_deposits_compounding_method_check CHECK ((compounding_method = ANY (ARRAY['SIMPLE'::text, 'DAILY'::text, 'MONTHLY'::text, 'QUARTERLY'::text, 'ANNUALLY'::text]))),
    CONSTRAINT fixed_deposits_day_count_basis_check CHECK ((day_count_basis = ANY (ARRAY['ACT_365_FIXED'::text, 'ACT_ACT'::text, 'ACT_360'::text, '30_360'::text]))),
    CONSTRAINT fixed_deposits_deleted_at_check CHECK ((deleted_at IS NULL)),
    CONSTRAINT fixed_deposits_terms_snapshot_check CHECK ((jsonb_typeof(terms_snapshot) = 'object'::text))
);

ALTER TABLE ONLY public.fixed_deposits FORCE ROW LEVEL SECURITY;


--
-- Name: savings_account_contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_account_contracts (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    product_version_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    contract_reference text NOT NULL,
    accepted_at timestamp with time zone NOT NULL,
    terms_hash text NOT NULL,
    acceptance_evidence jsonb NOT NULL,
    document_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT savings_account_contracts_acceptance_evidence_check CHECK ((jsonb_typeof(acceptance_evidence) = 'object'::text))
);

ALTER TABLE ONLY public.savings_account_contracts FORCE ROW LEVEL SECURITY;


--
-- Name: savings_account_holders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_account_holders (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    role public.savings_account_holder_role_enum NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    mandate_role text DEFAULT 'VIEW_ONLY'::text NOT NULL,
    consent_reference text,
    revoked_at timestamp with time zone,
    CONSTRAINT savings_account_holders_mandate_role_check CHECK ((mandate_role = ANY (ARRAY['OWNER'::text, 'SIGNATORY'::text, 'VIEW_ONLY'::text, 'NOMINEE'::text])))
);

ALTER TABLE ONLY public.savings_account_holders FORCE ROW LEVEL SECURITY;


--
-- Name: savings_account_restrictions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_account_restrictions (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    restriction_type text NOT NULL,
    reason_code text NOT NULL,
    reason text NOT NULL,
    source text NOT NULL,
    starts_at timestamp with time zone DEFAULT now() NOT NULL,
    ends_at timestamp with time zone,
    created_by uuid NOT NULL,
    released_by uuid,
    released_at timestamp with time zone,
    release_reason text,
    external_case_reference text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT savings_account_restrictions_check CHECK (((ends_at IS NULL) OR (ends_at > starts_at))),
    CONSTRAINT savings_account_restrictions_check1 CHECK (((released_at IS NULL) OR ((released_by IS NOT NULL) AND (release_reason IS NOT NULL)))),
    CONSTRAINT savings_account_restrictions_restriction_type_check CHECK ((restriction_type = ANY (ARRAY['NO_DEBIT'::text, 'NO_CREDIT'::text, 'FROZEN'::text, 'CLOSURE_BLOCK'::text]))),
    CONSTRAINT savings_account_restrictions_source_check CHECK ((source = ANY (ARRAY['COMPLIANCE'::text, 'COURT_ORDER'::text, 'CUSTOMER'::text, 'ADMIN'::text, 'SYSTEM'::text])))
);

ALTER TABLE ONLY public.savings_account_restrictions FORCE ROW LEVEL SECURITY;


--
-- Name: savings_account_status_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_account_status_history (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    previous_status public.savings_account_status_enum,
    new_status public.savings_account_status_enum NOT NULL,
    reason text,
    changed_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    reason_code text NOT NULL,
    approved_by uuid,
    request_id text,
    correlation_id uuid,
    effective_at timestamp with time zone DEFAULT now() NOT NULL,
    source text NOT NULL,
    CONSTRAINT savings_account_status_history_source_check CHECK ((source = ANY (ARRAY['CUSTOMER'::text, 'ADMIN'::text, 'COMPLIANCE'::text, 'SYSTEM'::text])))
);

ALTER TABLE ONLY public.savings_account_status_history FORCE ROW LEVEL SECURITY;


--
-- Name: savings_account_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_account_transactions (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    transaction_reference character varying(100) NOT NULL,
    transaction_type public.savings_account_transaction_type_enum NOT NULL,
    direction public.savings_account_transaction_direction_enum NOT NULL,
    amount bigint NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'SUCCESSFUL'::public.savings_transaction_status_enum NOT NULL,
    channel public.savings_transaction_channel_enum NOT NULL,
    description character varying(500),
    balance_before bigint NOT NULL,
    balance_after bigint NOT NULL,
    available_balance_before bigint NOT NULL,
    available_balance_after bigint NOT NULL,
    payment_transaction_id uuid,
    ledger_transaction_id uuid,
    deposit_id uuid,
    withdrawal_id uuid,
    goal_id uuid,
    goal_contribution_id uuid,
    goal_withdrawal_id uuid,
    fixed_deposit_id uuid,
    reversed_transaction_id uuid,
    reversal_reason text,
    idempotency_key character varying(255),
    correlation_id uuid,
    request_id character varying(100),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    transaction_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_by uuid,
    transfer_request_id uuid,
    interest_payment_id uuid,
    interest_accrual_id uuid,
    adjustment_id uuid,
    recurring_execution_id uuid,
    operation_id uuid NOT NULL,
    leg_code text NOT NULL,
    ledger_entry_id uuid NOT NULL,
    ledger_sequence bigint NOT NULL,
    CONSTRAINT chk_savings_account_transaction_amount CHECK ((amount > 0)),
    CONSTRAINT chk_savings_account_transaction_available_after CHECK ((available_balance_after >= 0)),
    CONSTRAINT chk_savings_account_transaction_available_balance CHECK (((available_balance_before <= balance_before) AND (available_balance_after <= balance_after))),
    CONSTRAINT chk_savings_account_transaction_available_before CHECK ((available_balance_before >= 0)),
    CONSTRAINT chk_savings_account_transaction_balance_after CHECK ((balance_after >= 0)),
    CONSTRAINT chk_savings_account_transaction_balance_before CHECK ((balance_before >= 0)),
    CONSTRAINT chk_savings_account_transaction_reversal CHECK (((reversed_transaction_id IS NULL) OR (transaction_type = ANY (ARRAY['REVERSAL'::public.savings_account_transaction_type_enum, 'INTEREST_REVERSAL'::public.savings_account_transaction_type_enum, 'FEE_REVERSAL'::public.savings_account_transaction_type_enum])))),
    CONSTRAINT savings_account_transactions_check CHECK (((ledger_transaction_id IS NOT NULL) AND (processed_at IS NOT NULL))),
    CONSTRAINT savings_account_transactions_check1 CHECK (((transaction_type = ANY (ARRAY['REVERSAL'::public.savings_account_transaction_type_enum, 'INTEREST_REVERSAL'::public.savings_account_transaction_type_enum, 'FEE_REVERSAL'::public.savings_account_transaction_type_enum])) = (reversed_transaction_id IS NOT NULL))),
    CONSTRAINT savings_account_transactions_check2 CHECK (((reversed_transaction_id IS NULL) OR (reversed_transaction_id <> id))),
    CONSTRAINT savings_account_transactions_ledger_sequence_check CHECK ((ledger_sequence > 0)),
    CONSTRAINT savings_account_transactions_status_check CHECK ((status = 'SUCCESSFUL'::public.savings_transaction_status_enum))
);

ALTER TABLE ONLY public.savings_account_transactions FORCE ROW LEVEL SECURITY;


--
-- Name: TABLE savings_account_transactions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.savings_account_transactions IS 'Operational transaction journal for savings accounts. Financial accounting source of truth remains parc_ledger.';


--
-- Name: COLUMN savings_account_transactions.customer_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.savings_account_transactions.customer_id IS 'Logical reference to the customer in parc_auth_customer. No cross-database FK.';


--
-- Name: COLUMN savings_account_transactions.balance_before; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.savings_account_transactions.balance_before IS 'Operational savings balance immediately before this transaction.';


--
-- Name: COLUMN savings_account_transactions.balance_after; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.savings_account_transactions.balance_after IS 'Operational savings balance immediately after this transaction.';


--
-- Name: COLUMN savings_account_transactions.payment_transaction_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.savings_account_transactions.payment_transaction_id IS 'Logical reference to the related transaction in parc_payment. No cross-database FK.';


--
-- Name: COLUMN savings_account_transactions.ledger_transaction_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.savings_account_transactions.ledger_transaction_id IS 'Logical reference to the authoritative transaction in parc_ledger. No cross-database FK.';


--
-- Name: savings_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_accounts (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    savings_product_id uuid NOT NULL,
    account_number character varying(100) NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    status public.savings_account_status_enum DEFAULT 'PENDING'::public.savings_account_status_enum NOT NULL,
    current_balance bigint DEFAULT 0 NOT NULL,
    held_balance bigint DEFAULT 0 NOT NULL,
    accrued_interest numeric(30,12) DEFAULT 0 NOT NULL,
    total_interest_earned bigint DEFAULT 0 NOT NULL,
    total_deposited bigint DEFAULT 0 NOT NULL,
    total_withdrawn bigint DEFAULT 0 NOT NULL,
    opened_at timestamp with time zone,
    closed_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_by uuid,
    deleted_at timestamp with time zone,
    product_version_id uuid NOT NULL,
    ledger_entity_id uuid,
    ledger_book_id uuid,
    ledger_account_id uuid NOT NULL,
    ledger_interest_payable_account_id uuid,
    version bigint DEFAULT 0 NOT NULL,
    last_ledger_sequence bigint DEFAULT 0 NOT NULL,
    ledger_synced_at timestamp with time zone,
    available_balance bigint GENERATED ALWAYS AS ((current_balance - held_balance)) STORED,
    opening_sequence bigint NOT NULL,
    opening_idempotency_key character varying(255),
    opening_request_hash character(64),
    product_type public.savings_product_type_enum NOT NULL,
    CONSTRAINT chk_savings_account_balance CHECK (((current_balance >= 0) AND (held_balance >= 0) AND (held_balance <= current_balance) AND (available_balance >= 0) AND (accrued_interest >= (0)::numeric))),
    CONSTRAINT chk_savings_account_totals CHECK (((total_deposited >= 0) AND (total_withdrawn >= 0) AND (total_interest_earned >= 0))),
    CONSTRAINT savings_account_opening_hash CHECK (((opening_request_hash IS NULL) OR (opening_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_accounts_check1 CHECK (((closed_at IS NULL) OR (closed_at >= opened_at))),
    CONSTRAINT savings_accounts_closed_zero CHECK (((status <> 'CLOSED'::public.savings_account_status_enum) OR ((closed_at IS NOT NULL) AND (current_balance = 0) AND (held_balance = 0) AND (accrued_interest = (0)::numeric)))),
    CONSTRAINT savings_accounts_deleted_at_check CHECK ((deleted_at IS NULL)),
    CONSTRAINT savings_accounts_last_ledger_sequence_check CHECK ((last_ledger_sequence >= 0)),
    CONSTRAINT savings_accounts_version_check CHECK ((version >= 0))
);

ALTER TABLE ONLY public.savings_accounts FORCE ROW LEVEL SECURITY;


--
-- Name: savings_accounts_opening_sequence_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.savings_accounts ALTER COLUMN opening_sequence ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.savings_accounts_opening_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: savings_adjustments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_adjustments (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    adjustment_type public.adjustment_type_enum NOT NULL,
    amount numeric(20,2) NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    reason text NOT NULL,
    ledger_transaction_id uuid,
    approved_by uuid,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    adjustment_reference text NOT NULL,
    direction public.savings_account_transaction_direction_enum NOT NULL,
    status text DEFAULT 'REQUESTED'::text NOT NULL,
    approved_at timestamp with time zone,
    rejected_by uuid,
    rejection_reason text,
    supporting_document_id uuid,
    reversed_adjustment_id uuid,
    operation_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    request_id text,
    failure_code text,
    CONSTRAINT chk_savings_adjustment_amount CHECK ((amount > (0)::numeric)),
    CONSTRAINT savings_adjustments_check CHECK (((approved_by IS NULL) OR (approved_by <> created_by))),
    CONSTRAINT savings_adjustments_check1 CHECK (((status <> ALL (ARRAY['APPROVED'::text, 'POSTING'::text, 'SUCCESSFUL'::text])) OR ((approved_by IS NOT NULL) AND (approved_at IS NOT NULL)))),
    CONSTRAINT savings_adjustments_check2 CHECK (((status <> 'REJECTED'::text) OR ((rejected_by IS NOT NULL) AND (rejection_reason IS NOT NULL)))),
    CONSTRAINT savings_adjustments_check3 CHECK (((status <> 'SUCCESSFUL'::text) OR (ledger_transaction_id IS NOT NULL))),
    CONSTRAINT savings_adjustments_created_by_check CHECK ((created_by IS NOT NULL)),
    CONSTRAINT savings_adjustments_status_check CHECK ((status = ANY (ARRAY['REQUESTED'::text, 'APPROVED'::text, 'REJECTED'::text, 'POSTING'::text, 'SUCCESSFUL'::text, 'FAILED'::text, 'CANCELLED'::text])))
);

ALTER TABLE ONLY public.savings_adjustments FORCE ROW LEVEL SECURITY;


--
-- Name: savings_audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_audit_logs (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    actor_id uuid,
    actor_type text NOT NULL,
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    reason text,
    before_data jsonb,
    after_data jsonb,
    request_id text,
    correlation_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT savings_audit_logs_actor_type_check CHECK ((actor_type = ANY (ARRAY['CUSTOMER'::text, 'ADMIN'::text, 'SERVICE'::text])))
);

ALTER TABLE ONLY public.savings_audit_logs FORCE ROW LEVEL SECURITY;


--
-- Name: savings_balance_holds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_balance_holds (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    currency character(3) NOT NULL,
    hold_reference text NOT NULL,
    operation_id uuid NOT NULL,
    hold_type text NOT NULL,
    amount numeric(20,2) NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    withdrawal_id uuid,
    transfer_request_id uuid,
    ledger_hold_id uuid,
    ledger_capture_transaction_id uuid,
    reason text NOT NULL,
    expires_at timestamp with time zone,
    resolved_at timestamp with time zone,
    resolution_evidence jsonb,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT savings_balance_holds_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT savings_balance_holds_check CHECK (((expires_at IS NULL) OR (expires_at > created_at))),
    CONSTRAINT savings_balance_holds_check1 CHECK (((status = 'ACTIVE'::text) OR ((resolved_at IS NOT NULL) AND (resolution_evidence IS NOT NULL)))),
    CONSTRAINT savings_balance_holds_check2 CHECK (((status <> 'CAPTURED'::text) OR (ledger_capture_transaction_id IS NOT NULL))),
    CONSTRAINT savings_balance_holds_hold_type_check CHECK ((hold_type = ANY (ARRAY['WITHDRAWAL'::text, 'TRANSFER'::text, 'PLACEMENT'::text, 'COMPLIANCE'::text, 'ADMIN'::text]))),
    CONSTRAINT savings_balance_holds_status_check CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'CAPTURED'::text, 'RELEASED'::text, 'EXPIRED'::text])))
);

ALTER TABLE ONLY public.savings_balance_holds FORCE ROW LEVEL SECURITY;


--
-- Name: savings_deposits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_deposits (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    deposit_reference character varying(100) NOT NULL,
    amount bigint NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    channel public.savings_transaction_channel_enum NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    payment_transaction_id uuid,
    ledger_transaction_id uuid,
    received_at timestamp with time zone,
    processed_at timestamp with time zone,
    failure_reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    operation_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    request_id text,
    failure_code text,
    request_hash character(64),
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    CONSTRAINT chk_savings_deposit_amount CHECK ((amount > 0)),
    CONSTRAINT savings_deposit_ledger_hash CHECK (((ledger_request_hash IS NULL) OR (ledger_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_deposit_request_hash CHECK ((request_hash ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT savings_deposit_success_evidence CHECK (((status <> 'SUCCESSFUL'::public.savings_transaction_status_enum) OR ((ledger_transaction_id IS NOT NULL) AND (ledger_journal_id IS NOT NULL) AND (ledger_request_hash IS NOT NULL) AND (ledger_posted_at IS NOT NULL) AND (processed_at IS NOT NULL)))),
    CONSTRAINT savings_deposits_check CHECK ((((status)::text <> 'SUCCESSFUL'::text) OR (ledger_transaction_id IS NOT NULL)))
);

ALTER TABLE ONLY public.savings_deposits FORCE ROW LEVEL SECURITY;


--
-- Name: savings_goal_contributions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_goal_contributions (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    goal_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    amount bigint NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    channel public.savings_transaction_channel_enum NOT NULL,
    payment_transaction_id uuid,
    ledger_transaction_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    deposit_id uuid NOT NULL,
    contribution_reference text NOT NULL,
    CONSTRAINT chk_goal_contribution_amount CHECK ((amount > 0))
);

ALTER TABLE ONLY public.savings_goal_contributions FORCE ROW LEVEL SECURITY;


--
-- Name: savings_goal_milestones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_goal_milestones (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    goal_id uuid NOT NULL,
    milestone_type public.milestone_type_enum NOT NULL,
    percentage_value numeric(7,4),
    amount_value numeric(20,2),
    date_value date,
    achieved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_goal_milestone_value CHECK ((((milestone_type = 'PERCENTAGE'::public.milestone_type_enum) AND (percentage_value > (0)::numeric) AND (percentage_value <= (100)::numeric) AND (amount_value IS NULL) AND (date_value IS NULL)) OR ((milestone_type = 'AMOUNT'::public.milestone_type_enum) AND (amount_value > (0)::numeric) AND (percentage_value IS NULL) AND (date_value IS NULL)) OR ((milestone_type = 'DATE'::public.milestone_type_enum) AND (date_value IS NOT NULL) AND (amount_value IS NULL) AND (percentage_value IS NULL)))),
    CONSTRAINT savings_goal_milestones_check CHECK ((num_nonnulls(percentage_value, amount_value, date_value) = 1))
);

ALTER TABLE ONLY public.savings_goal_milestones FORCE ROW LEVEL SECURITY;


--
-- Name: savings_goal_withdrawals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_goal_withdrawals (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    goal_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    amount bigint NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    payment_transaction_id uuid,
    ledger_transaction_id uuid,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    withdrawal_id uuid NOT NULL,
    withdrawal_reference text NOT NULL,
    withdrawal_kind text DEFAULT 'PARTIAL'::text NOT NULL,
    forfeited_interest_minor bigint DEFAULT 0 NOT NULL,
    idempotency_key character varying(255),
    request_hash character(64),
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    CONSTRAINT chk_goal_withdrawal_amount CHECK ((amount > 0)),
    CONSTRAINT savings_goal_withdrawal_forfeiture CHECK ((forfeited_interest_minor >= 0)),
    CONSTRAINT savings_goal_withdrawal_hash CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_goal_withdrawal_kind CHECK ((withdrawal_kind = ANY (ARRAY['PARTIAL'::text, 'BREAK'::text]))),
    CONSTRAINT savings_goal_withdrawal_ledger_hash CHECK (((ledger_request_hash IS NULL) OR (ledger_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_goal_withdrawal_success CHECK (((status <> 'SUCCESSFUL'::public.savings_transaction_status_enum) OR ((ledger_transaction_id IS NOT NULL) AND (ledger_journal_id IS NOT NULL) AND (ledger_request_hash IS NOT NULL) AND (ledger_posted_at IS NOT NULL) AND (processed_at IS NOT NULL))))
);

ALTER TABLE ONLY public.savings_goal_withdrawals FORCE ROW LEVEL SECURITY;


--
-- Name: savings_goals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_goals (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    goal_reference character varying(100) NOT NULL,
    goal_name character varying(150) NOT NULL,
    description text,
    target_amount bigint NOT NULL,
    current_amount bigint DEFAULT 0 NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    target_date date,
    status public.savings_goal_status_enum DEFAULT 'ACTIVE'::public.savings_goal_status_enum NOT NULL,
    auto_save_enabled boolean DEFAULT false NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    creation_idempotency_key character varying(255),
    creation_request_hash character(64),
    product_terms_hash character(64),
    partial_withdrawal_limit_rate numeric(18,10) DEFAULT 50 NOT NULL,
    partial_withdrawal_limit_count integer DEFAULT 1 NOT NULL,
    partial_withdrawal_count integer DEFAULT 0 NOT NULL,
    withdrawn_interest_forfeiture boolean DEFAULT true NOT NULL,
    break_forfeits_all_interest boolean DEFAULT true NOT NULL,
    accrued_interest numeric(30,12) DEFAULT 0 NOT NULL,
    broken_at timestamp with time zone,
    completed_at timestamp with time zone,
    lifecycle_evidence jsonb,
    CONSTRAINT chk_savings_goal_current CHECK ((current_amount >= 0)),
    CONSTRAINT chk_savings_goal_target CHECK ((target_amount > 0)),
    CONSTRAINT savings_goal_creation_hash CHECK (((creation_request_hash IS NULL) OR (creation_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_goal_interest_nonnegative CHECK ((accrued_interest >= (0)::numeric)),
    CONSTRAINT savings_goal_lifecycle_evidence CHECK ((((status <> 'CANCELLED'::public.savings_goal_status_enum) OR ((broken_at IS NOT NULL) AND (lifecycle_evidence IS NOT NULL))) AND ((status <> 'COMPLETED'::public.savings_goal_status_enum) OR (completed_at IS NOT NULL)))),
    CONSTRAINT savings_goal_partial_policy CHECK (((partial_withdrawal_limit_rate = (50)::numeric) AND (partial_withdrawal_limit_count = 1) AND ((partial_withdrawal_count >= 0) AND (partial_withdrawal_count <= partial_withdrawal_limit_count)))),
    CONSTRAINT savings_goal_terms_hash CHECK (((product_terms_hash IS NULL) OR (product_terms_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_goals_deleted_at_check CHECK ((deleted_at IS NULL))
);

ALTER TABLE ONLY public.savings_goals FORCE ROW LEVEL SECURITY;


--
-- Name: savings_idempotency_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_idempotency_keys (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    customer_id uuid,
    idempotency_key character varying(255) NOT NULL,
    request_hash character varying(128) NOT NULL,
    operation_type character varying(100) NOT NULL,
    resource_id uuid,
    response_status integer,
    response_body jsonb,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    status text DEFAULT 'PROCESSING'::text NOT NULL,
    http_method text,
    endpoint text,
    locked_at timestamp with time zone,
    locked_by text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT savings_idempotency_keys_check CHECK ((expires_at > created_at)),
    CONSTRAINT savings_idempotency_keys_response_status_check CHECK (((response_status IS NULL) OR ((response_status >= 100) AND (response_status <= 599)))),
    CONSTRAINT savings_idempotency_keys_status_check CHECK ((status = ANY (ARRAY['PROCESSING'::text, 'COMPLETED'::text, 'FAILED'::text])))
);

ALTER TABLE ONLY public.savings_idempotency_keys FORCE ROW LEVEL SECURITY;


--
-- Name: savings_inbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_inbox_events (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    source_service text NOT NULL,
    event_id uuid NOT NULL,
    consumer_name text NOT NULL,
    event_type text NOT NULL,
    event_version integer NOT NULL,
    aggregate_id uuid,
    aggregate_version bigint,
    correlation_id uuid NOT NULL,
    causation_id uuid,
    request_id text,
    payload jsonb NOT NULL,
    payload_hash text NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    attempt_count integer DEFAULT 0 NOT NULL,
    available_at timestamp with time zone DEFAULT now() NOT NULL,
    locked_at timestamp with time zone,
    locked_by text,
    last_error text,
    occurred_at timestamp with time zone NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    dead_lettered_at timestamp with time zone,
    CONSTRAINT savings_inbox_events_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT savings_inbox_events_check CHECK (((status <> 'PROCESSED'::text) OR (processed_at IS NOT NULL))),
    CONSTRAINT savings_inbox_events_event_version_check CHECK ((event_version > 0)),
    CONSTRAINT savings_inbox_events_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'PROCESSING'::text, 'PROCESSED'::text, 'FAILED'::text, 'DEAD_LETTER'::text])))
);

ALTER TABLE ONLY public.savings_inbox_events FORCE ROW LEVEL SECURITY;


--
-- Name: savings_interest_accrual_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_interest_accrual_batches (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    accrual_date date NOT NULL,
    currency character(3) NOT NULL,
    batch_reference text NOT NULL,
    algorithm_version text NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    accounts_processed integer DEFAULT 0 NOT NULL,
    total_interest numeric(30,12) DEFAULT 0 NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    idempotency_key character varying(255),
    request_hash character(64),
    correlation_id uuid,
    attempt_count integer DEFAULT 0 NOT NULL,
    locked_at timestamp with time zone,
    locked_by text,
    lease_expires_at timestamp with time zone,
    next_retry_at timestamp with time zone,
    CONSTRAINT interest_accrual_batch_attempts CHECK ((attempt_count >= 0)),
    CONSTRAINT interest_accrual_batch_hash CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT interest_accrual_batch_lease CHECK ((((locked_at IS NULL) = (locked_by IS NULL)) AND ((locked_at IS NULL) = (lease_expires_at IS NULL)))),
    CONSTRAINT savings_interest_accrual_batches_accounts_processed_check CHECK ((accounts_processed >= 0)),
    CONSTRAINT savings_interest_accrual_batches_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'PROCESSING'::text, 'COMPLETED'::text, 'FAILED'::text]))),
    CONSTRAINT savings_interest_accrual_batches_total_interest_check CHECK ((total_interest >= (0)::numeric))
);

ALTER TABLE ONLY public.savings_interest_accrual_batches FORCE ROW LEVEL SECURITY;


--
-- Name: savings_interest_accrual_corrections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_interest_accrual_corrections (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    interest_accrual_id uuid NOT NULL,
    correction_reference text NOT NULL,
    signed_amount numeric(30,12) NOT NULL,
    reason text NOT NULL,
    created_by uuid NOT NULL,
    approved_by uuid NOT NULL,
    ledger_transaction_id uuid NOT NULL,
    correction_payment_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    approval_id uuid,
    approval_authority_level integer,
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    CONSTRAINT interest_correction_approval CHECK (((approval_id IS NOT NULL) AND (created_by <> approved_by))),
    CONSTRAINT interest_correction_ledger CHECK (((ledger_request_hash IS NOT NULL) AND (ledger_request_hash ~ '^[a-f0-9]{64}$'::text) AND (ledger_journal_id IS NOT NULL) AND (ledger_posted_at IS NOT NULL))),
    CONSTRAINT savings_interest_accrual_corrections_check CHECK ((created_by <> approved_by)),
    CONSTRAINT savings_interest_accrual_corrections_signed_amount_check CHECK ((signed_amount <> (0)::numeric))
);

ALTER TABLE ONLY public.savings_interest_accrual_corrections FORCE ROW LEVEL SECURITY;


--
-- Name: savings_interest_accruals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_interest_accruals (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    accrual_date date NOT NULL,
    opening_balance bigint NOT NULL,
    applicable_rate numeric(18,10) NOT NULL,
    interest_amount numeric(30,12) NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    posted boolean DEFAULT false NOT NULL,
    ledger_transaction_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    product_version_id uuid NOT NULL,
    product_rate_id uuid,
    fixed_deposit_rate_id uuid,
    accrual_batch_id uuid NOT NULL,
    fixed_deposit_id uuid,
    calculation_basis_amount bigint NOT NULL,
    day_count_basis text NOT NULL,
    days_in_basis integer NOT NULL,
    calculation_method public.interest_calculation_method_enum NOT NULL,
    posted_at timestamp with time zone,
    request_hash character(64),
    calculation_snapshot jsonb,
    CONSTRAINT chk_interest_accrual_amount CHECK ((interest_amount >= (0)::numeric)),
    CONSTRAINT interest_accrual_basis_minor CHECK ((calculation_basis_amount >= 0)),
    CONSTRAINT interest_accrual_opening_minor CHECK ((opening_balance >= 0)),
    CONSTRAINT interest_accrual_rate CHECK ((applicable_rate >= (0)::numeric)),
    CONSTRAINT interest_accrual_request_hash CHECK (((request_hash IS NOT NULL) AND (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT interest_accrual_snapshot CHECK (((calculation_snapshot IS NOT NULL) AND (jsonb_typeof(calculation_snapshot) = 'object'::text))),
    CONSTRAINT savings_interest_accruals_check CHECK ((num_nonnulls(product_rate_id, fixed_deposit_rate_id) = 1)),
    CONSTRAINT savings_interest_accruals_check1 CHECK (((fixed_deposit_id IS NOT NULL) = (fixed_deposit_rate_id IS NOT NULL))),
    CONSTRAINT savings_interest_accruals_check2 CHECK ((posted = (ledger_transaction_id IS NOT NULL))),
    CONSTRAINT savings_interest_accruals_check3 CHECK (((NOT posted) OR (posted_at IS NOT NULL))),
    CONSTRAINT savings_interest_accruals_day_count_basis_check CHECK ((day_count_basis = ANY (ARRAY['ACT_365_FIXED'::text, 'ACT_ACT'::text, 'ACT_360'::text, '30_360'::text]))),
    CONSTRAINT savings_interest_accruals_days_in_basis_check CHECK ((days_in_basis = ANY (ARRAY[360, 365, 366])))
);

ALTER TABLE ONLY public.savings_interest_accruals FORCE ROW LEVEL SECURITY;


--
-- Name: savings_interest_payment_accruals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_interest_payment_accruals (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    interest_payment_id uuid NOT NULL,
    interest_accrual_id uuid NOT NULL,
    allocated_unrounded numeric(30,12) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    allocated_minor bigint DEFAULT 0 NOT NULL,
    CONSTRAINT interest_allocation_minor CHECK ((allocated_minor >= 0)),
    CONSTRAINT savings_interest_payment_accruals_allocated_amount_check CHECK ((allocated_unrounded >= (0)::numeric))
);

ALTER TABLE ONLY public.savings_interest_payment_accruals FORCE ROW LEVEL SECURITY;


--
-- Name: savings_interest_payment_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_interest_payment_batches (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    batch_reference text NOT NULL,
    currency character(3) NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    status text DEFAULT 'PENDING'::text NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    idempotency_key character varying(255),
    request_hash character(64),
    correlation_id uuid,
    attempt_count integer DEFAULT 0 NOT NULL,
    locked_at timestamp with time zone,
    locked_by text,
    lease_expires_at timestamp with time zone,
    next_retry_at timestamp with time zone,
    payments_processed integer DEFAULT 0 NOT NULL,
    total_paid_minor bigint DEFAULT 0 NOT NULL,
    CONSTRAINT interest_payment_batch_counts CHECK (((attempt_count >= 0) AND (payments_processed >= 0) AND (total_paid_minor >= 0))),
    CONSTRAINT interest_payment_batch_hash CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT interest_payment_batch_lease CHECK ((((locked_at IS NULL) = (locked_by IS NULL)) AND ((locked_at IS NULL) = (lease_expires_at IS NULL)))),
    CONSTRAINT savings_interest_payment_batches_check CHECK ((period_end >= period_start)),
    CONSTRAINT savings_interest_payment_batches_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'PROCESSING'::text, 'COMPLETED'::text, 'FAILED'::text])))
);

ALTER TABLE ONLY public.savings_interest_payment_batches FORCE ROW LEVEL SECURITY;


--
-- Name: savings_interest_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_interest_payments (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    payment_reference character varying(100) NOT NULL,
    amount bigint NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    payment_period_start date NOT NULL,
    payment_period_end date NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    ledger_transaction_id uuid,
    paid_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    tax_amount bigint DEFAULT 0 NOT NULL,
    settlement_basis text DEFAULT 'ACCRUED'::text NOT NULL,
    fixed_deposit_id uuid,
    payment_batch_id uuid NOT NULL,
    rounding_adjustment bigint DEFAULT 0 NOT NULL,
    operation_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    request_id text,
    failure_code text,
    net_amount bigint GENERATED ALWAYS AS ((amount - tax_amount)) STORED,
    request_hash character(64),
    calculation_snapshot jsonb,
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    interest_expense_account_id uuid,
    CONSTRAINT chk_interest_payment_amount CHECK (((amount)::numeric >= (0)::numeric)),
    CONSTRAINT chk_interest_payment_period CHECK ((payment_period_end >= payment_period_start)),
    CONSTRAINT interest_payment_hash CHECK (((request_hash IS NOT NULL) AND (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT interest_payment_ledger_hash CHECK (((ledger_request_hash IS NULL) OR (ledger_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT interest_payment_snapshot CHECK (((calculation_snapshot IS NOT NULL) AND (jsonb_typeof(calculation_snapshot) = 'object'::text))),
    CONSTRAINT interest_payment_success_evidence CHECK (((status <> 'SUCCESSFUL'::public.savings_transaction_status_enum) OR ((ledger_transaction_id IS NOT NULL) AND (ledger_journal_id IS NOT NULL) AND (ledger_request_hash IS NOT NULL) AND (ledger_posted_at IS NOT NULL) AND (interest_expense_account_id IS NOT NULL) AND (paid_at IS NOT NULL)))),
    CONSTRAINT savings_interest_payments_check CHECK (((settlement_basis <> 'PREPAID'::text) OR (fixed_deposit_id IS NOT NULL))),
    CONSTRAINT savings_interest_payments_check1 CHECK ((tax_amount <= amount)),
    CONSTRAINT savings_interest_payments_check2 CHECK ((((status)::text <> 'SUCCESSFUL'::text) OR (ledger_transaction_id IS NOT NULL))),
    CONSTRAINT savings_interest_payments_settlement_basis_check CHECK ((settlement_basis = ANY (ARRAY['ACCRUED'::text, 'PREPAID'::text]))),
    CONSTRAINT savings_interest_payments_tax_amount_check CHECK (((tax_amount)::numeric >= (0)::numeric))
);

ALTER TABLE ONLY public.savings_interest_payments FORCE ROW LEVEL SECURITY;


--
-- Name: savings_outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_outbox_events (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    aggregate_type character varying(100) NOT NULL,
    aggregate_id uuid NOT NULL,
    event_type character varying(150) NOT NULL,
    payload jsonb NOT NULL,
    status character varying(30) DEFAULT 'PENDING'::character varying NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    available_at timestamp with time zone DEFAULT now() NOT NULL,
    published_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    event_version integer DEFAULT 1 NOT NULL,
    aggregate_version bigint NOT NULL,
    correlation_id uuid NOT NULL,
    causation_id uuid,
    request_id text,
    partition_key text NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    locked_at timestamp with time zone,
    locked_by text,
    dead_lettered_at timestamp with time zone,
    CONSTRAINT chk_savings_outbox_status CHECK (((status)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('PROCESSING'::character varying)::text, ('PUBLISHED'::character varying)::text, ('FAILED'::character varying)::text, ('DEAD_LETTER'::character varying)::text]))),
    CONSTRAINT savings_outbox_events_aggregate_version_check CHECK ((aggregate_version > 0)),
    CONSTRAINT savings_outbox_events_check CHECK ((((status)::text <> 'PUBLISHED'::text) OR (published_at IS NOT NULL))),
    CONSTRAINT savings_outbox_events_event_version_check CHECK ((event_version > 0)),
    CONSTRAINT savings_outbox_events_retry_count_check CHECK ((retry_count >= 0))
);

ALTER TABLE ONLY public.savings_outbox_events FORCE ROW LEVEL SECURITY;


--
-- Name: savings_processing_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_processing_attempts (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    target_service text NOT NULL,
    outcome text NOT NULL,
    started_at timestamp with time zone NOT NULL,
    finished_at timestamp with time zone NOT NULL,
    error_code text,
    error_message text,
    response_reference text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT savings_processing_attempts_attempt_number_check CHECK ((attempt_number > 0)),
    CONSTRAINT savings_processing_attempts_check CHECK ((finished_at >= started_at)),
    CONSTRAINT savings_processing_attempts_outcome_check CHECK ((outcome = ANY (ARRAY['SUCCESS'::text, 'FAILURE'::text, 'UNKNOWN'::text])))
);

ALTER TABLE ONLY public.savings_processing_attempts FORCE ROW LEVEL SECURITY;


--
-- Name: savings_product_fees; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_product_fees (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_product_id uuid NOT NULL,
    fee_code character varying(50) NOT NULL,
    fee_name character varying(150) NOT NULL,
    percentage_rate numeric(18,10),
    fixed_amount bigint,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    product_version_id uuid NOT NULL,
    fee_event text NOT NULL,
    calculation_basis text DEFAULT 'TRANSACTION_AMOUNT'::text NOT NULL,
    minimum_fee bigint DEFAULT 0 NOT NULL,
    maximum_fee bigint,
    tax_inclusive boolean DEFAULT false NOT NULL,
    ledger_fee_code text NOT NULL,
    effective_from timestamp with time zone NOT NULL,
    effective_to timestamp with time zone,
    CONSTRAINT chk_savings_fee_value CHECK ((((percentage_rate IS NOT NULL) AND (fixed_amount IS NULL)) OR ((percentage_rate IS NULL) AND (fixed_amount IS NOT NULL)))),
    CONSTRAINT savings_product_fees_calculation_basis_check CHECK ((calculation_basis = ANY (ARRAY['TRANSACTION_AMOUNT'::text, 'PRINCIPAL'::text, 'INTEREST'::text, 'FLAT'::text]))),
    CONSTRAINT savings_product_fees_check CHECK (((maximum_fee IS NULL) OR (maximum_fee >= minimum_fee))),
    CONSTRAINT savings_product_fees_check1 CHECK (((effective_to IS NULL) OR (effective_to > effective_from))),
    CONSTRAINT savings_product_fees_fee_event_check CHECK ((fee_event = ANY (ARRAY['WITHDRAWAL'::text, 'EARLY_LIQUIDATION'::text, 'TRANSFER'::text, 'CLOSURE'::text, 'MAINTENANCE'::text]))),
    CONSTRAINT savings_product_fees_fixed_amount_check CHECK (((fixed_amount IS NULL) OR ((fixed_amount)::numeric >= (0)::numeric))),
    CONSTRAINT savings_product_fees_minimum_fee_check CHECK (((minimum_fee)::numeric >= (0)::numeric)),
    CONSTRAINT savings_product_fees_percentage_rate_check CHECK (((percentage_rate IS NULL) OR ((percentage_rate >= (0)::numeric) AND (percentage_rate <= (100)::numeric))))
);

ALTER TABLE ONLY public.savings_product_fees FORCE ROW LEVEL SECURITY;


--
-- Name: savings_product_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_product_rates (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_product_id uuid NOT NULL,
    effective_from timestamp with time zone NOT NULL,
    effective_to timestamp with time zone,
    interest_rate numeric(18,10) NOT NULL,
    minimum_balance bigint,
    maximum_balance bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    product_version_id uuid NOT NULL,
    CONSTRAINT chk_savings_rate CHECK ((interest_rate >= (0)::numeric)),
    CONSTRAINT chk_savings_rate_dates CHECK (((effective_to IS NULL) OR (effective_to > effective_from))),
    CONSTRAINT savings_product_rates_check CHECK (((maximum_balance IS NULL) OR ((maximum_balance)::numeric > COALESCE((minimum_balance)::numeric, (0)::numeric)))),
    CONSTRAINT savings_product_rates_minimum_balance_check CHECK (((minimum_balance IS NULL) OR ((minimum_balance)::numeric >= (0)::numeric)))
);

ALTER TABLE ONLY public.savings_product_rates FORCE ROW LEVEL SECURITY;


--
-- Name: savings_product_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_product_rules (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_product_id uuid NOT NULL,
    rule_code character varying(100) NOT NULL,
    rule_name character varying(200) NOT NULL,
    rule_type character varying(100) NOT NULL,
    configuration jsonb DEFAULT '{}'::jsonb NOT NULL,
    is_mandatory boolean DEFAULT true NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    product_version_id uuid NOT NULL,
    CONSTRAINT savings_product_rules_configuration_check CHECK ((jsonb_typeof(configuration) = 'object'::text)),
    CONSTRAINT savings_product_rules_rule_type_check CHECK (((rule_type)::text ~ '^[A-Z][A-Z0-9_]*$'::text))
);

ALTER TABLE ONLY public.savings_product_rules FORCE ROW LEVEL SECURITY;


--
-- Name: savings_product_tiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_product_tiers (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_product_id uuid NOT NULL,
    tier_code character varying(50) NOT NULL,
    minimum_balance bigint,
    maximum_balance bigint,
    interest_rate numeric(18,10),
    configuration jsonb DEFAULT '{}'::jsonb NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    product_version_id uuid NOT NULL,
    effective_from timestamp with time zone NOT NULL,
    effective_to timestamp with time zone,
    CONSTRAINT chk_savings_tier_balance CHECK (((minimum_balance IS NULL) OR (maximum_balance IS NULL) OR (maximum_balance >= minimum_balance))),
    CONSTRAINT savings_product_tiers_check CHECK (((maximum_balance IS NULL) OR ((maximum_balance)::numeric > COALESCE((minimum_balance)::numeric, (0)::numeric)))),
    CONSTRAINT savings_product_tiers_check1 CHECK (((effective_to IS NULL) OR (effective_to > effective_from))),
    CONSTRAINT savings_product_tiers_interest_rate_check CHECK (((interest_rate IS NULL) OR (interest_rate >= (0)::numeric))),
    CONSTRAINT savings_product_tiers_minimum_balance_check CHECK (((minimum_balance IS NULL) OR ((minimum_balance)::numeric >= (0)::numeric)))
);

ALTER TABLE ONLY public.savings_product_tiers FORCE ROW LEVEL SECURITY;


--
-- Name: savings_product_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_product_versions (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_product_id uuid NOT NULL,
    version_number integer NOT NULL,
    status text DEFAULT 'DRAFT'::text NOT NULL,
    effective_from timestamp with time zone NOT NULL,
    effective_to timestamp with time zone,
    currency character(3) NOT NULL,
    product_type public.savings_product_type_enum NOT NULL,
    minimum_balance bigint,
    minimum_deposit bigint DEFAULT 0 NOT NULL,
    maximum_balance bigint,
    calculation_method public.interest_calculation_method_enum NOT NULL,
    payment_frequency public.interest_payment_frequency_enum NOT NULL,
    rate_basis text DEFAULT 'ANNUAL_PERCENT'::text NOT NULL,
    day_count_basis text NOT NULL,
    compounding_method text NOT NULL,
    withdrawal_allowed boolean DEFAULT true NOT NULL,
    early_withdrawal_allowed boolean DEFAULT false NOT NULL,
    lock_period_days integer DEFAULT 0 NOT NULL,
    terms jsonb NOT NULL,
    terms_hash text NOT NULL,
    created_by uuid NOT NULL,
    approved_by uuid,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    annual_rate numeric(18,10) DEFAULT 0 NOT NULL,
    is_current boolean DEFAULT false NOT NULL,
    idempotency_key character varying(255),
    request_hash character(64),
    approval_id uuid,
    approval_payload_hash character(64),
    approval_maker_id uuid,
    approval_checker_ids uuid[],
    approved_authority_level integer,
    published_by uuid,
    publication_idempotency_key character varying(255),
    publication_request_hash character(64),
    CONSTRAINT savings_maker_checker CHECK (((approval_checker_ids IS NULL) OR (NOT (approval_maker_id = ANY (approval_checker_ids))))),
    CONSTRAINT savings_ordinary_no_minimum CHECK (((product_type <> 'ORDINARY'::public.savings_product_type_enum) OR (minimum_balance IS NULL))),
    CONSTRAINT savings_product_versions_check CHECK (((effective_to IS NULL) OR (effective_to > effective_from))),
    CONSTRAINT savings_product_versions_check1 CHECK (((maximum_balance IS NULL) OR (maximum_balance >= minimum_balance))),
    CONSTRAINT savings_product_versions_check2 CHECK (((approved_by IS NULL) OR (approved_by <> created_by))),
    CONSTRAINT savings_product_versions_check3 CHECK (((status <> 'PUBLISHED'::text) OR ((approved_by IS NOT NULL) AND (published_at IS NOT NULL)))),
    CONSTRAINT savings_product_versions_compounding_method_check CHECK ((compounding_method = ANY (ARRAY['SIMPLE'::text, 'DAILY'::text, 'MONTHLY'::text, 'QUARTERLY'::text, 'ANNUALLY'::text]))),
    CONSTRAINT savings_product_versions_currency_check CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT savings_product_versions_day_count_basis_check CHECK ((day_count_basis = ANY (ARRAY['ACT_365_FIXED'::text, 'ACT_ACT'::text, 'ACT_360'::text, '30_360'::text]))),
    CONSTRAINT savings_product_versions_lock_period_days_check CHECK ((lock_period_days >= 0)),
    CONSTRAINT savings_product_versions_minimum_balance_check CHECK (((minimum_balance)::numeric >= (0)::numeric)),
    CONSTRAINT savings_product_versions_minimum_deposit_check CHECK (((minimum_deposit)::numeric >= (0)::numeric)),
    CONSTRAINT savings_product_versions_publication_request_hash_check CHECK (((publication_request_hash IS NULL) OR (publication_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_product_versions_rate_basis_check CHECK ((rate_basis = 'ANNUAL_PERCENT'::text)),
    CONSTRAINT savings_product_versions_request_hash_check CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_product_versions_terms_check CHECK ((jsonb_typeof(terms) = 'object'::text)),
    CONSTRAINT savings_product_versions_version_number_check CHECK ((version_number > 0)),
    CONSTRAINT savings_publication_evidence CHECK (((status <> ALL (ARRAY['PUBLISHED'::text, 'RETIRED'::text])) OR ((approval_id IS NOT NULL) AND (approval_payload_hash IS NOT NULL) AND (approval_maker_id IS NOT NULL) AND (cardinality(approval_checker_ids) > 0) AND (approved_authority_level > 0) AND (published_by IS NOT NULL) AND (published_at IS NOT NULL)))),
    CONSTRAINT savings_version_status CHECK ((status = ANY (ARRAY['DRAFT'::text, 'PENDING_APPROVAL'::text, 'PUBLISHED'::text, 'RETIRED'::text])))
);

ALTER TABLE ONLY public.savings_product_versions FORCE ROW LEVEL SECURITY;


--
-- Name: savings_products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_products (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    product_code character varying(50) NOT NULL,
    product_name character varying(150) NOT NULL,
    product_type public.savings_product_type_enum NOT NULL,
    description text,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    minimum_balance bigint DEFAULT 0 NOT NULL,
    minimum_deposit bigint DEFAULT 0 NOT NULL,
    maximum_balance bigint,
    interest_rate numeric(18,10) DEFAULT 0 NOT NULL,
    interest_calculation_method public.interest_calculation_method_enum DEFAULT 'DAILY_BALANCE'::public.interest_calculation_method_enum NOT NULL,
    interest_payment_frequency public.interest_payment_frequency_enum DEFAULT 'MONTHLY'::public.interest_payment_frequency_enum NOT NULL,
    withdrawal_allowed boolean DEFAULT true NOT NULL,
    withdrawal_fee_enabled boolean DEFAULT false NOT NULL,
    early_withdrawal_allowed boolean DEFAULT true NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    configuration jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    updated_by uuid,
    deleted_at timestamp with time zone,
    lifecycle_status text DEFAULT 'DRAFT'::text NOT NULL,
    idempotency_key character varying(255),
    request_hash character(64),
    CONSTRAINT chk_savings_product_interest CHECK ((interest_rate >= (0)::numeric)),
    CONSTRAINT chk_savings_product_max_balance CHECK (((maximum_balance IS NULL) OR (maximum_balance >= minimum_balance))),
    CONSTRAINT chk_savings_product_min_balance CHECK (((minimum_balance)::numeric >= (0)::numeric)),
    CONSTRAINT chk_savings_product_min_deposit CHECK (((minimum_deposit)::numeric >= (0)::numeric)),
    CONSTRAINT savings_products_currency_check CHECK ((currency ~ '^[A-Z]{3}$'::text)),
    CONSTRAINT savings_products_lifecycle_status_check CHECK ((lifecycle_status = ANY (ARRAY['DRAFT'::text, 'ACTIVE'::text, 'RETIRED'::text]))),
    CONSTRAINT savings_products_request_hash_check CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text)))
);

ALTER TABLE ONLY public.savings_products FORCE ROW LEVEL SECURITY;


--
-- Name: savings_reconciliation_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_reconciliation_items (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    reconciliation_run_id uuid NOT NULL,
    savings_account_id uuid,
    resource_type text NOT NULL,
    resource_id uuid NOT NULL,
    currency character(3),
    expected_amount numeric(24,8),
    actual_amount numeric(24,8),
    discrepancy_type text NOT NULL,
    evidence jsonb NOT NULL,
    status text DEFAULT 'OPEN'::text NOT NULL,
    resolution text,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    adjustment_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT savings_reconciliation_items_check CHECK (((status <> ALL (ARRAY['RESOLVED'::text, 'ACCEPTED'::text])) OR ((resolution IS NOT NULL) AND (resolved_by IS NOT NULL) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT savings_reconciliation_items_status_check CHECK ((status = ANY (ARRAY['OPEN'::text, 'INVESTIGATING'::text, 'RESOLVED'::text, 'ACCEPTED'::text])))
);

ALTER TABLE ONLY public.savings_reconciliation_items FORCE ROW LEVEL SECURITY;


--
-- Name: savings_reconciliation_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_reconciliation_runs (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    run_reference text NOT NULL,
    reconciliation_type text NOT NULL,
    as_of_at timestamp with time zone NOT NULL,
    ledger_watermark bigint,
    status text DEFAULT 'PENDING'::text NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    discrepancy_count integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT savings_reconciliation_runs_discrepancy_count_check CHECK ((discrepancy_count >= 0)),
    CONSTRAINT savings_reconciliation_runs_reconciliation_type_check CHECK ((reconciliation_type = ANY (ARRAY['LEDGER_BALANCES'::text, 'PAYMENT_STATUS'::text, 'INTEREST'::text, 'HOLDS'::text, 'FIXED_DEPOSITS'::text]))),
    CONSTRAINT savings_reconciliation_runs_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'PROCESSING'::text, 'COMPLETED'::text, 'FAILED'::text])))
);

ALTER TABLE ONLY public.savings_reconciliation_runs FORCE ROW LEVEL SECURITY;


--
-- Name: savings_recurring_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_recurring_executions (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    recurring_plan_id uuid NOT NULL,
    execution_number integer NOT NULL,
    scheduled_date date NOT NULL,
    amount bigint NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    payment_transaction_id uuid,
    ledger_transaction_id uuid,
    attempted_at timestamp with time zone,
    completed_at timestamp with time zone,
    failure_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    deposit_id uuid,
    attempt_count integer DEFAULT 0 NOT NULL,
    next_retry_at timestamp with time zone,
    locked_at timestamp with time zone,
    locked_by text,
    failure_code text,
    operation_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    request_id text,
    request_hash character(64),
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    lease_expires_at timestamp with time zone,
    retry_classification text,
    terminal_at timestamp with time zone,
    CONSTRAINT recurring_execution_amount_minor CHECK ((amount > 0)),
    CONSTRAINT recurring_execution_hash CHECK (((request_hash IS NOT NULL) AND (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT recurring_execution_lease CHECK ((((locked_at IS NULL) = (locked_by IS NULL)) AND ((locked_at IS NULL) = (lease_expires_at IS NULL)))),
    CONSTRAINT recurring_execution_ledger_hash CHECK (((ledger_request_hash IS NULL) OR (ledger_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT recurring_execution_retry_classification CHECK (((retry_classification IS NULL) OR (retry_classification = ANY (ARRAY['RETRYABLE'::text, 'TERMINAL'::text, 'INSUFFICIENT_FUNDS'::text])))),
    CONSTRAINT recurring_execution_success_evidence CHECK (((status <> 'SUCCESSFUL'::public.savings_transaction_status_enum) OR ((deposit_id IS NOT NULL) AND (ledger_transaction_id IS NOT NULL) AND (ledger_journal_id IS NOT NULL) AND (ledger_request_hash IS NOT NULL) AND (ledger_posted_at IS NOT NULL) AND (completed_at IS NOT NULL)))),
    CONSTRAINT savings_recurring_executions_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT savings_recurring_executions_check CHECK ((((status)::text <> 'SUCCESSFUL'::text) OR (ledger_transaction_id IS NOT NULL))),
    CONSTRAINT savings_recurring_executions_execution_number_check CHECK ((execution_number > 0))
);

ALTER TABLE ONLY public.savings_recurring_executions FORCE ROW LEVEL SECURITY;


--
-- Name: savings_recurring_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_recurring_plans (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    goal_id uuid,
    plan_reference character varying(100) NOT NULL,
    amount bigint NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    frequency public.recurring_frequency_enum NOT NULL,
    start_date date NOT NULL,
    end_date date,
    next_execution_date date,
    max_executions integer,
    execution_count integer DEFAULT 0 NOT NULL,
    source_account_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    timezone_name text DEFAULT 'Africa/Lagos'::text NOT NULL,
    execution_time time without time zone DEFAULT '08:00:00'::time without time zone NOT NULL,
    payment_mandate_id uuid,
    retry_limit integer DEFAULT 3 NOT NULL,
    status text DEFAULT 'ACTIVE'::text NOT NULL,
    funding_source text DEFAULT 'WALLET'::text NOT NULL,
    creation_idempotency_key character varying(255),
    creation_request_hash character(64),
    correlation_id uuid,
    consent_reference character varying(255),
    schedule_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    aggregate_version bigint DEFAULT 1 NOT NULL,
    completed_at timestamp with time zone,
    cancelled_at timestamp with time zone,
    CONSTRAINT chk_recurring_dates CHECK (((end_date IS NULL) OR (end_date >= start_date))),
    CONSTRAINT chk_recurring_execution_count CHECK ((execution_count >= 0)),
    CONSTRAINT recurring_plan_aggregate_version CHECK ((aggregate_version > 0)),
    CONSTRAINT recurring_plan_amount_minor CHECK ((amount > 0)),
    CONSTRAINT recurring_plan_creation_evidence CHECK (((creation_idempotency_key IS NOT NULL) AND (creation_request_hash IS NOT NULL) AND (correlation_id IS NOT NULL) AND (consent_reference IS NOT NULL))),
    CONSTRAINT recurring_plan_creation_hash CHECK (((creation_request_hash IS NULL) OR (creation_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT recurring_plan_snapshot CHECK ((jsonb_typeof(schedule_snapshot) = 'object'::text)),
    CONSTRAINT recurring_plan_status CHECK ((status = ANY (ARRAY['ACTIVE'::text, 'PAUSED'::text, 'COMPLETED'::text, 'CANCELLED'::text, 'EXHAUSTED'::text]))),
    CONSTRAINT recurring_plan_terminal_time CHECK ((((status <> ALL (ARRAY['COMPLETED'::text, 'EXHAUSTED'::text])) OR (completed_at IS NOT NULL)) AND ((status <> 'CANCELLED'::text) OR (cancelled_at IS NOT NULL)))),
    CONSTRAINT recurring_plan_wallet_only CHECK (((funding_source = 'WALLET'::text) AND (source_account_id IS NOT NULL))),
    CONSTRAINT savings_recurring_plans_check CHECK (((max_executions IS NULL) OR (execution_count <= max_executions))),
    CONSTRAINT savings_recurring_plans_check1 CHECK (((next_execution_date IS NULL) OR (next_execution_date >= start_date))),
    CONSTRAINT savings_recurring_plans_check2 CHECK (((end_date IS NULL) OR (next_execution_date IS NULL) OR (next_execution_date <= end_date))),
    CONSTRAINT savings_recurring_plans_max_executions_check CHECK (((max_executions IS NULL) OR (max_executions > 0))),
    CONSTRAINT savings_recurring_plans_retry_limit_check CHECK (((retry_limit >= 0) AND (retry_limit <= 20)))
);

ALTER TABLE ONLY public.savings_recurring_plans FORCE ROW LEVEL SECURITY;


--
-- Name: savings_transfer_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_transfer_requests (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    source_savings_account_id uuid NOT NULL,
    destination_savings_account_id uuid,
    destination_account_id uuid,
    customer_id uuid NOT NULL,
    transfer_reference character varying(100) NOT NULL,
    amount numeric(20,2) NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    payment_transaction_id uuid,
    ledger_transaction_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    failure_reason text,
    operation_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    request_id text,
    failure_code text,
    CONSTRAINT chk_savings_transfer_amount CHECK ((amount > (0)::numeric)),
    CONSTRAINT savings_transfer_requests_check CHECK ((num_nonnulls(destination_savings_account_id, destination_account_id) = 1)),
    CONSTRAINT savings_transfer_requests_check1 CHECK (((destination_savings_account_id IS NULL) OR (destination_savings_account_id <> source_savings_account_id))),
    CONSTRAINT savings_transfer_requests_check2 CHECK ((((status)::text <> 'SUCCESSFUL'::text) OR (ledger_transaction_id IS NOT NULL)))
);

ALTER TABLE ONLY public.savings_transfer_requests FORCE ROW LEVEL SECURITY;


--
-- Name: savings_withdrawals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.savings_withdrawals (
    id uuid DEFAULT public.gen_random_uuid() NOT NULL,
    tenant_id uuid NOT NULL,
    savings_account_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    withdrawal_reference character varying(100) NOT NULL,
    amount bigint NOT NULL,
    fee_amount bigint DEFAULT 0 NOT NULL,
    currency character(3) DEFAULT 'NGN'::bpchar NOT NULL,
    channel public.savings_transaction_channel_enum NOT NULL,
    status public.savings_transaction_status_enum DEFAULT 'PENDING'::public.savings_transaction_status_enum NOT NULL,
    destination_account_id uuid,
    payment_transaction_id uuid,
    ledger_transaction_id uuid,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    failure_reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    operation_id uuid NOT NULL,
    idempotency_key text NOT NULL,
    correlation_id uuid NOT NULL,
    request_id text,
    failure_code text,
    request_hash character(64),
    ledger_journal_id uuid,
    ledger_request_hash character(64),
    ledger_posted_at timestamp with time zone,
    CONSTRAINT chk_savings_withdrawal_amount CHECK ((amount > 0)),
    CONSTRAINT chk_savings_withdrawal_fee CHECK ((fee_amount >= 0)),
    CONSTRAINT savings_withdrawal_ledger_hash CHECK (((ledger_request_hash IS NULL) OR (ledger_request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_withdrawal_request_hash CHECK (((request_hash IS NULL) OR (request_hash ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT savings_withdrawal_success_evidence CHECK (((status <> 'SUCCESSFUL'::public.savings_transaction_status_enum) OR ((ledger_transaction_id IS NOT NULL) AND (ledger_journal_id IS NOT NULL) AND (ledger_request_hash IS NOT NULL) AND (ledger_posted_at IS NOT NULL) AND (processed_at IS NOT NULL)))),
    CONSTRAINT savings_withdrawals_check CHECK ((((status)::text <> 'SUCCESSFUL'::text) OR (ledger_transaction_id IS NOT NULL)))
);

ALTER TABLE ONLY public.savings_withdrawals FORCE ROW LEVEL SECURITY;


--
-- Name: fixed_deposit_instructions fixed_deposit_instructions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_instructions
    ADD CONSTRAINT fixed_deposit_instructions_pkey PRIMARY KEY (id);


--
-- Name: fixed_deposit_instructions fixed_deposit_instructions_tenant_id_fixed_deposit_id_instr_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_instructions
    ADD CONSTRAINT fixed_deposit_instructions_tenant_id_fixed_deposit_id_instr_key UNIQUE (tenant_id, fixed_deposit_id, instruction_number);


--
-- Name: fixed_deposit_instructions fixed_deposit_instructions_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_instructions
    ADD CONSTRAINT fixed_deposit_instructions_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: fixed_deposit_interest_payments fixed_deposit_interest_paymen_tenant_id_fixed_deposit_id_pa_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT fixed_deposit_interest_paymen_tenant_id_fixed_deposit_id_pa_key UNIQUE (tenant_id, fixed_deposit_id, payment_period_start, payment_period_end);


--
-- Name: fixed_deposit_interest_payments fixed_deposit_interest_paymen_tenant_id_interest_payment_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT fixed_deposit_interest_paymen_tenant_id_interest_payment_id_key UNIQUE (tenant_id, interest_payment_id);


--
-- Name: fixed_deposit_interest_payments fixed_deposit_interest_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT fixed_deposit_interest_payments_pkey PRIMARY KEY (id);


--
-- Name: fixed_deposit_interest_payments fixed_deposit_interest_payments_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT fixed_deposit_interest_payments_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: fixed_deposit_interest_payments fixed_deposit_interest_payments_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT fixed_deposit_interest_payments_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: fixed_deposit_liquidations fixed_deposit_liquidations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_liquidations
    ADD CONSTRAINT fixed_deposit_liquidations_pkey PRIMARY KEY (id);


--
-- Name: fixed_deposit_liquidations fixed_deposit_liquidations_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_liquidations
    ADD CONSTRAINT fixed_deposit_liquidations_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: fixed_deposit_liquidations fixed_deposit_liquidations_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_liquidations
    ADD CONSTRAINT fixed_deposit_liquidations_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: fixed_deposit_liquidations fixed_deposit_liquidations_tenant_id_liquidation_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_liquidations
    ADD CONSTRAINT fixed_deposit_liquidations_tenant_id_liquidation_reference_key UNIQUE (tenant_id, liquidation_reference);


--
-- Name: fixed_deposit_maturities fixed_deposit_maturities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_maturities
    ADD CONSTRAINT fixed_deposit_maturities_pkey PRIMARY KEY (id);


--
-- Name: fixed_deposit_maturities fixed_deposit_maturities_tenant_id_fixed_deposit_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_maturities
    ADD CONSTRAINT fixed_deposit_maturities_tenant_id_fixed_deposit_id_key UNIQUE (tenant_id, fixed_deposit_id);


--
-- Name: fixed_deposit_maturities fixed_deposit_maturities_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_maturities
    ADD CONSTRAINT fixed_deposit_maturities_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: fixed_deposit_maturities fixed_deposit_maturities_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_maturities
    ADD CONSTRAINT fixed_deposit_maturities_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: fixed_deposit_maturities fixed_deposit_maturities_tenant_id_maturity_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_maturities
    ADD CONSTRAINT fixed_deposit_maturities_tenant_id_maturity_reference_key UNIQUE (tenant_id, maturity_reference);


--
-- Name: fixed_deposit_quotes fixed_deposit_quotes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_quotes
    ADD CONSTRAINT fixed_deposit_quotes_pkey PRIMARY KEY (id);


--
-- Name: fixed_deposit_quotes fixed_deposit_quotes_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_quotes
    ADD CONSTRAINT fixed_deposit_quotes_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: fixed_deposit_quotes fixed_deposit_quotes_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_quotes
    ADD CONSTRAINT fixed_deposit_quotes_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: fixed_deposit_quotes fixed_deposit_quotes_tenant_id_quote_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_quotes
    ADD CONSTRAINT fixed_deposit_quotes_tenant_id_quote_hash_key UNIQUE (tenant_id, quote_hash);


--
-- Name: fixed_deposit_rates fixed_deposit_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_rates
    ADD CONSTRAINT fixed_deposit_rates_pkey PRIMARY KEY (id);


--
-- Name: fixed_deposit_rates fixed_deposit_rates_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_rates
    ADD CONSTRAINT fixed_deposit_rates_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: fixed_deposit_rates fixed_deposit_rates_tenant_id_id_product_version_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_rates
    ADD CONSTRAINT fixed_deposit_rates_tenant_id_id_product_version_id_key UNIQUE (tenant_id, id, product_version_id);


--
-- Name: fixed_deposit_renewals fixed_deposit_renewals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_renewals
    ADD CONSTRAINT fixed_deposit_renewals_pkey PRIMARY KEY (id);


--
-- Name: fixed_deposit_renewals fixed_deposit_renewals_tenant_id_fixed_deposit_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_renewals
    ADD CONSTRAINT fixed_deposit_renewals_tenant_id_fixed_deposit_id_key UNIQUE (tenant_id, fixed_deposit_id);


--
-- Name: fixed_deposit_renewals fixed_deposit_renewals_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_renewals
    ADD CONSTRAINT fixed_deposit_renewals_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: fixed_deposit_renewals fixed_deposit_renewals_tenant_id_renewed_fixed_deposit_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_renewals
    ADD CONSTRAINT fixed_deposit_renewals_tenant_id_renewed_fixed_deposit_id_key UNIQUE (tenant_id, renewed_fixed_deposit_id);


--
-- Name: fixed_deposits fixed_deposits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_pkey PRIMARY KEY (id);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_contract_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_contract_reference_key UNIQUE (tenant_id, contract_reference);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_id_currency_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_id_currency_key UNIQUE (tenant_id, id, currency);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_id_savings_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_id_savings_account_id_key UNIQUE (tenant_id, id, savings_account_id);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_savings_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_savings_account_id_key UNIQUE (tenant_id, savings_account_id);


--
-- Name: savings_account_contracts savings_account_contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_contracts
    ADD CONSTRAINT savings_account_contracts_pkey PRIMARY KEY (id);


--
-- Name: savings_account_contracts savings_account_contracts_tenant_id_contract_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_contracts
    ADD CONSTRAINT savings_account_contracts_tenant_id_contract_reference_key UNIQUE (tenant_id, contract_reference);


--
-- Name: savings_account_contracts savings_account_contracts_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_contracts
    ADD CONSTRAINT savings_account_contracts_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_account_contracts savings_account_contracts_tenant_id_savings_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_contracts
    ADD CONSTRAINT savings_account_contracts_tenant_id_savings_account_id_key UNIQUE (tenant_id, savings_account_id);


--
-- Name: savings_account_holders savings_account_holders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_holders
    ADD CONSTRAINT savings_account_holders_pkey PRIMARY KEY (id);


--
-- Name: savings_account_holders savings_account_holders_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_holders
    ADD CONSTRAINT savings_account_holders_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_account_restrictions savings_account_restrictions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_restrictions
    ADD CONSTRAINT savings_account_restrictions_pkey PRIMARY KEY (id);


--
-- Name: savings_account_restrictions savings_account_restrictions_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_restrictions
    ADD CONSTRAINT savings_account_restrictions_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_account_status_history savings_account_status_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_status_history
    ADD CONSTRAINT savings_account_status_history_pkey PRIMARY KEY (id);


--
-- Name: savings_account_status_history savings_account_status_history_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_status_history
    ADD CONSTRAINT savings_account_status_history_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_pkey PRIMARY KEY (id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_ledger_entry_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_ledger_entry_id_key UNIQUE (tenant_id, ledger_entry_id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_operation_id_savings_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_operation_id_savings_key UNIQUE (tenant_id, operation_id, savings_account_id, leg_code);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_savings_account_id_l_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_savings_account_id_l_key UNIQUE (tenant_id, savings_account_id, ledger_sequence);


--
-- Name: savings_accounts savings_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_accounts
    ADD CONSTRAINT savings_accounts_pkey PRIMARY KEY (id);


--
-- Name: savings_accounts savings_accounts_tenant_id_id_currency_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_accounts
    ADD CONSTRAINT savings_accounts_tenant_id_id_currency_key UNIQUE (tenant_id, id, currency);


--
-- Name: savings_accounts savings_accounts_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_accounts
    ADD CONSTRAINT savings_accounts_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_accounts savings_accounts_tenant_id_ledger_book_id_ledger_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_accounts
    ADD CONSTRAINT savings_accounts_tenant_id_ledger_book_id_ledger_account_id_key UNIQUE (tenant_id, ledger_book_id, ledger_account_id);


--
-- Name: savings_adjustments savings_adjustments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_adjustments
    ADD CONSTRAINT savings_adjustments_pkey PRIMARY KEY (id);


--
-- Name: savings_adjustments savings_adjustments_tenant_id_adjustment_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_adjustments
    ADD CONSTRAINT savings_adjustments_tenant_id_adjustment_reference_key UNIQUE (tenant_id, adjustment_reference);


--
-- Name: savings_adjustments savings_adjustments_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_adjustments
    ADD CONSTRAINT savings_adjustments_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_adjustments savings_adjustments_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_adjustments
    ADD CONSTRAINT savings_adjustments_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: savings_audit_logs savings_audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_audit_logs
    ADD CONSTRAINT savings_audit_logs_pkey PRIMARY KEY (id);


--
-- Name: savings_audit_logs savings_audit_logs_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_audit_logs
    ADD CONSTRAINT savings_audit_logs_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_balance_holds savings_balance_holds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_balance_holds
    ADD CONSTRAINT savings_balance_holds_pkey PRIMARY KEY (id);


--
-- Name: savings_balance_holds savings_balance_holds_tenant_id_hold_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_balance_holds
    ADD CONSTRAINT savings_balance_holds_tenant_id_hold_reference_key UNIQUE (tenant_id, hold_reference);


--
-- Name: savings_balance_holds savings_balance_holds_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_balance_holds
    ADD CONSTRAINT savings_balance_holds_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_balance_holds savings_balance_holds_tenant_id_operation_id_savings_accoun_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_balance_holds
    ADD CONSTRAINT savings_balance_holds_tenant_id_operation_id_savings_accoun_key UNIQUE (tenant_id, operation_id, savings_account_id, hold_type);


--
-- Name: savings_deposits savings_deposits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_deposits
    ADD CONSTRAINT savings_deposits_pkey PRIMARY KEY (id);


--
-- Name: savings_deposits savings_deposits_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_deposits
    ADD CONSTRAINT savings_deposits_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_deposits savings_deposits_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_deposits
    ADD CONSTRAINT savings_deposits_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: fixed_deposit_rates savings_fd_rate_nonoverlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_rates
    ADD CONSTRAINT savings_fd_rate_nonoverlap EXCLUDE USING gist (tenant_id WITH =, product_version_id WITH =, tenure_days WITH =, numrange((minimum_amount)::numeric, (maximum_amount)::numeric, '[)'::text) WITH &&, tstzrange(effective_from, effective_to, '[)'::text) WITH &&);


--
-- Name: savings_goal_contributions savings_goal_contributions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_contributions
    ADD CONSTRAINT savings_goal_contributions_pkey PRIMARY KEY (id);


--
-- Name: savings_goal_contributions savings_goal_contributions_tenant_id_contribution_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_contributions
    ADD CONSTRAINT savings_goal_contributions_tenant_id_contribution_reference_key UNIQUE (tenant_id, contribution_reference);


--
-- Name: savings_goal_contributions savings_goal_contributions_tenant_id_deposit_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_contributions
    ADD CONSTRAINT savings_goal_contributions_tenant_id_deposit_id_key UNIQUE (tenant_id, deposit_id);


--
-- Name: savings_goal_contributions savings_goal_contributions_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_contributions
    ADD CONSTRAINT savings_goal_contributions_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_goal_milestones savings_goal_milestones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_milestones
    ADD CONSTRAINT savings_goal_milestones_pkey PRIMARY KEY (id);


--
-- Name: savings_goal_milestones savings_goal_milestones_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_milestones
    ADD CONSTRAINT savings_goal_milestones_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_goal_withdrawals savings_goal_withdrawals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_withdrawals
    ADD CONSTRAINT savings_goal_withdrawals_pkey PRIMARY KEY (id);


--
-- Name: savings_goal_withdrawals savings_goal_withdrawals_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_withdrawals
    ADD CONSTRAINT savings_goal_withdrawals_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_goal_withdrawals savings_goal_withdrawals_tenant_id_withdrawal_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_withdrawals
    ADD CONSTRAINT savings_goal_withdrawals_tenant_id_withdrawal_id_key UNIQUE (tenant_id, withdrawal_id);


--
-- Name: savings_goal_withdrawals savings_goal_withdrawals_tenant_id_withdrawal_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_withdrawals
    ADD CONSTRAINT savings_goal_withdrawals_tenant_id_withdrawal_reference_key UNIQUE (tenant_id, withdrawal_reference);


--
-- Name: savings_goals savings_goals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goals
    ADD CONSTRAINT savings_goals_pkey PRIMARY KEY (id);


--
-- Name: savings_goals savings_goals_tenant_id_id_currency_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goals
    ADD CONSTRAINT savings_goals_tenant_id_id_currency_key UNIQUE (tenant_id, id, currency);


--
-- Name: savings_goals savings_goals_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goals
    ADD CONSTRAINT savings_goals_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_goals savings_goals_tenant_id_id_savings_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goals
    ADD CONSTRAINT savings_goals_tenant_id_id_savings_account_id_key UNIQUE (tenant_id, id, savings_account_id);


--
-- Name: savings_goals savings_goals_tenant_id_savings_account_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goals
    ADD CONSTRAINT savings_goals_tenant_id_savings_account_id_key UNIQUE (tenant_id, savings_account_id);


--
-- Name: savings_idempotency_keys savings_idempotency_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_idempotency_keys
    ADD CONSTRAINT savings_idempotency_keys_pkey PRIMARY KEY (id);


--
-- Name: savings_idempotency_keys savings_idempotency_keys_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_idempotency_keys
    ADD CONSTRAINT savings_idempotency_keys_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_inbox_events savings_inbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_inbox_events
    ADD CONSTRAINT savings_inbox_events_pkey PRIMARY KEY (id);


--
-- Name: savings_inbox_events savings_inbox_events_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_inbox_events
    ADD CONSTRAINT savings_inbox_events_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_inbox_events savings_inbox_events_tenant_id_source_service_event_id_cons_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_inbox_events
    ADD CONSTRAINT savings_inbox_events_tenant_id_source_service_event_id_cons_key UNIQUE (tenant_id, source_service, event_id, consumer_name);


--
-- Name: savings_interest_accrual_batches savings_interest_accrual_batc_tenant_id_accrual_date_curren_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_batches
    ADD CONSTRAINT savings_interest_accrual_batc_tenant_id_accrual_date_curren_key UNIQUE (tenant_id, accrual_date, currency);


--
-- Name: savings_interest_accrual_batches savings_interest_accrual_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_batches
    ADD CONSTRAINT savings_interest_accrual_batches_pkey PRIMARY KEY (id);


--
-- Name: savings_interest_accrual_batches savings_interest_accrual_batches_tenant_id_batch_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_batches
    ADD CONSTRAINT savings_interest_accrual_batches_tenant_id_batch_reference_key UNIQUE (tenant_id, batch_reference);


--
-- Name: savings_interest_accrual_batches savings_interest_accrual_batches_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_batches
    ADD CONSTRAINT savings_interest_accrual_batches_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_interest_accrual_corrections savings_interest_accrual_corr_tenant_id_correction_referenc_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_corrections
    ADD CONSTRAINT savings_interest_accrual_corr_tenant_id_correction_referenc_key UNIQUE (tenant_id, correction_reference);


--
-- Name: savings_interest_accrual_corrections savings_interest_accrual_corrections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_corrections
    ADD CONSTRAINT savings_interest_accrual_corrections_pkey PRIMARY KEY (id);


--
-- Name: savings_interest_accrual_corrections savings_interest_accrual_corrections_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_corrections
    ADD CONSTRAINT savings_interest_accrual_corrections_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_interest_accruals savings_interest_accruals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT savings_interest_accruals_pkey PRIMARY KEY (id);


--
-- Name: savings_interest_accruals savings_interest_accruals_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT savings_interest_accruals_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_interest_payment_accruals savings_interest_payment_accr_tenant_id_interest_accrual_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payment_accruals
    ADD CONSTRAINT savings_interest_payment_accr_tenant_id_interest_accrual_id_key UNIQUE (tenant_id, interest_accrual_id);


--
-- Name: savings_interest_payment_accruals savings_interest_payment_accruals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payment_accruals
    ADD CONSTRAINT savings_interest_payment_accruals_pkey PRIMARY KEY (id);


--
-- Name: savings_interest_payment_accruals savings_interest_payment_accruals_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payment_accruals
    ADD CONSTRAINT savings_interest_payment_accruals_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_interest_payment_batches savings_interest_payment_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payment_batches
    ADD CONSTRAINT savings_interest_payment_batches_pkey PRIMARY KEY (id);


--
-- Name: savings_interest_payment_batches savings_interest_payment_batches_tenant_id_batch_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payment_batches
    ADD CONSTRAINT savings_interest_payment_batches_tenant_id_batch_reference_key UNIQUE (tenant_id, batch_reference);


--
-- Name: savings_interest_payment_batches savings_interest_payment_batches_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payment_batches
    ADD CONSTRAINT savings_interest_payment_batches_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_interest_payments savings_interest_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT savings_interest_payments_pkey PRIMARY KEY (id);


--
-- Name: savings_interest_payments savings_interest_payments_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT savings_interest_payments_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_interest_payments savings_interest_payments_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT savings_interest_payments_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: savings_interest_payments savings_interest_payments_tenant_id_savings_account_id_paym_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT savings_interest_payments_tenant_id_savings_account_id_paym_key UNIQUE (tenant_id, savings_account_id, payment_period_start, payment_period_end);


--
-- Name: savings_outbox_events savings_outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_outbox_events
    ADD CONSTRAINT savings_outbox_events_pkey PRIMARY KEY (id);


--
-- Name: savings_outbox_events savings_outbox_events_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_outbox_events
    ADD CONSTRAINT savings_outbox_events_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_processing_attempts savings_processing_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_processing_attempts
    ADD CONSTRAINT savings_processing_attempts_pkey PRIMARY KEY (id);


--
-- Name: savings_processing_attempts savings_processing_attempts_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_processing_attempts
    ADD CONSTRAINT savings_processing_attempts_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_processing_attempts savings_processing_attempts_tenant_id_operation_id_target_s_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_processing_attempts
    ADD CONSTRAINT savings_processing_attempts_tenant_id_operation_id_target_s_key UNIQUE (tenant_id, operation_id, target_service, attempt_number);


--
-- Name: savings_product_fees savings_product_fees_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_fees
    ADD CONSTRAINT savings_product_fees_pkey PRIMARY KEY (id);


--
-- Name: savings_product_fees savings_product_fees_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_fees
    ADD CONSTRAINT savings_product_fees_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_product_rates savings_product_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rates
    ADD CONSTRAINT savings_product_rates_pkey PRIMARY KEY (id);


--
-- Name: savings_product_rates savings_product_rates_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rates
    ADD CONSTRAINT savings_product_rates_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_product_rates savings_product_rates_tenant_id_id_product_version_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rates
    ADD CONSTRAINT savings_product_rates_tenant_id_id_product_version_id_key UNIQUE (tenant_id, id, product_version_id);


--
-- Name: savings_product_rules savings_product_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rules
    ADD CONSTRAINT savings_product_rules_pkey PRIMARY KEY (id);


--
-- Name: savings_product_rules savings_product_rules_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rules
    ADD CONSTRAINT savings_product_rules_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_product_tiers savings_product_tiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_tiers
    ADD CONSTRAINT savings_product_tiers_pkey PRIMARY KEY (id);


--
-- Name: savings_product_tiers savings_product_tiers_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_tiers
    ADD CONSTRAINT savings_product_tiers_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_product_versions savings_product_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_versions
    ADD CONSTRAINT savings_product_versions_pkey PRIMARY KEY (id);


--
-- Name: savings_product_versions savings_product_versions_tenant_id_id_currency_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_versions
    ADD CONSTRAINT savings_product_versions_tenant_id_id_currency_key UNIQUE (tenant_id, id, currency);


--
-- Name: savings_product_versions savings_product_versions_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_versions
    ADD CONSTRAINT savings_product_versions_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_product_versions savings_product_versions_tenant_id_id_savings_product_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_versions
    ADD CONSTRAINT savings_product_versions_tenant_id_id_savings_product_id_key UNIQUE (tenant_id, id, savings_product_id);


--
-- Name: savings_product_versions savings_product_versions_tenant_id_savings_product_id_versi_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_versions
    ADD CONSTRAINT savings_product_versions_tenant_id_savings_product_id_versi_key UNIQUE (tenant_id, savings_product_id, version_number);


--
-- Name: savings_products savings_products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_products
    ADD CONSTRAINT savings_products_pkey PRIMARY KEY (id);


--
-- Name: savings_products savings_products_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_products
    ADD CONSTRAINT savings_products_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_product_rates savings_rate_nonoverlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rates
    ADD CONSTRAINT savings_rate_nonoverlap EXCLUDE USING gist (tenant_id WITH =, product_version_id WITH =, numrange(COALESCE((minimum_balance)::numeric, (0)::numeric), (maximum_balance)::numeric, '[)'::text) WITH &&, tstzrange(effective_from, effective_to, '[)'::text) WITH &&);


--
-- Name: savings_reconciliation_items savings_reconciliation_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_items
    ADD CONSTRAINT savings_reconciliation_items_pkey PRIMARY KEY (id);


--
-- Name: savings_reconciliation_items savings_reconciliation_items_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_items
    ADD CONSTRAINT savings_reconciliation_items_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_reconciliation_items savings_reconciliation_items_tenant_id_reconciliation_run_i_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_items
    ADD CONSTRAINT savings_reconciliation_items_tenant_id_reconciliation_run_i_key UNIQUE (tenant_id, reconciliation_run_id, resource_type, resource_id, discrepancy_type);


--
-- Name: savings_reconciliation_runs savings_reconciliation_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_runs
    ADD CONSTRAINT savings_reconciliation_runs_pkey PRIMARY KEY (id);


--
-- Name: savings_reconciliation_runs savings_reconciliation_runs_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_runs
    ADD CONSTRAINT savings_reconciliation_runs_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_reconciliation_runs savings_reconciliation_runs_tenant_id_run_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_runs
    ADD CONSTRAINT savings_reconciliation_runs_tenant_id_run_reference_key UNIQUE (tenant_id, run_reference);


--
-- Name: savings_recurring_executions savings_recurring_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_executions
    ADD CONSTRAINT savings_recurring_executions_pkey PRIMARY KEY (id);


--
-- Name: savings_recurring_executions savings_recurring_executions_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_executions
    ADD CONSTRAINT savings_recurring_executions_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_recurring_executions savings_recurring_executions_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_executions
    ADD CONSTRAINT savings_recurring_executions_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: savings_recurring_executions savings_recurring_executions_tenant_id_recurring_plan_id_sc_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_executions
    ADD CONSTRAINT savings_recurring_executions_tenant_id_recurring_plan_id_sc_key UNIQUE (tenant_id, recurring_plan_id, scheduled_date);


--
-- Name: savings_recurring_plans savings_recurring_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_plans
    ADD CONSTRAINT savings_recurring_plans_pkey PRIMARY KEY (id);


--
-- Name: savings_recurring_plans savings_recurring_plans_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_plans
    ADD CONSTRAINT savings_recurring_plans_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_product_tiers savings_tier_nonoverlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_tiers
    ADD CONSTRAINT savings_tier_nonoverlap EXCLUDE USING gist (tenant_id WITH =, product_version_id WITH =, numrange(COALESCE((minimum_balance)::numeric, (0)::numeric), (maximum_balance)::numeric, '[)'::text) WITH &&, tstzrange(effective_from, effective_to, '[)'::text) WITH &&) WHERE (is_active);


--
-- Name: savings_transfer_requests savings_transfer_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_transfer_requests
    ADD CONSTRAINT savings_transfer_requests_pkey PRIMARY KEY (id);


--
-- Name: savings_transfer_requests savings_transfer_requests_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_transfer_requests
    ADD CONSTRAINT savings_transfer_requests_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_transfer_requests savings_transfer_requests_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_transfer_requests
    ADD CONSTRAINT savings_transfer_requests_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: savings_withdrawals savings_withdrawals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_withdrawals
    ADD CONSTRAINT savings_withdrawals_pkey PRIMARY KEY (id);


--
-- Name: savings_withdrawals savings_withdrawals_tenant_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_withdrawals
    ADD CONSTRAINT savings_withdrawals_tenant_id_id_key UNIQUE (tenant_id, id);


--
-- Name: savings_withdrawals savings_withdrawals_tenant_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_withdrawals
    ADD CONSTRAINT savings_withdrawals_tenant_id_idempotency_key_key UNIQUE (tenant_id, idempotency_key);


--
-- Name: fixed_deposit_interest_payments uq_fixed_deposit_interest_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT uq_fixed_deposit_interest_reference UNIQUE (tenant_id, payment_reference);


--
-- Name: fixed_deposits uq_fixed_deposit_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT uq_fixed_deposit_reference UNIQUE (tenant_id, deposit_reference);


--
-- Name: savings_interest_payments uq_interest_payment_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT uq_interest_payment_reference UNIQUE (tenant_id, payment_reference);


--
-- Name: savings_recurring_executions uq_recurring_execution; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_executions
    ADD CONSTRAINT uq_recurring_execution UNIQUE (tenant_id, recurring_plan_id, execution_number);


--
-- Name: savings_recurring_plans uq_recurring_plan_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_plans
    ADD CONSTRAINT uq_recurring_plan_reference UNIQUE (tenant_id, plan_reference);


--
-- Name: savings_account_holders uq_savings_account_customer_role; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_holders
    ADD CONSTRAINT uq_savings_account_customer_role UNIQUE (savings_account_id, customer_id, role);


--
-- Name: savings_accounts uq_savings_account_number; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_accounts
    ADD CONSTRAINT uq_savings_account_number UNIQUE (tenant_id, account_number);


--
-- Name: savings_account_transactions uq_savings_account_transaction_idempotency; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT uq_savings_account_transaction_idempotency UNIQUE (tenant_id, savings_account_id, idempotency_key);


--
-- Name: savings_account_transactions uq_savings_account_transaction_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT uq_savings_account_transaction_reference UNIQUE (tenant_id, transaction_reference);


--
-- Name: savings_deposits uq_savings_deposit_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_deposits
    ADD CONSTRAINT uq_savings_deposit_reference UNIQUE (tenant_id, deposit_reference);


--
-- Name: savings_goals uq_savings_goal_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goals
    ADD CONSTRAINT uq_savings_goal_reference UNIQUE (tenant_id, goal_reference);


--
-- Name: savings_idempotency_keys uq_savings_idempotency; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_idempotency_keys
    ADD CONSTRAINT uq_savings_idempotency UNIQUE (tenant_id, idempotency_key);


--
-- Name: savings_interest_accruals uq_savings_interest_accrual; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT uq_savings_interest_accrual UNIQUE (tenant_id, savings_account_id, accrual_date);


--
-- Name: savings_products uq_savings_product_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_products
    ADD CONSTRAINT uq_savings_product_code UNIQUE (tenant_id, product_code);


--
-- Name: savings_product_fees uq_savings_product_fee; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_fees
    ADD CONSTRAINT uq_savings_product_fee UNIQUE (product_version_id, fee_code);


--
-- Name: savings_product_rules uq_savings_product_rule; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rules
    ADD CONSTRAINT uq_savings_product_rule UNIQUE (product_version_id, rule_code);


--
-- Name: savings_product_tiers uq_savings_product_tier; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_tiers
    ADD CONSTRAINT uq_savings_product_tier UNIQUE (product_version_id, tier_code);


--
-- Name: savings_transfer_requests uq_savings_transfer_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_transfer_requests
    ADD CONSTRAINT uq_savings_transfer_reference UNIQUE (tenant_id, transfer_reference);


--
-- Name: savings_withdrawals uq_savings_withdrawal_reference; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_withdrawals
    ADD CONSTRAINT uq_savings_withdrawal_reference UNIQUE (tenant_id, withdrawal_reference);


--
-- Name: fixed_deposit_rates_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fixed_deposit_rates_version_idx ON public.fixed_deposit_rates USING btree (tenant_id, product_version_id);


--
-- Name: idx_fixed_deposit_due_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposit_due_active ON public.fixed_deposits USING btree (tenant_id, maturity_date, id) WHERE (status = 'ACTIVE'::public.fixed_deposit_status_enum);


--
-- Name: idx_fixed_deposit_interest_payments; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposit_interest_payments ON public.fixed_deposit_interest_payments USING btree (fixed_deposit_id, payment_date);


--
-- Name: idx_fixed_deposit_quote_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposit_quote_expiry ON public.fixed_deposit_quotes USING btree (tenant_id, expires_at) WHERE (consumed_at IS NULL);


--
-- Name: idx_fixed_deposit_rates_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposit_rates_product ON public.fixed_deposit_rates USING btree (savings_product_id, tenure_days);


--
-- Name: idx_fixed_deposit_renewals_deposit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposit_renewals_deposit ON public.fixed_deposit_renewals USING btree (fixed_deposit_id, created_at DESC);


--
-- Name: idx_fixed_deposits_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposits_account ON public.fixed_deposits USING btree (savings_account_id);


--
-- Name: idx_fixed_deposits_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposits_customer ON public.fixed_deposits USING btree (tenant_id, customer_id);


--
-- Name: idx_fixed_deposits_maturity; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposits_maturity ON public.fixed_deposits USING btree (tenant_id, maturity_date);


--
-- Name: idx_fixed_deposits_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fixed_deposits_status ON public.fixed_deposits USING btree (tenant_id, status);


--
-- Name: idx_goal_contributions_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_goal_contributions_customer ON public.savings_goal_contributions USING btree (tenant_id, customer_id);


--
-- Name: idx_goal_contributions_goal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_goal_contributions_goal ON public.savings_goal_contributions USING btree (goal_id, created_at DESC);


--
-- Name: idx_goal_contributions_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_goal_contributions_ledger ON public.savings_goal_contributions USING btree (ledger_transaction_id);


--
-- Name: idx_goal_milestones_goal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_goal_milestones_goal ON public.savings_goal_milestones USING btree (goal_id);


--
-- Name: idx_goal_withdrawals_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_goal_withdrawals_customer ON public.savings_goal_withdrawals USING btree (tenant_id, customer_id);


--
-- Name: idx_goal_withdrawals_goal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_goal_withdrawals_goal ON public.savings_goal_withdrawals USING btree (goal_id, created_at DESC);


--
-- Name: idx_interest_accruals_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interest_accruals_account ON public.savings_interest_accruals USING btree (savings_account_id, accrual_date DESC);


--
-- Name: idx_interest_accruals_unposted; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interest_accruals_unposted ON public.savings_interest_accruals USING btree (tenant_id, accrual_date) WHERE (posted = false);


--
-- Name: idx_interest_payments_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interest_payments_account ON public.savings_interest_payments USING btree (savings_account_id, created_at DESC);


--
-- Name: idx_interest_payments_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interest_payments_customer ON public.savings_interest_payments USING btree (tenant_id, customer_id);


--
-- Name: idx_interest_payments_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_interest_payments_status ON public.savings_interest_payments USING btree (tenant_id, status);


--
-- Name: idx_recurring_execution_retry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_execution_retry ON public.savings_recurring_executions USING btree (tenant_id, next_retry_at, id) WHERE (status = ANY (ARRAY['PENDING'::public.savings_transaction_status_enum, 'FAILED'::public.savings_transaction_status_enum]));


--
-- Name: idx_recurring_executions_plan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_executions_plan ON public.savings_recurring_executions USING btree (recurring_plan_id, execution_number);


--
-- Name: idx_recurring_executions_scheduled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_executions_scheduled ON public.savings_recurring_executions USING btree (scheduled_date, status);


--
-- Name: idx_recurring_executions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_executions_status ON public.savings_recurring_executions USING btree (tenant_id, status);


--
-- Name: idx_recurring_plan_claim; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_plan_claim ON public.savings_recurring_plans USING btree (tenant_id, next_execution_date, id) WHERE ((status = 'ACTIVE'::text) AND is_active);


--
-- Name: idx_recurring_plans_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_plans_account ON public.savings_recurring_plans USING btree (savings_account_id);


--
-- Name: idx_recurring_plans_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_plans_customer ON public.savings_recurring_plans USING btree (tenant_id, customer_id);


--
-- Name: idx_recurring_plans_next_execution; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_plans_next_execution ON public.savings_recurring_plans USING btree (next_execution_date) WHERE (is_active = true);


--
-- Name: idx_savings_account_holders_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_holders_customer ON public.savings_account_holders USING btree (tenant_id, customer_id);


--
-- Name: idx_savings_account_status_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_status_history ON public.savings_account_status_history USING btree (savings_account_id, created_at DESC);


--
-- Name: idx_savings_account_transactions_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_account ON public.savings_account_transactions USING btree (tenant_id, savings_account_id, transaction_at DESC);


--
-- Name: idx_savings_account_transactions_correlation; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_correlation ON public.savings_account_transactions USING btree (correlation_id) WHERE (correlation_id IS NOT NULL);


--
-- Name: idx_savings_account_transactions_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_customer ON public.savings_account_transactions USING btree (tenant_id, customer_id, transaction_at DESC);


--
-- Name: idx_savings_account_transactions_deposit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_deposit ON public.savings_account_transactions USING btree (deposit_id) WHERE (deposit_id IS NOT NULL);


--
-- Name: idx_savings_account_transactions_fixed_deposit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_fixed_deposit ON public.savings_account_transactions USING btree (fixed_deposit_id, transaction_at DESC) WHERE (fixed_deposit_id IS NOT NULL);


--
-- Name: idx_savings_account_transactions_goal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_goal ON public.savings_account_transactions USING btree (goal_id, transaction_at DESC) WHERE (goal_id IS NOT NULL);


--
-- Name: idx_savings_account_transactions_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_ledger ON public.savings_account_transactions USING btree (ledger_transaction_id) WHERE (ledger_transaction_id IS NOT NULL);


--
-- Name: idx_savings_account_transactions_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_payment ON public.savings_account_transactions USING btree (payment_transaction_id) WHERE (payment_transaction_id IS NOT NULL);


--
-- Name: idx_savings_account_transactions_recent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_recent ON public.savings_account_transactions USING btree (tenant_id, transaction_at DESC);


--
-- Name: idx_savings_account_transactions_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_status ON public.savings_account_transactions USING btree (tenant_id, status, transaction_at DESC);


--
-- Name: idx_savings_account_transactions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_type ON public.savings_account_transactions USING btree (tenant_id, transaction_type, transaction_at DESC);


--
-- Name: idx_savings_account_transactions_withdrawal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_account_transactions_withdrawal ON public.savings_account_transactions USING btree (withdrawal_id) WHERE (withdrawal_id IS NOT NULL);


--
-- Name: idx_savings_accounts_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_accounts_customer ON public.savings_accounts USING btree (tenant_id, customer_id);


--
-- Name: idx_savings_accounts_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_accounts_number ON public.savings_accounts USING btree (account_number);


--
-- Name: idx_savings_accounts_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_accounts_product ON public.savings_accounts USING btree (tenant_id, savings_product_id);


--
-- Name: idx_savings_accounts_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_accounts_status ON public.savings_accounts USING btree (tenant_id, status);


--
-- Name: idx_savings_adjustments_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_adjustments_account ON public.savings_adjustments USING btree (savings_account_id, created_at DESC);


--
-- Name: idx_savings_adjustments_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_adjustments_customer ON public.savings_adjustments USING btree (tenant_id, customer_id);


--
-- Name: idx_savings_deposits_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_deposits_account ON public.savings_deposits USING btree (tenant_id, savings_account_id, created_at DESC);


--
-- Name: idx_savings_deposits_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_deposits_customer ON public.savings_deposits USING btree (tenant_id, customer_id);


--
-- Name: idx_savings_deposits_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_deposits_ledger ON public.savings_deposits USING btree (ledger_transaction_id);


--
-- Name: idx_savings_deposits_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_deposits_status ON public.savings_deposits USING btree (tenant_id, status);


--
-- Name: idx_savings_goals_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_goals_account ON public.savings_goals USING btree (savings_account_id);


--
-- Name: idx_savings_goals_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_goals_customer ON public.savings_goals USING btree (tenant_id, customer_id);


--
-- Name: idx_savings_goals_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_goals_status ON public.savings_goals USING btree (tenant_id, status);


--
-- Name: idx_savings_goals_target_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_goals_target_date ON public.savings_goals USING btree (tenant_id, target_date);


--
-- Name: idx_savings_idempotency_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_idempotency_expiry ON public.savings_idempotency_keys USING btree (expires_at);


--
-- Name: idx_savings_outbox_aggregate; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_outbox_aggregate ON public.savings_outbox_events USING btree (aggregate_type, aggregate_id);


--
-- Name: idx_savings_outbox_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_outbox_pending ON public.savings_outbox_events USING btree (available_at) WHERE ((status)::text = 'PENDING'::text);


--
-- Name: idx_savings_product_fees_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_product_fees_product ON public.savings_product_fees USING btree (savings_product_id);


--
-- Name: idx_savings_product_rates_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_product_rates_product ON public.savings_product_rates USING btree (savings_product_id, effective_from DESC);


--
-- Name: idx_savings_product_rules_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_product_rules_product ON public.savings_product_rules USING btree (savings_product_id);


--
-- Name: idx_savings_product_tiers_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_product_tiers_product ON public.savings_product_tiers USING btree (savings_product_id);


--
-- Name: idx_savings_products_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_products_active ON public.savings_products USING btree (tenant_id, is_active);


--
-- Name: idx_savings_products_tenant; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_products_tenant ON public.savings_products USING btree (tenant_id);


--
-- Name: idx_savings_products_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_products_type ON public.savings_products USING btree (tenant_id, product_type);


--
-- Name: idx_savings_transfers_destination; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_transfers_destination ON public.savings_transfer_requests USING btree (destination_savings_account_id);


--
-- Name: idx_savings_transfers_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_transfers_source ON public.savings_transfer_requests USING btree (source_savings_account_id, created_at DESC);


--
-- Name: idx_savings_transfers_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_transfers_status ON public.savings_transfer_requests USING btree (tenant_id, status);


--
-- Name: idx_savings_version_catalog; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_version_catalog ON public.savings_product_versions USING btree (tenant_id, product_type, status, effective_from);


--
-- Name: idx_savings_withdrawals_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_withdrawals_account ON public.savings_withdrawals USING btree (tenant_id, savings_account_id, created_at DESC);


--
-- Name: idx_savings_withdrawals_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_withdrawals_customer ON public.savings_withdrawals USING btree (tenant_id, customer_id);


--
-- Name: idx_savings_withdrawals_ledger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_withdrawals_ledger ON public.savings_withdrawals USING btree (ledger_transaction_id);


--
-- Name: idx_savings_withdrawals_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_savings_withdrawals_status ON public.savings_withdrawals USING btree (tenant_id, status);


--
-- Name: savings_audit_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_audit_resource ON public.savings_audit_logs USING btree (tenant_id, resource_type, resource_id, created_at DESC);


--
-- Name: savings_holds_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_holds_active ON public.savings_balance_holds USING btree (tenant_id, savings_account_id) WHERE (status = 'ACTIVE'::text);


--
-- Name: savings_holds_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_holds_expiry ON public.savings_balance_holds USING btree (tenant_id, expires_at) WHERE (status = 'ACTIVE'::text);


--
-- Name: savings_inbox_work; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_inbox_work ON public.savings_inbox_events USING btree (tenant_id, available_at) WHERE (status = ANY (ARRAY['PENDING'::text, 'FAILED'::text]));


--
-- Name: savings_one_live_liquidation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX savings_one_live_liquidation ON public.fixed_deposit_liquidations USING btree (tenant_id, fixed_deposit_id) WHERE (status <> ALL (ARRAY['REJECTED'::text, 'CANCELLED'::text]));


--
-- Name: savings_one_prepaid_interest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX savings_one_prepaid_interest ON public.savings_interest_payments USING btree (tenant_id, fixed_deposit_id) WHERE (settlement_basis = 'PREPAID'::text);


--
-- Name: savings_outbox_retry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_outbox_retry ON public.savings_outbox_events USING btree (tenant_id, available_at) WHERE ((status)::text = ANY (ARRAY[('PENDING'::character varying)::text, ('FAILED'::character varying)::text]));


--
-- Name: savings_primary_holder; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX savings_primary_holder ON public.savings_account_holders USING btree (tenant_id, savings_account_id) WHERE ((role = 'PRIMARY'::public.savings_account_holder_role_enum) AND (revoked_at IS NULL));


--
-- Name: savings_product_fees_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_product_fees_version_idx ON public.savings_product_fees USING btree (tenant_id, product_version_id);


--
-- Name: savings_product_rates_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_product_rates_version_idx ON public.savings_product_rates USING btree (tenant_id, product_version_id);


--
-- Name: savings_product_rules_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_product_rules_version_idx ON public.savings_product_rules USING btree (tenant_id, product_version_id);


--
-- Name: savings_product_tiers_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_product_tiers_version_idx ON public.savings_product_tiers USING btree (tenant_id, product_version_id);


--
-- Name: savings_reconciliation_open; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_reconciliation_open ON public.savings_reconciliation_items USING btree (tenant_id, status) WHERE (status = ANY (ARRAY['OPEN'::text, 'INVESTIGATING'::text]));


--
-- Name: savings_restrictions_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX savings_restrictions_active ON public.savings_account_restrictions USING btree (tenant_id, savings_account_id) WHERE (released_at IS NULL);


--
-- Name: uq_fixed_deposit_current_instruction; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_fixed_deposit_current_instruction ON public.fixed_deposit_instructions USING btree (tenant_id, fixed_deposit_id) WHERE (superseded_at IS NULL);


--
-- Name: uq_fixed_deposit_instruction_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_fixed_deposit_instruction_idempotency ON public.fixed_deposit_instructions USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: uq_fixed_deposit_open_liquidation; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_fixed_deposit_open_liquidation ON public.fixed_deposit_liquidations USING btree (tenant_id, fixed_deposit_id) WHERE (status <> ALL (ARRAY['FAILED'::text, 'REJECTED'::text, 'CANCELLED'::text]));


--
-- Name: uq_fixed_deposit_placement_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_fixed_deposit_placement_idempotency ON public.fixed_deposits USING btree (tenant_id, placement_idempotency_key) WHERE (placement_idempotency_key IS NOT NULL);


--
-- Name: uq_interest_accrual_batch_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_interest_accrual_batch_idempotency ON public.savings_interest_accrual_batches USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: uq_interest_payment_batch_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_interest_payment_batch_idempotency ON public.savings_interest_payment_batches USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: uq_recurring_plan_creation_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_recurring_plan_creation_idempotency ON public.savings_recurring_plans USING btree (tenant_id, creation_idempotency_key);


--
-- Name: uq_savings_account_opening_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_account_opening_idempotency ON public.savings_accounts USING btree (tenant_id, opening_idempotency_key) WHERE (opening_idempotency_key IS NOT NULL);


--
-- Name: uq_savings_account_opening_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_account_opening_sequence ON public.savings_accounts USING btree (opening_sequence);


--
-- Name: uq_savings_current_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_current_version ON public.savings_product_versions USING btree (tenant_id, savings_product_id) WHERE is_current;


--
-- Name: uq_savings_goal_creation_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_goal_creation_idempotency ON public.savings_goals USING btree (tenant_id, creation_idempotency_key) WHERE (creation_idempotency_key IS NOT NULL);


--
-- Name: uq_savings_goal_one_break; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_goal_one_break ON public.savings_goal_withdrawals USING btree (tenant_id, goal_id) WHERE ((withdrawal_kind = 'BREAK'::text) AND (status <> ALL (ARRAY['FAILED'::public.savings_transaction_status_enum, 'CANCELLED'::public.savings_transaction_status_enum, 'REVERSED'::public.savings_transaction_status_enum])));


--
-- Name: uq_savings_goal_one_partial; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_goal_one_partial ON public.savings_goal_withdrawals USING btree (tenant_id, goal_id) WHERE ((withdrawal_kind = 'PARTIAL'::text) AND (status <> ALL (ARRAY['FAILED'::public.savings_transaction_status_enum, 'CANCELLED'::public.savings_transaction_status_enum, 'REVERSED'::public.savings_transaction_status_enum])));


--
-- Name: uq_savings_goal_withdrawal_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_goal_withdrawal_idempotency ON public.savings_goal_withdrawals USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: uq_savings_one_customer_product_account; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_one_customer_product_account ON public.savings_accounts USING btree (tenant_id, customer_id, savings_product_id, currency) WHERE ((deleted_at IS NULL) AND (product_type = ANY (ARRAY['ORDINARY'::public.savings_product_type_enum, 'TARGET'::public.savings_product_type_enum])));


--
-- Name: uq_savings_outbox_aggregate_fact; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_outbox_aggregate_fact ON public.savings_outbox_events USING btree (tenant_id, aggregate_type, aggregate_id, event_type, aggregate_version);


--
-- Name: uq_savings_product_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_product_idempotency ON public.savings_products USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: uq_savings_publication_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_publication_idempotency ON public.savings_product_versions USING btree (tenant_id, publication_idempotency_key) WHERE (publication_idempotency_key IS NOT NULL);


--
-- Name: uq_savings_version_idempotency; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_savings_version_idempotency ON public.savings_product_versions USING btree (tenant_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);


--
-- Name: savings_accounts account_setup; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER account_setup AFTER INSERT OR UPDATE ON public.savings_accounts DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.savings_require_account_setup();


--
-- Name: savings_interest_accruals accrual_context; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER accrual_context BEFORE INSERT ON public.savings_interest_accruals FOR EACH ROW EXECUTE FUNCTION public.savings_validate_accrual_context();


--
-- Name: savings_balance_holds apply_hold; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER apply_hold BEFORE INSERT OR DELETE OR UPDATE ON public.savings_balance_holds FOR EACH ROW EXECUTE FUNCTION public.savings_apply_hold();


--
-- Name: savings_balance_holds check_hold_capture; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER check_hold_capture AFTER INSERT OR UPDATE ON public.savings_balance_holds DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.savings_check_capture();


--
-- Name: savings_interest_payments check_interest_total; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER check_interest_total AFTER INSERT OR UPDATE ON public.savings_interest_payments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.savings_check_interest_total();


--
-- Name: fixed_deposit_interest_payments fd_interest_context; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER fd_interest_context BEFORE INSERT OR UPDATE ON public.fixed_deposit_interest_payments FOR EACH ROW EXECUTE FUNCTION public.savings_validate_fd_interest();


--
-- Name: savings_account_holders holder_setup; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER holder_setup AFTER INSERT OR DELETE OR UPDATE ON public.savings_account_holders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.savings_require_account_setup();


--
-- Name: fixed_deposit_renewals immutable_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_row BEFORE DELETE OR UPDATE ON public.fixed_deposit_renewals FOR EACH ROW EXECUTE FUNCTION public.savings_reject_mutation();


--
-- Name: savings_account_contracts immutable_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_row BEFORE DELETE OR UPDATE ON public.savings_account_contracts FOR EACH ROW EXECUTE FUNCTION public.savings_reject_mutation();


--
-- Name: savings_account_status_history immutable_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_row BEFORE DELETE OR UPDATE ON public.savings_account_status_history FOR EACH ROW EXECUTE FUNCTION public.savings_reject_mutation();


--
-- Name: savings_account_transactions immutable_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_row BEFORE DELETE OR UPDATE ON public.savings_account_transactions FOR EACH ROW EXECUTE FUNCTION public.savings_reject_mutation();


--
-- Name: savings_audit_logs immutable_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_row BEFORE DELETE OR UPDATE ON public.savings_audit_logs FOR EACH ROW EXECUTE FUNCTION public.savings_reject_mutation();


--
-- Name: savings_interest_accrual_corrections immutable_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_row BEFORE DELETE OR UPDATE ON public.savings_interest_accrual_corrections FOR EACH ROW EXECUTE FUNCTION public.savings_reject_mutation();


--
-- Name: savings_interest_payment_accruals immutable_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_row BEFORE DELETE OR UPDATE ON public.savings_interest_payment_accruals FOR EACH ROW EXECUTE FUNCTION public.savings_reject_mutation();


--
-- Name: savings_processing_attempts immutable_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_row BEFORE DELETE OR UPDATE ON public.savings_processing_attempts FOR EACH ROW EXECUTE FUNCTION public.savings_reject_mutation();


--
-- Name: fixed_deposit_liquidations liquidation_claim; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER liquidation_claim BEFORE INSERT OR UPDATE ON public.fixed_deposit_liquidations FOR EACH ROW EXECUTE FUNCTION public.savings_validate_maturity_claim();


--
-- Name: fixed_deposit_maturities maturity_claim; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER maturity_claim BEFORE INSERT OR UPDATE ON public.fixed_deposit_maturities FOR EACH ROW EXECUTE FUNCTION public.savings_validate_maturity_claim();


--
-- Name: savings_account_transactions project_journal; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER project_journal AFTER INSERT ON public.savings_account_transactions FOR EACH ROW EXECUTE FUNCTION public.savings_project_journal();


--
-- Name: savings_interest_accruals protect_accrual; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_accrual BEFORE DELETE OR UPDATE ON public.savings_interest_accruals FOR EACH ROW EXECUTE FUNCTION public.savings_protect_accrual();


--
-- Name: fixed_deposit_interest_payments protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.fixed_deposit_interest_payments FOR EACH ROW EXECUTE FUNCTION public.savings_protect_success();


--
-- Name: fixed_deposit_liquidations protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.fixed_deposit_liquidations FOR EACH ROW EXECUTE FUNCTION public.savings_protect_success();


--
-- Name: fixed_deposit_maturities protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.fixed_deposit_maturities FOR EACH ROW EXECUTE FUNCTION public.savings_protect_success();


--
-- Name: savings_adjustments protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.savings_adjustments FOR EACH ROW EXECUTE FUNCTION public.savings_protect_success();


--
-- Name: savings_deposits protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.savings_deposits FOR EACH ROW EXECUTE FUNCTION public.savings_protect_deposit();


--
-- Name: savings_goal_contributions protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.savings_goal_contributions FOR EACH ROW EXECUTE FUNCTION public.savings_protect_goal_final();


--
-- Name: savings_goal_withdrawals protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.savings_goal_withdrawals FOR EACH ROW EXECUTE FUNCTION public.savings_protect_goal_final();


--
-- Name: savings_interest_payments protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.savings_interest_payments FOR EACH ROW EXECUTE FUNCTION public.savings_protect_success();


--
-- Name: savings_recurring_executions protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.savings_recurring_executions FOR EACH ROW EXECUTE FUNCTION public.savings_protect_success();


--
-- Name: savings_transfer_requests protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.savings_transfer_requests FOR EACH ROW EXECUTE FUNCTION public.savings_protect_success();


--
-- Name: savings_withdrawals protect_final; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON public.savings_withdrawals FOR EACH ROW EXECUTE FUNCTION public.savings_protect_withdrawal();


--
-- Name: fixed_deposits protect_fixed_deposit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_fixed_deposit BEFORE DELETE OR UPDATE ON public.fixed_deposits FOR EACH ROW EXECUTE FUNCTION public.savings_protect_fixed_deposit();


--
-- Name: savings_goals protect_goal; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_goal BEFORE DELETE OR UPDATE ON public.savings_goals FOR EACH ROW EXECUTE FUNCTION public.savings_protect_goal();


--
-- Name: fixed_deposit_instructions protect_instruction; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_instruction BEFORE DELETE OR UPDATE ON public.fixed_deposit_instructions FOR EACH ROW EXECUTE FUNCTION public.savings_protect_fd_instruction();


--
-- Name: savings_product_versions protect_version; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_version BEFORE DELETE OR UPDATE ON public.savings_product_versions FOR EACH ROW EXECUTE FUNCTION public.savings_protect_version();


--
-- Name: fixed_deposit_rates protect_version_child; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_version_child BEFORE INSERT OR DELETE OR UPDATE ON public.fixed_deposit_rates FOR EACH ROW EXECUTE FUNCTION public.savings_protect_version_child();


--
-- Name: savings_product_fees protect_version_child; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_version_child BEFORE INSERT OR DELETE OR UPDATE ON public.savings_product_fees FOR EACH ROW EXECUTE FUNCTION public.savings_protect_version_child();


--
-- Name: savings_product_rates protect_version_child; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_version_child BEFORE INSERT OR DELETE OR UPDATE ON public.savings_product_rates FOR EACH ROW EXECUTE FUNCTION public.savings_protect_version_child();


--
-- Name: savings_product_rules protect_version_child; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_version_child BEFORE INSERT OR DELETE OR UPDATE ON public.savings_product_rules FOR EACH ROW EXECUTE FUNCTION public.savings_protect_version_child();


--
-- Name: savings_product_tiers protect_version_child; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_version_child BEFORE INSERT OR DELETE OR UPDATE ON public.savings_product_tiers FOR EACH ROW EXECUTE FUNCTION public.savings_protect_version_child();


--
-- Name: fixed_deposit_renewals renewal_context; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER renewal_context BEFORE INSERT ON public.fixed_deposit_renewals FOR EACH ROW EXECUTE FUNCTION public.savings_validate_renewal();


--
-- Name: savings_idempotency_keys savings_idempotency_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER savings_idempotency_updated BEFORE UPDATE ON public.savings_idempotency_keys FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_product_versions savings_version_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER savings_version_updated BEFORE UPDATE ON public.savings_product_versions FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: fixed_deposits trg_fixed_deposits_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_fixed_deposits_updated_at BEFORE UPDATE ON public.fixed_deposits FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_account_transactions trg_savings_account_transactions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_savings_account_transactions_updated_at BEFORE UPDATE ON public.savings_account_transactions FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_accounts trg_savings_accounts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_savings_accounts_updated_at BEFORE UPDATE ON public.savings_accounts FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_goals trg_savings_goals_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_savings_goals_updated_at BEFORE UPDATE ON public.savings_goals FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_product_fees trg_savings_product_fees_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_savings_product_fees_updated_at BEFORE UPDATE ON public.savings_product_fees FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_product_rules trg_savings_product_rules_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_savings_product_rules_updated_at BEFORE UPDATE ON public.savings_product_rules FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_product_tiers trg_savings_product_tiers_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_savings_product_tiers_updated_at BEFORE UPDATE ON public.savings_product_tiers FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_products trg_savings_products_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_savings_products_updated_at BEFORE UPDATE ON public.savings_products FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_recurring_plans trg_savings_recurring_plans_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_savings_recurring_plans_updated_at BEFORE UPDATE ON public.savings_recurring_plans FOR EACH ROW EXECUTE FUNCTION public.set_savings_updated_at();


--
-- Name: savings_accounts validate_account; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_account BEFORE INSERT OR UPDATE ON public.savings_accounts FOR EACH ROW EXECUTE FUNCTION public.savings_validate_account();


--
-- Name: savings_interest_payment_accruals validate_allocation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_allocation BEFORE INSERT ON public.savings_interest_payment_accruals FOR EACH ROW EXECUTE FUNCTION public.savings_validate_allocation();


--
-- Name: savings_account_contracts validate_contract; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_contract BEFORE INSERT ON public.savings_account_contracts FOR EACH ROW EXECUTE FUNCTION public.savings_validate_holder_contract();


--
-- Name: fixed_deposits validate_fixed_deposit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_fixed_deposit BEFORE INSERT OR DELETE OR UPDATE ON public.fixed_deposits FOR EACH ROW EXECUTE FUNCTION public.savings_validate_fixed_deposit();


--
-- Name: savings_goal_contributions validate_goal_contribution; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_goal_contribution BEFORE INSERT OR UPDATE ON public.savings_goal_contributions FOR EACH ROW EXECUTE FUNCTION public.savings_validate_goal_classification();


--
-- Name: savings_goal_withdrawals validate_goal_withdrawal; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_goal_withdrawal BEFORE INSERT OR UPDATE ON public.savings_goal_withdrawals FOR EACH ROW EXECUTE FUNCTION public.savings_validate_goal_classification();


--
-- Name: savings_account_holders validate_holder; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_holder BEFORE INSERT OR UPDATE ON public.savings_account_holders FOR EACH ROW EXECUTE FUNCTION public.savings_validate_holder_contract();


--
-- Name: savings_account_transactions validate_journal; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_journal BEFORE INSERT ON public.savings_account_transactions FOR EACH ROW EXECUTE FUNCTION public.savings_validate_journal();


--
-- Name: savings_recurring_executions validate_recurring_execution; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_recurring_execution BEFORE INSERT OR UPDATE ON public.savings_recurring_executions FOR EACH ROW EXECUTE FUNCTION public.savings_validate_recurring_execution();


--
-- Name: savings_recurring_plans validate_recurring_plan; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_recurring_plan BEFORE INSERT OR DELETE OR UPDATE ON public.savings_recurring_plans FOR EACH ROW EXECUTE FUNCTION public.savings_validate_recurring_plan();


--
-- Name: fixed_deposit_instructions fixed_deposit_instructions_tenant_id_fixed_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_instructions
    ADD CONSTRAINT fixed_deposit_instructions_tenant_id_fixed_deposit_id_fkey FOREIGN KEY (tenant_id, fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id);


--
-- Name: fixed_deposit_interest_payments fixed_deposit_interest_paymen_tenant_id_fixed_deposit_id_c_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT fixed_deposit_interest_paymen_tenant_id_fixed_deposit_id_c_fkey FOREIGN KEY (tenant_id, fixed_deposit_id, currency) REFERENCES public.fixed_deposits(tenant_id, id, currency);


--
-- Name: fixed_deposit_interest_payments fixed_deposit_interest_paymen_tenant_id_interest_payment_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT fixed_deposit_interest_paymen_tenant_id_interest_payment_i_fkey FOREIGN KEY (tenant_id, interest_payment_id) REFERENCES public.savings_interest_payments(tenant_id, id);


--
-- Name: fixed_deposit_liquidations fixed_deposit_liquidations_tenant_id_fixed_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_liquidations
    ADD CONSTRAINT fixed_deposit_liquidations_tenant_id_fixed_deposit_id_fkey FOREIGN KEY (tenant_id, fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id);


--
-- Name: fixed_deposit_maturities fixed_deposit_maturities_tenant_id_fixed_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_maturities
    ADD CONSTRAINT fixed_deposit_maturities_tenant_id_fixed_deposit_id_fkey FOREIGN KEY (tenant_id, fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id);


--
-- Name: fixed_deposit_maturities fixed_deposit_maturities_tenant_id_instruction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_maturities
    ADD CONSTRAINT fixed_deposit_maturities_tenant_id_instruction_id_fkey FOREIGN KEY (tenant_id, instruction_id) REFERENCES public.fixed_deposit_instructions(tenant_id, id);


--
-- Name: fixed_deposit_quotes fixed_deposit_quotes_tenant_id_fixed_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_quotes
    ADD CONSTRAINT fixed_deposit_quotes_tenant_id_fixed_deposit_id_fkey FOREIGN KEY (tenant_id, fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id);


--
-- Name: fixed_deposit_quotes fixed_deposit_quotes_tenant_id_product_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_quotes
    ADD CONSTRAINT fixed_deposit_quotes_tenant_id_product_version_id_fkey FOREIGN KEY (tenant_id, product_version_id) REFERENCES public.savings_product_versions(tenant_id, id);


--
-- Name: fixed_deposit_rates fixed_deposit_rates_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_rates
    ADD CONSTRAINT fixed_deposit_rates_version_fk FOREIGN KEY (tenant_id, product_version_id, savings_product_id) REFERENCES public.savings_product_versions(tenant_id, id, savings_product_id);


--
-- Name: fixed_deposit_renewals fixed_deposit_renewals_tenant_id_renewal_instruction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_renewals
    ADD CONSTRAINT fixed_deposit_renewals_tenant_id_renewal_instruction_id_fkey FOREIGN KEY (tenant_id, renewal_instruction_id) REFERENCES public.fixed_deposit_instructions(tenant_id, id);


--
-- Name: fixed_deposit_renewals fixed_deposit_renewals_tenant_id_renewed_fixed_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_renewals
    ADD CONSTRAINT fixed_deposit_renewals_tenant_id_renewed_fixed_deposit_id_fkey FOREIGN KEY (tenant_id, renewed_fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id);


--
-- Name: fixed_deposits fixed_deposits_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_fixed_deposit_rate_id_product_ver_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_fixed_deposit_rate_id_product_ver_fkey FOREIGN KEY (tenant_id, fixed_deposit_rate_id, product_version_id) REFERENCES public.fixed_deposit_rates(tenant_id, id, product_version_id);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_funding_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_funding_deposit_id_fkey FOREIGN KEY (tenant_id, funding_deposit_id) REFERENCES public.savings_deposits(tenant_id, id);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_previous_fixed_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_previous_fixed_deposit_id_fkey FOREIGN KEY (tenant_id, previous_fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id);


--
-- Name: fixed_deposits fixed_deposits_tenant_id_product_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fixed_deposits_tenant_id_product_version_id_fkey FOREIGN KEY (tenant_id, product_version_id) REFERENCES public.savings_product_versions(tenant_id, id);


--
-- Name: fixed_deposit_interest_payments fk_fixed_deposit_interest_payment; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_interest_payments
    ADD CONSTRAINT fk_fixed_deposit_interest_payment FOREIGN KEY (tenant_id, fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: fixed_deposit_rates fk_fixed_deposit_rate_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_rates
    ADD CONSTRAINT fk_fixed_deposit_rate_product FOREIGN KEY (tenant_id, savings_product_id) REFERENCES public.savings_products(tenant_id, id);


--
-- Name: fixed_deposit_renewals fk_fixed_deposit_renewal; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposit_renewals
    ADD CONSTRAINT fk_fixed_deposit_renewal FOREIGN KEY (tenant_id, fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: fixed_deposits fk_fixed_deposit_savings_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fixed_deposits
    ADD CONSTRAINT fk_fixed_deposit_savings_account FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_goal_contributions fk_goal_contribution_goal; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_contributions
    ADD CONSTRAINT fk_goal_contribution_goal FOREIGN KEY (tenant_id, goal_id) REFERENCES public.savings_goals(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_goal_milestones fk_goal_milestone; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_milestones
    ADD CONSTRAINT fk_goal_milestone FOREIGN KEY (tenant_id, goal_id) REFERENCES public.savings_goals(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_goal_withdrawals fk_goal_withdrawal_goal; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_withdrawals
    ADD CONSTRAINT fk_goal_withdrawal_goal FOREIGN KEY (tenant_id, goal_id) REFERENCES public.savings_goals(tenant_id, id);


--
-- Name: savings_interest_accruals fk_interest_accrual_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT fk_interest_accrual_account FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_interest_payments fk_interest_payment_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT fk_interest_payment_account FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_recurring_executions fk_recurring_execution_plan; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_executions
    ADD CONSTRAINT fk_recurring_execution_plan FOREIGN KEY (tenant_id, recurring_plan_id) REFERENCES public.savings_recurring_plans(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_recurring_plans fk_recurring_goal; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_plans
    ADD CONSTRAINT fk_recurring_goal FOREIGN KEY (tenant_id, goal_id) REFERENCES public.savings_goals(tenant_id, id);


--
-- Name: savings_recurring_plans fk_recurring_savings_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_plans
    ADD CONSTRAINT fk_recurring_savings_account FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_account_holders fk_savings_account_holder; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_holders
    ADD CONSTRAINT fk_savings_account_holder FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_accounts fk_savings_account_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_accounts
    ADD CONSTRAINT fk_savings_account_product FOREIGN KEY (tenant_id, savings_product_id) REFERENCES public.savings_products(tenant_id, id);


--
-- Name: savings_account_status_history fk_savings_account_status_history; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_status_history
    ADD CONSTRAINT fk_savings_account_status_history FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_adjustments fk_savings_adjustment_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_adjustments
    ADD CONSTRAINT fk_savings_adjustment_account FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_deposits fk_savings_deposit_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_deposits
    ADD CONSTRAINT fk_savings_deposit_account FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_goals fk_savings_goal_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goals
    ADD CONSTRAINT fk_savings_goal_account FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_product_fees fk_savings_product_fee_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_fees
    ADD CONSTRAINT fk_savings_product_fee_product FOREIGN KEY (tenant_id, savings_product_id) REFERENCES public.savings_products(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_product_rates fk_savings_product_rate_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rates
    ADD CONSTRAINT fk_savings_product_rate_product FOREIGN KEY (tenant_id, savings_product_id) REFERENCES public.savings_products(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_product_rules fk_savings_product_rule_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rules
    ADD CONSTRAINT fk_savings_product_rule_product FOREIGN KEY (tenant_id, savings_product_id) REFERENCES public.savings_products(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_product_tiers fk_savings_product_tier_product; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_tiers
    ADD CONSTRAINT fk_savings_product_tier_product FOREIGN KEY (tenant_id, savings_product_id) REFERENCES public.savings_products(tenant_id, id) ON DELETE RESTRICT;


--
-- Name: savings_transfer_requests fk_savings_transfer_destination; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_transfer_requests
    ADD CONSTRAINT fk_savings_transfer_destination FOREIGN KEY (tenant_id, destination_savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_transfer_requests fk_savings_transfer_source; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_transfer_requests
    ADD CONSTRAINT fk_savings_transfer_source FOREIGN KEY (tenant_id, source_savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_withdrawals fk_savings_withdrawal_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_withdrawals
    ADD CONSTRAINT fk_savings_withdrawal_account FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_account_contracts savings_account_contracts_tenant_id_product_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_contracts
    ADD CONSTRAINT savings_account_contracts_tenant_id_product_version_id_fkey FOREIGN KEY (tenant_id, product_version_id) REFERENCES public.savings_product_versions(tenant_id, id);


--
-- Name: savings_account_contracts savings_account_contracts_tenant_id_savings_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_contracts
    ADD CONSTRAINT savings_account_contracts_tenant_id_savings_account_id_fkey FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_account_restrictions savings_account_restrictions_tenant_id_savings_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_restrictions
    ADD CONSTRAINT savings_account_restrictions_tenant_id_savings_account_id_fkey FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_adjustment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_adjustment_id_fkey FOREIGN KEY (tenant_id, adjustment_id) REFERENCES public.savings_adjustments(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_deposit_id_fkey FOREIGN KEY (tenant_id, deposit_id) REFERENCES public.savings_deposits(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_fixed_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_fixed_deposit_id_fkey FOREIGN KEY (tenant_id, fixed_deposit_id) REFERENCES public.fixed_deposits(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_goal_contribution_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_goal_contribution_i_fkey FOREIGN KEY (tenant_id, goal_contribution_id) REFERENCES public.savings_goal_contributions(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_goal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_goal_id_fkey FOREIGN KEY (tenant_id, goal_id) REFERENCES public.savings_goals(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_goal_withdrawal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_goal_withdrawal_id_fkey FOREIGN KEY (tenant_id, goal_withdrawal_id) REFERENCES public.savings_goal_withdrawals(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_interest_accrual_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_interest_accrual_id_fkey FOREIGN KEY (tenant_id, interest_accrual_id) REFERENCES public.savings_interest_accruals(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_interest_payment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_interest_payment_id_fkey FOREIGN KEY (tenant_id, interest_payment_id) REFERENCES public.savings_interest_payments(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_recurring_execution_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_recurring_execution_fkey FOREIGN KEY (tenant_id, recurring_execution_id) REFERENCES public.savings_recurring_executions(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_reversed_transactio_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_reversed_transactio_fkey FOREIGN KEY (tenant_id, reversed_transaction_id) REFERENCES public.savings_account_transactions(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_transfer_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_transfer_request_id_fkey FOREIGN KEY (tenant_id, transfer_request_id) REFERENCES public.savings_transfer_requests(tenant_id, id);


--
-- Name: savings_account_transactions savings_account_transactions_tenant_id_withdrawal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_account_transactions
    ADD CONSTRAINT savings_account_transactions_tenant_id_withdrawal_id_fkey FOREIGN KEY (tenant_id, withdrawal_id) REFERENCES public.savings_withdrawals(tenant_id, id);


--
-- Name: savings_accounts savings_account_version_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_accounts
    ADD CONSTRAINT savings_account_version_currency_fk FOREIGN KEY (tenant_id, product_version_id, currency) REFERENCES public.savings_product_versions(tenant_id, id, currency);


--
-- Name: savings_accounts savings_account_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_accounts
    ADD CONSTRAINT savings_account_version_fk FOREIGN KEY (tenant_id, product_version_id, savings_product_id) REFERENCES public.savings_product_versions(tenant_id, id, savings_product_id);


--
-- Name: savings_adjustments savings_adjustments_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_adjustments
    ADD CONSTRAINT savings_adjustments_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_adjustments savings_adjustments_tenant_id_reversed_adjustment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_adjustments
    ADD CONSTRAINT savings_adjustments_tenant_id_reversed_adjustment_id_fkey FOREIGN KEY (tenant_id, reversed_adjustment_id) REFERENCES public.savings_adjustments(tenant_id, id);


--
-- Name: savings_balance_holds savings_balance_holds_tenant_id_savings_account_id_currenc_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_balance_holds
    ADD CONSTRAINT savings_balance_holds_tenant_id_savings_account_id_currenc_fkey FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_balance_holds savings_balance_holds_tenant_id_transfer_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_balance_holds
    ADD CONSTRAINT savings_balance_holds_tenant_id_transfer_request_id_fkey FOREIGN KEY (tenant_id, transfer_request_id) REFERENCES public.savings_transfer_requests(tenant_id, id);


--
-- Name: savings_balance_holds savings_balance_holds_tenant_id_withdrawal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_balance_holds
    ADD CONSTRAINT savings_balance_holds_tenant_id_withdrawal_id_fkey FOREIGN KEY (tenant_id, withdrawal_id) REFERENCES public.savings_withdrawals(tenant_id, id);


--
-- Name: savings_deposits savings_deposits_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_deposits
    ADD CONSTRAINT savings_deposits_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_product_fees savings_fee_version_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_fees
    ADD CONSTRAINT savings_fee_version_currency_fk FOREIGN KEY (tenant_id, product_version_id, currency) REFERENCES public.savings_product_versions(tenant_id, id, currency);


--
-- Name: savings_goal_contributions savings_goal_contributions_tenant_id_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_contributions
    ADD CONSTRAINT savings_goal_contributions_tenant_id_deposit_id_fkey FOREIGN KEY (tenant_id, deposit_id) REFERENCES public.savings_deposits(tenant_id, id);


--
-- Name: savings_goal_contributions savings_goal_contributions_tenant_id_goal_id_currency_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_contributions
    ADD CONSTRAINT savings_goal_contributions_tenant_id_goal_id_currency_fkey FOREIGN KEY (tenant_id, goal_id, currency) REFERENCES public.savings_goals(tenant_id, id, currency);


--
-- Name: savings_goal_withdrawals savings_goal_withdrawals_tenant_id_goal_id_currency_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_withdrawals
    ADD CONSTRAINT savings_goal_withdrawals_tenant_id_goal_id_currency_fkey FOREIGN KEY (tenant_id, goal_id, currency) REFERENCES public.savings_goals(tenant_id, id, currency);


--
-- Name: savings_goal_withdrawals savings_goal_withdrawals_tenant_id_withdrawal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goal_withdrawals
    ADD CONSTRAINT savings_goal_withdrawals_tenant_id_withdrawal_id_fkey FOREIGN KEY (tenant_id, withdrawal_id) REFERENCES public.savings_withdrawals(tenant_id, id);


--
-- Name: savings_goals savings_goals_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_goals
    ADD CONSTRAINT savings_goals_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_interest_accrual_corrections savings_interest_accrual_corr_tenant_id_correction_payment_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_corrections
    ADD CONSTRAINT savings_interest_accrual_corr_tenant_id_correction_payment_fkey FOREIGN KEY (tenant_id, correction_payment_id) REFERENCES public.savings_interest_payments(tenant_id, id);


--
-- Name: savings_interest_accrual_corrections savings_interest_accrual_corr_tenant_id_interest_accrual_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accrual_corrections
    ADD CONSTRAINT savings_interest_accrual_corr_tenant_id_interest_accrual_i_fkey FOREIGN KEY (tenant_id, interest_accrual_id) REFERENCES public.savings_interest_accruals(tenant_id, id);


--
-- Name: savings_interest_accruals savings_interest_accruals_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT savings_interest_accruals_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_interest_accruals savings_interest_accruals_tenant_id_accrual_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT savings_interest_accruals_tenant_id_accrual_batch_id_fkey FOREIGN KEY (tenant_id, accrual_batch_id) REFERENCES public.savings_interest_accrual_batches(tenant_id, id);


--
-- Name: savings_interest_accruals savings_interest_accruals_tenant_id_fixed_deposit_id_savin_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT savings_interest_accruals_tenant_id_fixed_deposit_id_savin_fkey FOREIGN KEY (tenant_id, fixed_deposit_id, savings_account_id) REFERENCES public.fixed_deposits(tenant_id, id, savings_account_id);


--
-- Name: savings_interest_accruals savings_interest_accruals_tenant_id_fixed_deposit_rate_id__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT savings_interest_accruals_tenant_id_fixed_deposit_rate_id__fkey FOREIGN KEY (tenant_id, fixed_deposit_rate_id, product_version_id) REFERENCES public.fixed_deposit_rates(tenant_id, id, product_version_id);


--
-- Name: savings_interest_accruals savings_interest_accruals_tenant_id_product_rate_id_produc_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT savings_interest_accruals_tenant_id_product_rate_id_produc_fkey FOREIGN KEY (tenant_id, product_rate_id, product_version_id) REFERENCES public.savings_product_rates(tenant_id, id, product_version_id);


--
-- Name: savings_interest_accruals savings_interest_accruals_tenant_id_product_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_accruals
    ADD CONSTRAINT savings_interest_accruals_tenant_id_product_version_id_fkey FOREIGN KEY (tenant_id, product_version_id) REFERENCES public.savings_product_versions(tenant_id, id);


--
-- Name: savings_interest_payment_accruals savings_interest_payment_accr_tenant_id_interest_accrual_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payment_accruals
    ADD CONSTRAINT savings_interest_payment_accr_tenant_id_interest_accrual_i_fkey FOREIGN KEY (tenant_id, interest_accrual_id) REFERENCES public.savings_interest_accruals(tenant_id, id);


--
-- Name: savings_interest_payment_accruals savings_interest_payment_accr_tenant_id_interest_payment_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payment_accruals
    ADD CONSTRAINT savings_interest_payment_accr_tenant_id_interest_payment_i_fkey FOREIGN KEY (tenant_id, interest_payment_id) REFERENCES public.savings_interest_payments(tenant_id, id);


--
-- Name: savings_interest_payments savings_interest_payments_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT savings_interest_payments_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_interest_payments savings_interest_payments_tenant_id_fixed_deposit_id_savin_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT savings_interest_payments_tenant_id_fixed_deposit_id_savin_fkey FOREIGN KEY (tenant_id, fixed_deposit_id, savings_account_id) REFERENCES public.fixed_deposits(tenant_id, id, savings_account_id);


--
-- Name: savings_interest_payments savings_interest_payments_tenant_id_payment_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_interest_payments
    ADD CONSTRAINT savings_interest_payments_tenant_id_payment_batch_id_fkey FOREIGN KEY (tenant_id, payment_batch_id) REFERENCES public.savings_interest_payment_batches(tenant_id, id);


--
-- Name: savings_product_fees savings_product_fees_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_fees
    ADD CONSTRAINT savings_product_fees_version_fk FOREIGN KEY (tenant_id, product_version_id, savings_product_id) REFERENCES public.savings_product_versions(tenant_id, id, savings_product_id);


--
-- Name: savings_product_rates savings_product_rates_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rates
    ADD CONSTRAINT savings_product_rates_version_fk FOREIGN KEY (tenant_id, product_version_id, savings_product_id) REFERENCES public.savings_product_versions(tenant_id, id, savings_product_id);


--
-- Name: savings_product_rules savings_product_rules_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_rules
    ADD CONSTRAINT savings_product_rules_version_fk FOREIGN KEY (tenant_id, product_version_id, savings_product_id) REFERENCES public.savings_product_versions(tenant_id, id, savings_product_id);


--
-- Name: savings_product_tiers savings_product_tiers_version_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_tiers
    ADD CONSTRAINT savings_product_tiers_version_fk FOREIGN KEY (tenant_id, product_version_id, savings_product_id) REFERENCES public.savings_product_versions(tenant_id, id, savings_product_id);


--
-- Name: savings_product_versions savings_product_versions_tenant_id_savings_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_product_versions
    ADD CONSTRAINT savings_product_versions_tenant_id_savings_product_id_fkey FOREIGN KEY (tenant_id, savings_product_id) REFERENCES public.savings_products(tenant_id, id);


--
-- Name: savings_reconciliation_items savings_reconciliation_items_tenant_id_adjustment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_items
    ADD CONSTRAINT savings_reconciliation_items_tenant_id_adjustment_id_fkey FOREIGN KEY (tenant_id, adjustment_id) REFERENCES public.savings_adjustments(tenant_id, id);


--
-- Name: savings_reconciliation_items savings_reconciliation_items_tenant_id_reconciliation_run__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_items
    ADD CONSTRAINT savings_reconciliation_items_tenant_id_reconciliation_run__fkey FOREIGN KEY (tenant_id, reconciliation_run_id) REFERENCES public.savings_reconciliation_runs(tenant_id, id);


--
-- Name: savings_reconciliation_items savings_reconciliation_items_tenant_id_savings_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_reconciliation_items
    ADD CONSTRAINT savings_reconciliation_items_tenant_id_savings_account_id_fkey FOREIGN KEY (tenant_id, savings_account_id) REFERENCES public.savings_accounts(tenant_id, id);


--
-- Name: savings_recurring_executions savings_recurring_executions_tenant_id_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_executions
    ADD CONSTRAINT savings_recurring_executions_tenant_id_deposit_id_fkey FOREIGN KEY (tenant_id, deposit_id) REFERENCES public.savings_deposits(tenant_id, id);


--
-- Name: savings_recurring_plans savings_recurring_plans_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_plans
    ADD CONSTRAINT savings_recurring_plans_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_recurring_plans savings_recurring_plans_tenant_id_goal_id_savings_account__fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_recurring_plans
    ADD CONSTRAINT savings_recurring_plans_tenant_id_goal_id_savings_account__fkey FOREIGN KEY (tenant_id, goal_id, savings_account_id) REFERENCES public.savings_goals(tenant_id, id, savings_account_id);


--
-- Name: savings_transfer_requests savings_transfer_requests_tenant_id_destination_savings_ac_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_transfer_requests
    ADD CONSTRAINT savings_transfer_requests_tenant_id_destination_savings_ac_fkey FOREIGN KEY (tenant_id, destination_savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_transfer_requests savings_transfer_requests_tenant_id_source_savings_account_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_transfer_requests
    ADD CONSTRAINT savings_transfer_requests_tenant_id_source_savings_account_fkey FOREIGN KEY (tenant_id, source_savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: savings_withdrawals savings_withdrawals_account_currency_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.savings_withdrawals
    ADD CONSTRAINT savings_withdrawals_account_currency_fk FOREIGN KEY (tenant_id, savings_account_id, currency) REFERENCES public.savings_accounts(tenant_id, id, currency);


--
-- Name: fixed_deposit_instructions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fixed_deposit_instructions ENABLE ROW LEVEL SECURITY;

--
-- Name: fixed_deposit_instructions fixed_deposit_instructions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fixed_deposit_instructions_tenant_policy ON public.fixed_deposit_instructions USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: fixed_deposit_interest_payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fixed_deposit_interest_payments ENABLE ROW LEVEL SECURITY;

--
-- Name: fixed_deposit_interest_payments fixed_deposit_interest_payments_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fixed_deposit_interest_payments_tenant_policy ON public.fixed_deposit_interest_payments USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: fixed_deposit_liquidations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fixed_deposit_liquidations ENABLE ROW LEVEL SECURITY;

--
-- Name: fixed_deposit_liquidations fixed_deposit_liquidations_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fixed_deposit_liquidations_tenant_policy ON public.fixed_deposit_liquidations USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: fixed_deposit_maturities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fixed_deposit_maturities ENABLE ROW LEVEL SECURITY;

--
-- Name: fixed_deposit_maturities fixed_deposit_maturities_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fixed_deposit_maturities_tenant_policy ON public.fixed_deposit_maturities USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: fixed_deposit_quotes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fixed_deposit_quotes ENABLE ROW LEVEL SECURITY;

--
-- Name: fixed_deposit_quotes fixed_deposit_quotes_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fixed_deposit_quotes_tenant_policy ON public.fixed_deposit_quotes USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: fixed_deposit_rates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fixed_deposit_rates ENABLE ROW LEVEL SECURITY;

--
-- Name: fixed_deposit_rates fixed_deposit_rates_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fixed_deposit_rates_tenant_policy ON public.fixed_deposit_rates USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: fixed_deposit_renewals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fixed_deposit_renewals ENABLE ROW LEVEL SECURITY;

--
-- Name: fixed_deposit_renewals fixed_deposit_renewals_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fixed_deposit_renewals_tenant_policy ON public.fixed_deposit_renewals USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: fixed_deposits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fixed_deposits ENABLE ROW LEVEL SECURITY;

--
-- Name: fixed_deposits fixed_deposits_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fixed_deposits_tenant_policy ON public.fixed_deposits USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_account_contracts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_account_contracts ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_account_contracts savings_account_contracts_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_account_contracts_tenant_policy ON public.savings_account_contracts USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_account_holders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_account_holders ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_account_holders savings_account_holders_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_account_holders_tenant_policy ON public.savings_account_holders USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_account_restrictions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_account_restrictions ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_account_restrictions savings_account_restrictions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_account_restrictions_tenant_policy ON public.savings_account_restrictions USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_account_status_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_account_status_history ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_account_status_history savings_account_status_history_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_account_status_history_tenant_policy ON public.savings_account_status_history USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_account_transactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_account_transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_account_transactions savings_account_transactions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_account_transactions_tenant_policy ON public.savings_account_transactions USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_accounts savings_accounts_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_accounts_tenant_policy ON public.savings_accounts USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_adjustments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_adjustments ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_adjustments savings_adjustments_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_adjustments_tenant_policy ON public.savings_adjustments USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_audit_logs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_audit_logs ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_audit_logs savings_audit_logs_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_audit_logs_tenant_policy ON public.savings_audit_logs USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_balance_holds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_balance_holds ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_balance_holds savings_balance_holds_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_balance_holds_tenant_policy ON public.savings_balance_holds USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_deposits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_deposits ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_deposits savings_deposits_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_deposits_tenant_policy ON public.savings_deposits USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_goal_contributions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_goal_contributions ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_goal_contributions savings_goal_contributions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_goal_contributions_tenant_policy ON public.savings_goal_contributions USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_goal_milestones; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_goal_milestones ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_goal_milestones savings_goal_milestones_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_goal_milestones_tenant_policy ON public.savings_goal_milestones USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_goal_withdrawals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_goal_withdrawals ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_goal_withdrawals savings_goal_withdrawals_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_goal_withdrawals_tenant_policy ON public.savings_goal_withdrawals USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_goals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_goals ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_goals savings_goals_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_goals_tenant_policy ON public.savings_goals USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_idempotency_keys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_idempotency_keys ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_idempotency_keys savings_idempotency_keys_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_idempotency_keys_tenant_policy ON public.savings_idempotency_keys USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_inbox_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_inbox_events ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_inbox_events savings_inbox_events_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_inbox_events_tenant_policy ON public.savings_inbox_events USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_interest_accrual_batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_interest_accrual_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_interest_accrual_batches savings_interest_accrual_batches_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_interest_accrual_batches_tenant_policy ON public.savings_interest_accrual_batches USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_interest_accrual_corrections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_interest_accrual_corrections ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_interest_accrual_corrections savings_interest_accrual_corrections_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_interest_accrual_corrections_tenant_policy ON public.savings_interest_accrual_corrections USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_interest_accruals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_interest_accruals ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_interest_accruals savings_interest_accruals_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_interest_accruals_tenant_policy ON public.savings_interest_accruals USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_interest_payment_accruals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_interest_payment_accruals ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_interest_payment_accruals savings_interest_payment_accruals_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_interest_payment_accruals_tenant_policy ON public.savings_interest_payment_accruals USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_interest_payment_batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_interest_payment_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_interest_payment_batches savings_interest_payment_batches_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_interest_payment_batches_tenant_policy ON public.savings_interest_payment_batches USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_interest_payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_interest_payments ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_interest_payments savings_interest_payments_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_interest_payments_tenant_policy ON public.savings_interest_payments USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_outbox_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_outbox_events ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_outbox_events savings_outbox_events_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_outbox_events_tenant_policy ON public.savings_outbox_events USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_processing_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_processing_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_processing_attempts savings_processing_attempts_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_processing_attempts_tenant_policy ON public.savings_processing_attempts USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_product_fees; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_product_fees ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_product_fees savings_product_fees_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_product_fees_tenant_policy ON public.savings_product_fees USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_product_rates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_product_rates ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_product_rates savings_product_rates_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_product_rates_tenant_policy ON public.savings_product_rates USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_product_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_product_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_product_rules savings_product_rules_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_product_rules_tenant_policy ON public.savings_product_rules USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_product_tiers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_product_tiers ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_product_tiers savings_product_tiers_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_product_tiers_tenant_policy ON public.savings_product_tiers USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_product_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_product_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_product_versions savings_product_versions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_product_versions_tenant_policy ON public.savings_product_versions USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_products; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_products ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_products savings_products_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_products_tenant_policy ON public.savings_products USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_reconciliation_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_reconciliation_items ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_reconciliation_items savings_reconciliation_items_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_reconciliation_items_tenant_policy ON public.savings_reconciliation_items USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_reconciliation_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_reconciliation_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_reconciliation_runs savings_reconciliation_runs_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_reconciliation_runs_tenant_policy ON public.savings_reconciliation_runs USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_recurring_executions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_recurring_executions ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_recurring_executions savings_recurring_executions_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_recurring_executions_tenant_policy ON public.savings_recurring_executions USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_recurring_plans; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_recurring_plans ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_recurring_plans savings_recurring_plans_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_recurring_plans_tenant_policy ON public.savings_recurring_plans USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_transfer_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_transfer_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_transfer_requests savings_transfer_requests_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_transfer_requests_tenant_policy ON public.savings_transfer_requests USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- Name: savings_withdrawals; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.savings_withdrawals ENABLE ROW LEVEL SECURITY;

--
-- Name: savings_withdrawals savings_withdrawals_tenant_policy; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY savings_withdrawals_tenant_policy ON public.savings_withdrawals USING ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid)) WITH CHECK ((tenant_id = (NULLIF(current_setting('app.current_tenant_id'::text, true), ''::text))::uuid));


--
-- PostgreSQL database dump complete
--

