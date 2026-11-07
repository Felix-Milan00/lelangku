-- ============================================================
-- LelangKu — Migration Phase 2: Digital Wallet, Wallet Bidding,
-- Advanced Scheduling fields, Live Admin Auction Control.
-- Incremental & idempotent: safe to run on top of Phase 1.
-- Money is BIGINT IDR everywhere. Ledger is immutable.
-- Auth model for admin/trusted functions:
--   * auth.role() IS NULL  -> trusted direct DB context
--     (SQL Editor / Management API / pg_cron) = allowed.
--   * otherwise the caller must be a profile with role='admin'
--     (public.is_admin()).
-- Browser clients can NEVER update wallet balances directly:
-- no INSERT/UPDATE/DELETE policies exist for wallets /
-- wallet_transactions; all changes go through SECURITY DEFINER
-- functions below.
-- ============================================================

-- 1. AUCTIONS: extra columns
ALTER TABLE public.auctions ADD COLUMN IF NOT EXISTS reserve_price bigint CHECK (reserve_price IS NULL OR reserve_price >= 0);
ALTER TABLE public.auctions ADD COLUMN IF NOT EXISTS actual_end_time timestamptz;
ALTER TABLE public.auctions ADD COLUMN IF NOT EXISTS completed_at timestamptz;

-- 2. WALLETS
CREATE TABLE IF NOT EXISTS public.wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE CASCADE,
  available_balance bigint NOT NULL DEFAULT 0 CHECK (available_balance >= 0),
  reserved_balance bigint NOT NULL DEFAULT 0 CHECK (reserved_balance >= 0),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','frozen','closed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 3. WALLET TRANSACTIONS (immutable ledger)
