-- ============================================================
-- LelangKu Fase 4 — Fitur masukan dosen pembimbing (2026-11-12)
-- Alur persetujuan seller & barang, halaman pre-auction, deposit &
-- penjamin, pembayaran 24 jam + verifikasi admin, biaya admin &
-- pencairan seller, alamat per transaksi, pengiriman & resi,
-- sanksi pemenang tidak membayar, blokir email permanen.
-- ============================================================

-- ---------- 1. Nilai enum notifikasi baru ----------
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'reserve_not_met';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'seller_application';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'seller_approved';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'seller_rejected';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'item_submitted';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'item_approved';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'item_rejected';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'schedule_proposed';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'schedule_approved';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'schedule_rejected';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'payment_proof_submitted';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'payment_rejected';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'fee_approval_requested';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'fee_approved';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'fee_rejected';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'payout_sent';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'address_submitted';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'item_shipped';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'item_received';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'deposit_submitted';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'deposit_verified';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'deposit_rejected';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'account_sanctioned';
ALTER TYPE public.notification_type ADD VALUE IF NOT EXISTS 'payment_expired';

-- ---------- 2. Pengaturan platform ----------
UPDATE public.platform_settings SET setting_value = '24'::jsonb WHERE setting_key = 'payment_deadline_hours';
UPDATE public.platform_settings SET setting_value = '5'::jsonb WHERE setting_key = 'platform_fee_percent';
INSERT INTO public.platform_settings(setting_key, setting_value)
VALUES ('payment_instructions', '"Bayar instan memakai saldo Wallet LelangKu, atau transfer manual ke BCA 8890 1234 56 a.n. LelangKu lalu unggah bukti transfer di halaman Transaksi."'::jsonb)
ON CONFLICT (setting_key) DO NOTHING;

-- ---------- 3. Kolom baru ----------
ALTER TABLE public.auctions ADD COLUMN IF NOT EXISTS min_deposit bigint NOT NULL DEFAULT 0;

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS guarantor_name text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS guarantor_phone text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS guarantor_relation text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS guarantor_address text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS guarantor_id_number text;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS guarantor_completed boolean NOT NULL DEFAULT false;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS banned_until timestamptz;

ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS admin_fee_percent numeric NOT NULL DEFAULT 0;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS admin_fee_amount bigint NOT NULL DEFAULT 0;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS seller_net_amount bigint NOT NULL DEFAULT 0;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS fee_status text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS fee_reject_reason text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS payout_status text NOT NULL DEFAULT 'Belum Cair';
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS payout_at timestamptz;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS rejection_reason text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_recipient_name text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_phone text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_province text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_city text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_district text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_subdistrict text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_postal_code text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_address_detail text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS ship_courier_note text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS address_submitted_at timestamptz;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS courier_name text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS tracking_number text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS shipped_at timestamptz;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS shipping_note text;
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS shipping_status text NOT NULL DEFAULT 'Menunggu Pembayaran';
ALTER TABLE public.transactions ADD COLUMN IF NOT EXISTS received_at timestamptz;

-- ---------- 4. Tabel baru ----------
CREATE TABLE IF NOT EXISTS public.seller_applications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  store_name text,
  description text,
  status text NOT NULL DEFAULT 'Menunggu',
  admin_note text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS seller_applications_one_pending
  ON public.seller_applications(user_id) WHERE status = 'Menunggu';

