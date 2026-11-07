# LelangKu — Versi Publik (Vercel)

**Situs live:** https://lelangku-three.vercel.app

Versi publik dari platform lelang **LelangKu**: satu file statis (`index.html`, tanpa build step) yang membaca data **nyata** langsung dari Supabase, siap di-deploy ke Vercel.

## Isi Folder

| File | Fungsi |
|---|---|
| `index.html` | Seluruh aplikasi (HTML + CSS + JavaScript dalam satu file) |
| `vercel.json` | Konfigurasi deployment statis Vercel (clean URLs, rewrite SPA, header keamanan dasar) |
| `README.md` | Dokumen ini |
| `phase2-wallet-live-control.sql` | Migrasi Fase 2 (wallet, admin control, RPC `place_bid_with_wallet`) — sudah dijalankan di Supabase |

## Cara Deploy ke Vercel

### Opsi A — Import dari dashboard Vercel

1. Push folder ini ke repositori Git (GitHub/GitLab/Bitbucket), atau buat repo baru berisi 3 file ini.
2. Buka [vercel.com/new](https://vercel.com/new), pilih repositori tersebut.
3. Framework Preset: pilih **Other** (ini situs statis, tidak ada build command dan tidak ada output directory khusus — root folder adalah output-nya).
4. Klik **Deploy**. Selesai — Vercel akan memberikan URL publik `https://<nama-project>.vercel.app`.

### Opsi B — Vercel CLI

```bash
npm i -g vercel
cd lelangku-vercel
vercel        # deploy preview
vercel --prod # deploy production
```

Tidak ada environment variable yang perlu diatur: konfigurasi Supabase sudah tertanam di `index.html`.

### Setelah deploy: daftarkan URL di Supabase Auth

Agar login/daftar bekerja dari domain Vercel Anda, buka **Supabase Dashboard → project LelangKu → Authentication → URL Configuration**, lalu tambahkan URL Vercel Anda (mis. `https://lelangku.vercel.app/**`) ke **Redirect URLs** dan isi **Site URL** dengan URL tersebut.

## Konfigurasi Supabase

- Project URL: `https://oseauffstvagprxpgjtn.supabase.co`
- Kunci yang dipakai di frontend adalah **publishable key** — kunci ini memang dirancang untuk publik/browser dan perlindungannya berasal dari Row Level Security (RLS) di database, bukan dari kerahasiaan kuncinya.
- **Tidak ada** kunci privat apa pun di repo ini: tidak ada service_role key, secret key, atau access token. Kunci-kunci tersebut jangan pernah dimasukkan ke kode frontend atau repo.
- Skema database yang diharapkan: tabel `categories`, `auctions`, `auction_images`, `bids`, `profiles`, `watchlists`, `notifications`, serta RPC `place_bid(p_auction_id, p_amount)` — semuanya sudah terpasang & terseed di project Supabase tersebut (6 kategori, 13 lelang, 36 bid saat dibuat).

## Fase 2 — Wallet, Watchlist Sempurna & Admin

Fungsi database baru (sudah terpasang di Supabase):

- Tabel `wallets` dan `wallet_transactions` (saldo tersedia/tertahan + mutasi saldo bertanda +/-).
- Kolom baru di `auctions`: `reserve_price`, `actual_end_time`, `completed_at`; tabel `auction_admin_actions` & `auction_pause_history` untuk audit aksi admin.
- RPC bid baru: `place_bid_with_wallet(p_auction_id, p_amount)` — menggantikan `place_bid`. Bid kini menahan saldo wallet penawar; bila saldo kurang, RPC mengembalikan `code: 'INSUFFICIENT_BALANCE'` beserta pesan, bid minimum, dan saldo wallet.
- RPC wallet: `create_user_wallet(p_user_id)`, `admin_add_wallet_balance(...)`, `admin_deduct_wallet_balance(...)` (pengurangan wajib menyertakan alasan).
- RPC kontrol lelang admin: `admin_end_auction`, `admin_extend_auction(p_minutes)`, `admin_pause_auction`, `admin_resume_auction`, `admin_cancel_auction` (pembatalan wajib alasan). Semua RPC `admin_*` hanya berhasil bila profil pemanggil berperan `admin`.

Fitur aplikasi Fase 2:

- **Watchlist khusus** — Menu "Watchlist" selalu terlihat di navbar, route `#/watchlist`: grid kartu dengan badge Live/Scheduled/Berakhir + Winning/Outbid/Watching, countdown live, filter Semua/Live/Berakhir, tombol Hapus, empty state, dan ikon bintang toggle di kartu marketplace/home yang tersinkron.
- **Wallet** — Menu muncul setelah login, route `#/wallet`, plus indikator saldo tersedia di navbar (realtime dari tabel `wallets`/`wallet_transactions`). Halaman bergaya Finup: total saldo (tersedia + tertahan), kartu Saldo Tersedia & Saldo Tertahan terpisah, grafik garis pergerakan saldo dari mutasi nyata, Analytics Masuk/Keluar bulan berjalan dengan sparkline, dan tabel Latest Wallet Transactions dengan tab filter (Semua/Masuk/Keluar/Lelang/Admin), pencarian, dan pagination 10 per halaman. Bila wallet belum ada, aplikasi memanggil `create_user_wallet`.
- **Bid dengan wallet** — Tombol Pasang Bid memakai `place_bid_with_wallet`; respons saldo kurang menampilkan pesan database + tombol "Buka Wallet"; bid sukses memperbarui saldo navbar dari respons RPC.
- **Admin** — Menu "Admin" hanya tampil untuk profil berperan `admin` (route `#/admin`) dengan tab: **Live Control** (statistik, tabel lelang Live/Paused, panel detail per lelang dengan grafik & riwayat bid, timeline aktivitas admin, dan aksi Akhiri/Perpanjang (+1/+2/+5/+10/+30/custom menit)/Jeda/Lanjutkan/Batalkan — semua lewat dialog konfirmasi + alasan), **Wallet Management** (total semua saldo, tabel semua wallet + pencarian, Tambah/Kurangi Saldo via modal dengan pratinjau saldo baru dan `idempotency_key`), **Buat Lelang** (form berseksi Info Barang / Pricing termasuk Reserve & Buy Now / Jadwal From–To atau Mulai+Durasi preset dengan pratinjau waktu selesai Asia/Jakarta / Pengaturan anti-sniping, panel Product Details live, pilihan Draft/Scheduled/Publish Immediately), dan **Monitoring Bid** (semua bid terbaru dengan filter per lelang & pencarian username, penanda pemimpin saat ini).

### Menjadi admin & saldo awal

- Untuk menjadi admin, **role profil harus diubah menjadi `admin` lewat database** (mis. Supabase SQL Editor: `update public.profiles set role = 'admin' where email = '<email>'`). Tidak ada cara mengangkat diri sendiri dari UI — ini disengaja demi keamanan.
- **Saldo awal pengguna baru adalah Rp0** sampai admin menambahkannya lewat tab Wallet Management. Tanpa saldo, bid akan ditolak dengan kode `INSUFFICIENT_BALANCE`.
- Saldo wallet adalah kredit yang dikelola admin platform, bukan deposit tunai.

## Fitur

- **Home** — Hero dark navy, statistik live (total lelang live, total lelang, total bid, kategori, nilai bid live), Featured Auctions, Live Auctions, Ending Soon, daftar Kategori, dan Cara Kerja 7 langkah.
- **Marketplace** — Semua lelang dari Supabase (join kategori + foto), pencarian nama, filter kategori & status, sortir: berakhir segera / harga tertinggi / harga terendah / terbaru.
- **Kartu lelang** — Foto (fallback placeholder bila foto gagal dimuat), kategori, bid tertinggi/harga awal, jumlah bid, countdown live per detik, status, tombol Lihat Lelang.
- **Halaman detail** (routing hash `#/auction/<slug>`) — Galeri foto dengan thumbnail, deskripsi, kondisi, harga awal, kelipatan minimum, bid minimum berikutnya, total bid, waktu mulai/berakhir + countdown, dan riwayat bid dengan username penawar.
- **Pasang bid** — Wajib login. Memanggil RPC `place_bid_with_wallet` di Supabase (validasi & penahanan saldo dilakukan di database) dan menampilkan pesan sukses/gagal dari respons RPC apa adanya. Dilengkapi quick chips: minimum, +1×, +2×, +5× kelipatan.
- **Watchlist** — Menu khusus `#/watchlist` (lihat Fase 2), bintang toggle di kartu, serta tombol watchlist di halaman detail.
- **Auth** — Modal Masuk/Daftar memakai Supabase Auth (`signInWithPassword` / `signUp`), indikator sesi (nama pengguna) di navbar, dan tombol Keluar.
- **Realtime** — Berlangganan perubahan tabel `auctions` & `bids` via Supabase Realtime sehingga harga & riwayat bid ter-refresh otomatis tanpa reload, plus tombol **Muat Ulang** manual sebagai fallback.
- **Tampilan** — Bahasa Indonesia, format Rupiah (`Intl` id-ID), desain Deep Navy `#101828`/`#172554` + Gold `#D6A84F`, responsif untuk HP dan desktop, dilengkapi loading skeleton, empty state, dan error state.

## Catatan

- Aplikasi ini murni statis: semua logika keamanan & validasi bid hidup di Supabase (RLS + RPC), bukan di file ini.
- Routing memakai hash (`#/`, `#/auction/<slug>`) sehingga tidak membutuhkan konfigurasi server khusus; `vercel.json` tetap menyediakan rewrite SPA untuk path bersih.
