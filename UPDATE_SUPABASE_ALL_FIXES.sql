-- ============================================================
-- 🚀 SCRIPT UTAMA PERBAIKAN SUPABASE (LELANGKU)
-- Salin seluruh isi file ini, paste ke Supabase SQL Editor, lalu klik RUN.
-- Menyelesaikan 2 masalah sekaligus:
-- 1. Izin Admin membuat lelang konsinyasi (RLS & RPC).
-- 2. Konkurensi Detik Sama (Penawar yang kalah cepat milidetik TETAP masuk ke log bids).
-- ============================================================

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
-- 2. RPC: ADMIN_CREATE_AUCTION (Bypass RLS dengan validasi Role Admin)
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
-- 3. TRIGGER MUTASI BIDS TERKONTROL (Anti Bypass SQL)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._check_bid_security()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF current_setting('lelangku.allow_bid_mutation', true) <> 'on' AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'DIRECT_BID_MUTATION_BLOCKED: Penambahan/perubahan bid langsung via SQL atau REST API dilarang keras. Semua bid wajib melalui RPC resmi place_bid_with_wallet().' USING ERRCODE = '42501';
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
  v_bidder_name text;
  v_bidder_username text;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You must be signed in to place a bid');
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bid amount must be a positive number');
  END IF;

  SELECT COALESCE(full_name, username, 'Penawar'), COALESCE(username, 'user')
  INTO v_bidder_name, v_bidder_username
  FROM public.profiles WHERE id = v_user;

  -- Kunci baris lelang secara eksklusif (Row-Level Locking untuk isolasi konkurensi ACID)
  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction not found');
  END IF;

  -- Anti-Shill Bidding: Penjual dilarang menawar barang miliknya sendiri
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
  IF v_prev_amount IS NULL OR v_prev_amount = 0 THEN 
    v_required := v_auction.starting_price;
  ELSE 
    v_required := v_prev_amount + v_auction.minimum_increment; 
  END IF;

  -- 1. Penawar tertinggi saat ini tidak boleh menawar diri sendiri
  IF v_prev_bidder = v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are already the highest bidder');
  END IF;

  -- 2. Cek apakah tawaran di bawah starting price absolut
  IF p_amount < v_auction.starting_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bid must be at least the starting price', 'starting_price', v_auction.starting_price);
  END IF;

  -- 3. Validasi dompet dan ketersediaan saldo
  v_wallet := public._get_or_create_wallet(v_user);
  IF v_wallet.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet is not active', 'code', 'WALLET_INACTIVE');
  END IF;
  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Saldo Anda tidak mencukupi untuk melakukan penawaran ini.',
      'code', 'INSUFFICIENT_BALANCE', 'available_balance', v_wallet.available_balance);
  END IF;

  -- ============================================================
  -- KASUS 1: DETEKSI KONKURENSI TIE / KALAH CEPAT (Outpaced by Milliseconds)
  -- Terjadi saat dua penawar menawar di detik yang sama:
  -- Penawar 1 masuk lebih dulu dan berhasil menaikkan status lelang.
  -- Penawar 2 (kalah beberapa milidetik) menawar nominal yang sudah tidak memenuhi v_required.
  -- Solusi Terdistribusi: Tetap CATAT bid Penawar 2 ke tabel bids sebagai bukti audit sistem!
  -- Saldo Penawar 2 TIDAK terpotong (aman).
  -- ============================================================
  IF p_amount < v_required THEN
    PERFORM set_config('lelangku.allow_bid_mutation', 'on', true);

    SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence
    FROM public.bids WHERE auction_id = p_auction_id;

    -- Catat penawaran ke tabel bids (audit log konkurensi terdistribusi)
    INSERT INTO public.bids (auction_id, bidder_id, amount, bid_sequence)
    VALUES (p_auction_id, v_user, p_amount, v_sequence)
    RETURNING id, created_at INTO v_bid_id, v_created_at;

    -- Surat notifikasi untuk penawar yang kalah cepat
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

  -- ============================================================
  -- KASUS 2: BID SAH TERDEPAN (Pemenang Sementara / Highest Bidder)
  -- ============================================================
  PERFORM set_config('lelangku.allow_bid_mutation', 'on', true);

  SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence
  FROM public.bids WHERE auction_id = p_auction_id;

  INSERT INTO public.bids (auction_id, bidder_id, amount, bid_sequence)
  VALUES (p_auction_id, v_user, p_amount, v_sequence) 
  RETURNING id, created_at INTO v_bid_id, v_created_at;

  -- Kembalikan reservasi penawar sebelumnya yang tersalip
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

  -- Kunci saldo penawar baru ke status reserved
  UPDATE public.wallets 
  SET available_balance = available_balance - p_amount,
      reserved_balance = reserved_balance + p_amount 
  WHERE id = v_wallet.id;

  PERFORM public._ledger(v_wallet, 'Bid Reservation Hold', p_amount,
    v_wallet.available_balance, v_wallet.available_balance - p_amount,
    v_wallet.reserved_balance, v_wallet.reserved_balance + p_amount,
    p_auction_id, v_bid_id, NULL, 'Saldo dikunci untuk penawaran pada lelang: "' || v_auction.title || '"', v_user, NULL);

  -- Anti-Sniping Extension
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
-- 5. GRANT HAK AKSES EKSEKUSI RPC
-- ------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.admin_create_auction TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_bid_with_wallet(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.buy_now_with_wallet(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_auction(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.become_seller() TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_test_notification(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_all_notifications_read() TO authenticated;