CREATE TABLE IF NOT EXISTS public.wallet_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES public.wallets(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  transaction_type text NOT NULL CHECK (transaction_type IN (
    'Admin Balance Addition','Admin Balance Deduction',
    'Auction Bid Reservation','Bid Reservation Release',
    'Auction Payment','Refund','Wallet Adjustment')),
  amount bigint NOT NULL, -- signed: + incoming to total balance, - outgoing
  available_balance_before bigint NOT NULL,
  available_balance_after bigint NOT NULL,
  reserved_balance_before bigint NOT NULL,
  reserved_balance_after bigint NOT NULL,
  related_auction_id uuid REFERENCES public.auctions(id) ON DELETE SET NULL,
  related_bid_id uuid REFERENCES public.bids(id) ON DELETE SET NULL,
  reference_number text,
  description text,
  performed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  idempotency_key text UNIQUE,
  status text NOT NULL DEFAULT 'completed',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_user_created ON public.wallet_transactions(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_auction ON public.wallet_transactions(related_auction_id);
CREATE INDEX IF NOT EXISTS idx_wallets_user ON public.wallets(user_id);

-- 4. AUCTION ADMIN ACTIONS + PAUSE HISTORY
CREATE TABLE IF NOT EXISTS public.auction_admin_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auction_id uuid NOT NULL REFERENCES public.auctions(id) ON DELETE CASCADE,
  admin_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  action_type text NOT NULL CHECK (action_type IN ('end','extend','pause','resume','cancel','publish','edit')),
  previous_values jsonb,
  new_values jsonb,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_actions_auction ON public.auction_admin_actions(auction_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.auction_pause_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auction_id uuid NOT NULL REFERENCES public.auctions(id) ON DELETE CASCADE,
  paused_at timestamptz NOT NULL DEFAULT now(),
  resumed_at timestamptz,
  remaining_seconds bigint,
  paused_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  resumed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pause_history_auction ON public.auction_pause_history(auction_id, created_at DESC);

-- 5. updated_at trigger for wallets
DROP TRIGGER IF EXISTS trg_wallets_updated_at ON public.wallets;
CREATE TRIGGER trg_wallets_updated_at BEFORE UPDATE ON public.wallets
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 6. Ledger immutability
CREATE OR REPLACE FUNCTION public._wallet_tx_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'wallet_transactions are immutable'; END; $$;
DROP TRIGGER IF EXISTS trg_wallet_tx_no_update ON public.wallet_transactions;
CREATE TRIGGER trg_wallet_tx_no_update BEFORE UPDATE OR DELETE ON public.wallet_transactions
  FOR EACH ROW EXECUTE FUNCTION public._wallet_tx_immutable();

-- 7. Auto-create wallet for every new profile + backfill
CREATE OR REPLACE FUNCTION public.create_user_wallet(p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.wallets(user_id) VALUES (p_user_id)
  ON CONFLICT (user_id) DO NOTHING RETURNING id INTO v_id;
  IF v_id IS NULL THEN SELECT id INTO v_id FROM public.wallets WHERE user_id = p_user_id; END IF;
  RETURN jsonb_build_object('success', true, 'wallet_id', v_id, 'user_id', p_user_id);
END; $$;

CREATE OR REPLACE FUNCTION public._handle_new_profile_wallet() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.wallets(user_id) VALUES (NEW.id) ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS trg_profiles_create_wallet ON public.profiles;
CREATE TRIGGER trg_profiles_create_wallet AFTER INSERT ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public._handle_new_profile_wallet();

INSERT INTO public.wallets(user_id)
SELECT id FROM public.profiles ON CONFLICT (user_id) DO NOTHING;

-- 8. RLS
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auction_admin_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auction_pause_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wallets_select_own_or_admin ON public.wallets;
CREATE POLICY wallets_select_own_or_admin ON public.wallets FOR SELECT
  USING (user_id = auth.uid() OR public.is_admin());
DROP POLICY IF EXISTS wallet_tx_select_own_or_admin ON public.wallet_transactions;
CREATE POLICY wallet_tx_select_own_or_admin ON public.wallet_transactions FOR SELECT
  USING (user_id = auth.uid() OR public.is_admin());
DROP POLICY IF EXISTS admin_actions_select_admin ON public.auction_admin_actions;
CREATE POLICY admin_actions_select_admin ON public.auction_admin_actions FOR SELECT
  USING (public.is_admin());
DROP POLICY IF EXISTS pause_history_select_admin ON public.auction_pause_history;
CREATE POLICY pause_history_select_admin ON public.auction_pause_history FOR SELECT
  USING (public.is_admin());
-- No client INSERT/UPDATE/DELETE policies on wallets / wallet_transactions on purpose.

-- 9. Internal helpers
CREATE OR REPLACE FUNCTION public._require_admin_or_trusted() RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN auth.role() IS NULL OR public.is_admin();
END; $$;

CREATE OR REPLACE FUNCTION public._get_or_create_wallet(p_user_id uuid)
RETURNS public.wallets LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_wallet public.wallets%ROWTYPE;
BEGIN
  INSERT INTO public.wallets(user_id) VALUES (p_user_id) ON CONFLICT (user_id) DO NOTHING;
  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = p_user_id FOR UPDATE;
  RETURN v_wallet;
END; $$;

CREATE OR REPLACE FUNCTION public._ledger(
  p_wallet public.wallets, p_type text, p_amount bigint,
  p_avail_before bigint, p_avail_after bigint, p_res_before bigint, p_res_after bigint,
  p_auction uuid, p_bid uuid, p_ref text, p_desc text, p_by uuid, p_idem text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.wallet_transactions(
    wallet_id, user_id, transaction_type, amount,
    available_balance_before, available_balance_after,
    reserved_balance_before, reserved_balance_after,
    related_auction_id, related_bid_id, reference_number, description, performed_by, idempotency_key)
  VALUES (p_wallet.id, p_wallet.user_id, p_type, p_amount,
    p_avail_before, p_avail_after, p_res_before, p_res_after,
    p_auction, p_bid, p_ref, p_desc, p_by, p_idem)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

-- 10. ADMIN ADD BALANCE
CREATE OR REPLACE FUNCTION public.admin_add_wallet_balance(
  p_user_id uuid, p_amount bigint, p_description text DEFAULT NULL,
  p_reference text DEFAULT NULL, p_idempotency_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_wallet public.wallets%ROWTYPE;
  v_by uuid := auth.uid();
  v_tx uuid;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can add wallet balance');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Amount must be greater than zero');
  END IF;
  IF p_idempotency_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.wallet_transactions WHERE idempotency_key = p_idempotency_key) THEN
    RETURN jsonb_build_object('success', true, 'duplicate', true, 'user_id', p_user_id);
  END IF;
  v_wallet := public._get_or_create_wallet(p_user_id);
  UPDATE public.wallets SET available_balance = available_balance + p_amount
  WHERE id = v_wallet.id;
  v_tx := public._ledger(v_wallet, 'Admin Balance Addition', p_amount,
    v_wallet.available_balance, v_wallet.available_balance + p_amount,
    v_wallet.reserved_balance, v_wallet.reserved_balance,
    NULL, NULL, p_reference,
    COALESCE(p_description, 'Penambahan saldo oleh admin'), v_by, p_idempotency_key);
  INSERT INTO public.notifications(user_id, type, title, message)
  VALUES (p_user_id, 'general', 'Saldo wallet ditambahkan',
    'Admin menambahkan saldo sebesar Rp' || to_char(p_amount, 'FM999,999,999,999') || ' ke wallet Anda.');
  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx, 'user_id', p_user_id,
    'available_balance', v_wallet.available_balance + p_amount,
    'reserved_balance', v_wallet.reserved_balance);
END; $$;

-- 11. ADMIN DEDUCT BALANCE (never touches reserved funds, never negative)
CREATE OR REPLACE FUNCTION public.admin_deduct_wallet_balance(
  p_user_id uuid, p_amount bigint, p_description text,
  p_reference text DEFAULT NULL, p_idempotency_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_wallet public.wallets%ROWTYPE;
  v_by uuid := auth.uid();
  v_tx uuid;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can deduct wallet balance');
  END IF;
  IF p_description IS NULL OR btrim(p_description) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Reason is required for balance deduction');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Amount must be greater than zero');
  END IF;
  IF p_idempotency_key IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.wallet_transactions WHERE idempotency_key = p_idempotency_key) THEN
    RETURN jsonb_build_object('success', true, 'duplicate', true, 'user_id', p_user_id);
  END IF;
  v_wallet := public._get_or_create_wallet(p_user_id);
  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Deduction exceeds available balance',
      'available_balance', v_wallet.available_balance);
  END IF;
  UPDATE public.wallets SET available_balance = available_balance - p_amount
  WHERE id = v_wallet.id;
  v_tx := public._ledger(v_wallet, 'Admin Balance Deduction', -p_amount,
    v_wallet.available_balance, v_wallet.available_balance - p_amount,
    v_wallet.reserved_balance, v_wallet.reserved_balance,
    NULL, NULL, p_reference, p_description, v_by, p_idempotency_key);
  INSERT INTO public.notifications(user_id, type, title, message)
  VALUES (p_user_id, 'general', 'Saldo wallet dikurangi',
    'Admin mengurangi saldo sebesar Rp' || to_char(p_amount, 'FM999,999,999,999') || ' dari wallet Anda. Alasan: ' || p_description);
  RETURN jsonb_build_object('success', true, 'transaction_id', v_tx, 'user_id', p_user_id,
    'available_balance', v_wallet.available_balance - p_amount,
    'reserved_balance', v_wallet.reserved_balance);
END; $$;

-- 12. PLACE BID WITH WALLET (atomic: bid + release previous + reserve new)
CREATE OR REPLACE FUNCTION public.place_bid_with_wallet(p_auction_id uuid, p_amount bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user uuid := auth.uid();
  v_auction public.auctions%ROWTYPE;
  v_required bigint;
  v_sequence integer;
  v_bid_id uuid;
  v_prev_bidder uuid;
  v_prev_amount bigint;
  v_prev_bid_id uuid;
  v_new_end timestamptz;
  v_extended boolean := false;
  v_wallet public.wallets%ROWTYPE;
  v_prev_wallet public.wallets%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You must be signed in to place a bid');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bid amount must be a positive number');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction not found');
  END IF;
  IF v_auction.seller_id = v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'You cannot bid on your own auction');
  END IF;
  IF v_auction.status <> 'Live' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction is not live');
  END IF;
  IF now() < v_auction.start_time THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction has not started yet');
  END IF;
  IF now() >= v_auction.end_time THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction has already ended');
  END IF;
  v_prev_bidder := v_auction.highest_bidder_id;
  v_prev_amount := v_auction.current_highest_bid;
  IF v_prev_amount IS NULL THEN v_required := v_auction.starting_price;
  ELSE v_required := v_prev_amount + v_auction.minimum_increment; END IF;
  IF p_amount < v_required THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bid is too low', 'minimum_required', v_required);
  END IF;
  IF v_prev_bidder = v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are already the highest bidder');
  END IF;

  -- Wallet validation (available balance only; reserved is locked)
  v_wallet := public._get_or_create_wallet(v_user);
  IF v_wallet.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet is not active', 'code', 'WALLET_INACTIVE');
  END IF;
  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Saldo Anda tidak mencukupi untuk melakukan penawaran ini.',
      'code', 'INSUFFICIENT_BALANCE', 'available_balance', v_wallet.available_balance);
  END IF;

  SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence
  FROM public.bids WHERE auction_id = p_auction_id;
  INSERT INTO public.bids (auction_id, bidder_id, amount, bid_sequence)
  VALUES (p_auction_id, v_user, p_amount, v_sequence) RETURNING id INTO v_bid_id;

  -- Release previous highest bidder reservation
  IF v_prev_bidder IS NOT NULL AND v_prev_amount IS NOT NULL THEN
    SELECT id INTO v_prev_bid_id FROM public.bids
    WHERE auction_id = p_auction_id AND bidder_id = v_prev_bidder AND amount = v_prev_amount
    ORDER BY bid_sequence DESC LIMIT 1;
    v_prev_wallet := public._get_or_create_wallet(v_prev_bidder);
    IF v_prev_wallet.reserved_balance >= v_prev_amount THEN
      UPDATE public.wallets SET available_balance = available_balance + v_prev_amount,
        reserved_balance = reserved_balance - v_prev_amount WHERE id = v_prev_wallet.id;
      PERFORM public._ledger(v_prev_wallet, 'Bid Reservation Release', v_prev_amount,
        v_prev_wallet.available_balance, v_prev_wallet.available_balance + v_prev_amount,
        v_prev_wallet.reserved_balance, v_prev_wallet.reserved_balance - v_prev_amount,
        p_auction_id, v_prev_bid_id, NULL, 'Reservasi bid dikembalikan karena ada bid yang lebih tinggi', v_user, NULL);
    END IF;
    INSERT INTO public.notifications (user_id, auction_id, type, title, message, metadata)
    VALUES (v_prev_bidder, p_auction_id, 'outbid', 'You have been outbid',
      'Someone placed a higher bid on "' || v_auction.title || '".',
      jsonb_build_object('amount', p_amount, 'bid_id', v_bid_id));
  END IF;

  -- Reserve new bidder funds
  UPDATE public.wallets SET available_balance = available_balance - p_amount,
    reserved_balance = reserved_balance + p_amount WHERE id = v_wallet.id;
  PERFORM public._ledger(v_wallet, 'Auction Bid Reservation', -p_amount,
    v_wallet.available_balance, v_wallet.available_balance - p_amount,
    v_wallet.reserved_balance, v_wallet.reserved_balance + p_amount,
    p_auction_id, v_bid_id, NULL, 'Reservasi dana untuk bid tertinggi saat ini', v_user, NULL);

  v_new_end := v_auction.end_time;
  IF v_auction.anti_sniping_enabled
     AND v_auction.end_time - now() <= make_interval(secs => v_auction.extension_threshold_seconds) THEN
    v_new_end := v_auction.end_time + make_interval(secs => v_auction.extension_duration_seconds);
    v_extended := true;
  END IF;
  UPDATE public.auctions SET current_highest_bid = p_amount,
    highest_bidder_id = v_user, end_time = v_new_end WHERE id = p_auction_id;

  INSERT INTO public.notifications (user_id, auction_id, type, title, message, metadata)
  VALUES (v_auction.seller_id, p_auction_id, 'bid_placed', 'New bid on your auction',
    'A new bid was placed on "' || v_auction.title || '".',
    jsonb_build_object('amount', p_amount, 'bid_id', v_bid_id));

  RETURN jsonb_build_object('success', true, 'bid_id', v_bid_id,
    'auction_id', p_auction_id, 'amount', p_amount, 'bid_sequence', v_sequence,
    'current_highest_bid', p_amount, 'highest_bidder_id', v_user,
    'end_time', v_new_end, 'extended', v_extended,
    'wallet_available', v_wallet.available_balance - p_amount,
    'wallet_reserved', v_wallet.reserved_balance + p_amount);
