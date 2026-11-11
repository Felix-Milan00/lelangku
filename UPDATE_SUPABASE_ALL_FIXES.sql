-- ============================================================
-- 🚀 SCRIPT UTAMA PERBAIKAN SUPABASE (LELANGKU)
-- Salin seluruh isi file ini, paste ke Supabase SQL Editor, lalu klik RUN.
-- Menyelesaikan:
-- 1. Enum payment_status fix (Akhiri Sekarang berhasil 100%).
-- 2. Surat Hasil Akhir & Omset Penjualan otomatis masuk ke Seller Hub.
-- 3. Logging Konkurensi Milidetik (Penawar yang kalah cepat tetap tercatat di log bids).
-- 4. Izin Admin membuat lelang konsinyasi.
-- ============================================================

-- ------------------------------------------------------------
-- 0. PERBARUI ENUM & CHECK CONSTRAINT
-- ------------------------------------------------------------
ALTER TYPE public.payment_status ADD VALUE IF NOT EXISTS 'Completed';

ALTER TABLE public.wallet_transactions DROP CONSTRAINT IF EXISTS wallet_transactions_transaction_type_check;
ALTER TABLE public.wallet_transactions ADD CONSTRAINT wallet_transactions_transaction_type_check CHECK (
  transaction_type IN (
    'Admin Balance Addition',
    'Admin Balance Deduction',
    'Auction Bid Reservation',
    'Bid Reservation Hold',
    'Bid Reservation Release',
    'Auction Payment',
    'Auction Sale Proceeds',
    'Buy Now Payment',
    'Refund',
    'Wallet Adjustment'
  )
);

