-- ============================================================
-- WEBSITE LELANG — SUPABASE MIGRATION (PostgreSQL)
-- File: supabase-migration-website-lelang.sql
-- ============================================================
-- CARA MENJALANKAN:
-- 1) Supabase SQL Editor (paling mudah):
--    Dashboard > SQL Editor > New query > paste seluruh file
--    ini > Run. Jalankan SEKALI pada project kosong.
--    File ini memakai IF NOT EXISTS / ON CONFLICT di banyak
--    tempat agar aman diulang untuk bagian non-enum/tabel,
--    tapi enum & policy perlu di-drop manual bila mau reset total.
-- 2) Supabase CLI:
--    supabase db push   (letakkan file ini di
--    supabase/migrations/<timestamp>_website_lelang.sql)
--    atau: psql "$DATABASE_URL" -f supabase-migration-website-lelang.sql
--
-- ENV UNTUK FRONTEND (Vite) — .env.local, JANGAN commit:
--    VITE_SUPABASE_URL=https://<project-ref>.supabase.co
--    VITE_SUPABASE_ANON_KEY=<anon public key dari Dashboard>
--
-- BOOTSTRAP ADMIN PERTAMA:
--    1. Register user biasa lewat aplikasi / Auth Dashboard.
--    2. Profil otomatis dibuat oleh trigger on_auth_user_created.
--    3. Di SQL Editor jalankan (ganti email sesuai user Anda):
--       UPDATE public.profiles SET role = 'admin'
--       WHERE email = 'admin@example.com';
--    Hanya lakukan ini dari SQL Editor / service_role.
--
-- PERINGATAN KEAMANAN:
--    JANGAN PERNAH expose SUPABASE_SERVICE_ROLE_KEY di frontend.
--    service_role bypass semua RLS. Frontend HANYA boleh pakai
--    anon key + RLS di file ini. service_role hanya untuk
--    server / Edge Function / SQL Editor.
-- ============================================================

