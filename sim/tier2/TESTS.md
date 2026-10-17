# Tes simulasi (Tier 2)

Jalankan semua tes Tier 2: `bash sim/tier2/run_sim_t2.sh`. Tes Tier 1 tetap di `bash sim/run_sim.sh`. Kebutuhan software sama dengan Tier 1 (lihat `sim/TESTS.md`).
Setiap testbench bersifat *self-checking* dan mencetak satu baris `PASS <nama>` atau `FAIL <nama>`.

## Waveform

Setiap testbench menulis `sim_build/<nama_testbench>.vcd` di root repo:

| File | Isi |
|---|---|
| `sim_build/tb_tdl_glitch_line.vcd` | Kalibrasi TDL dan alert saat periode clock dipendekkan |
| `sim_build/tb_glitch_injector.vcd` | Satu glitch clock per `arm` |
| `sim_build/tb_slow_path.vcd` | RO mesh, P2SE, LIF dan detektor pembanding |
| `sim_build/tb_de10_nano_top_t2.vcd` | Demo board Tier 2 lengkap (glitch asli tertangkap TDL) |

Buka dengan `gtkwave sim_build/tb_de10_nano_top_t2.vcd` atau Surfer. Folder `sim_build/` diabaikan oleh git. Tambahkan `-DNO_DUMP` pada perintah `iverilog` untuk melewati waveform.

## Model simulasi

Bagian yang hanya ada di FPGA diganti model di `sim/tier2/models/`: `sys_pll` (clock ideal dengan fase yang bisa diatur) dan `ro_cell` (oscillator yang setengah periodenya diubah oleh testbench). Simulasi RTL tidak punya delay gerbang, jadi output carry chain TDL dipaksa oleh testbench ke pola yang akan terlihat pada chain asli untuk kedalaman tertentu.

## Apa yang diuji

| Testbench | Yang dicek |
|---|---|
| `tb_tdl_glitch_line` | Kalibrasi aktif dengan kedalaman nominal dan mencatat nilai minimum per polaritas edge; tidak ada alert selama 500 siklus dengan jitter kedalaman; satu capture yang dipendekkan memicu alert dalam 2 edge dan paling lama 2 siklus; penurunan di dalam margin diabaikan; tidak ada alert saat Sentinel off; chain jenuh atau edge yang tidak pernah sampai ke chain melaporkan `cal_bad` dan tidak pernah alert |
| `tb_glitch_injector` | Tanpa `arm`, output sama dengan clk_a; satu `arm` menghasilkan tepat satu periode pendek (PHI) dan satu periode panjang (2T - PHI); tidak ada pulsa lebih sempit dari glitch yang dirancang; re-arm menghasilkan satu glitch lagi; ENABLE = 0 meneruskan clk_a tanpa perubahan |
| `tb_slow_path` | RO mesh, P2SE, LIF dan dua detektor ablasi pada RO model: saat stabil, tidak ada detektor yang aktif; drift seragam lambat, LIF dan EWMA tetap diam sementara threshold tetap memberi alarm palsu; penurunan cepat pada satu RO, LIF aktif dalam 4 window; lonjakan seragam cepat di semua RO, LIF tetap diam (common mode) sementara EWMA saja ikut aktif |
| `tb_de10_nano_top_t2` | Top board lengkap dengan model PLL, tombol dan switch: tampilan SW2 menunjukkan TDL armed dan kedalamannya; operasi bersih di 80 MHz merilis ciphertext FIPS-197; serangan SW1 = 0 (jalur Tier 1) diblokir dan dihitung; serangan SW1 = 1 menyuntikkan tepat satu glitch clock di round AES terakhir, TDL menangkapnya, rilis diblokir, dihitung sekali; saat Sentinel off, glitch yang sama tidak diblokir dan tidak dihitung; burst TDL 5 siklus dihitung sekali; tampilan SW2 menghentikan penghitungan; penurunan RO lokal sampai ke counter lewat LIF; event ke-4 menghapus key dan mengunci; KEY0 tidak membatalkan lockdown; SW3 + KEY0 membuka kunci |

## Batasan

Kedalaman TDL, frekuensi RO, dan apakah glitch yang disuntikkan benar-benar membuat AES salah, bergantung pada delay silikon asli. Semua itu dicek di board, bukan di sini.