-- ------------------------------------------------------------
-- 1. IZIN RLS ADMIN MEMBUAT LELANG KONSINYASI MILIK SELLER
-- ------------------------------------------------------------
DROP POLICY IF EXISTS auctions_insert_seller ON public.auctions;
DROP POLICY IF EXISTS auctions_insert_seller_or_admin ON public.auctions;
CREATE POLICY auctions_insert_seller_or_admin ON public.auctions
  FOR INSERT WITH CHECK (seller_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS auction_images_insert_policy ON public.auction_images;
DROP POLICY IF EXISTS auction_images_insert_seller ON public.auction_images;
DROP POLICY IF EXISTS auction_images_insert_seller_or_admin ON public.auction_images;
CREATE POLICY auction_images_insert_seller_or_admin ON public.auction_images
  FOR INSERT WITH CHECK (
    public.is_admin() OR EXISTS (
      SELECT 1 FROM public.auctions a
      WHERE a.id = auction_id AND (a.seller_id = auth.uid() OR public.is_admin())
    )
  );

-- ------------------------------------------------------------
-- 2. RPC: ADMIN_CREATE_AUCTION
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_create_auction(
  p_seller_id uuid,
  p_category_id uuid,
  p_title text,
  p_slug text,
  p_description text,
  p_condition text,
  p_location text,
  p_starting_price bigint,
  p_minimum_increment bigint,
  p_reserve_price bigint,
  p_buy_now_price bigint,
  p_start_time timestamptz,
  p_end_time timestamptz,
  p_status text,
  p_is_featured boolean,
  p_anti_sniping_enabled boolean,
  p_extension_threshold_seconds integer,
  p_extension_duration_seconds integer,
  p_image_url text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auction_id uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hanya administrator yang berhak menerbitkan lelang.');
  END IF;

  INSERT INTO public.auctions (
    seller_id, category_id, title, slug, description, condition, location,
    starting_price, current_highest_bid, minimum_increment, reserve_price,
    buy_now_price, start_time, end_time, status, is_featured,
    anti_sniping_enabled, extension_threshold_seconds, extension_duration_seconds
  ) VALUES (
    p_seller_id, p_category_id, p_title, p_slug, p_description, p_condition, p_location,
    p_starting_price, 0, p_minimum_increment, p_reserve_price,
    p_buy_now_price, p_start_time, p_end_time, p_status, p_is_featured,
    p_anti_sniping_enabled, p_extension_threshold_seconds, p_extension_duration_seconds
  ) RETURNING id INTO v_auction_id;

  IF p_image_url IS NOT NULL AND trim(p_image_url) <> '' THEN
    INSERT INTO public.auction_images (auction_id, image_url, is_primary, sort_order)
    VALUES (v_auction_id, trim(p_image_url), true, 0);
  END IF;

  RETURN jsonb_build_object('success', true, 'id', v_auction_id);
END; $$;

-- ------------------------------------------------------------
-- 3. TRIGGER MUTASI BIDS TERKONTROL
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._check_bid_security()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF current_setting('lelangku.allow_bid_mutation', true) <> 'on' AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'DIRECT_BID_MUTATION_BLOCKED: Penambahan/perubahan bid langsung via SQL atau REST API dilarang keras.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_protect_bids_mutation ON public.bids;
CREATE TRIGGER trg_protect_bids_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.bids
  FOR EACH ROW EXECUTE FUNCTION public._check_bid_security();

-- ------------------------------------------------------------
-- 4. RPC: PLACE_BID_WITH_WALLET DENGAN LOGGING KONKURENSI MILIDETIK
-- ------------------------------------------------------------
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
  v_created_at timestamptz;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You must be signed in to place a bid');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bid amount must be a positive number');
  END IF;

  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); END IF;
  IF v_auction.seller_id = v_user THEN RETURN jsonb_build_object('success', false, 'error', 'You cannot bid on your own auction'); END IF;
  IF v_auction.status <> 'Live' THEN RETURN jsonb_build_object('success', false, 'error', 'Auction is not live'); END IF;
  IF now() < v_auction.start_time THEN RETURN jsonb_build_object('success', false, 'error', 'Auction has not started yet'); END IF;
  IF now() >= v_auction.end_time THEN RETURN jsonb_build_object('success', false, 'error', 'Auction has already ended'); END IF;

  v_prev_bidder := v_auction.highest_bidder_id;
  v_prev_amount := v_auction.current_highest_bid;
  IF v_prev_amount IS NULL OR v_prev_amount = 0 THEN 
    v_required := v_auction.starting_price;
  ELSE 
    v_required := v_prev_amount + v_auction.minimum_increment; 
  END IF;

  IF v_prev_bidder = v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are already the highest bidder');
  END IF;

  IF p_amount < v_auction.starting_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bid must be at least the starting price');
  END IF;

  v_wallet := public._get_or_create_wallet(v_user);
  IF v_wallet.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet is not active');
  END IF;
  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Saldo Anda tidak mencukupi untuk melakukan penawaran ini.', 'code', 'INSUFFICIENT_BALANCE');
  END IF;

  -- KASUS 1: KALAH CEPAT KARENA KONKURENSI MILIDETIK (TETAP DICATAT KE TABEL BIDS)
  IF p_amount < v_required THEN
    PERFORM set_config('lelangku.allow_bid_mutation', 'on', true);

    SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence
    FROM public.bids WHERE auction_id = p_auction_id;

    INSERT INTO public.bids (auction_id, bidder_id, amount, bid_sequence)
    VALUES (p_auction_id, v_user, p_amount, v_sequence)
    RETURNING id, created_at INTO v_bid_id, v_created_at;

    INSERT INTO public.notifications (user_id, auction_id, type, title, message, metadata)
    VALUES (v_user, p_auction_id, 'outbid', '⚡ Tawaran Konkurensi: Kalah Cepat Terkunci',
      'Tawaran Anda sebesar Rp' || to_char(p_amount, 'FM999,999,999,999') || ' tercatat di ledger sistem (Urutan #' || v_sequence || '), namun kalah cepat beberapa milidetik dari penawar sebelumnya (First-Come First-Served).',
      jsonb_build_object('amount', p_amount, 'bid_id', v_bid_id, 'status', 'outpaced_tie'));

    RETURN jsonb_build_object(
      'success', true,
      'tied_outpaced', true,
      'code', 'CONCURRENT_TIE_OUTPACED',
      'message', '⚡ Konkurensi Terdeteksi: Bid Anda sebesar Rp' || to_char(p_amount, 'FM999,999,999,999') || ' berhasil dicatat di ledger sistem (#' || v_sequence || '), namun kalah cepat beberapa milidetik dari penawar sebelumnya (First-Come First-Served). Status: Kalah Cepat.',
      'bid_id', v_bid_id,
      'bid_sequence', v_sequence,
      'created_at_iso', v_created_at,
      'current_highest_bid', v_auction.current_highest_bid,
      'highest_bidder_id', v_prev_bidder,
      'wallet_available', v_wallet.available_balance,
      'wallet_reserved', v_wallet.reserved_balance
    );
  END IF;

  -- KASUS 2: BID SAH TERDEPAN (Pemenang Sementara)
  PERFORM set_config('lelangku.allow_bid_mutation', 'on', true);

  SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence
  FROM public.bids WHERE auction_id = p_auction_id;

  INSERT INTO public.bids (auction_id, bidder_id, amount, bid_sequence)
  VALUES (p_auction_id, v_user, p_amount, v_sequence) 
  RETURNING id, created_at INTO v_bid_id, v_created_at;

  IF v_prev_bidder IS NOT NULL AND v_prev_amount IS NOT NULL THEN
    SELECT id INTO v_prev_bid_id FROM public.bids
    WHERE auction_id = p_auction_id AND bidder_id = v_prev_bidder AND amount = v_prev_amount
    ORDER BY bid_sequence DESC LIMIT 1;

    v_prev_wallet := public._get_or_create_wallet(v_prev_bidder);
    IF v_prev_wallet.reserved_balance >= v_prev_amount THEN
      UPDATE public.wallets 
      SET available_balance = available_balance + v_prev_amount,
          reserved_balance = reserved_balance - v_prev_amount 
      WHERE id = v_prev_wallet.id;

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

  UPDATE public.wallets 
  SET available_balance = available_balance - p_amount,
      reserved_balance = reserved_balance + p_amount 
  WHERE id = v_wallet.id;

  PERFORM public._ledger(v_wallet, 'Auction Bid Reservation', -p_amount,
    v_wallet.available_balance, v_wallet.available_balance - p_amount,
    v_wallet.reserved_balance, v_wallet.reserved_balance + p_amount,
    p_auction_id, v_bid_id, NULL, 'Saldo dikunci untuk penawaran pada lelang: "' || v_auction.title || '"', v_user, NULL);

  v_new_end := v_auction.end_time;
  IF v_auction.anti_sniping_enabled 
     AND v_auction.end_time - now() <= make_interval(secs => COALESCE(v_auction.extension_threshold_seconds, 30)) THEN
    v_new_end := v_auction.end_time + make_interval(secs => COALESCE(v_auction.extension_duration_seconds, 120));
    v_extended := true;
  END IF;

  UPDATE public.auctions 
  SET current_highest_bid = p_amount,
      highest_bidder_id = v_user, 
      end_time = v_new_end 
  WHERE id = p_auction_id;

  RETURN jsonb_build_object(
    'success', true, 
    'bid_id', v_bid_id,
    'bid_sequence', v_sequence,
    'created_at_iso', v_created_at,
    'current_highest_bid', p_amount,
    'highest_bidder_id', v_user,
    'extended', v_extended,
    'new_end_time', v_new_end,
    'wallet_available', v_wallet.available_balance - p_amount,
    'wallet_reserved', v_wallet.reserved_balance + p_amount
  );
