# Tes simulasi (Tier 1)

Semua testbench bersifat *self-checking*: setiap testbench mencetak satu baris `PASS <nama>` atau `FAIL <nama>`. Setiap kali dijalankan, testbench juga menulis file waveform (`.vcd`).

## Yang dibutuhkan

| Kebutuhan | Pilihan |
|---|---|
| Simulator | **Icarus Verilog** (`iverilog` dan `vvp`) di PATH. Kalau tidak ada, script otomatis memakai Docker image LibreLane (`ghcr.io/librelane/librelane:3.0.14`). |
| Shell bash | Linux, WSL, atau Git Bash di Windows |
| Penampil waveform | **GTKWave** atau **Surfer** (Surfer juga bisa dibuka di browser: app.surfer-project.org) |

Cara install Icarus Verilog yang disarankan:
- **WSL / Linux**: `sudo apt install iverilog gtkwave`
- **Windows tanpa WSL**: OSS CAD Suite dari GitHub YosysHQ (`oss-cad-suite-build`, versi `windows-x64`). Isinya sudah termasuk iverilog, yosys dan gtkwave.

## Langkah membuat waveform

1. Buka terminal (WSL atau Git Bash) di folder root repo `peruri-sentinel-chip/`.
2. Cek simulator: `iverilog -V`. Kalau muncul versi, lanjut.
3. Jalankan semua tes Tier 1:
   ```
   bash sim/run_sim.sh
   ```
4. Hasil yang benar:
   ```
   PASS  tb_aes128_core
   PASS  tb_aes_sbox
   PASS  tb_core_busy
   PASS  tb_de10_nano_top
   PASS  tb_output_release_gate
   PASS  tb_tamper_fsm
   waveform: sim_build/tb_*.vcd (GTKWave atau Surfer)
   ```
5. Buka waveform, contohnya:
   ```
   gtkwave sim_build/tb_de10_nano_top.vcd
   ```
   Di GTKWave: pilih modul di panel kiri atas (SST), lalu drag sinyal ke panel waveform.

## Lokasi file waveform

| File | Isi |
|---|---|
| `sim_build/tb_aes128_core.vcd` | Uji vektor AES dan pola fault DFA |
| `sim_build/tb_output_release_gate.vcd` | Gate memblokir ciphertext saat alarm |
| `sim_build/tb_tamper_fsm.vcd` | Counter tamper, zeroize, lockdown |
| `sim_build/tb_de10_nano_top.vcd` | Demo board lengkap (paling berguna untuk pitch) |

Folder `sim_build/` ada di root repo dan **diabaikan oleh git** (`.gitignore`). Waveform selalu dibuat ulang dari RTL terbaru, jadi tidak perlu di-commit. Simpan salinan ke folder lain kalau ingin dipakai untuk slide.

Untuk melewati pembuatan waveform (simulasi lebih cepat), tambahkan `-DNO_DUMP` pada perintah `iverilog`.

## Apa yang diuji

Catatan build: `run_sim.sh` membaca komentar `// BUILD: prod|both` di baris awal testbench (default demo). `tb_prod_build` dikompilasi tanpa `DEMO_BUILD`; `tb_aes_sbox` di kedua build.

