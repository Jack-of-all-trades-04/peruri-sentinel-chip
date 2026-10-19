# Diagram

Acuan terkini (RTL freeze 19 Okt 2026):

- `diagram_blok_rtl_freeze.png`: diagram blok RTL freeze Tier 2.
- `waveforms/`: waveform siklus-akurat dari simulasi RTL freeze (terukur, simulasi). Cara membuat ulang: `verif/wave/`.

Gambar lain:

- `diagram_1_arsitektur_sistem.png`: arsitektur target lengkap, termasuk Tier 3 (HPS, AXI, dashboard) yang belum diimplementasikan.
- `diagram_2_datapath_clock_domain.png`, `diagram_3_fsm_respon_bertingkat.png`, `diagram_4_timing_output_release_gate.png`: gambar versi proposal (8 Okt 2026). Sebagian isinya sudah digantikan oleh RTL freeze 19 Okt, misalnya `graduated_tamper_fsm` diganti `tamper_persist_fsm` dengan NVM, target 120 MHz (kini CLK_sys 80 MHz di FPGA), dan angka zeroize lama. Untuk nilai terkini gunakan `diagram_blok_rtl_freeze.png` dan `waveforms/`.