END; $$;

-- ------------------------------------------------------------
-- 5. RPC: FINALIZE_AUCTION (PENYELESAIAN LELANG, PENCAIRAN KE SELLER, & SURAT SELLER)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finalize_auction(p_auction_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auction public.auctions%ROWTYPE;
  v_winner_wallet public.wallets%ROWTYPE;
  v_seller_wallet public.wallets%ROWTYPE;
  v_hours integer := 72;
  v_winner_name text;
  v_winner_username text;
  v_bid_count integer;
BEGIN
  IF NOT public._require_admin_or_trusted() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Only administrators can finalize auctions');
  END IF;

  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN 
    RETURN jsonb_build_object('success', false, 'error', 'Auction not found'); 
  END IF;

  IF v_auction.status IN ('Completed','No Winner','Cancelled') THEN
    RETURN jsonb_build_object('success', true, 'already_finalized', true, 'status', v_auction.status);
  END IF;

  SELECT COALESCE((setting_value #>> '{}')::integer, 72) INTO v_hours
  FROM public.platform_settings WHERE setting_key = 'payment_deadline_hours';
  IF v_hours IS NULL THEN v_hours := 72; END IF;

  -- A. Ada Penawar Tertinggi
  IF v_auction.highest_bidder_id IS NOT NULL AND v_auction.current_highest_bid IS NOT NULL THEN
    
    -- Cek Reserve Price jika ada
    IF v_auction.reserve_price IS NOT NULL AND v_auction.current_highest_bid < v_auction.reserve_price THEN
      PERFORM public.release_bid_reservation(p_auction_id);
      
      UPDATE public.auctions 
      SET status = 'No Winner',
          actual_end_time = COALESCE(actual_end_time, end_time), 
          completed_at = now()
      WHERE id = p_auction_id;

      INSERT INTO public.notifications(user_id, auction_id, type, title, message)
      VALUES (v_auction.seller_id, p_auction_id, 'reserve_not_met', 'Lelang Berakhir (Batas Cadangan Tidak Terpenuhi)',
        'Lelang "' || v_auction.title || '" berakhir tanpa pemenang karena bid tertinggi belum mencapai Reserve Price Anda.');

      RETURN jsonb_build_object('success', true, 'status', 'No Winner', 'reason', 'RESERVE_PRICE_NOT_MET');
    END IF;

    -- 1. Potong saldo reserved penawar yang menang
    v_winner_wallet := public._get_or_create_wallet(v_auction.highest_bidder_id);
    IF v_winner_wallet.reserved_balance >= v_auction.current_highest_bid THEN
      UPDATE public.wallets 
      SET reserved_balance = reserved_balance - v_auction.current_highest_bid
      WHERE id = v_winner_wallet.id;

      PERFORM public._ledger(v_winner_wallet, 'Auction Payment', -v_auction.current_highest_bid,
        v_winner_wallet.available_balance, v_winner_wallet.available_balance,
        v_winner_wallet.reserved_balance, v_winner_wallet.reserved_balance - v_auction.current_highest_bid,
        p_auction_id, NULL, NULL, 'Pembayaran lelang yang dimenangkan', auth.uid(), NULL);
    END IF;

    -- 2. UANG 100% MASUK KE WALLET SELLER (Penjualan Sukses)
    v_seller_wallet := public._get_or_create_wallet(v_auction.seller_id);
    UPDATE public.wallets 
    SET available_balance = available_balance + v_auction.current_highest_bid
    WHERE id = v_seller_wallet.id;

    PERFORM public._ledger(v_seller_wallet, 'Auction Sale Proceeds', v_auction.current_highest_bid,
      v_seller_wallet.available_balance, v_seller_wallet.available_balance + v_auction.current_highest_bid,
      v_seller_wallet.reserved_balance, v_seller_wallet.reserved_balance,
      p_auction_id, NULL, NULL, 'Hasil penjualan lelang untuk barang: "' || v_auction.title || '"', auth.uid(), NULL);

    -- 3. Catat transaksi resmi dengan status 'Paid' (Sesuai Enum Database)
    INSERT INTO public.transactions(auction_id, winner_id, seller_id, final_price, payment_status, payment_deadline)
    VALUES (p_auction_id, v_auction.highest_bidder_id, v_auction.seller_id,
      v_auction.current_highest_bid, 'Paid', now() + make_interval(hours => v_hours))
    ON CONFLICT (auction_id) DO UPDATE 
    SET payment_status = 'Paid', final_price = EXCLUDED.final_price;

    -- 4. Update status lelang menjadi Selesai (Completed)
    UPDATE public.auctions 
    SET status = 'Completed',
        actual_end_time = COALESCE(actual_end_time, end_time), 
        completed_at = now()
    WHERE id = p_auction_id;

    -- Ambil profil pemenang dan total penawaran masuk
    SELECT COALESCE(full_name, username, 'Penawar'), COALESCE(username, 'user')
    INTO v_winner_name, v_winner_username
    FROM public.profiles WHERE id = v_auction.highest_bidder_id;

    SELECT count(*) INTO v_bid_count
    FROM public.bids WHERE auction_id = p_auction_id;

    -- 5. Notifikasi Surat Resmi ke Pemenang & Penjual
    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (v_auction.highest_bidder_id, p_auction_id, 'auction_won', 'Selamat! Anda Menang Lelang',
      'Selamat! Anda memenangkan "' || v_auction.title || '" seharga Rp' || to_char(v_auction.current_highest_bid, 'FM999,999,999,999') || '.',
      jsonb_build_object('amount', v_auction.current_highest_bid, 'auction_title', v_auction.title));

    -- SURAT RESMI KE KOTAK MASUK SELLER
    INSERT INTO public.notifications(user_id, auction_id, type, title, message, metadata)
    VALUES (
      v_auction.seller_id,
      p_auction_id,
      'auction_sold',
      '🏆 Laporan Hasil Akhir: "' || v_auction.title || '" Terjual!',
      'Selamat! Lelang barang "' || v_auction.title || '" Anda telah resmi berakhir dan sukses terjual.' || chr(10) ||
      '• Pembeli / Pemenang: ' || v_winner_name || ' (@' || v_winner_username || ')' || chr(10) ||
      '• Harga Akhir Terjual: Rp' || to_char(v_auction.current_highest_bid, 'FM999,999,999,999') || chr(10) ||
      '• Total Penawaran Masuk: ' || v_bid_count || ' bid' || chr(10) ||
      '• Status Pencairan: Dana sebesar Rp' || to_char(v_auction.current_highest_bid, 'FM999,999,999,999') || ' telah otomatis masuk ke dompet Anda.',
      jsonb_build_object(
        'event', 'auction_completed',
        'auction_title', v_auction.title,
        'winner_name', v_winner_name,
        'winner_username', v_winner_username,
        'winner_id', v_auction.highest_bidder_id,
        'final_price', v_auction.current_highest_bid,
        'amount', v_auction.current_highest_bid,
        'total_bids', v_bid_count,
        'method', 'Lelang Terbuka',
        'completed_at', now()
      )
    );

    RETURN jsonb_build_object('success', true, 'status', 'Completed',
      'winner_id', v_auction.highest_bidder_id, 'seller_id', v_auction.seller_id, 'final_price', v_auction.current_highest_bid);
  ELSE
    UPDATE public.auctions 
    SET status = 'No Winner',
        actual_end_time = COALESCE(actual_end_time, end_time), 
        completed_at = now()
    WHERE id = p_auction_id;
    RETURN jsonb_build_object('success', true, 'status', 'No Winner');
  END IF;
END; $$;

-- ------------------------------------------------------------
-- 6. RPC: ADMIN_END_AUCTION
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 7. GRANT HAK AKSES EKSEKUSI RPC
-- ------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.admin_create_auction TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_bid_with_wallet(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_auction(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_end_auction(uuid, text) TO authenticated;
