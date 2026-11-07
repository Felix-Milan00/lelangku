-- ============================================================
-- LelangKu — Phase 3: Seller System, Privacy Protection, Millisecond Audit & SQL Anti-Bypass
-- Jalankan file ini di Supabase SQL Editor (Dashboard -> SQL Editor -> New Query -> Run)
-- ============================================================

-- 1. PASTIKAN ENUM USER ROLE MEMILIKI 'seller'
DO $$ BEGIN
  ALTER TYPE public.user_role ADD VALUE IF NOT EXISTS 'seller';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 2. UPDATE CHECK CONSTRAINT TRANSAKSI WALLET UNTUK HASIL PENJUALAN SELLER
ALTER TABLE public.wallet_transactions DROP CONSTRAINT IF EXISTS wallet_transactions_transaction_type_check;
ALTER TABLE public.wallet_transactions ADD CONSTRAINT wallet_transactions_transaction_type_check CHECK (
  transaction_type IN (
    'Admin Balance Addition',
    'Admin Balance Deduction',
    'Auction Bid Reservation',
    'Bid Reservation Release',
    'Auction Payment',
    'Auction Sale Proceeds',   -- Saldo masuk untuk Seller ketika barang lelang terjual
    'Buy Now Payment',          -- Pembayaran instan Buy Now
    'Refund',
    'Wallet Adjustment'
  )
);

-- ============================================================
-- 3. PERLINDUNGAN ANTI-BYPASS SQL (Anti-Cheat / Anti-Injection)
-- Mencegah user/hacker melakukan direct INSERT/UPDATE/DELETE ke tabel bids
-- Semua bid WAJIB lewat place_bid_with_wallet() atau buy_now_with_wallet()
-- ============================================================
CREATE OR REPLACE FUNCTION public._check_bid_security()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- Cek apakah pemanggilan berasal dari fungsi RPC terverifikasi
  IF current_setting('lelangku.allow_bid_mutation', true) <> 'on' AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'DIRECT_BID_MUTATION_BLOCKED: Penambahan/perubahan bid langsung via SQL atau REST API dilarang keras. Semua bid wajib melalui RPC resmi place_bid_with_wallet().' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_protect_bids_mutation ON public.bids;
CREATE TRIGGER trg_protect_bids_mutation
  BEFORE INSERT OR UPDATE OR DELETE ON public.bids
  FOR EACH ROW EXECUTE FUNCTION public._check_bid_security();

-- ============================================================
-- 4. RPC: PLACE_BID_WITH_WALLET (Ditingkatkan dengan flag keamanan & audit)
-- ============================================================
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

  -- Kunci baris lelang secara eksklusif (Row-Level Locking untuk mencegah Race Condition)
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
  IF v_prev_amount IS NULL THEN 
    v_required := v_auction.starting_price;
  ELSE 
    v_required := v_prev_amount + v_auction.minimum_increment; 
  END IF;

  IF p_amount < v_required THEN
    RETURN jsonb_build_object('success', false, 'error', 'Bid is too low', 'minimum_required', v_required);
  END IF;
  IF v_prev_bidder = v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'You are already the highest bidder');
  END IF;

  -- Validasi saldo wallet
  v_wallet := public._get_or_create_wallet(v_user);
  IF v_wallet.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Wallet is not active', 'code', 'WALLET_INACTIVE');
  END IF;
  IF v_wallet.available_balance < p_amount THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Saldo Anda tidak mencukupi untuk melakukan penawaran ini.',
      'code', 'INSUFFICIENT_BALANCE', 'available_balance', v_wallet.available_balance);
  END IF;

  -- Buka kunci izin mutasi tabel bids khusus sesi transaksi ini
  PERFORM set_config('lelangku.allow_bid_mutation', 'on', true);

  SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence
  FROM public.bids WHERE auction_id = p_auction_id;

  INSERT INTO public.bids (auction_id, bidder_id, amount, bid_sequence)
  VALUES (p_auction_id, v_user, p_amount, v_sequence) 
  RETURNING id, created_at INTO v_bid_id, v_created_at;

  -- Kembalikan reservasi penawar sebelumnya
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

  UPDATE public.auctions 
  SET current_highest_bid = p_amount,
      highest_bidder_id = v_user, 
      end_time = v_new_end 
  WHERE id = p_auction_id;

  INSERT INTO public.notifications (user_id, auction_id, type, title, message, metadata)
  VALUES (v_auction.seller_id, p_auction_id, 'bid_placed', 'New bid on your auction',
    'A new bid was placed on "' || v_auction.title || '".',
    jsonb_build_object('amount', p_amount, 'bid_id', v_bid_id));

  RETURN jsonb_build_object(
    'success', true, 
    'bid_id', v_bid_id,
    'bid_sequence', v_sequence,
    'created_at_iso', v_created_at,
    'current_highest_bid', p_amount, 
    'extended', v_extended, 
    'new_end_time', v_new_end,
    'wallet_available', v_wallet.available_balance - p_amount,
    'wallet_reserved', v_wallet.reserved_balance + p_amount
  );