CREATE TABLE IF NOT EXISTS public.item_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text,
  category_id uuid REFERENCES public.categories(id),
  condition text,
  location text,
  starting_price bigint NOT NULL DEFAULT 0,
  reserve_price bigint,
  buy_now_price bigint,
  image_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  proposed_start_time timestamptz,
  proposed_duration_minutes integer,
  status text NOT NULL DEFAULT 'Menunggu Review',
  admin_start_time timestamptz,
  admin_duration_minutes integer,
  admin_note text,
  schedule_reject_reason text,
  min_deposit bigint NOT NULL DEFAULT 0,
  auction_id uuid REFERENCES public.auctions(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_deposits (
  user_id uuid PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  verified_balance bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.deposit_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  amount bigint NOT NULL,
  proof_url text,
  storage_path text,
  status text NOT NULL DEFAULT 'Menunggu Verifikasi',
  admin_note text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.deposit_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  type text NOT NULL,
  amount bigint NOT NULL,
  balance_after bigint NOT NULL,
  reference_id uuid,
  description text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.blocked_emails (
  email text PRIMARY KEY,
  reason text,
  blocked_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Ledger deposit tidak dapat diubah/dihapus (audit)
CREATE OR REPLACE FUNCTION public._deposit_tx_immutable()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
  RAISE EXCEPTION 'deposit_transactions is immutable';
END; $function$;
DROP TRIGGER IF EXISTS deposit_tx_no_update ON public.deposit_transactions;
CREATE TRIGGER deposit_tx_no_update BEFORE UPDATE OR DELETE ON public.deposit_transactions
  FOR EACH ROW EXECUTE FUNCTION public._deposit_tx_immutable();

-- ---------- 5. RLS ----------
ALTER TABLE public.seller_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_deposits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deposit_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deposit_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocked_emails ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS seller_applications_select ON public.seller_applications;
CREATE POLICY seller_applications_select ON public.seller_applications FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS item_submissions_select ON public.item_submissions;
CREATE POLICY item_submissions_select ON public.item_submissions FOR SELECT
  USING (auth.uid() = seller_id OR public.is_admin());
DROP POLICY IF EXISTS user_deposits_select ON public.user_deposits;
CREATE POLICY user_deposits_select ON public.user_deposits FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS deposit_requests_select ON public.deposit_requests;
CREATE POLICY deposit_requests_select ON public.deposit_requests FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS deposit_transactions_select ON public.deposit_transactions;
CREATE POLICY deposit_transactions_select ON public.deposit_transactions FOR SELECT
  USING (auth.uid() = user_id OR public.is_admin());
DROP POLICY IF EXISTS blocked_emails_admin ON public.blocked_emails;
CREATE POLICY blocked_emails_admin ON public.blocked_emails FOR SELECT
  USING (public.is_admin());

-- ---------- 6. Realtime ----------
ALTER PUBLICATION supabase_realtime ADD TABLE public.seller_applications;
ALTER PUBLICATION supabase_realtime ADD TABLE public.item_submissions;
ALTER PUBLICATION supabase_realtime ADD TABLE public.transactions;
ALTER PUBLICATION supabase_realtime ADD TABLE public.deposit_requests;
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_deposits;

-- ---------- 7. Helper notifikasi admin ----------
CREATE OR REPLACE FUNCTION public._notify_admins(
  p_type public.notification_type, p_title text, p_message text,
  p_auction_id uuid DEFAULT NULL, p_metadata jsonb DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  SELECT id, p_auction_id, p_type, p_title, p_message, COALESCE(p_metadata, '{}'::jsonb)
  FROM public.profiles WHERE role = 'admin';
END; $function$;

-- Hitung biaya admin dari pengaturan platform
CREATE OR REPLACE FUNCTION public._calc_fee(p_tx public.transactions)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_pct numeric := 0;
BEGIN
  SELECT COALESCE((setting_value #>> '{}')::numeric, 0) INTO v_pct
  FROM public.platform_settings WHERE setting_key = 'platform_fee_percent';
  IF v_pct IS NULL THEN v_pct := 0; END IF;
  UPDATE public.transactions SET
    admin_fee_percent = v_pct,
    admin_fee_amount = ROUND(p_tx.final_price * v_pct / 100)::bigint,
    seller_net_amount = p_tx.final_price - ROUND(p_tx.final_price * v_pct / 100)::bigint,
    fee_status = 'Menunggu Persetujuan Seller'
  WHERE id = p_tx.id;
END; $function$;

-- ============================================================
-- 8. Alur pengajuan & persetujuan seller
-- ============================================================
CREATE OR REPLACE FUNCTION public.apply_seller(p_store_name text DEFAULT NULL, p_description text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user uuid := auth.uid(); v_id uuid;
BEGIN
  IF v_user IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Must be logged in'); END IF;
  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user AND role IN ('seller','admin')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Akun Anda sudah memiliki hak seller/admin');
  END IF;
  IF EXISTS (SELECT 1 FROM public.seller_applications WHERE user_id = v_user AND status = 'Menunggu') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Anda masih memiliki pengajuan yang menunggu pemeriksaan admin');
  END IF;
  INSERT INTO public.seller_applications(user_id, store_name, description)
  VALUES (v_user, p_store_name, p_description) RETURNING id INTO v_id;
  PERFORM public._notify_admins('seller_application', 'Permohonan Seller Baru',
    'Ada permohonan menjadi seller yang menunggu pemeriksaan Anda.', NULL,
    jsonb_build_object('application_id', v_id, 'user_id', v_user));
  RETURN jsonb_build_object('success', true, 'application_id', v_id, 'status', 'Menunggu');
END; $function$;

-- become_seller lama dialihkan menjadi pengajuan (menutup celah bypass persetujuan admin)
CREATE OR REPLACE FUNCTION public.become_seller()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.apply_seller(NULL, 'Pengajuan dari Seller Hub');
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_review_seller_application(p_id uuid, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_app public.seller_applications%ROWTYPE;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can review applications');
  END IF;
  SELECT * INTO v_app FROM public.seller_applications WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Application not found'); END IF;
  IF v_app.status <> 'Menunggu' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pengajuan ini sudah diperiksa');
  END IF;
  UPDATE public.seller_applications SET status = CASE WHEN p_approve THEN 'Disetujui' ELSE 'Ditolak' END,
    admin_note = p_note, reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  WHERE id = p_id;
  IF p_approve THEN
    UPDATE public.profiles SET role = 'seller' WHERE id = v_app.user_id AND role = 'user';
    INSERT INTO public.notifications(user_id, type, title, message)
    VALUES (v_app.user_id, 'seller_approved', 'Permohonan Seller Disetujui',
      'Selamat! Permohonan Anda menjadi seller telah disetujui admin. Anda sekarang dapat mengajukan barang untuk dilelang melalui Seller Hub.');
  ELSE
    INSERT INTO public.notifications(user_id, type, title, message)
    VALUES (v_app.user_id, 'seller_rejected', 'Permohonan Seller Ditolak',
      'Permohonan Anda menjadi seller ditolak oleh admin.' || COALESCE(' Catatan admin: ' || p_note, ''));
  END IF;
  RETURN jsonb_build_object('success', true, 'status', CASE WHEN p_approve THEN 'Disetujui' ELSE 'Ditolak' END);
END; $function$;

-- ============================================================
-- 9. Pengajuan barang oleh seller + persetujuan jadwal dua arah
-- ============================================================
CREATE OR REPLACE FUNCTION public.submit_item(
  p_title text, p_description text, p_category_id uuid, p_condition text, p_location text,
  p_starting_price bigint, p_reserve_price bigint, p_buy_now_price bigint,
  p_image_urls jsonb, p_proposed_start_time timestamptz, p_proposed_duration_minutes integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user uuid := auth.uid(); v_id uuid;
BEGIN
  IF v_user IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Must be logged in'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = v_user AND role IN ('seller','admin')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hanya seller terdaftar yang dapat mengajukan barang');
  END IF;
  IF p_title IS NULL OR length(trim(p_title)) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Judul barang wajib diisi');
  END IF;
  INSERT INTO public.item_submissions(seller_id, title, description, category_id, condition, location,
    starting_price, reserve_price, buy_now_price, image_urls, proposed_start_time, proposed_duration_minutes)
  VALUES (v_user, p_title, p_description, p_category_id, p_condition, p_location,
    COALESCE(p_starting_price, 0), p_reserve_price, p_buy_now_price,
    COALESCE(p_image_urls, '[]'::jsonb), p_proposed_start_time, p_proposed_duration_minutes)
  RETURNING id INTO v_id;
  PERFORM public._notify_admins('item_submitted', 'Pengajuan Barang Baru',
    'Seller mengajukan barang "' || p_title || '" untuk dilelang. Mohon diperiksa.', NULL,
    jsonb_build_object('submission_id', v_id, 'seller_id', v_user));
  RETURN jsonb_build_object('success', true, 'submission_id', v_id, 'status', 'Menunggu Review');
END; $function$;

CREATE OR REPLACE FUNCTION public.seller_edit_submission(
  p_id uuid, p_title text, p_description text, p_category_id uuid, p_condition text, p_location text,
  p_starting_price bigint, p_reserve_price bigint, p_buy_now_price bigint,
  p_image_urls jsonb, p_proposed_start_time timestamptz, p_proposed_duration_minutes integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_sub public.item_submissions%ROWTYPE; v_user uuid := auth.uid();
BEGIN
  SELECT * INTO v_sub FROM public.item_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Submission not found'); END IF;
  IF v_sub.seller_id <> v_user AND NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bukan pengajuan Anda');
  END IF;
  IF v_sub.status NOT IN ('Menunggu Review','Ditolak','Jadwal Ditolak') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pengajuan yang sudah diproses hanya boleh diubah kategorinya');
  END IF;
  UPDATE public.item_submissions SET title = p_title, description = p_description, category_id = p_category_id,
    condition = p_condition, location = p_location, starting_price = COALESCE(p_starting_price, 0),
    reserve_price = p_reserve_price, buy_now_price = p_buy_now_price, image_urls = COALESCE(p_image_urls, '[]'::jsonb),
    proposed_start_time = p_proposed_start_time, proposed_duration_minutes = p_proposed_duration_minutes,
    updated_at = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('success', true);
END; $function$;

-- Setelah barang ditetapkan untuk lelang, seller hanya boleh mengubah kategori
CREATE OR REPLACE FUNCTION public.seller_update_submission_category(p_id uuid, p_category_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_sub public.item_submissions%ROWTYPE; v_user uuid := auth.uid();
BEGIN
  SELECT * INTO v_sub FROM public.item_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Submission not found'); END IF;
  IF v_sub.seller_id <> v_user AND NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bukan pengajuan Anda');
  END IF;
  UPDATE public.item_submissions SET category_id = p_category_id, updated_at = now() WHERE id = p_id;
  RETURN jsonb_build_object('success', true);
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_review_item(
  p_id uuid, p_approve boolean, p_note text DEFAULT NULL,
  p_start_time timestamptz DEFAULT NULL, p_duration_minutes integer DEFAULT NULL, p_min_deposit bigint DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_sub public.item_submissions%ROWTYPE;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can review items');
  END IF;
  SELECT * INTO v_sub FROM public.item_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Submission not found'); END IF;
  IF v_sub.status NOT IN ('Menunggu Review','Jadwal Ditolak') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pengajuan ini tidak sedang menunggu review/jadwal');
  END IF;
  IF NOT p_approve THEN
    UPDATE public.item_submissions SET status = 'Ditolak', admin_note = p_note, updated_at = now() WHERE id = p_id;
    INSERT INTO public.notifications(user_id, type, title, message)
    VALUES (v_sub.seller_id, 'item_rejected', 'Pengajuan Barang Ditolak',
      'Pengajuan barang "' || v_sub.title || '" ditolak oleh admin.' || COALESCE(' Catatan: ' || p_note, ''));
    RETURN jsonb_build_object('success', true, 'status', 'Ditolak');
  END IF;
  IF p_start_time IS NULL OR p_duration_minutes IS NULL OR p_duration_minutes <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Admin wajib menentukan jadwal mulai dan durasi lelang');
  END IF;
  UPDATE public.item_submissions SET status = 'Menunggu Persetujuan Jadwal',
    admin_start_time = p_start_time, admin_duration_minutes = p_duration_minutes,
    min_deposit = COALESCE(p_min_deposit, 0), admin_note = p_note, schedule_reject_reason = NULL, updated_at = now()
  WHERE id = p_id;
  INSERT INTO public.notifications(user_id, type, title, message)
  VALUES (v_sub.seller_id, 'schedule_proposed', 'Jadwal Lelang Ditentukan Admin',
    'Admin telah menentukan jadwal untuk barang "' || v_sub.title || '": mulai ' ||
    to_char(p_start_time AT TIME ZONE 'Asia/Jakarta', 'DD Mon YYYY HH24:MI') || ' WIB, durasi ' || p_duration_minutes ||
    ' menit. Mohon periksa dan setujui atau tolak jadwal ini di Seller Hub.');
  RETURN jsonb_build_object('success', true, 'status', 'Menunggu Persetujuan Jadwal');
END; $function$;

CREATE OR REPLACE FUNCTION public.seller_respond_schedule(p_id uuid, p_approve boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_sub public.item_submissions%ROWTYPE; v_user uuid := auth.uid();
BEGIN
  SELECT * INTO v_sub FROM public.item_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Submission not found'); END IF;
  IF v_sub.seller_id <> v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bukan pengajuan Anda');
  END IF;
  IF v_sub.status <> 'Menunggu Persetujuan Jadwal' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tidak ada jadwal yang menunggu persetujuan Anda');
  END IF;
  IF p_approve THEN
    UPDATE public.item_submissions SET status = 'Disetujui', updated_at = now() WHERE id = p_id;
    PERFORM public._notify_admins('schedule_approved', 'Jadwal Lelang Disetujui Seller',
      'Seller menyetujui jadwal untuk barang "' || v_sub.title || '". Admin dapat melanjutkan penjadwalan lelang.', NULL,
      jsonb_build_object('submission_id', p_id));
    RETURN jsonb_build_object('success', true, 'status', 'Disetujui');
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Alasan penolakan jadwal wajib diisi');
  END IF;
  UPDATE public.item_submissions SET status = 'Jadwal Ditolak', schedule_reject_reason = p_reason, updated_at = now()
  WHERE id = p_id;
  PERFORM public._notify_admins('schedule_rejected', 'Jadwal Lelang Ditolak Seller',
    'Seller menolak jadwal untuk barang "' || v_sub.title || '". Alasan: ' || p_reason ||
    '. Pengajuan dikembalikan untuk diperbaiki/dijadwalkan ulang.', NULL,
    jsonb_build_object('submission_id', p_id));
  RETURN jsonb_build_object('success', true, 'status', 'Jadwal Ditolak');
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_publish_submission(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_sub public.item_submissions%ROWTYPE;
  v_auction_id uuid; v_slug text; v_end timestamptz; v_status public.auction_status;
  v_img text; v_idx integer := 0;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can publish auctions');
  END IF;
  SELECT * INTO v_sub FROM public.item_submissions WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Submission not found'); END IF;
  IF v_sub.status <> 'Disetujui' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pengajuan harus berstatus Disetujui (jadwal disetujui seller) sebelum diterbitkan');
  END IF;
  v_end := v_sub.admin_start_time + make_interval(mins => v_sub.admin_duration_minutes);
  v_status := CASE WHEN v_sub.admin_start_time <= now() AND v_end > now() THEN 'Live'::public.auction_status
                   ELSE 'Scheduled'::public.auction_status END;
  v_slug := lower(regexp_replace(v_sub.title, '[^a-zA-Z0-9]+', '-', 'g')) || '-' || substr(md5(random()::text), 1, 6);
  INSERT INTO public.auctions(seller_id, category_id, title, slug, description, condition, location,
    starting_price, current_highest_bid, minimum_increment, reserve_price, buy_now_price,
    start_time, end_time, status, min_deposit)
  VALUES (v_sub.seller_id, v_sub.category_id, v_sub.title, v_slug, v_sub.description, v_sub.condition, v_sub.location,
    v_sub.starting_price, v_sub.starting_price, 10000, v_sub.reserve_price, v_sub.buy_now_price,
    v_sub.admin_start_time, v_end, v_status, v_sub.min_deposit)
  RETURNING id INTO v_auction_id;
  FOR v_img IN SELECT jsonb_array_elements_text(COALESCE(v_sub.image_urls, '[]'::jsonb)) LOOP
    INSERT INTO public.auction_images(auction_id, image_url, is_primary, sort_order)
    VALUES (v_auction_id, v_img, v_idx = 0, v_idx);
    v_idx := v_idx + 1;
  END LOOP;
  UPDATE public.item_submissions SET status = 'Terjadwal', auction_id = v_auction_id, updated_at = now() WHERE id = p_id;
  INSERT INTO public.notifications(user_id, auction_id, type, title, message)
  VALUES (v_sub.seller_id, v_auction_id, 'item_approved', 'Barang Berhasil Dijadwalkan',
    'Barang "' || v_sub.title || '" telah diterbitkan dan dijadwalkan untuk dilelang mulai ' ||
    to_char(v_sub.admin_start_time AT TIME ZONE 'Asia/Jakarta', 'DD Mon YYYY HH24:MI') || ' WIB.');
  RETURN jsonb_build_object('success', true, 'auction_id', v_auction_id, 'status', v_status::text);
END; $function$;

-- Promosi otomatis lelang terjadwal yang waktunya tiba -> Live
CREATE OR REPLACE FUNCTION public.promote_due_auctions()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  UPDATE public.auctions SET status = 'Live'
  WHERE status = 'Scheduled' AND start_time <= now() AND end_time > now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'promoted', v_n);
END; $function$;

-- ============================================================
-- 10. Data penjamin & deposit (syarat mengikuti lelang berdeposit)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_guarantor(
  p_name text, p_phone text, p_relation text, p_address text, p_id_number text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user uuid := auth.uid();
BEGIN
  IF v_user IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Must be logged in'); END IF;
  IF COALESCE(trim(p_name),'') = '' OR COALESCE(trim(p_phone),'') = '' OR COALESCE(trim(p_relation),'') = ''
     OR COALESCE(trim(p_address),'') = '' OR COALESCE(trim(p_id_number),'') = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Semua data penjamin wajib dilengkapi');
  END IF;
  UPDATE public.profiles SET guarantor_name = p_name, guarantor_phone = p_phone,
    guarantor_relation = p_relation, guarantor_address = p_address,
    guarantor_id_number = p_id_number, guarantor_completed = true
  WHERE id = v_user;
  RETURN jsonb_build_object('success', true, 'guarantor_completed', true);
END; $function$;

CREATE OR REPLACE FUNCTION public.submit_deposit(p_amount bigint, p_proof_url text DEFAULT NULL, p_storage_path text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user uuid := auth.uid(); v_id uuid;
BEGIN
  IF v_user IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Must be logged in'); END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Nominal deposit harus lebih dari 0');
  END IF;
  INSERT INTO public.deposit_requests(user_id, amount, proof_url, storage_path)
  VALUES (v_user, p_amount, p_proof_url, p_storage_path) RETURNING id INTO v_id;
  PERFORM public._notify_admins('deposit_submitted', 'Pengajuan Deposit Baru',
    'Ada pengajuan deposit sebesar Rp' || to_char(p_amount, 'FM999,999,999,999') || ' yang menunggu verifikasi.', NULL,
    jsonb_build_object('deposit_request_id', v_id, 'user_id', v_user));
  RETURN jsonb_build_object('success', true, 'request_id', v_id, 'status', 'Menunggu Verifikasi');
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_review_deposit(p_id uuid, p_approve boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_req public.deposit_requests%ROWTYPE; v_bal bigint;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can review deposits');
  END IF;
  SELECT * INTO v_req FROM public.deposit_requests WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Deposit request not found'); END IF;
  IF v_req.status <> 'Menunggu Verifikasi' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pengajuan deposit ini sudah diperiksa');
  END IF;
  UPDATE public.deposit_requests SET status = CASE WHEN p_approve THEN 'Terverifikasi' ELSE 'Ditolak' END,
    admin_note = p_note, reviewed_by = auth.uid(), reviewed_at = now() WHERE id = p_id;
  IF p_approve THEN
    INSERT INTO public.user_deposits(user_id, verified_balance) VALUES (v_req.user_id, v_req.amount)
    ON CONFLICT (user_id) DO UPDATE SET verified_balance = public.user_deposits.verified_balance + EXCLUDED.verified_balance,
      updated_at = now()
    RETURNING verified_balance INTO v_bal;
    INSERT INTO public.deposit_transactions(user_id, type, amount, balance_after, reference_id, description, created_by)
    VALUES (v_req.user_id, 'Deposit Diverifikasi', v_req.amount, v_bal, v_req.id,
      'Deposit diterima dan diverifikasi admin', auth.uid());
    INSERT INTO public.notifications(user_id, type, title, message)
    VALUES (v_req.user_id, 'deposit_verified', 'Deposit Diverifikasi',
      'Deposit Anda sebesar Rp' || to_char(v_req.amount, 'FM999,999,999,999') ||
      ' telah diterima dan diverifikasi. Saldo deposit terverifikasi Anda sekarang Rp' || to_char(v_bal, 'FM999,999,999,999') || '.');
  ELSE
    INSERT INTO public.notifications(user_id, type, title, message)
    VALUES (v_req.user_id, 'deposit_rejected', 'Deposit Ditolak',
      'Pengajuan deposit sebesar Rp' || to_char(v_req.amount, 'FM999,999,999,999') ||
      ' ditolak oleh admin.' || COALESCE(' Catatan: ' || p_note, ''));
  END IF;
  RETURN jsonb_build_object('success', true, 'status', CASE WHEN p_approve THEN 'Terverifikasi' ELSE 'Ditolak' END);
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_deduct_deposit(p_user_id uuid, p_amount bigint, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_dep public.user_deposits%ROWTYPE; v_cut bigint; v_bal bigint;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can deduct deposits');
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Alasan pemotongan deposit wajib diisi');
  END IF;
  SELECT * INTO v_dep FROM public.user_deposits WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND OR v_dep.verified_balance <= 0 THEN
    RETURN jsonb_build_object('success', true, 'deducted', 0, 'note', 'Tidak ada deposit terverifikasi');
  END IF;
  v_cut := LEAST(p_amount, v_dep.verified_balance);
  UPDATE public.user_deposits SET verified_balance = verified_balance - v_cut, updated_at = now()
  WHERE user_id = p_user_id RETURNING verified_balance INTO v_bal;
  INSERT INTO public.deposit_transactions(user_id, type, amount, balance_after, description, created_by)
  VALUES (p_user_id, 'Deposit Dipotong (Sanksi)', -v_cut, v_bal, p_reason, auth.uid());
  INSERT INTO public.notifications(user_id, type, title, message)
  VALUES (p_user_id, 'account_sanctioned', 'Deposit Dipotong',
    'Deposit Anda dipotong sebesar Rp' || to_char(v_cut, 'FM999,999,999,999') || '. Alasan: ' || p_reason);
  RETURN jsonb_build_object('success', true, 'deducted', v_cut, 'balance_after', v_bal);
END; $function$;

-- Gerbang bid Fase 4: akun sehat + (untuk lelang berdeposit) penjamin lengkap & deposit cukup,
-- lalu meneruskan ke mesin bid yang sudah ada.
CREATE OR REPLACE FUNCTION public.place_bid_with_wallet_v2(p_auction_id uuid, p_amount bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_profile public.profiles%ROWTYPE;
  v_auction public.auctions%ROWTYPE;
  v_deposit bigint := 0;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You must be signed in to bid', 'code', 'NOT_SIGNED_IN');
  END IF;
  SELECT * INTO v_profile FROM public.profiles WHERE id = v_user;
  IF v_profile.account_status = 'banned' THEN
    RETURN jsonb_build_object('success', false, 'code', 'AKUN_DIBLOKIR',
      'error', 'Akun Anda telah diblokir permanen dari platform dan tidak dapat mengikuti lelang.');
  END IF;
  IF v_profile.account_status = 'suspended' AND v_profile.banned_until IS NOT NULL AND v_profile.banned_until > now() THEN
    RETURN jsonb_build_object('success', false, 'code', 'AKUN_DITANGGUHKAN',
      'error', 'Akun Anda sedang ditangguhkan sampai ' ||
        to_char(v_profile.banned_until AT TIME ZONE 'Asia/Jakarta', 'DD Mon YYYY HH24:MI') || ' WIB.');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF COALESCE(v_auction.min_deposit, 0) > 0 THEN
    IF NOT v_profile.guarantor_completed THEN
      RETURN jsonb_build_object('success', false, 'code', 'PENJAMIN_BELUM_LENGKAP',
        'error', 'Lelang ini mewajibkan data penjamin. Lengkapi data penjamin Anda terlebih dahulu di halaman Wallet.');
    END IF;
    SELECT COALESCE(verified_balance, 0) INTO v_deposit FROM public.user_deposits WHERE user_id = v_user;
    IF COALESCE(v_deposit, 0) < v_auction.min_deposit THEN
      RETURN jsonb_build_object('success', false, 'code', 'DEPOSIT_KURANG',
        'error', 'Deposit terverifikasi Anda (Rp' || to_char(COALESCE(v_deposit,0), 'FM999,999,999,999') ||
          ') belum memenuhi syarat minimum lelang ini (Rp' || to_char(v_auction.min_deposit, 'FM999,999,999,999') ||
          '). Ajukan deposit di halaman Wallet dan tunggu verifikasi admin.',
        'deposit_balance', COALESCE(v_deposit, 0), 'min_deposit', v_auction.min_deposit);
    END IF;
  END IF;
  RETURN public.place_bid_with_wallet(p_auction_id, p_amount);
END; $function$;

-- ============================================================
-- 11. Siklus pembayaran pemenang: bayar -> verifikasi -> biaya
--     admin -> persetujuan seller -> pencairan -> alamat -> kirim
-- ============================================================
CREATE OR REPLACE FUNCTION public.buyer_pay_with_wallet(p_tx_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_tx public.transactions%ROWTYPE;
  v_wallet public.wallets%ROWTYPE;
  v_from_reserved bigint; v_from_available bigint;
BEGIN
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF v_tx.winner_id <> v_user THEN RETURN jsonb_build_object('success', false, 'error', 'Bukan transaksi Anda'); END IF;
  IF v_tx.payment_status NOT IN ('Awaiting Payment','Rejected') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transaksi ini tidak sedang menunggu pembayaran');
  END IF;
  IF v_tx.payment_deadline IS NOT NULL AND v_tx.payment_deadline < now() AND v_tx.payment_status = 'Awaiting Payment' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Batas waktu pembayaran (24 jam) telah berakhir');
  END IF;
  v_wallet := public._get_or_create_wallet(v_user);
  v_from_reserved := LEAST(v_wallet.reserved_balance, v_tx.final_price);
  v_from_available := v_tx.final_price - v_from_reserved;
  IF v_wallet.available_balance < v_from_available THEN
    RETURN jsonb_build_object('success', false, 'code', 'INSUFFICIENT_BALANCE',
      'error', 'Saldo wallet tidak mencukupi untuk membayar transaksi ini.');
  END IF;
  IF v_tx.final_price > 0 THEN
    UPDATE public.wallets SET reserved_balance = reserved_balance - v_from_reserved,
      available_balance = available_balance - v_from_available WHERE id = v_wallet.id;
    PERFORM public._ledger(v_wallet, 'Auction Payment', -v_tx.final_price,
      v_wallet.available_balance, v_wallet.available_balance - v_from_available,
      v_wallet.reserved_balance, v_wallet.reserved_balance - v_from_reserved,
      v_tx.auction_id, NULL, NULL, 'Pembayaran transaksi lelang via wallet', v_user, NULL);
  END IF;
  UPDATE public.transactions SET payment_status = 'Paid', payment_method = 'Wallet LelangKu',
    paid_at = now(), rejection_reason = NULL, updated_at = now() WHERE id = p_tx_id;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id;
  PERFORM public._calc_fee(v_tx);
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id;
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  VALUES (v_tx.seller_id, v_tx.auction_id, 'fee_approval_requested', 'Pembayaran Diterima — Persetujuan Biaya Admin',
    'Pembeli telah membayar Rp' || to_char(v_tx.final_price, 'FM999,999,999,999') ||
    '. Biaya admin ' || v_tx.admin_fee_percent || '% = Rp' || to_char(v_tx.admin_fee_amount, 'FM999,999,999,999') ||
    ', pendapatan bersih Anda Rp' || to_char(v_tx.seller_net_amount, 'FM999,999,999,999') ||
    '. Mohon setujui potongan biaya admin di Seller Hub agar dana dapat dicairkan.',
    jsonb_build_object('transaction_id', p_tx_id));
  PERFORM public._notify_admins('payment_confirmed', 'Pembayaran Pemenang Diterima (Wallet)',
    'Pemenang membayar Rp' || to_char(v_tx.final_price, 'FM999,999,999,999') || ' via wallet. Menunggu persetujuan biaya admin dari seller.',
    v_tx.auction_id, jsonb_build_object('transaction_id', p_tx_id));
  RETURN jsonb_build_object('success', true, 'status', 'Paid');
END; $function$;

CREATE OR REPLACE FUNCTION public.buyer_submit_payment_proof(
  p_tx_id uuid, p_file_url text, p_storage_path text, p_file_name text,
  p_method text DEFAULT 'Transfer Bank', p_notes text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user uuid := auth.uid(); v_tx public.transactions%ROWTYPE; v_proof uuid;
BEGIN
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF v_tx.winner_id <> v_user THEN RETURN jsonb_build_object('success', false, 'error', 'Bukan transaksi Anda'); END IF;
  IF v_tx.payment_status NOT IN ('Awaiting Payment','Rejected') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transaksi ini tidak sedang menunggu pembayaran');
  END IF;
  INSERT INTO public.payment_proofs(transaction_id, uploader_id, file_url, storage_path, file_name, notes)
  VALUES (p_tx_id, v_user, p_file_url, p_storage_path, p_file_name, p_notes) RETURNING id INTO v_proof;
  UPDATE public.transactions SET payment_status = 'Payment Submitted', payment_method = p_method,
    rejection_reason = NULL, updated_at = now() WHERE id = p_tx_id;
  PERFORM public._notify_admins('payment_proof_submitted', 'Bukti Pembayaran Perlu Diverifikasi',
    'Pemenang mengunggah bukti pembayaran sebesar Rp' || to_char(v_tx.final_price, 'FM999,999,999,999') ||
    ' (' || p_method || '). Mohon periksa dan verifikasi.', v_tx.auction_id,
    jsonb_build_object('transaction_id', p_tx_id, 'proof_id', v_proof));
  RETURN jsonb_build_object('success', true, 'status', 'Payment Submitted', 'proof_id', v_proof);
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_verify_payment(p_tx_id uuid, p_approve boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_tx public.transactions%ROWTYPE;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can verify payments');
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF v_tx.payment_status NOT IN ('Payment Submitted','Under Review') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transaksi ini tidak sedang menunggu verifikasi');
  END IF;
  UPDATE public.payment_proofs SET reviewed_by = auth.uid(), reviewed_at = now(), review_notes = p_reason
  WHERE transaction_id = p_tx_id AND reviewed_at IS NULL;
  IF NOT p_approve THEN
    UPDATE public.transactions SET payment_status = 'Rejected', rejection_reason = p_reason, updated_at = now()
    WHERE id = p_tx_id;
    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (v_tx.winner_id, v_tx.auction_id, 'payment_rejected', 'Pembayaran Ditolak',
      'Pembayaran Anda ditolak oleh admin.' || COALESCE(' Alasan: ' || p_reason, '') ||
      ' Perbaiki sesuai petunjuk lalu unggah ulang bukti pembayaran, atau bayar memakai saldo wallet sebelum batas waktu berakhir.',
      jsonb_build_object('transaction_id', p_tx_id));
    RETURN jsonb_build_object('success', true, 'status', 'Rejected');
  END IF;
  -- Pembayaran manual terverifikasi: reservasi wallet pemenang dilepas kembali
  PERFORM public.release_bid_reservation(v_tx.auction_id);
  UPDATE public.transactions SET payment_status = 'Paid', paid_at = now(), rejection_reason = NULL, updated_at = now()
  WHERE id = p_tx_id;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id;
  PERFORM public._calc_fee(v_tx);
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id;
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  VALUES (v_tx.winner_id, v_tx.auction_id, 'payment_confirmed', 'Pembayaran Berhasil Diverifikasi',
    'Pembayaran Anda sebesar Rp' || to_char(v_tx.final_price, 'FM999,999,999,999') ||
    ' telah diverifikasi admin. Silakan isi alamat pengiriman pada halaman Transaksi.',
    jsonb_build_object('transaction_id', p_tx_id));
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  VALUES (v_tx.seller_id, v_tx.auction_id, 'fee_approval_requested', 'Pembayaran Diterima — Persetujuan Biaya Admin',
    'Pembeli telah membayar Rp' || to_char(v_tx.final_price, 'FM999,999,999,999') ||
    '. Biaya admin ' || v_tx.admin_fee_percent || '% = Rp' || to_char(v_tx.admin_fee_amount, 'FM999,999,999,999') ||
    ', pendapatan bersih Anda Rp' || to_char(v_tx.seller_net_amount, 'FM999,999,999,999') ||
    '. Mohon setujui potongan biaya admin di Seller Hub agar dana dapat dicairkan.',
    jsonb_build_object('transaction_id', p_tx_id));
  RETURN jsonb_build_object('success', true, 'status', 'Paid');
END; $function$;

CREATE OR REPLACE FUNCTION public.seller_respond_fee(p_tx_id uuid, p_approve boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user uuid := auth.uid(); v_tx public.transactions%ROWTYPE;
BEGIN
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF v_tx.seller_id <> v_user THEN RETURN jsonb_build_object('success', false, 'error', 'Bukan transaksi Anda'); END IF;
  IF v_tx.fee_status IS DISTINCT FROM 'Menunggu Persetujuan Seller' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tidak ada biaya admin yang menunggu persetujuan Anda');
  END IF;
  IF p_approve THEN
    UPDATE public.transactions SET fee_status = 'Disetujui', payout_status = 'Menunggu Pencairan', updated_at = now()
    WHERE id = p_tx_id;
    PERFORM public._notify_admins('fee_approved', 'Biaya Admin Disetujui Seller',
      'Seller menyetujui biaya admin Rp' || to_char(v_tx.admin_fee_amount, 'FM999,999,999,999') ||
      '. Dana bersih Rp' || to_char(v_tx.seller_net_amount, 'FM999,999,999,999') || ' siap dicairkan ke seller.',
      v_tx.auction_id, jsonb_build_object('transaction_id', p_tx_id));
    RETURN jsonb_build_object('success', true, 'fee_status', 'Disetujui');
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Alasan penolakan biaya admin wajib diisi');
  END IF;
  UPDATE public.transactions SET fee_status = 'Ditolak', fee_reject_reason = p_reason, updated_at = now()
  WHERE id = p_tx_id;
  PERFORM public._notify_admins('fee_rejected', 'Biaya Admin Ditolak Seller',
    'Seller menolak potongan biaya admin Rp' || to_char(v_tx.admin_fee_amount, 'FM999,999,999,999') ||
    '. Alasan: ' || p_reason, v_tx.auction_id, jsonb_build_object('transaction_id', p_tx_id));
  RETURN jsonb_build_object('success', true, 'fee_status', 'Ditolak');
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_adjust_fee(p_tx_id uuid, p_percent numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_tx public.transactions%ROWTYPE;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can adjust fees');
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF p_percent < 0 OR p_percent > 100 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Persentase biaya harus 0-100');
  END IF;
  UPDATE public.transactions SET admin_fee_percent = p_percent,
    admin_fee_amount = ROUND(final_price * p_percent / 100)::bigint,
    seller_net_amount = final_price - ROUND(final_price * p_percent / 100)::bigint,
    fee_status = 'Menunggu Persetujuan Seller', fee_reject_reason = NULL, updated_at = now()
  WHERE id = p_tx_id;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id;
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  VALUES (v_tx.seller_id, v_tx.auction_id, 'fee_approval_requested', 'Biaya Admin Diperbarui',
    'Admin memperbarui biaya admin menjadi ' || p_percent || '% = Rp' || to_char(v_tx.admin_fee_amount, 'FM999,999,999,999') ||
    ', pendapatan bersih Anda Rp' || to_char(v_tx.seller_net_amount, 'FM999,999,999,999') ||
    '. Mohon periksa dan setujui di Seller Hub.', jsonb_build_object('transaction_id', p_tx_id));
  RETURN jsonb_build_object('success', true, 'fee_amount', v_tx.admin_fee_amount, 'seller_net', v_tx.seller_net_amount);
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_payout_seller(p_tx_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_tx public.transactions%ROWTYPE; v_wallet public.wallets%ROWTYPE;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can pay out sellers');
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF v_tx.payment_status <> 'Paid' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pembayaran pembeli belum terverifikasi (Paid)');
  END IF;
  IF v_tx.fee_status IS DISTINCT FROM 'Disetujui' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Seller belum menyetujui potongan biaya admin');
  END IF;
  IF v_tx.payout_status = 'Sudah Dibayarkan' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Dana sudah dicairkan sebelumnya');
  END IF;
  v_wallet := public._get_or_create_wallet(v_tx.seller_id);
  UPDATE public.wallets SET available_balance = available_balance + v_tx.seller_net_amount WHERE id = v_wallet.id;
  PERFORM public._ledger(v_wallet, 'Auction Sale Proceeds', v_tx.seller_net_amount,
    v_wallet.available_balance, v_wallet.available_balance + v_tx.seller_net_amount,
    v_wallet.reserved_balance, v_wallet.reserved_balance,
    v_tx.auction_id, NULL, NULL,
    'Pencairan hasil lelang (bersih setelah biaya admin ' || v_tx.admin_fee_percent || '%)', auth.uid(), NULL);
  UPDATE public.transactions SET payout_status = 'Sudah Dibayarkan', payout_at = now(), updated_at = now()
  WHERE id = p_tx_id;
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  VALUES (v_tx.seller_id, v_tx.auction_id, 'payout_sent', 'Dana Hasil Lelang Telah Dibayarkan',
    'Admin telah mencairkan dana hasil lelang sebesar Rp' || to_char(v_tx.seller_net_amount, 'FM999,999,999,999') ||
    ' (bersih setelah biaya admin) ke wallet Anda.', jsonb_build_object('transaction_id', p_tx_id));
  RETURN jsonb_build_object('success', true, 'payout_status', 'Sudah Dibayarkan', 'amount', v_tx.seller_net_amount);
END; $function$;

-- ---------- Alamat pengiriman per transaksi ----------
CREATE OR REPLACE FUNCTION public.buyer_submit_address(
  p_tx_id uuid, p_name text, p_phone text, p_province text, p_city text, p_district text,
  p_subdistrict text, p_postal_code text, p_address_detail text, p_courier_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user uuid := auth.uid(); v_tx public.transactions%ROWTYPE;
BEGIN
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF v_tx.winner_id <> v_user THEN RETURN jsonb_build_object('success', false, 'error', 'Bukan transaksi Anda'); END IF;
  IF v_tx.payment_status NOT IN ('Paid','Completed') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Alamat pengiriman hanya dapat diisi setelah pembayaran terverifikasi');
  END IF;
  IF COALESCE(trim(p_name),'') = '' OR COALESCE(trim(p_phone),'') = '' OR COALESCE(trim(p_province),'') = ''
     OR COALESCE(trim(p_city),'') = '' OR COALESCE(trim(p_district),'') = '' OR COALESCE(trim(p_subdistrict),'') = ''
     OR COALESCE(trim(p_postal_code),'') = '' OR COALESCE(trim(p_address_detail),'') = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Semua kolom alamat wajib dilengkapi (kecuali catatan kurir)');
  END IF;
  UPDATE public.transactions SET ship_recipient_name = p_name, ship_phone = p_phone, ship_province = p_province,
    ship_city = p_city, ship_district = p_district, ship_subdistrict = p_subdistrict,
    ship_postal_code = p_postal_code, ship_address_detail = p_address_detail, ship_courier_note = p_courier_note,
    address_submitted_at = now(),
    shipping_status = CASE WHEN shipping_status IN ('Menunggu Pembayaran','Menunggu Alamat') THEN 'Alamat Diterima' ELSE shipping_status END,
    updated_at = now()
  WHERE id = p_tx_id;
  PERFORM public._notify_admins('address_submitted', 'Alamat Pengiriman Diterima',
    'Pemenang telah mengirim alamat pengiriman. Silakan proses pengiriman barang.', v_tx.auction_id,
    jsonb_build_object('transaction_id', p_tx_id));
  RETURN jsonb_build_object('success', true, 'shipping_status', 'Alamat Diterima');
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_update_shipping(
  p_tx_id uuid, p_status text, p_courier text DEFAULT NULL, p_tracking text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_tx public.transactions%ROWTYPE;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can manage shipping');
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF p_status NOT IN ('Sedang Diproses','Sedang Dikemas','Dalam Pengiriman') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Status pengiriman tidak valid');
  END IF;
  IF p_status = 'Dalam Pengiriman' AND (COALESCE(trim(p_courier),'') = '' OR COALESCE(trim(p_tracking),'') = '') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Nama ekspedisi dan nomor resi wajib diisi saat barang dikirim');
  END IF;
  UPDATE public.transactions SET shipping_status = p_status,
    courier_name = COALESCE(p_courier, courier_name),
    tracking_number = COALESCE(p_tracking, tracking_number),
    shipping_note = COALESCE(p_note, shipping_note),
    shipped_at = CASE WHEN p_status = 'Dalam Pengiriman' THEN COALESCE(shipped_at, now()) ELSE shipped_at END,
    updated_at = now()
  WHERE id = p_tx_id;
  IF p_status = 'Dalam Pengiriman' THEN
    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (v_tx.winner_id, v_tx.auction_id, 'item_shipped', 'Barang Anda Telah Dikirim',
      'Barang telah dikirim via ' || p_courier || ' dengan nomor resi ' || p_tracking ||
      '. Pantau statusnya di halaman Transaksi dan konfirmasikan saat barang diterima.',
      jsonb_build_object('transaction_id', p_tx_id, 'tracking_number', p_tracking, 'courier', p_courier));
  ELSE
    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (v_tx.winner_id, v_tx.auction_id, 'general', 'Status Pengiriman Diperbarui',
      'Status pengiriman barang Anda sekarang: ' || p_status || '.', jsonb_build_object('transaction_id', p_tx_id));
  END IF;
  RETURN jsonb_build_object('success', true, 'shipping_status', p_status);
END; $function$;

CREATE OR REPLACE FUNCTION public.buyer_confirm_received(p_tx_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_user uuid := auth.uid(); v_tx public.transactions%ROWTYPE;
BEGIN
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF v_tx.winner_id <> v_user THEN RETURN jsonb_build_object('success', false, 'error', 'Bukan transaksi Anda'); END IF;
  IF v_tx.shipping_status <> 'Dalam Pengiriman' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Barang belum dalam pengiriman');
  END IF;
  UPDATE public.transactions SET shipping_status = 'Transaksi Selesai', payment_status = 'Completed',
    received_at = now(), updated_at = now() WHERE id = p_tx_id;
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  VALUES (v_tx.seller_id, v_tx.auction_id, 'item_received', 'Barang Telah Diterima Pembeli',
    'Pembeli telah mengonfirmasi penerimaan barang. Transaksi selesai.',
    jsonb_build_object('transaction_id', p_tx_id));
  PERFORM public._notify_admins('item_received', 'Transaksi Selesai',
    'Pembeli mengonfirmasi barang diterima. Transaksi selesai.', v_tx.auction_id,
    jsonb_build_object('transaction_id', p_tx_id));
  RETURN jsonb_build_object('success', true, 'status', 'Completed');
END; $function$;

-- ============================================================
-- 12. Pemenang tidak membayar: tenggat lewat, sanksi, blokir
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_expired_payments()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_tx public.transactions%ROWTYPE; v_n integer := 0;
BEGIN
  FOR v_tx IN
    SELECT * FROM public.transactions
    WHERE payment_status = 'Awaiting Payment' AND payment_deadline IS NOT NULL AND payment_deadline < now()
    FOR UPDATE
  LOOP
    PERFORM public.release_bid_reservation(v_tx.auction_id);
    UPDATE public.transactions SET payment_status = 'Expired', updated_at = now() WHERE id = v_tx.id;
    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (v_tx.winner_id, v_tx.auction_id, 'payment_expired', 'Batas Waktu Pembayaran Berakhir',
      'Anda tidak menyelesaikan pembayaran dalam 24 jam sehingga transaksi dinyatakan gagal. Deposit dapat dikenakan pemotongan dan akun dapat dikenakan sanksi sesuai kebijakan platform.',
      jsonb_build_object('transaction_id', v_tx.id));
    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (v_tx.seller_id, v_tx.auction_id, 'payment_expired', 'Pemenang Tidak Menyelesaikan Pembayaran',
      'Pemenang lelang tidak menyelesaikan pembayaran dalam batas waktu. Barang akan dikembalikan ke pengelolaan admin.',
      jsonb_build_object('transaction_id', v_tx.id));
    PERFORM public._notify_admins('payment_expired', 'Pembayaran Pemenang Kedaluwarsa',
      'Sebuah transaksi melewati batas pembayaran 24 jam dan dinyatakan Expired. Tentukan sanksi bila perlu.',
      v_tx.auction_id, jsonb_build_object('transaction_id', v_tx.id));
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'expired', v_n);
END; $function$;

CREATE OR REPLACE FUNCTION public.admin_handle_nonpayment(
  p_tx_id uuid, p_forfeit_amount bigint DEFAULT 0,
  p_ban_mode text DEFAULT 'none', p_ban_days integer DEFAULT 0, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_tx public.transactions%ROWTYPE;
  v_email text; v_cut bigint := 0;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can handle non-payment');
  END IF;
  SELECT * INTO v_tx FROM public.transactions WHERE id = p_tx_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Transaction not found'); END IF;
  IF v_tx.payment_status NOT IN ('Awaiting Payment','Expired','Rejected') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transaksi ini tidak dalam status gagal bayar');
  END IF;
  -- Lepas reservasi wallet pemenang (idempotent)
  PERFORM public.release_bid_reservation(v_tx.auction_id);
  -- Potong deposit sebagai sanksi bila diminta
  IF COALESCE(p_forfeit_amount, 0) > 0 THEN
    SELECT COALESCE((public.admin_deduct_deposit(v_tx.winner_id, p_forfeit_amount,
      COALESCE(p_reason, 'Sanksi tidak menyelesaikan pembayaran lelang')) ->> 'deducted')::bigint, 0) INTO v_cut;
  END IF;
  -- Sanksi akun
  IF p_ban_mode = 'temporary' THEN
    UPDATE public.profiles SET account_status = 'suspended',
      banned_until = now() + make_interval(days => GREATEST(COALESCE(p_ban_days, 0), 1))
    WHERE id = v_tx.winner_id;
  ELSIF p_ban_mode = 'permanent' THEN
    UPDATE public.profiles SET account_status = 'banned', banned_until = NULL WHERE id = v_tx.winner_id;
    SELECT email INTO v_email FROM public.profiles WHERE id = v_tx.winner_id;
    IF v_email IS NOT NULL THEN
      INSERT INTO public.blocked_emails(email, reason, blocked_by)
      VALUES (lower(v_email), COALESCE(p_reason, 'Diblokir permanen: tidak menyelesaikan pembayaran lelang'), auth.uid())
      ON CONFLICT (email) DO NOTHING;
    END IF;
  END IF;
  -- Transaksi gagal; barang kembali ke pengelolaan admin (pengajuan terkait dibuka lagi dari awal)
  UPDATE public.transactions SET payment_status = 'Cancelled',
    notes = COALESCE(notes || ' | ', '') || 'Dinyatakan gagal bayar oleh admin. ' || COALESCE(p_reason, ''),
    updated_at = now() WHERE id = p_tx_id;
  UPDATE public.auctions SET status = 'Cancelled' WHERE id = v_tx.auction_id AND status = 'Completed';
  UPDATE public.item_submissions SET status = 'Menunggu Review', auction_id = NULL, updated_at = now()
  WHERE auction_id = v_tx.auction_id AND status = 'Terjadwal';
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  VALUES (v_tx.winner_id, v_tx.auction_id, 'account_sanctioned', 'Transaksi Gagal & Sanksi Diterapkan',
    'Transaksi Anda dinyatakan gagal karena tidak menyelesaikan pembayaran.' ||
    CASE WHEN v_cut > 0 THEN ' Deposit dipotong Rp' || to_char(v_cut, 'FM999,999,999,999') || '.' ELSE '' END ||
    CASE WHEN p_ban_mode = 'temporary' THEN ' Akun ditangguhkan selama ' || GREATEST(COALESCE(p_ban_days,0),1) || ' hari.'
         WHEN p_ban_mode = 'permanent' THEN ' Akun diblokir permanen dan email Anda tidak dapat digunakan untuk mendaftar kembali.'
         ELSE '' END,
    jsonb_build_object('transaction_id', p_tx_id));
  INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
  VALUES (v_tx.seller_id, v_tx.auction_id, 'general', 'Barang Kembali ke Pengelolaan Admin',
    'Pemenang sebelumnya tidak menyelesaikan pembayaran. Barang dikembalikan ke pengelolaan admin; pengajuan ulang mengikuti alur persetujuan dan penjadwalan dari awal.',
    jsonb_build_object('transaction_id', p_tx_id));
  RETURN jsonb_build_object('success', true, 'status', 'Cancelled', 'deposit_deducted', v_cut, 'ban_mode', p_ban_mode);
END; $function$;

-- Admin memperbarui pengaturan platform (persentase biaya, instruksi pembayaran, tenggat)
CREATE OR REPLACE FUNCTION public.admin_update_setting(p_key text, p_value jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can update settings');
  END IF;
  IF p_key NOT IN ('platform_fee_percent','payment_instructions','payment_deadline_hours') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pengaturan ini tidak dapat diubah dari sini');
  END IF;
  INSERT INTO public.platform_settings(setting_key, setting_value) VALUES (p_key, p_value)
  ON CONFLICT (setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;
  RETURN jsonb_build_object('success', true, 'key', p_key);
END; $function$;

-- Akun dengan email terblokir permanen tidak dapat mendaftar kembali
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM public.blocked_emails WHERE lower(email) = lower(NEW.email)) THEN
    RAISE EXCEPTION 'Email ini telah diblokir permanen dari platform LelangKu karena pelanggaran ketentuan.';
  END IF;
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
END; $function$;

-- ============================================================
-- 13. Finalisasi lelang versi Fase 4:
-- pemenang TIDAK lagi langsung lunas — transaksi dibuat dengan
-- status Awaiting Payment dan tenggat 24 jam; reservasi wallet
-- pemenang tetap ditahan sebagai jaminan sampai pembayaran
-- terverifikasi (atau dilepas bila membayar manual).
-- ============================================================
CREATE OR REPLACE FUNCTION public.finalize_auction(p_auction_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_auction public.auctions%ROWTYPE;
  v_hours integer := 24;
  v_winner_name text; v_winner_username text; v_bid_count integer;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can finalize auctions');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.status IN ('Completed','No Winner','Cancelled') THEN
    RETURN jsonb_build_object('success', true, 'already_finalized', true, 'status', v_auction.status);
  END IF;
  SELECT COALESCE((setting_value #>> '{}')::integer, 24) INTO v_hours
  FROM public.platform_settings WHERE setting_key = 'payment_deadline_hours';
  IF v_hours IS NULL THEN v_hours := 24; END IF;

  IF v_auction.highest_bidder_id IS NOT NULL AND v_auction.current_highest_bid IS NOT NULL THEN
    IF v_auction.reserve_price IS NOT NULL AND v_auction.current_highest_bid < v_auction.reserve_price THEN
      PERFORM public.release_bid_reservation(p_auction_id);
      UPDATE public.auctions
      SET status = 'No Winner', actual_end_time = COALESCE(actual_end_time, end_time), completed_at = now()
      WHERE id = p_auction_id;
      INSERT INTO public.notifications(user_id, auction_id, type, title, message)
      VALUES (v_auction.seller_id, p_auction_id, 'reserve_not_met', 'Lelang Berakhir (Reserve Tidak Terpenuhi)',
        'Lelang "' || v_auction.title || '" berakhir tanpa pemenang karena bid tertinggi belum mencapai Reserve Price Anda.');
      RETURN jsonb_build_object('success', true, 'status', 'No Winner', 'reason', 'RESERVE_PRICE_NOT_MET');
    END IF;

    INSERT INTO public.transactions(auction_id, winner_id, seller_id, final_price, payment_status, payment_deadline, shipping_status)
    VALUES (p_auction_id, v_auction.highest_bidder_id, v_auction.seller_id,
      v_auction.current_highest_bid, 'Awaiting Payment', now() + make_interval(hours => v_hours), 'Menunggu Pembayaran')
    ON CONFLICT (auction_id) DO UPDATE
    SET payment_status = 'Awaiting Payment', final_price = EXCLUDED.final_price,
        payment_deadline = EXCLUDED.payment_deadline;

    UPDATE public.auctions
    SET status = 'Completed', actual_end_time = COALESCE(actual_end_time, end_time), completed_at = now()
    WHERE id = p_auction_id;

    SELECT COALESCE(full_name, username, 'Penawar'), COALESCE(username, 'user')
    INTO v_winner_name, v_winner_username
    FROM public.profiles WHERE id = v_auction.highest_bidder_id;
    SELECT count(*) INTO v_bid_count FROM public.bids WHERE auction_id = p_auction_id;

    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (
      v_auction.seller_id, p_auction_id, 'auction_sold',
      '🏆 Laporan Hasil Akhir: "' || v_auction.title || '" Terjual!',
      'Selamat! Lelang barang "' || v_auction.title || '" Anda berakhir dan terjual.' || chr(10) ||
      '• Pembeli / Pemenang: ' || v_winner_name || ' (@' || v_winner_username || ')' || chr(10) ||
      '• Harga Akhir Terjual: Rp' || to_char(v_auction.current_highest_bid, 'FM999,999,999,999') || chr(10) ||
      '• Total Penawaran Masuk: ' || v_bid_count || ' bid' || chr(10) ||
      '• Status: Menunggu pembayaran pembeli (maks ' || v_hours || ' jam). Dana diteruskan ke wallet Anda setelah pembayaran terverifikasi dan Anda menyetujui biaya admin.',
      jsonb_build_object('event', 'auction_completed', 'auction_title', v_auction.title,
        'winner_name', v_winner_name, 'winner_username', v_winner_username,
        'winner_id', v_auction.highest_bidder_id, 'final_price', v_auction.current_highest_bid,
        'amount', v_auction.current_highest_bid, 'total_bids', v_bid_count,
        'method', 'Lelang Terbuka', 'completed_at', now()));

    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (v_auction.highest_bidder_id, p_auction_id, 'auction_won', 'Selamat! Anda Menang Lelang',
      'Selamat! Anda memenangkan "' || v_auction.title || '" seharga Rp' ||
      to_char(v_auction.current_highest_bid, 'FM999,999,999,999') ||
      '. Segera selesaikan pembayaran maks ' || v_hours || ' jam (sebelum ' ||
      to_char((now() + make_interval(hours => v_hours)) AT TIME ZONE 'Asia/Jakarta', 'DD Mon YYYY HH24:MI') ||
      ' WIB) melalui halaman Transaksi: bayar memakai saldo wallet atau transfer manual lalu unggah buktinya.',
      jsonb_build_object('amount', v_auction.current_highest_bid, 'auction_title', v_auction.title));

    PERFORM public._notify_admins('general', 'Lelang Selesai — Menunggu Pembayaran',
      'Lelang "' || v_auction.title || '" selesai. Pemenang wajib membayar maks ' || v_hours || ' jam.',
      p_auction_id, NULL);

    RETURN jsonb_build_object('success', true, 'status', 'Completed',
      'winner_id', v_auction.highest_bidder_id, 'seller_id', v_auction.seller_id,
      'final_price', v_auction.current_highest_bid, 'payment_status', 'Awaiting Payment');
  ELSE
    UPDATE public.auctions
    SET status = 'No Winner', actual_end_time = COALESCE(actual_end_time, end_time), completed_at = now()
    WHERE id = p_auction_id;
    INSERT INTO public.notifications(user_id, auction_id, type, title, message)
    VALUES (v_auction.seller_id, p_auction_id, 'auction_lost', 'Lelang Berakhir Tanpa Pemenang',
      'Lelang "' || v_auction.title || '" berakhir tanpa ada penawaran yang masuk.');
    RETURN jsonb_build_object('success', true, 'status', 'No Winner');
  END IF;
END; $function$;

-- ============================================================
-- 14. Buy Now versi Fase 4: dana pembeli DITAHAN (reserved),
-- transaksi Awaiting Payment 24 jam — penyelesaian mengikuti
-- alur pembayaran yang sama seperti pemenang lelang.
-- ============================================================
CREATE OR REPLACE FUNCTION public.buy_now_with_wallet(p_auction_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_auction public.auctions%ROWTYPE;
  v_price bigint;
  v_buyer_wallet public.wallets%ROWTYPE;
  v_sequence integer; v_bid_id uuid; v_hours integer := 24;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You must be signed in to purchase');
  END IF;
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.seller_id = v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'You cannot purchase your own auction');
  END IF;
  IF v_auction.status <> 'Live' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction is not live');
  END IF;
  IF v_auction.end_time <= now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction has ended');
  END IF;
  IF v_auction.buy_now_price IS NULL OR v_auction.buy_now_price <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'This auction does not have a Buy Now price');
  END IF;
  v_price := v_auction.buy_now_price;
  v_buyer_wallet := public._get_or_create_wallet(v_user);
  IF v_buyer_wallet.available_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Saldo wallet Anda tidak mencukupi untuk Beli Sekarang.',
      'code', 'INSUFFICIENT_BALANCE', 'available_balance', v_buyer_wallet.available_balance, 'required', v_price);
  END IF;
  PERFORM public.release_bid_reservation(p_auction_id);
  PERFORM set_config('lelangku.allow_bid_mutation', 'on', true);
  SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence FROM public.bids WHERE auction_id = p_auction_id;
  INSERT INTO public.bids(auction_id, bidder_id, amount, bid_sequence)
  VALUES (p_auction_id, v_user, v_price, v_sequence) RETURNING id INTO v_bid_id;
  -- Tahan dana pembeli sebagai jaminan pembayaran (belum diteruskan ke seller)
  UPDATE public.wallets SET available_balance = available_balance - v_price,
    reserved_balance = reserved_balance + v_price WHERE id = v_buyer_wallet.id;
  PERFORM public._ledger(v_buyer_wallet, 'Auction Bid Reservation', -v_price,
    v_buyer_wallet.available_balance, v_buyer_wallet.available_balance - v_price,
    v_buyer_wallet.reserved_balance, v_buyer_wallet.reserved_balance + v_price,
    p_auction_id, v_bid_id, NULL, 'Dana ditahan untuk pembelian Buy Now: "' || v_auction.title || '"', v_user, NULL);
  SELECT COALESCE((setting_value #>> '{}')::integer, 24) INTO v_hours
  FROM public.platform_settings WHERE setting_key = 'payment_deadline_hours';
  IF v_hours IS NULL THEN v_hours := 24; END IF;
  INSERT INTO public.transactions(auction_id, winner_id, seller_id, final_price, payment_status, payment_deadline, shipping_status)
  VALUES (p_auction_id, v_user, v_auction.seller_id, v_price, 'Awaiting Payment',
    now() + make_interval(hours => v_hours), 'Menunggu Pembayaran')
  ON CONFLICT (auction_id) DO UPDATE SET payment_status = 'Awaiting Payment',
    final_price = EXCLUDED.final_price, payment_deadline = EXCLUDED.payment_deadline;
  UPDATE public.auctions SET status = 'Completed', current_highest_bid = v_price,
    highest_bidder_id = v_user, actual_end_time = now(), completed_at = now()
  WHERE id = p_auction_id;
  INSERT INTO public.notifications(user_id, auction_id, type, title, message)
  VALUES (v_user, p_auction_id, 'auction_won', 'Pembelian Buy Now Berhasil — Menunggu Pembayaran',
    'Anda membeli "' || v_auction.title || '" seharga Rp' || to_char(v_price, 'FM999,999,999,999') ||
    ' via Buy Now. Selesaikan pembayaran maks ' || v_hours || ' jam di halaman Transaksi.');
  INSERT INTO public.notifications(user_id, auction_id, type, title, message)
  VALUES (v_auction.seller_id, p_auction_id, 'auction_sold', 'Barang Anda Terjual via Buy Now!',
    'Barang "' || v_auction.title || '" dibeli via Buy Now seharga Rp' || to_char(v_price, 'FM999,999,999,999') ||
    '. Menunggu pembayaran pembeli (maks ' || v_hours || ' jam); dana diteruskan setelah pembayaran terverifikasi dan biaya admin disetujui.');
  RETURN jsonb_build_object('success', true, 'message', 'Pembelian Buy Now tercatat. Selesaikan pembayaran di halaman Transaksi.',
    'final_price', v_price, 'payment_status', 'Awaiting Payment');
END; $function$;