END; $$;

-- 13. RELEASE BID RESERVATION (admin/trusted; used standalone)
CREATE OR REPLACE FUNCTION public.release_bid_reservation(p_auction_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auction public.auctions%ROWTYPE;
  v_wallet public.wallets%ROWTYPE;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can release reservations');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.highest_bidder_id IS NULL OR v_auction.current_highest_bid IS NULL THEN
    RETURN jsonb_build_object('success', true, 'released', 0);
  END IF;
  v_wallet := public._get_or_create_wallet(v_auction.highest_bidder_id);
  IF v_wallet.reserved_balance >= v_auction.current_highest_bid THEN
    UPDATE public.wallets SET available_balance = available_balance + v_auction.current_highest_bid,
      reserved_balance = reserved_balance - v_auction.current_highest_bid WHERE id = v_wallet.id;
    PERFORM public._ledger(v_wallet, 'Bid Reservation Release', v_auction.current_highest_bid,
      v_wallet.available_balance, v_wallet.available_balance + v_auction.current_highest_bid,
      v_wallet.reserved_balance, v_wallet.reserved_balance - v_auction.current_highest_bid,
      p_auction_id, NULL, NULL, 'Reservasi bid dikembalikan', auth.uid(), NULL);
    RETURN jsonb_build_object('success', true, 'released', v_auction.current_highest_bid);
  END IF;
  RETURN jsonb_build_object('success', true, 'released', 0);
END; $$;

-- 14. FINALIZE AUCTION (idempotent settlement)
CREATE OR REPLACE FUNCTION public.finalize_auction(p_auction_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auction public.auctions%ROWTYPE;
  v_wallet public.wallets%ROWTYPE;
  v_hours integer := 72;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can finalize auctions');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.status IN ('Completed','No Winner','Cancelled') THEN
    RETURN jsonb_build_object('success', true, 'already_finalized', true, 'status', v_auction.status);
  END IF;
  SELECT COALESCE((setting_value #>> '{}')::integer, 72) INTO v_hours
  FROM public.platform_settings WHERE setting_key = 'payment_deadline_hours';
  IF v_hours IS NULL THEN v_hours := 72; END IF;

  IF v_auction.highest_bidder_id IS NOT NULL AND v_auction.current_highest_bid IS NOT NULL THEN
    -- Winner: reserved -> payment (total balance decreases by final price)
    v_wallet := public._get_or_create_wallet(v_auction.highest_bidder_id);
    IF v_wallet.reserved_balance >= v_auction.current_highest_bid THEN
      UPDATE public.wallets SET reserved_balance = reserved_balance - v_auction.current_highest_bid
      WHERE id = v_wallet.id;
      PERFORM public._ledger(v_wallet, 'Auction Payment', -v_auction.current_highest_bid,
        v_wallet.available_balance, v_wallet.available_balance,
        v_wallet.reserved_balance, v_wallet.reserved_balance - v_auction.current_highest_bid,
        p_auction_id, NULL, NULL, 'Pembayaran lelang yang dimenangkan', auth.uid(), NULL);
    END IF;
    INSERT INTO public.transactions(auction_id, winner_id, seller_id, final_price, payment_status, payment_deadline)
    VALUES (p_auction_id, v_auction.highest_bidder_id, v_auction.seller_id,
      v_auction.current_highest_bid, 'Awaiting Payment', now() + make_interval(hours => v_hours))
    ON CONFLICT (auction_id) DO NOTHING;
    UPDATE public.auctions SET status = 'Completed',
      actual_end_time = COALESCE(actual_end_time, end_time), completed_at = now()
    WHERE id = p_auction_id;
    INSERT INTO public.notifications(user_id, auction_id, type, title, message)
    VALUES (v_auction.highest_bidder_id, p_auction_id, 'auction_won', 'You won this auction',
      'Selamat! Anda memenangkan "' || v_auction.title || '".');
    RETURN jsonb_build_object('success', true, 'status', 'Completed',
      'winner_id', v_auction.highest_bidder_id, 'final_price', v_auction.current_highest_bid);
  ELSE
    UPDATE public.auctions SET status = 'No Winner',
      actual_end_time = COALESCE(actual_end_time, end_time), completed_at = now()
    WHERE id = p_auction_id;
    RETURN jsonb_build_object('success', true, 'status', 'No Winner');
  END IF;
END; $$;

-- close_expired_auctions now settles wallets via finalize_auction
CREATE OR REPLACE FUNCTION public.close_expired_auctions()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_done integer := 0;
BEGIN
  FOR v_id IN
    SELECT id FROM public.auctions WHERE status = 'Live' AND end_time <= now() ORDER BY end_time ASC
  LOOP
    PERFORM public.finalize_auction(v_id);
    v_done := v_done + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'finalized', v_done);
END; $$;

-- 15. ADMIN LIVE CONTROLS
CREATE OR REPLACE FUNCTION public.admin_end_auction(p_auction_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_auction public.auctions%ROWTYPE; v_result jsonb;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can end auctions');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.status NOT IN ('Live','Paused') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction is not active');
  END IF;
  INSERT INTO public.auction_admin_actions(auction_id, admin_id, action_type, previous_values, new_values, reason)
  VALUES (p_auction_id, auth.uid(), 'end',
    jsonb_build_object('end_time', v_auction.end_time, 'status', v_auction.status),
    jsonb_build_object('end_time', now()), p_reason);
  UPDATE public.auctions SET end_time = now(), actual_end_time = now() WHERE id = p_auction_id;
  v_result := public.finalize_auction(p_auction_id);
  RETURN jsonb_build_object('success', true, 'finalize', v_result);
END; $$;

CREATE OR REPLACE FUNCTION public.admin_extend_auction(p_auction_id uuid, p_minutes integer, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_auction public.auctions%ROWTYPE; v_new_end timestamptz;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can extend auctions');
  END IF;
  IF p_minutes IS NULL OR p_minutes <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Extension minutes must be greater than zero');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.status <> 'Live' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only live auctions can be extended');
  END IF;
  v_new_end := v_auction.end_time + make_interval(mins => p_minutes);
  UPDATE public.auctions SET end_time = v_new_end WHERE id = p_auction_id;
  INSERT INTO public.auction_admin_actions(auction_id, admin_id, action_type, previous_values, new_values, reason)
  VALUES (p_auction_id, auth.uid(), 'extend',
    jsonb_build_object('end_time', v_auction.end_time),
    jsonb_build_object('end_time', v_new_end, 'added_minutes', p_minutes), p_reason);
  RETURN jsonb_build_object('success', true, 'previous_end_time', v_auction.end_time, 'new_end_time', v_new_end);
END; $$;

CREATE OR REPLACE FUNCTION public.admin_pause_auction(p_auction_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_auction public.auctions%ROWTYPE; v_remaining bigint;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can pause auctions');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.status <> 'Live' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only live auctions can be paused');
  END IF;
  v_remaining := GREATEST(0, EXTRACT(EPOCH FROM (v_auction.end_time - now()))::bigint);
  UPDATE public.auctions SET status = 'Paused' WHERE id = p_auction_id;
  INSERT INTO public.auction_pause_history(auction_id, remaining_seconds, paused_by, reason)
  VALUES (p_auction_id, v_remaining, auth.uid(), p_reason);
  INSERT INTO public.auction_admin_actions(auction_id, admin_id, action_type, previous_values, new_values, reason)
  VALUES (p_auction_id, auth.uid(), 'pause',
    jsonb_build_object('status', 'Live'), jsonb_build_object('status', 'Paused', 'remaining_seconds', v_remaining), p_reason);
  INSERT INTO public.notifications(user_id, auction_id, type, title, message)
  SELECT DISTINCT bidder_id, p_auction_id, 'general', 'Auction paused',
    'Lelang "' || v_auction.title || '" dijeda sementara oleh admin.'
  FROM public.bids WHERE auction_id = p_auction_id;
  RETURN jsonb_build_object('success', true, 'remaining_seconds', v_remaining);
END; $$;

CREATE OR REPLACE FUNCTION public.admin_resume_auction(p_auction_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_auction public.auctions%ROWTYPE; v_pause public.auction_pause_history%ROWTYPE; v_new_end timestamptz;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can resume auctions');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.status <> 'Paused' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only paused auctions can be resumed');
  END IF;
  SELECT * INTO v_pause FROM public.auction_pause_history
  WHERE auction_id = p_auction_id AND resumed_at IS NULL ORDER BY paused_at DESC LIMIT 1;
  IF NOT FOUND OR v_pause.remaining_seconds IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No open pause record found');
  END IF;
  v_new_end := now() + make_interval(secs => v_pause.remaining_seconds::double precision);
  UPDATE public.auctions SET status = 'Live', end_time = v_new_end WHERE id = p_auction_id;
  UPDATE public.auction_pause_history SET resumed_at = now(), resumed_by = auth.uid() WHERE id = v_pause.id;
  INSERT INTO public.auction_admin_actions(auction_id, admin_id, action_type, previous_values, new_values, reason)
  VALUES (p_auction_id, auth.uid(), 'resume',
    jsonb_build_object('status', 'Paused'), jsonb_build_object('status', 'Live', 'end_time', v_new_end), p_reason);
  RETURN jsonb_build_object('success', true, 'new_end_time', v_new_end);
END; $$;

CREATE OR REPLACE FUNCTION public.admin_cancel_auction(p_auction_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_auction public.auctions%ROWTYPE;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can cancel auctions');
  END IF;
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cancellation reason is required');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.status IN ('Completed','Cancelled','No Winner') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction is already finished');
  END IF;
  PERFORM public.release_bid_reservation(p_auction_id);
  UPDATE public.auctions SET status = 'Cancelled', actual_end_time = now(), completed_at = now()
  WHERE id = p_auction_id;
  INSERT INTO public.auction_admin_actions(auction_id, admin_id, action_type, previous_values, new_values, reason)
  VALUES (p_auction_id, auth.uid(), 'cancel',
    jsonb_build_object('status', v_auction.status), jsonb_build_object('status', 'Cancelled'), p_reason);
  INSERT INTO public.notifications(user_id, auction_id, type, title, message)
  SELECT DISTINCT bidder_id, p_auction_id, 'general', 'Auction cancelled',
    'Lelang "' || v_auction.title || '" dibatalkan oleh admin. Dana reservasi Anda dikembalikan.'
  FROM public.bids WHERE auction_id = p_auction_id;
  RETURN jsonb_build_object('success', true, 'status', 'Cancelled');
END; $$;

-- 16. GRANTS (RLS still applies for reads; functions are the only write path)
REVOKE ALL ON FUNCTION public.admin_add_wallet_balance(uuid, bigint, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_deduct_wallet_balance(uuid, bigint, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.place_bid_with_wallet(uuid, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.release_bid_reservation(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_auction(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_end_auction(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_extend_auction(uuid, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_pause_auction(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_resume_auction(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_cancel_auction(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_user_wallet(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_add_wallet_balance(uuid, bigint, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_deduct_wallet_balance(uuid, bigint, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_bid_with_wallet(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_bid_reservation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_auction(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_end_auction(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_extend_auction(uuid, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_pause_auction(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resume_auction(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_cancel_auction(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_user_wallet(uuid) TO authenticated;