| Testbench | Yang dicek |
|---|---|
| `tb_aes128_core` | Vektor FIPS-197 Appendix C.1, FIPS-197 Appendix B dan NIST SP 800-38A F.1.1; latensi 11 siklus dari `start`; fault satu byte di round 9 mengubah tepat 4 byte ciphertext (pola DFA) |
| `tb_aes_sbox` | Semua 256 input S-box dibandingkan dengan model acuan independen di testbench (invers GF(2^8) lalu transformasi affine, FIPS-197 bagian 5.1.1), tanpa tabel |
| `tb_core_busy` | Handshake `peruri_sentinel_core` (dengan model NVM): permintaan saat core sibuk (termasuk saat menulis NVM) diabaikan, bukan diantrekan, dan core tetap menerima permintaan berikutnya. Regresi untuk bug yang ditemukan co-simulation: sebelumnya permintaan saat sibuk membuat core macet sampai reset |
| `tb_output_release_gate` | Gate dengan handshake commit: rilis hanya setelah commit NVM bersih (`commit_fin` + `commit_clean`) dan tidak pernah sebelum commit; alarm di tengah operasi, saat `aes_done`, `aes_done`+1 sampai +H, saat menunggu commit, dan di siklus commit memblokir; alarm di siklus keputusan memblokir, alarm di siklus konfirmasi (D+1) dan sesudahnya tidak berpengaruh (gate dua salinan: keputusan D, konfirmasi D+1, `ct_valid` di D+2, satu siklus lebih lambat daripada gate satu salinan); lockdown di siklus keputusan atau konfirmasi memblokir, lockdown sesudah rilis tidak berpengaruh; `gate_fault` tidak pernah muncul pada run tanpa fault; `ct_valid` selalu satu siklus; commit tidak bersih, abort dini (saat operasi dan saat hold) memblokir; commit terlambat 20 siklus tetap dirilis sesudahnya; tanpa commit tidak pernah dirilis; Sentinel OFF mengabaikan alarm tetapi tetap butuh commit; lockdown menahan rilis; `ct_out` nol setiap `ct_valid` = 0 |
| `tb_gate_single_fault` | Kampanye fault tunggal untuk `output_release_gate` (dua salinan kontrol A/B, rilis dua tahap). Gate acuan dan gate uji menerima input identik; pada gate uji satu bit register dibalik (deposit hierarkis di tepi turun, perilaku single-event upset) untuk setiap bit register gate (register data 128 bit: semua bit pada dua skenario rilis, cuplikan 9 bit pada skenario lain; state, counter HOLD, flag blocked/fin/ok kedua salinan, parity, flag tahap, dua rel valid, pulsa status, `ct_hold`, `ct_stage`, `ct_out`) di setiap siklus tujuh operasi (bersih, alarm saat hold, commit tidak bersih, abort dini, lockdown di siklus konfirmasi, commit terlambat, alarm saat WAIT). Cek: tidak pernah ada rilis yang tidak dilakukan gate acuan, paling banyak satu rilis, `ct_out` nol saat `ct_valid` = 0, rilis yang hilang harus disertai `gate_fault` atau `gate_blocked`, data rilis sama dengan acuan (flip register `ct_out` saat valid harus memunculkan `gate_fault`), gate kembali idle. Uji mutasi: tanpa rel valid kedua, tanpa parity, tanpa cek flag tahap atau tanpa cek state, testbench ini gagal |
| `tb_tamper_fsm` | Counter naik sekali per rising edge (alarm sticky 40 siklus dihitung sekali); tidak ada zeroize di bawah N = 4; zeroize dan lockdown saat N; key dihapus secara asinkron; lockdown tetap bertahan setelah user reset; debug unlock demo mengembalikan status demo |
| `tb_de10_nano_top` | Demo board lengkap dengan tombol dan switch: operasi bersih merilis ciphertext FIPS-197 C.1; SW0 = 0 + KEY1 merilis ciphertext faulty; SW0 = 1 + KEY1 memblokir setiap ciphertext faulty dan menaikkan counter; serangan ke-4 menghapus key dan mengunci chip; KEY0 tidak membatalkan lockdown; SW3 + KEY0 membuka kunci untuk latihan. Kontrol daya baru (SW3 = 1 + KEY1): kartu dijauhkan (POR core saja) tidak menghapus `alarm_count`; power-cut di tengah enkripsi menaikkan `tear_count` tanpa ciphertext faulty; `power_warn` membatalkan operasi (diblokir) dan menaikkan `tear_count`; SW3..1 = 111 menukar tampilan LED antara `alarm_count` dan `tear_count` |