END; $$;

-- ============================================================
-- 5. RPC: FINALIZE_AUCTION DENGAN TRANSFER KE SALDO SELLER
-- Ketika lelang berakhir, uang otomatis masuk ke wallet Seller!
-- Serta validasi Reserve Price (Batas Minimum Penjual)
-- ============================================================
CREATE OR REPLACE FUNCTION public.finalize_auction(p_auction_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_auction public.auctions%ROWTYPE;
  v_winner_wallet public.wallets%ROWTYPE;
  v_seller_wallet public.wallets%ROWTYPE;
  v_hours integer := 72;
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
    
    -- CEK RESERVE PRICE: Apakah penawaran memenuhi batas minimum penjual?
    IF v_auction.reserve_price IS NOT NULL AND v_auction.current_highest_bid < v_auction.reserve_price THEN
      -- Batas harga tidak terpenuhi (Reserve Not Met): Kembalikan dana penawar, lelang berstatus 'No Winner'
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

    -- Batas terpenuhi: Eksekusi transaksi
    -- 1. Potong saldo reserved penawar
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

    -- 2. UANG MASUK KE WALLET SELLER! (Penjualan Sukses)
    v_seller_wallet := public._get_or_create_wallet(v_auction.seller_id);
    UPDATE public.wallets 
    SET available_balance = available_balance + v_auction.current_highest_bid
    WHERE id = v_seller_wallet.id;

    PERFORM public._ledger(v_seller_wallet, 'Auction Sale Proceeds', v_auction.current_highest_bid,
      v_seller_wallet.available_balance, v_seller_wallet.available_balance + v_auction.current_highest_bid,
      v_seller_wallet.reserved_balance, v_seller_wallet.reserved_balance,
      p_auction_id, NULL, NULL, 'Hasil penjualan lelang untuk barang: "' || v_auction.title || '"', auth.uid(), NULL);

    -- 3. Catat transaksi resmi
    INSERT INTO public.transactions(auction_id, winner_id, seller_id, final_price, payment_status, payment_deadline)
    VALUES (p_auction_id, v_auction.highest_bidder_id, v_auction.seller_id,
      v_auction.current_highest_bid, 'Completed', now() + make_interval(hours => v_hours))
    ON CONFLICT (auction_id) DO NOTHING;

    UPDATE public.auctions 
    SET status = 'Completed',
        actual_end_time = COALESCE(actual_end_time, end_time), 
        completed_at = now()
    WHERE id = p_auction_id;

    -- Notifikasi ke Pemenang & Penjual
    INSERT INTO public.notifications(user_id, auction_id, type, title, message)
    VALUES (v_auction.highest_bidder_id, p_auction_id, 'auction_won', 'Selamat! Anda Menang Lelang',
      'Selamat! Anda memenangkan "' || v_auction.title || '" seharga Rp' || to_char(v_auction.current_highest_bid, 'FM999,999,999,999') || '.');

    INSERT INTO public.notifications(user_id, auction_id, type, title, message)
    VALUES (v_auction.seller_id, p_auction_id, 'auction_sold', 'Barang Anda Berhasil Terjual!',
      'Selamat! Barang lelang "' || v_auction.title || '" Anda berhasil terjual seharga Rp' || to_char(v_auction.current_highest_bid, 'FM999,999,999,999') || '. Saldo telah masuk ke wallet Anda.');

    RETURN jsonb_build_object('success', true, 'status', 'Completed',
      'winner_id', v_auction.highest_bidder_id, 'seller_id', v_auction.seller_id, 'final_price', v_auction.current_highest_bid);
  ELSE
    -- Tidak ada penawar
    UPDATE public.auctions 
    SET status = 'No Winner',
        actual_end_time = COALESCE(actual_end_time, end_time), 
        completed_at = now()
    WHERE id = p_auction_id;
    RETURN jsonb_build_object('success', true, 'status', 'No Winner');
  END IF;
END; $$;

-- ============================================================
-- 6. RPC: BUY_NOW_WITH_WALLET (Opsi Beli Langsung / Instant Buyout)
-- Memungkinkan pembeli membeli langsung tanpa menunggu countdown lelang
-- ============================================================
CREATE OR REPLACE FUNCTION public.buy_now_with_wallet(p_auction_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user uuid := auth.uid();
  v_auction public.auctions%ROWTYPE;
  v_price bigint;
  v_buyer_wallet public.wallets%ROWTYPE;
  v_seller_wallet public.wallets%ROWTYPE;
  v_sequence integer;
  v_bid_id uuid;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'You must be signed in to purchase');
  END IF;

  SELECT * INTO v_auction FROM public.auctions WHERE id = p_auction_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction not found');
  END IF;
  IF v_auction.seller_id = v_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'You cannot purchase your own auction');
  END IF;
  IF v_auction.status <> 'Live' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Auction is not live');
  END IF;
  IF v_auction.buy_now_price IS NULL OR v_auction.buy_now_price <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'This auction does not have a Buy Now price');
  END IF;

  v_price := v_auction.buy_now_price;

  -- Cek saldo buyer
  v_buyer_wallet := public._get_or_create_wallet(v_user);
  IF v_buyer_wallet.available_balance < v_price THEN
    RETURN jsonb_build_object('success', false, 'error', 'Saldo wallet Anda tidak mencukupi untuk Beli Sekarang.',
      'code', 'INSUFFICIENT_BALANCE', 'available_balance', v_buyer_wallet.available_balance, 'required', v_price);
  END IF;

  -- 1. Kembalikan reservasi penawar tertinggi sebelumnya jika ada
  PERFORM public.release_bid_reservation(p_auction_id);

  -- 2. Buka izin mutasi tabel bids untuk mencatat bid kemenangan akhir
  PERFORM set_config('lelangku.allow_bid_mutation', 'on', true);
  SELECT COALESCE(MAX(bid_sequence), 0) + 1 INTO v_sequence FROM public.bids WHERE auction_id = p_auction_id;
  INSERT INTO public.bids(auction_id, bidder_id, amount, bid_sequence)
  VALUES (p_auction_id, v_user, v_price, v_sequence)
  RETURNING id INTO v_bid_id;

  -- 3. Potong saldo Buyer
  UPDATE public.wallets 
  SET available_balance = available_balance - v_price 
  WHERE id = v_buyer_wallet.id;

  PERFORM public._ledger(v_buyer_wallet, 'Buy Now Payment', -v_price,
    v_buyer_wallet.available_balance, v_buyer_wallet.available_balance - v_price,
    v_buyer_wallet.reserved_balance, v_buyer_wallet.reserved_balance,
    p_auction_id, v_bid_id, NULL, 'Pembayaran instan Buy Now untuk lelang "' || v_auction.title || '"', v_user, NULL);

  -- 4. Tambah saldo ke Seller
  v_seller_wallet := public._get_or_create_wallet(v_auction.seller_id);
  UPDATE public.wallets 
  SET available_balance = available_balance + v_price 
  WHERE id = v_seller_wallet.id;

  PERFORM public._ledger(v_seller_wallet, 'Auction Sale Proceeds', v_price,
    v_seller_wallet.available_balance, v_seller_wallet.available_balance + v_price,
    v_seller_wallet.reserved_balance, v_seller_wallet.reserved_balance,
    p_auction_id, v_bid_id, NULL, 'Hasil penjualan langsung (Buy Now) untuk: "' || v_auction.title || '"', v_user, NULL);

  -- 5. Ubah status lelang menjadi Selesai (Completed)
  UPDATE public.auctions 
  SET status = 'Completed',
      current_highest_bid = v_price,
      highest_bidder_id = v_user,
      actual_end_time = now(),
      completed_at = now()
  WHERE id = p_auction_id;

  -- 6. Notifikasi
  INSERT INTO public.notifications(user_id, auction_id, type, title, message)
  VALUES (v_user, p_auction_id, 'auction_won', 'Pembelian Sukses (Buy Now)',
    'Selamat! Anda telah langsung membeli "' || v_auction.title || '" seharga Rp' || to_char(v_price, 'FM999,999,999,999') || '.');

  INSERT INTO public.notifications(user_id, auction_id, type, title, message)
  VALUES (v_auction.seller_id, p_auction_id, 'auction_sold', 'Barang Anda Terjual via Buy Now!',
    'Barang lelang "' || v_auction.title || '" Anda langsung dibeli oleh pembeli seharga Rp' || to_char(v_price, 'FM999,999,999,999') || '. Saldo telah masuk ke wallet Anda.');

  RETURN jsonb_build_object(
    'success', true, 
    'message', 'Barang berhasil dibeli melalui Buy Now!',
    'final_price', v_price,
    'wallet_available', v_buyer_wallet.available_balance - v_price
  );
END; $$;

-- ============================================================
-- 7. HELPER: AKTIFKAN ROLE SELLER
-- Memungkinkan pengguna mendaftar sebagai seller
-- ============================================================
CREATE OR REPLACE FUNCTION public.become_seller()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_user uuid := auth.uid();
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Must be logged in');
  END IF;

  UPDATE public.profiles
  SET role = 'seller'
  WHERE id = v_user AND role = 'user';

  RETURN jsonb_build_object('success', true, 'role', 'seller');
END; $$;

-- ============================================================
-- 8. GRANT HAK AKSES EKSEKUSI RPC
-- ============================================================
GRANT EXECUTE ON FUNCTION public.place_bid_with_wallet(uuid, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.buy_now_with_wallet(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_auction(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.become_seller() TO authenticated;