-- 1. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. ENUM TYPES
DO $$ BEGIN
  CREATE TYPE public.user_role AS ENUM ('user','seller','admin');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.account_status AS ENUM ('active','suspended','pending_verification','banned');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.auction_status AS ENUM (
    'Draft','Pending Approval','Scheduled','Live','Paused',
    'Completed','Cancelled','No Winner'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.payment_status AS ENUM (
    'Awaiting Payment','Payment Submitted','Under Review',
    'Paid','Rejected','Expired','Cancelled'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE TYPE public.notification_type AS ENUM (
    'bid_placed','outbid','auction_won','auction_lost',
    'auction_ending_soon','payment_reminder','payment_confirmed',
    'auction_approved','auction_rejected','general'
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 3. HELPER: updated_at trigger
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END; $$;

-- 4. TABLE: profiles (1-1 dengan auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username text UNIQUE,
  full_name text,
  email text UNIQUE,
  phone text,
  avatar_url text,
  role public.user_role NOT NULL DEFAULT 'user',
  account_status public.account_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT profiles_username_len CHECK (username IS NULL OR char_length(username) >= 3)
);

-- 5. TABLE: categories
CREATE TABLE IF NOT EXISTS public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  slug text NOT NULL UNIQUE,
  description text,
  image_url text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 6. TABLE: auctions
CREATE TABLE IF NOT EXISTS public.auctions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category_id uuid REFERENCES public.categories(id) ON DELETE SET NULL,
  title text NOT NULL,
  slug text NOT NULL UNIQUE,
  description text,
  condition text,
  location text,
  starting_price bigint NOT NULL CHECK (starting_price >= 0),
  current_highest_bid bigint CHECK (current_highest_bid IS NULL OR current_highest_bid >= 0),
  minimum_increment bigint NOT NULL DEFAULT 10000 CHECK (minimum_increment > 0),
  buy_now_price bigint CHECK (buy_now_price IS NULL OR buy_now_price >= 0),
  highest_bidder_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  start_time timestamptz NOT NULL,
  end_time timestamptz NOT NULL,
  status public.auction_status NOT NULL DEFAULT 'Draft',
  is_featured boolean NOT NULL DEFAULT false,
  view_count bigint NOT NULL DEFAULT 0 CHECK (view_count >= 0),
  anti_sniping_enabled boolean NOT NULL DEFAULT true,
  extension_threshold_seconds integer NOT NULL DEFAULT 30 CHECK (extension_threshold_seconds >= 0),
  extension_duration_seconds integer NOT NULL DEFAULT 120 CHECK (extension_duration_seconds > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT auctions_time_order CHECK (end_time > start_time),
  CONSTRAINT auctions_bid_gte_start CHECK (
    current_highest_bid IS NULL OR current_highest_bid >= starting_price)
);

-- 7. TABLE: auction_images
CREATE TABLE IF NOT EXISTS public.auction_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auction_id uuid NOT NULL REFERENCES public.auctions(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  storage_path text,
  is_primary boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 8. TABLE: bids
-- Direct INSERT dari client sengaja TIDAK diberi policy:
-- semua bid wajib lewat RPC place_bid() (SECURITY DEFINER).
CREATE TABLE IF NOT EXISTS public.bids (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auction_id uuid NOT NULL REFERENCES public.auctions(id) ON DELETE CASCADE,
  bidder_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount bigint NOT NULL CHECK (amount >= 0),
  bid_sequence integer NOT NULL CHECK (bid_sequence > 0),
  is_auto_bid boolean NOT NULL DEFAULT false,
  max_auto_bid_amount bigint CHECK (max_auto_bid_amount IS NULL OR max_auto_bid_amount >= amount),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT bids_unique_sequence UNIQUE (auction_id, bid_sequence)
);

-- 9. TABLE: watchlists
CREATE TABLE IF NOT EXISTS public.watchlists (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  auction_id uuid NOT NULL REFERENCES public.auctions(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT watchlists_unique UNIQUE (user_id, auction_id)
);

-- 10. TABLE: notifications
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  auction_id uuid REFERENCES public.auctions(id) ON DELETE SET NULL,
  type public.notification_type NOT NULL DEFAULT 'general',
  title text NOT NULL,
  message text NOT NULL,
  is_read boolean NOT NULL DEFAULT false,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 11. TABLE: transactions (satu transaksi per lelang selesai)
CREATE TABLE IF NOT EXISTS public.transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auction_id uuid NOT NULL UNIQUE REFERENCES public.auctions(id) ON DELETE CASCADE,
  winner_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  seller_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  final_price bigint NOT NULL CHECK (final_price >= 0),
  payment_status public.payment_status NOT NULL DEFAULT 'Awaiting Payment',
  payment_method text,
  payment_deadline timestamptz,
  paid_at timestamptz,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 12. TABLE: payment_proofs (PRIVAT — lihat Storage & RLS)
CREATE TABLE IF NOT EXISTS public.payment_proofs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL REFERENCES public.transactions(id) ON DELETE CASCADE,
  uploader_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  file_url text NOT NULL,
  storage_path text,
  file_name text,
  notes text,
  reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  review_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- 13. TABLE: admin_audit_logs
CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  action text NOT NULL,
  target_table text NOT NULL,
  target_id uuid,
  old_values jsonb,
  new_values jsonb,
  ip_address inet,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 14. TABLE: platform_settings (key-value, value = JSONB)
CREATE TABLE IF NOT EXISTS public.platform_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  setting_key text NOT NULL UNIQUE,
  setting_value jsonb NOT NULL DEFAULT '{}'::jsonb,
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.platform_settings (setting_key, setting_value, description) VALUES
  ('site_name', '"AuctionPro"'::jsonb, 'Nama platform'),
  ('default_minimum_increment', '10000'::jsonb, 'Kenaikan bid default (IDR)'),
  ('payment_deadline_hours', '72'::jsonb, 'Batas bayar pemenang (jam)'),
  ('anti_sniping_threshold_seconds', '30'::jsonb, 'Ambang anti-sniping (detik)'),
  ('anti_sniping_extension_seconds', '120'::jsonb, 'Perpanjangan anti-sniping (detik)'),
  ('platform_fee_percent', '0'::jsonb, 'Fee platform (%) — ubah sesuai kebijakan')
ON CONFLICT (setting_key) DO NOTHING;

-- 15. INDEXES
CREATE INDEX IF NOT EXISTS idx_auctions_status ON public.auctions(status);
CREATE INDEX IF NOT EXISTS idx_auctions_end_time ON public.auctions(end_time);
CREATE INDEX IF NOT EXISTS idx_auctions_category_id ON public.auctions(category_id);
CREATE INDEX IF NOT EXISTS idx_auctions_current_highest_bid ON public.auctions(current_highest_bid);
CREATE INDEX IF NOT EXISTS idx_auctions_seller_id ON public.auctions(seller_id);
CREATE INDEX IF NOT EXISTS idx_auctions_start_time ON public.auctions(start_time);
CREATE INDEX IF NOT EXISTS idx_auction_images_auction_id ON public.auction_images(auction_id);
CREATE INDEX IF NOT EXISTS idx_bids_auction_created ON public.bids(auction_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bids_bidder_id ON public.bids(bidder_id);
CREATE INDEX IF NOT EXISTS idx_notifications_user_read ON public.notifications(user_id, is_read);
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_watchlists_user_id ON public.watchlists(user_id);
CREATE INDEX IF NOT EXISTS idx_watchlists_auction_id ON public.watchlists(auction_id);
CREATE INDEX IF NOT EXISTS idx_transactions_winner_id ON public.transactions(winner_id);
CREATE INDEX IF NOT EXISTS idx_transactions_seller_id ON public.transactions(seller_id);
CREATE INDEX IF NOT EXISTS idx_transactions_payment_status ON public.transactions(payment_status);
CREATE INDEX IF NOT EXISTS idx_payment_proofs_transaction_id ON public.payment_proofs(transaction_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_admin_id ON public.admin_audit_logs(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_target ON public.admin_audit_logs(target_table, target_id);

-- 16. updated_at TRIGGERS
DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS trg_categories_updated_at ON public.categories;
CREATE TRIGGER trg_categories_updated_at BEFORE UPDATE ON public.categories
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS trg_auctions_updated_at ON public.auctions;
CREATE TRIGGER trg_auctions_updated_at BEFORE UPDATE ON public.auctions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS trg_auction_images_updated_at ON public.auction_images;
CREATE TRIGGER trg_auction_images_updated_at BEFORE UPDATE ON public.auction_images
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS trg_notifications_updated_at ON public.notifications;
CREATE TRIGGER trg_notifications_updated_at BEFORE UPDATE ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS trg_transactions_updated_at ON public.transactions;
CREATE TRIGGER trg_transactions_updated_at BEFORE UPDATE ON public.transactions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS trg_payment_proofs_updated_at ON public.payment_proofs;
CREATE TRIGGER trg_payment_proofs_updated_at BEFORE UPDATE ON public.payment_proofs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
DROP TRIGGER IF EXISTS trg_platform_settings_updated_at ON public.platform_settings;
CREATE TRIGGER trg_platform_settings_updated_at BEFORE UPDATE ON public.platform_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 17. AUTO-CREATE PROFILE saat user register di auth.users
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, username, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', ''),
    NULLIF(NEW.raw_user_meta_data ->> 'username', ''),
    NULLIF(NEW.raw_user_meta_data ->> 'avatar_url', '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 18. HELPER RLS: cek admin TANPA rekursi (SECURITY DEFINER)
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;

CREATE OR REPLACE FUNCTION public.is_seller_or_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('seller','admin')
  );
$$;

-- 19. CEGAH user mengubah role / account_status sendiri
CREATE OR REPLACE FUNCTION public.prevent_role_self_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF (NEW.role IS DISTINCT FROM OLD.role
      OR NEW.account_status IS DISTINCT FROM OLD.account_status)
     AND NOT public.is_admin()
     AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'Only admin can change role or account_status';
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_prevent_role_change ON public.profiles;
CREATE TRIGGER trg_prevent_role_change BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.prevent_role_self_change();

-- ============================================================
-- 20. RPC: place_bid — SATU-SATUNYA jalur resmi memasang bid
-- ============================================================
-- Rules:
--  * Must be signed in (auth.uid()).
--  * Auction row is locked FOR UPDATE (race-condition safe).
--  * Auction must be Live, already started, not yet ended.
--  * Seller cannot bid on their own auction.
--  * First bid: amount >= starting_price.
--    Next bids:  amount >= current_highest_bid + minimum_increment.
--  * Anti-sniping: if a valid bid lands within
--    extension_threshold_seconds of end_time, end_time is
--    extended by extension_duration_seconds.
-- Returns JSONB: {success:true, bid_id, amount, bid_sequence,
--   current_highest_bid, end_time, extended}
--   or {success:false, error:'<clear reason>'}
CREATE OR REPLACE FUNCTION public.place_bid(p_auction_id uuid, p_amount bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user uuid := auth.uid();
  v_auction public.auctions%ROWTYPE;
  v_required bigint;
  v_sequence integer;
  v_bid_id uuid;
  v_prev_bidder uuid;
  v_new_end timestamptz;
  v_extended boolean := false;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You must be signed in to place a bid');
  END IF;
  IF p_amount IS NULL OR p_amount < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bid amount must be a positive number');
  END IF;

  SELECT * INTO v_auction FROM public.auctions
  WHERE id = p_auction_id FOR UPDATE;

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
  IF v_auction.current_highest_bid IS NULL THEN
    v_required := v_auction.starting_price;
  ELSE
    v_required := v_auction.current_highest_bid + v_auction.minimum_increment;
  END IF;
  IF p_amount < v_required THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Bid is too low', 'minimum_required', v_required);
  END IF;
  IF v_prev_bidder = v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are already the highest bidder');
  END IF;

  SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence
  FROM public.bids WHERE auction_id = p_auction_id;

  INSERT INTO public.bids (auction_id, bidder_id, amount, bid_sequence)
  VALUES (p_auction_id, v_user, p_amount, v_sequence)
  RETURNING id INTO v_bid_id;

  v_new_end := v_auction.end_time;
  IF v_auction.anti_sniping_enabled
     AND v_auction.end_time - now() <= make_interval(secs => v_auction.extension_threshold_seconds) THEN
    v_new_end := v_auction.end_time + make_interval(secs => v_auction.extension_duration_seconds);
    v_extended := true;
  END IF;

  UPDATE public.auctions
  SET current_highest_bid = p_amount,
      highest_bidder_id = v_user,
      end_time = v_new_end
  WHERE id = p_auction_id;

  IF v_prev_bidder IS NOT NULL AND v_prev_bidder <> v_user THEN
    INSERT INTO public.notifications (user_id, auction_id, type, title, message, metadata)
    VALUES (v_prev_bidder, p_auction_id, 'outbid', 'You have been outbid',
      'Someone placed a higher bid on "' || v_auction.title || '".',
      jsonb_build_object('amount', p_amount, 'bid_id', v_bid_id));
  END IF;

  INSERT INTO public.notifications (user_id, auction_id, type, title, message, metadata)
  VALUES (v_auction.seller_id, p_auction_id, 'bid_placed', 'New bid on your auction',
    'A new bid was placed on "' || v_auction.title || '".',
    jsonb_build_object('amount', p_amount, 'bid_id', v_bid_id));

  RETURN jsonb_build_object('success', true, 'bid_id', v_bid_id,
    'auction_id', p_auction_id, 'amount', p_amount,
    'bid_sequence', v_sequence, 'current_highest_bid', p_amount,
    'highest_bidder_id', v_user, 'end_time', v_new_end,
    'extended', v_extended);
END; $$;

REVOKE ALL ON FUNCTION public.place_bid(uuid, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.place_bid(uuid, bigint) TO authenticated;

-- ============================================================
-- 21. RPC: close_expired_auctions — IDEMPOTENT
-- ============================================================
-- Call from pg_cron, Edge Function cron, or manually:
--   SELECT public.close_expired_auctions();
-- Safe to call repeatedly: status changes once, and
-- transactions.auction_id is UNIQUE + ON CONFLICT DO NOTHING,
-- so a winner transaction / notification is never duplicated
-- for an auction that is already Completed / No Winner.
CREATE OR REPLACE FUNCTION public.close_expired_auctions()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row public.auctions%ROWTYPE;
  v_completed integer := 0;
  v_no_winner integer := 0;
  v_deadline timestamptz;
  v_hours integer := 72;
BEGIN
  SELECT COALESCE((setting_value #>> '{}')::integer, 72) INTO v_hours
  FROM public.platform_settings WHERE setting_key = 'payment_deadline_hours';
  IF v_hours IS NULL THEN v_hours := 72; END IF;

  FOR v_row IN
    SELECT * FROM public.auctions
    WHERE status = 'Live' AND end_time <= now()
    ORDER BY end_time ASC
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_row.highest_bidder_id IS NOT NULL AND v_row.current_highest_bid IS NOT NULL THEN
      v_deadline := now() + make_interval(hours => v_hours);
      UPDATE public.auctions SET status = 'Completed' WHERE id = v_row.id;

      INSERT INTO public.transactions
        (auction_id, winner_id, seller_id, final_price, payment_status, payment_deadline)
      VALUES (v_row.id, v_row.highest_bidder_id, v_row.seller_id,
              v_row.current_highest_bid, 'Awaiting Payment', v_deadline)
      ON CONFLICT (auction_id) DO NOTHING;

      INSERT INTO public.notifications (user_id, auction_id, type, title, message, metadata)
      VALUES (v_row.highest_bidder_id, v_row.id, 'auction_won', 'You won this auction',
        'You won "' || v_row.title || '". Please complete payment before the deadline.',
        jsonb_build_object('final_price', v_row.current_highest_bid, 'payment_deadline', v_deadline));
      v_completed := v_completed + 1;
    ELSE
      UPDATE public.auctions SET status = 'No Winner' WHERE id = v_row.id;
      INSERT INTO public.notifications (user_id, auction_id, type, title, message)
      VALUES (v_row.seller_id, v_row.id, 'general', 'Auction ended with no winner',
        'Your auction "' || v_row.title || '" ended without any bids.');
      v_no_winner := v_no_winner + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true,
    'completed_with_winner', v_completed, 'no_winner', v_no_winner);
END; $$;

REVOKE ALL ON FUNCTION public.close_expired_auctions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.close_expired_auctions() TO authenticated, service_role;
-- NOTE: In production, restrict this further (admin / cron only)
-- e.g. schedule with pg_cron as postgres, not from the client.

-- Optional pg_cron example (enable pg_cron in Dashboard first):
-- SELECT cron.schedule('close-expired-auctions', '* * * * *',
--   $$ SELECT public.close_expired_auctions(); $$);

-- ============================================================
-- 22. ROW LEVEL SECURITY — enable on ALL tables
-- ============================================================
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auctions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auction_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bids ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.watchlists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_proofs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_settings ENABLE ROW LEVEL SECURITY;

-- Helper for re-runnable policies
CREATE OR REPLACE FUNCTION public._drop_policy(p_table text, p_policy text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', p_policy, p_table);
END; $$;

-- ---- profiles ----
SELECT public._drop_policy('profiles','profiles_select_public');
CREATE POLICY profiles_select_public ON public.profiles
  FOR SELECT USING (true);
SELECT public._drop_policy('profiles','profiles_insert_own');
CREATE POLICY profiles_insert_own ON public.profiles
  FOR INSERT WITH CHECK (auth.uid() = id);
SELECT public._drop_policy('profiles','profiles_update_own_or_admin');
CREATE POLICY profiles_update_own_or_admin ON public.profiles
  FOR UPDATE USING (auth.uid() = id OR public.is_admin())
  WITH CHECK (auth.uid() = id OR public.is_admin());
-- Role/account_status self-change is blocked by trigger in §19.
SELECT public._drop_policy('profiles','profiles_admin_delete');
CREATE POLICY profiles_admin_delete ON public.profiles
  FOR DELETE USING (public.is_admin());

-- ---- categories ----
SELECT public._drop_policy('categories','categories_select_public');
CREATE POLICY categories_select_public ON public.categories
  FOR SELECT USING (is_active = true OR public.is_admin());
SELECT public._drop_policy('categories','categories_admin_write');
CREATE POLICY categories_admin_write ON public.categories
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

-- ---- auctions ----
-- Public can read published auctions only. Draft / Pending
-- Approval are private to seller + admin.
SELECT public._drop_policy('auctions','auctions_select_public');
CREATE POLICY auctions_select_public ON public.auctions
  FOR SELECT USING (
    status IN ('Scheduled','Live','Paused','Completed','Cancelled','No Winner')
    OR seller_id = auth.uid() OR public.is_admin()
  );
SELECT public._drop_policy('auctions','auctions_insert_seller');
CREATE POLICY auctions_insert_seller ON public.auctions
  FOR INSERT WITH CHECK (seller_id = auth.uid());
SELECT public._drop_policy('auctions','auctions_update_seller_or_admin');
CREATE POLICY auctions_update_seller_or_admin ON public.auctions
  FOR UPDATE USING (seller_id = auth.uid() OR public.is_admin())
  WITH CHECK (seller_id = auth.uid() OR public.is_admin());
SELECT public._drop_policy('auctions','auctions_delete_seller_draft_or_admin');
CREATE POLICY auctions_delete_seller_draft_or_admin ON public.auctions
  FOR DELETE USING (
    public.is_admin() OR (seller_id = auth.uid() AND status = 'Draft')
  );

-- ---- auction_images ----
SELECT public._drop_policy('auction_images','auction_images_select_public');
CREATE POLICY auction_images_select_public ON public.auction_images
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM public.auctions a WHERE a.id = auction_id
    AND (a.status IN ('Scheduled','Live','Paused','Completed','Cancelled','No Winner')
         OR a.seller_id = auth.uid() OR public.is_admin())
  ));
SELECT public._drop_policy('auction_images','auction_images_write_seller_or_admin');
CREATE POLICY auction_images_write_seller_or_admin ON public.auction_images
  FOR ALL USING (EXISTS (
    SELECT 1 FROM public.auctions a WHERE a.id = auction_id
    AND (a.seller_id = auth.uid() OR public.is_admin())
  )) WITH CHECK (EXISTS (
    SELECT 1 FROM public.auctions a WHERE a.id = auction_id
    AND (a.seller_id = auth.uid() OR public.is_admin())
  ));

-- ---- bids (read-only for clients; writes only via place_bid) ----
SELECT public._drop_policy('bids','bids_select_public');
CREATE POLICY bids_select_public ON public.bids
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM public.auctions a WHERE a.id = auction_id
    AND (a.status IN ('Scheduled','Live','Paused','Completed','Cancelled','No Winner')
         OR a.seller_id = auth.uid() OR public.is_admin())
  ) OR bidder_id = auth.uid());
-- No INSERT/UPDATE/DELETE policy on purpose: place_bid()
-- is SECURITY DEFINER and bypasses RLS, direct writes are denied.

-- ---- watchlists (own rows only) ----
SELECT public._drop_policy('watchlists','watchlists_own');
CREATE POLICY watchlists_own ON public.watchlists
  FOR ALL USING (user_id = auth.uid() OR public.is_admin())
  WITH CHECK (user_id = auth.uid());

-- ---- notifications (own rows only) ----
SELECT public._drop_policy('notifications','notifications_select_own');
CREATE POLICY notifications_select_own ON public.notifications
  FOR SELECT USING (user_id = auth.uid() OR public.is_admin());
SELECT public._drop_policy('notifications','notifications_update_own');
CREATE POLICY notifications_update_own ON public.notifications
  FOR UPDATE USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
SELECT public._drop_policy('notifications','notifications_delete_own');
CREATE POLICY notifications_delete_own ON public.notifications
  FOR DELETE USING (user_id = auth.uid() OR public.is_admin());
-- Inserts come from place_bid / close_expired_auctions
-- (SECURITY DEFINER) or admin — no client INSERT policy.

-- ---- transactions ----
SELECT public._drop_policy('transactions','transactions_select_involved');
CREATE POLICY transactions_select_involved ON public.transactions
  FOR SELECT USING (winner_id = auth.uid() OR seller_id = auth.uid() OR public.is_admin());
SELECT public._drop_policy('transactions','transactions_update_admin');
CREATE POLICY transactions_update_admin ON public.transactions
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());
-- Winner may only move Awaiting Payment -> Payment Submitted:
SELECT public._drop_policy('transactions','transactions_winner_submit_payment');
CREATE POLICY transactions_winner_submit_payment ON public.transactions
  FOR UPDATE USING (winner_id = auth.uid() AND payment_status = 'Awaiting Payment')
  WITH CHECK (winner_id = auth.uid() AND payment_status IN ('Awaiting Payment','Payment Submitted'));
-- Inserts only via close_expired_auctions (SECURITY DEFINER).

-- ---- payment_proofs (PRIVATE) ----
SELECT public._drop_policy('payment_proofs','payment_proofs_select_involved');
CREATE POLICY payment_proofs_select_involved ON public.payment_proofs
  FOR SELECT USING (
    uploader_id = auth.uid() OR public.is_admin() OR EXISTS (
      SELECT 1 FROM public.transactions t WHERE t.id = transaction_id
      AND t.seller_id = auth.uid()
    )
  );
SELECT public._drop_policy('payment_proofs','payment_proofs_insert_winner');
CREATE POLICY payment_proofs_insert_winner ON public.payment_proofs
  FOR INSERT WITH CHECK (
    uploader_id = auth.uid() AND EXISTS (
      SELECT 1 FROM public.transactions t WHERE t.id = transaction_id
      AND t.winner_id = auth.uid()
    )
  );
SELECT public._drop_policy('payment_proofs','payment_proofs_update_admin');
CREATE POLICY payment_proofs_update_admin ON public.payment_proofs
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());

-- ---- admin_audit_logs (admin only) ----
SELECT public._drop_policy('admin_audit_logs','admin_audit_logs_admin_all');
CREATE POLICY admin_audit_logs_admin_all ON public.admin_audit_logs
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

-- ---- platform_settings ----
SELECT public._drop_policy('platform_settings','platform_settings_select_public');
CREATE POLICY platform_settings_select_public ON public.platform_settings
  FOR SELECT USING (true);
SELECT public._drop_policy('platform_settings','platform_settings_admin_write');
CREATE POLICY platform_settings_admin_write ON public.platform_settings
  FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP FUNCTION IF EXISTS public._drop_policy(text, text);

-- 23. GRANTS (RLS still controls row access)
GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.profiles, public.categories, public.auctions,
  public.auction_images, public.watchlists, public.notifications,
  public.transactions, public.payment_proofs,
  public.admin_audit_logs, public.platform_settings
  TO authenticated;
GRANT SELECT ON public.profiles, public.categories, public.auctions,
  public.auction_images, public.bids, public.platform_settings TO anon;
GRANT SELECT, UPDATE, DELETE ON public.bids TO authenticated;
-- bids INSERT intentionally NOT granted for direct client writes.

-- ============================================================
-- 24. STORAGE BUCKETS
-- ============================================================
INSERT INTO storage.buckets (id, name, public) VALUES
  ('auction-images', 'auction-images', true),
  ('category-images', 'category-images', true),
  ('user-avatars', 'user-avatars', true),
  ('payment-proofs', 'payment-proofs', false)  -- PRIVATE
ON CONFLICT (id) DO NOTHING;

-- Storage policies on storage.objects:
-- Public buckets: anyone can READ, only the owner folder
-- (<auth.uid()>/...) or admin can WRITE.
-- payment-proofs: NO public read. Only uploader (own folder),
-- the transaction's seller, and admin can read via signed URLs.
DO $$ BEGIN
  CREATE POLICY "auction-images public read" ON storage.objects
    FOR SELECT USING (bucket_id = 'auction-images');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "auction-images owner write" ON storage.objects
    FOR INSERT WITH CHECK (bucket_id = 'auction-images'
      AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "auction-images owner update delete" ON storage.objects
    FOR ALL USING (bucket_id = 'auction-images'
      AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "category-images public read" ON storage.objects
    FOR SELECT USING (bucket_id = 'category-images');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "category-images admin write" ON storage.objects
    FOR ALL USING (bucket_id = 'category-images' AND public.is_admin())
    WITH CHECK (bucket_id = 'category-images' AND public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "user-avatars public read" ON storage.objects
    FOR SELECT USING (bucket_id = 'user-avatars');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "user-avatars owner write" ON storage.objects
    FOR ALL USING (bucket_id = 'user-avatars'
      AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin()))
    WITH CHECK (bucket_id = 'user-avatars'
      AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "payment-proofs private read" ON storage.objects
    FOR SELECT USING (bucket_id = 'payment-proofs'
      AND (auth.uid()::text = (storage.foldername(name))[1] OR public.is_admin()));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "payment-proofs owner write" ON storage.objects
    FOR INSERT WITH CHECK (bucket_id = 'payment-proofs'
      AND auth.uid()::text = (storage.foldername(name))[1]);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE POLICY "payment-proofs admin manage" ON storage.objects
    FOR ALL USING (bucket_id = 'payment-proofs' AND public.is_admin())
    WITH CHECK (bucket_id = 'payment-proofs' AND public.is_admin());
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- NOTE on folder convention:
-- Upload payment proofs to: payment-proofs/<winner_uid>/<tx_id>-<file>
-- Upload auction images to:  auction-images/<seller_uid>/<auction_id>-<file>
-- Upload avatars to:         user-avatars/<user_uid>/avatar.<ext>
-- If your app uploads without a uid folder, adjust the policies
-- above instead of making payment-proofs public.

-- ============================================================
-- 25. REALTIME (optional — uncomment if the UI needs live bids)
-- ============================================================
-- ALTER PUBLICATION supabase_realtime ADD TABLE public.auctions;
-- ALTER PUBLICATION supabase_realtime ADD TABLE public.bids;
-- ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;

-- ============================================================
-- QUICK SMOKE TEST (run manually after migration, optional)
-- ============================================================
-- SELECT public.close_expired_auctions();
-- SELECT tablename, rowsecurity FROM pg_tables
--   WHERE schemaname = 'public' ORDER BY tablename;
-- -- As a signed-in non-owner test user:
-- -- SELECT public.place_bid('<live-auction-uuid>', 150000);
-- ============================================================
-- END OF MIGRATION
-- ============================================================
