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

| Testbench | Yang dicek |
|---|---|
| `tb_aes128_core` | Vektor FIPS-197 Appendix C.1, FIPS-197 Appendix B dan NIST SP 800-38A F.1.1; latensi 11 siklus dari `start`; fault satu byte di round 9 mengubah tepat 4 byte ciphertext (pola DFA) |
| `tb_output_release_gate` | Alarm di tengah operasi, saat `aes_done`, dan pada `aes_done`+1 sampai +4 memblokir rilis; alarm di +5 atau tanpa alarm melepas rilis; `ct_out` bernilai nol setiap kali `ct_valid` = 0; Sentinel OFF mengabaikan alarm; lockdown menahan semua rilis |
| `tb_tamper_fsm` | Counter naik sekali per rising edge (alarm sticky 40 siklus dihitung sekali); tidak ada zeroize di bawah N = 4; zeroize dan lockdown saat N; key dihapus secara asinkron; lockdown tetap bertahan setelah user reset; debug unlock demo mengembalikan status demo |
| `tb_de10_nano_top` | Demo board lengkap dengan tombol dan switch: operasi bersih merilis ciphertext FIPS-197 C.1; SW0 = 0 + KEY1 merilis ciphertext faulty; SW0 = 1 + KEY1 memblokir setiap ciphertext faulty dan menaikkan counter; serangan ke-4 menghapus key dan mengunci chip; KEY0 tidak membatalkan lockdown; SW3 + KEY0 membuka kunci untuk latihan |

## Batasan simulasi Tier 1

Alarm berasal dari harness demo (tombol), bukan dari sensor fisik. TDL carry chain dan ring oscillator ditambahkan di Tier 2 (`sim/tier2/`) dan harus dikonfirmasi di board, karena simulasi RTL tidak memodelkan delay gerbang.
