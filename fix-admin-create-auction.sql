-- ============================================================
-- FIX: IZIN ADMIN BUAT LELANG KONSINYASI (RLS & RPC)
-- Salin dan jalankan script ini di Supabase SQL Editor
-- ============================================================

-- 1. Perbarui RLS Policy table auctions agar Admin bisa insert dengan seller_id milik akun seller
DROP POLICY IF EXISTS auctions_insert_seller ON public.auctions;
DROP POLICY IF EXISTS auctions_insert_seller_or_admin ON public.auctions;
CREATE POLICY auctions_insert_seller_or_admin ON public.auctions
  FOR INSERT WITH CHECK (seller_id = auth.uid() OR public.is_admin());

-- 2. Perbarui RLS Policy table auction_images agar Admin bisa insert gambar lelang
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

-- 3. Stored Procedure RPC admin_create_auction (Bypass RLS dengan validasi Role Admin)
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
  -- Pastikan pemanggil adalah Admin
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

GRANT EXECUTE ON FUNCTION public.admin_create_auction TO authenticated;
