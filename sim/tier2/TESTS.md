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
| `tb_tdl_glitch_line` | Kalibrasi memilih tap coarse saat runtime: tetap di tap 0 bila kedalaman sudah masuk rentang, menyapu sampai tap pertama yang masuk [16, 60] (tap 6 pada model), memakai syarat longgar bila syarat ketat tidak pernah terpenuhi, dan glitch tetap tertangkap pada tap terpilih; kalibrasi aktif dengan kedalaman nominal dan mencatat nilai minimum per polaritas edge; tidak ada alert selama 500 siklus dengan jitter kedalaman; satu capture yang dipendekkan memicu alert dalam 3 edge dan paling lama 2 siklus; satu tap yang terbaca salah tepat di tap ambang (bubble) tidak memicu alert (alert membandingkan kedalaman, bukan satu tap); penurunan di dalam margin diabaikan; tidak ada alert saat Sentinel off; chain jenuh atau edge yang tidak pernah sampai ke chain melaporkan `cal_bad` dan tidak pernah alert |
| `tb_glitch_injector` | Tanpa `arm`, output sama dengan clk_a; satu `arm` menghasilkan tepat satu periode pendek (PHI) dan satu periode panjang (2T - PHI); tidak ada pulsa lebih sempit dari glitch yang dirancang; re-arm menghasilkan satu glitch lagi; ENABLE = 0 meneruskan clk_a tanpa perubahan |
| `tb_slow_path` | RO mesh, P2SE, LIF dan dua detektor ablasi pada RO model: saat stabil, tidak ada detektor yang aktif; drift seragam lambat, LIF dan EWMA tetap diam sementara threshold tetap memberi alarm palsu; penurunan cepat pada satu RO, LIF aktif dalam 4 window; lonjakan seragam cepat di semua RO, LIF tetap diam (common mode) sementara EWMA saja ikut aktif |
| `tb_de10_nano_top_t2` | Top board lengkap dengan model PLL, tombol dan switch: tampilan SW2 menunjukkan TDL armed dan kedalamannya; operasi bersih di 80 MHz merilis ciphertext FIPS-197; serangan SW1 = 0 (jalur Tier 1) diblokir dan dihitung; serangan SW1 = 1 menyuntikkan tepat satu glitch clock di round AES terakhir, TDL menangkapnya, rilis diblokir, dihitung sekali; saat Sentinel off, glitch yang sama tidak diblokir dan tidak dihitung; burst TDL 5 siklus dihitung sekali; tampilan SW2 menghentikan penghitungan; penurunan RO lokal sampai ke counter lewat LIF; event ke-4 menghapus key dan mengunci; KEY0 tidak membatalkan lockdown; SW3 + KEY0 membuka kunci |
| `tb_clock_monitor` | Clock monitor dengan RO lokal sebagai basis waktu (P2-1): clock nominal tidak memicu alarm; clock berhenti, terlalu lambat, dan terlalu cepat masing-masing memicu alarm; kembali nominal, alarm berhenti |
| `tb_core_t2_persist` | Inti Tier 2 dengan `tamper_persist_fsm` (NVM) di `CLK_sentinel` lewat handshake toggle, build demo dan produksi, pada rasio clock sys/sen 80/50, 30/50, 120/50 dan 50/50 berfase beda. Boot dari rekaman valid; operasi bersih merilis ciphertext FIPS-197 C.1; `ct_valid` tidak pernah naik sebelum sisi sys melihat commit bersih dan COMMIT NVM selesai (dicek tiap siklus, rekaman terbaru ber-`in_progress` = 0, `ct_out` nol saat `ct_valid` = 0); alarm dalam operasi di tiga posisi dan `power_warn` dalam operasi tidak merilis dan menaikkan `alarm_count`/`tear_count` di NVM; counter bertahan lewat POR kedua domain, POR di tengah operasi dihitung satu tear; N operasi beralarm mengunci (key nol, request diabaikan, core tidak macet, lockdown bertahan lewat POR); M tear mengunci; NVM kosong mengunci saat boot; reset pengguna (lebar 6 dan 3 siklus) dan `power_warn` disapu di tiap offset setelah request: paling banyak satu tear, handshake selalu tertutup, tidak ada AES untuk request yang terpotong reset, operasi berikutnya normal; alert dan request di dekat lockdown selalu dijawab |
| `tb_core_t2_clockmon` | Inti Tier 2 dengan clock monitor (RO lokal sebagai basis waktu) dan heartbeat silang `CLK_sys`/`CLK_sentinel`, build demo dan produksi. Clock nominal selama minimal 20 window monitor dengan beberapa operasi bersih: tidak ada alarm, setiap operasi merilis ciphertext FIPS-197 C.1; `CLK_sentinel` berhenti (saat idle dan di tengah operasi): tidak ada rilis, request baru ditolak, `sen_dead` dan `clk_fault` terpasang, dihitung satu kali di NVM, bit lengket sampai reset pengguna; `CLK_sys` lebih lambat dari 1/4x dan lebih cepat dari 2x (idle dan di tengah operasi): alarm, gate memblokir, dihitung satu kali per kejadian; `CLK_sys` berhenti di setiap offset operasi (dan berhenti lama): dihitung satu kali, tidak ada rilis setelah clock kembali; Sentinel OFF (demo): tidak ada alarm baru, tidak ada hitungan, jalur demo DFA tetap jalan; warm-up: tidak ada grant sebelum `MON_WARM` window bersih dan sebelum edge heartbeat pertama; heartbeat saja (keluaran monitor dipaksa diam): `CLK_sentinel` atau `CLK_sys` berhenti tetap terblokir dan terhitung; basis waktu (RO) berhenti: watchdog memasang `clk_fault`. Unit balapan: `go` DPA dan jawaban abort (commit tidak bersih) jatuh di siklus `CLK_sys` yang sama (NVM write 1 siklus, sys lambat, sen cepat, `power_warn` sesudah grant): AES tidak dimulai, core kembali idle, tidak ada rilis |

## Batasan

Kedalaman TDL, frekuensi RO, dan apakah glitch yang disuntikkan benar-benar membuat AES salah, bergantung pada delay silikon asli. Semua itu dicek di board, bukan di sini.