| `tb_prod_build` | **Build produksi** (tanpa `DEMO_BUILD`, dengan model NVM): operasi ditolak sebelum key ditulis; key ditulis sekali lewat `key_wr_en`/`key_wr_data` memberi FIPS-197; tulis kedua ditolak (vault tersegel, juga setelah reset user); alarm memblokir dan dihitung; N alarm -> zeroize+lockdown; tidak ada port unlock; key tidak bisa ditulis lagi setelah zeroize; core dengan NVM kosong (belum dipersonalisasi) boot ke lockdown dan tidak merilis apa pun |
| `tb_tamper_persist` | Counter persisten (P1-1, tingkat subsistem `tamper_persist_fsm` + `nvm_counter_model`): NVM kosong boot ke lockdown fail-secure; 3 operasi beralarm -> counter 3; counter bertahan lintas power-cycle; alarm ke-4 -> lockdown + key nol; lockdown bertahan lintas power-cycle |
| `tb_tamper_events` | Jalur alarm/abort FSM persisten: alarm di luar operasi -> EVENT (+1); alarm saat menulis COMMIT -> tertunda lalu EVENT, operasi tetap bersih; alarm saat boot -> dicatat setelah boot; alarm bersamaan dengan permintaan -> dibebankan ke operasi itu (tidak dirilis, satu hitungan); `power_warn` saat MARK -> tidak ada `op_grant`, `tear_count` +1; semua persisten lintas power-cycle |
| `tb_power_warn` | `power_warn` (droop): operasi dibatalkan -> `tear_count` +1, `alarm_count` tetap, tidak ada rilis; power_warn palsu saat serangan tetap tanpa output; `tear_count` = M -> lockdown |
| `tb_nvm_tearing` | Tulis NVM dipotong daya: salinan rusak ditolak CRC, salinan lain dipakai, counter tidak hilang, dua slot non-blank, controller tetap jalan dan counter monotonik |
| `tb_powercut_sweep` | Daya diputus di setiap offset (12) satu operasi: counter monotonik non-turun, satu operasi menambah paling banyak 1 count, tidak pernah ada rilis bersih saat operasi diserang/terputus |
| `tb_seq_wrap` | Nomor urut record NVM 8-bit melewati wrap 255 -> 0: boot harus memilih salinan TERBARU (aritmetika nomor seri), bukan `>=`. Bagian A: lebih dari 260 tulis NVM dan power cycle di setiap nilai 253..2 (5 jenis operasi x 6 offset), counter dibandingkan dengan model acuan setelah setiap boot (tidak turun, tidak ada tear palsu). Bagian B: pasangan record buatan 254/255, 255/0, 0/1, selisih 127, satu salinan rusak, dua rusak, tie (payload sama diterima, payload beda lockdown). Gagal pada logika lama `>=` (dibuktikan). Dilengkapi bukti formal P9 (`tamper_persist.sby`, task `bmc_wrap`)|
| `tb_start_abort_race` | Balapan `go` (akhir siklus dummy DPA) dan `commit_fin` abort pada siklus yang sama di `peruri_sentinel_core`: sapuan waktu `power_warn` dan latensi tulis NVM 1..4 siklus (stub NVM lokal; `nvm_counter_model` minimal 2 siklus sehingga tidak cukup, tumbukan hanya terjadi pada latensi 1), monitor membuktikan koinsidensi siklus-tepat terjadi; core harus kembali idle (`busy = 0`), tidak ada rilis, tear dihitung satu, operasi berikutnya merilis ciphertext benar. Gagal (core macet busy) bila `start` tidak memuat `~commit_fin` |

## Batasan simulasi Tier 1

Alarm berasal dari harness demo (tombol), bukan dari sensor fisik. TDL carry chain dan ring oscillator ditambahkan di Tier 2 (`sim/tier2/`) dan harus dikonfirmasi di board, karena simulasi RTL tidak memodelkan delay gerbang.

## Verifikasi lanjutan (`verif/`)

Selain testbench di atas, folder `verif/` berisi alur verifikasi tambahan. Semua memakai image Docker LibreLane bila tool tidak ada di PATH; `PDK_ROOT` menunjuk ke folder yang berisi `sky130A`.

| Script | Isi |
|---|---|
| `verif/coverage/run_coverage.sh` | Code coverage (Verilator `--coverage`): line, branch, expression, toggle per file RTL, gabungan semua testbench Tier 1 dan Tier 2 |
| `verif/formal/run_formal.sh` | Bukti formal (SymbiYosys) untuk gate + FSM + tripwire + vault dengan AES sebagai input bebas, dibandingkan dengan model acuan spesifikasi. Task `prove` (`sec_ctrl.sby`) dan `tp_prove` (`tamper_persist.sby`) adalah bukti tanpa batas kedalaman (engine abc pdr). `tp_bmc_wrap` bersifat bounded (kedalaman 40). Task `reach_release`, `reach_lockdown`, `tp_reach_wrap` (kedalaman 40), `tp_reach_lock` dan `tp_reach_clean` (kedalaman 60) adalah pencarian cover terbatas kedalaman: menemukan trace adalah hasil yang diharapkan, dan membuktikan bahwa bukti di atas tidak vacuous |
| `verif/netlist/synth_sky130.sh` | Sintesis ke sel standar `sky130_fd_sc_hd`, ringkasan jumlah sel, flip-flop, dan luas per modul (pra-layout, estimasi) |
| `verif/eqy/run_eqy.sh` | Equivalence check (Yosys eqy) RTL terhadap netlist sky130, per modul |
| `verif/gate/run_gate.sh` | Simulasi gate-level `tb_de10_nano_top` pada netlist sky130, toggle coverage gate-level, dan kampanye fault stuck-at pada blok keamanan |
| `verif/gate/run_cosim.sh` | Co-simulation RTL terhadap netlist dengan input acak (termasuk fault hook, alarm, reset), semua output dibandingkan setiap siklus |

