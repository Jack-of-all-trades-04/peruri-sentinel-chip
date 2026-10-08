# PERURI-SENTINEL

All-digital fault-attack sensor and key-protection IP for sovereign secure elements (e-Paspor). Designed for the PERURI Chip Hackathon 2026, Topik 01 (Secure Identity & Security Element Chip).

The design layers three defences. A tapped delay line (TDL) glitch canary on the attacked clock reacts within 1 to 2 cycles (target), and an 8-node ring oscillator mesh tracks slower drift over about 2 to 4 µs (estimasi). A multiplier-free leaky integrate-and-fire (LIF) filter separates local anomalies from environmental drift. An output release gate holds ciphertext until the sensors report clean, and graduated tamper response with asynchronous key zeroization limits denial of service. Always-on DPA hiding reduces power-trace correlation. Target platforms: Terasic DE10-Nano (Cyclone V SoC) for the demonstration and SkyWater sky130A through LibreLane for the ASIC flow.

## Gambar

![Gambar 1. Arsitektur sistem](diagrams/diagram_1_arsitektur_sistem.png)

*Gambar 1. Arsitektur sistem: HPS (Linux) terhubung ke fabric FPGA melalui Lightweight AXI-32. Blok bergaris putus hanya ada pada build demo.*

![Gambar 2. Datapath dan domain clock](diagrams/diagram_2_datapath_clock_domain.png)

*Gambar 2. Datapath dan domain clock. Alert TDL menuju output release gate langsung di CLK_sys tanpa CDC (oranye). Alarm lambat dan sinyal lintas domain melalui sync_2ff (biru). Zeroize asinkron ke key vault (merah).*

![Gambar 3. Diagram waktu output release gate](diagrams/diagram_4_timing_output_release_gate.png)

*Gambar 3. Diagram waktu output release gate (ilustrasi). A: operasi bersih; ciphertext dirilis setelah HOLD H = 4 siklus (estimasi). B: glitch pada ronde terakhir terdeteksi TDL dalam 2 siklus (target), gate memblokir rilis, dan tamper_counter naik satu.*

![Gambar 4. FSM respon bertingkat](diagrams/diagram_3_fsm_respon_bertingkat.png)

*Gambar 4. FSM respon bertingkat. Atas: sekuensi per operasi pada output_release_gate (CLK_sys). Bawah: tingkat tamper persisten pada graduated_tamper_fsm (CLK_sentinel). Penghitung naik per tepi naik alarm, bukan per masuk SUPPRESS.*

---

## 1. Threat Model & Physics of Physical Attacks

When an adversary gains physical possession of a sovereign identity document (such as an Indonesian e-Passport or e-KTP), attacks shift from software vulnerabilities to physical penetration:

```
[ PHYSICAL ADVERSARY ]
         │
         ├──► 1. Clock Glitch / Voltage Droop ────► Setup/Hold Violation ──► Instruction Skip / DFA
         ├──► 2. Laser / Optical Injection ──────► Substrate Photo-Current ─► Single Event Upset (SEU)
         └──► 3. Differential Power Analysis ────► Passive Current Traces ──► Master Key Recovery
                                                             │
                                                   [ FATAL EXPLOITATION ]
```

### Fault Injection (FI) & DFA Mitigation
* **Clock Glitches & Voltage Droop (DFA):** An external attacker deliberately introduces a nanosecond-level pulse into the clock pin or drops the power supply voltage ($V_{dd}$) during a critical cryptographic round (e.g., Round 8 or Round 9 of an AES-128/256 operation). This induces setup-time violations ($t_{su}$), causing intermediate state registers to latch corrupted data. If the resulting faulty ciphertext is released, Differential Fault Analysis (DFA; Piret & Quisquater 2003, Biham & Shamir 1997) deduces the private key in minutes with minimal cipher calculations. **Key Architectural Defense:** DFA is defeated not by post-facto key clearing alone, but by an **Output Release Gate** that suppresses faulty ciphertexts from ever reaching the bus.
* **Laser Fault Injection (LFI) & Optical Probing:** A focused infrared laser strike photo-generates electron-hole pairs in the silicon substrate, flipping target bits in registers (Single Event Upsets) to bypass authentication loops (`if (auth_ok == true)`).
  * *Limitation Note:* The 8-node Ring Oscillator mesh provides coarse floorplan monitoring and has limited spatial coverage against micron-scale localized laser spots. Denser substrate sensor grids are designated as future work.

### Side-Channel Analysis (SCA)
* **DPA / CPA:** By sampling instantaneous current draw over thousands of cryptographic rounds using an external oscilloscope on a shunt resistor, an attacker correlates power consumption with the Hamming weight of intermediate cipher states. Because external shunt measurements are completely passive and leave zero electrical footprint on-chip, **silicon hardware cannot detect ongoing DPA recording sessions**. Countermeasures must therefore be **ALWAYS-ON**, desynchronizing execution traces via continuous pseudo-random dummy cycle insertion and clock phase dithering (LFSR).

### Why Conventional Countermeasures Fail
* **Static Analog Detectors:** Process, Voltage, and Temperature (PVT) variations across dies, combined with silicon aging, force wide safety margins on fixed comparators, creating blind spots for calibrated micro-glitches. Moreover, open-source PDKs (SkyWater 130nm / Chip Merah Putih) lack hardened analog sensor IP libraries. An adaptive digital baseline enables tighter thresholds with low false-alarm rates.
* **Dual-Rail Precharge Logic:** Substantially increases silicon area and dynamic power, which is prohibitive for low-cost smart card footprints.
* **Comparison with Temporal Redundancy:** Executing encryption twice and comparing results doubles latency (100% overhead), fails against identical persistent glitches hitting both cycles, and leaves non-cryptographic control flow (e.g., `auth_ok` branches) unprotected. On-chip digital sensors provide complementary defense-in-depth.

---

## 2. Physical Telemetry & On-Chip Sensor Network

Peruri-Sentinel integrates an all-digital, distributed sensor mesh across the silicon floorplan that monitors operational integrity:

```
       ┌────────────────────────────────────────────────────────┐
       │           ALL-DIGITAL ON-CHIP TELEMETRY FABRIC         │
       └───────────────────────────┬────────────────────────────┘
                                   │
         ┌─────────────────────────┴─────────────────────────┐
         ▼                                                   ▼
┌──────────────────┐                                ┌──────────────────┐
│ Fast Path: TDL   │                                │ Slow Path: RO    │
│ Canary Sensor    │                                │ Mesh (8 Nodes)   │
├──────────────────┤                                ├──────────────────┤
│ Samples CLK_sys  │                                │ Gate Window      │
│ 1-2 Cycles Target│                                │ 2-4 µs (Estimasi)│
└────────┬─────────┘                                └────────┬─────────┘
         │                                                   │
         └─────────────────────────┬─────────────────────────┘
                                   ▼
                  [ 12-Channel Digitized Vector ]
                                   │
               (Optional Off-Chip Board Monitor: LTC2308
                12-Bit ADC via Dedicated 2x5 Header)
```

### Tapped Delay Line (TDL) Canary Glitch Sensors (Fast Path)
* **Mechanism:** High-speed carry chains (implemented using Cyclone V ALM fast-carry structures or cascaded delay stages in Sky130).
* **Observation Target:** Samples the attacked system clock (`CLK_sys`) directly (Zick et al., FPGA 2013).
* **Function & Timing:** Any sub-nanosecond clock glitch or transient $V_{dd}$ droop prevents the test edge from traversing its nominal distance, causing an immediate deviation in the TDL register vector within **1 to 2 clock cycles (target)**.

### Distributed Ring Oscillator (RO) Mesh (Slow Path)
* **Mechanism:** Eight small Ring Oscillators (odd-numbered inverter loops) placed across the floorplan near key registers and cipher datapaths. Synthesized with `(* syn_keep = 1 *)` / `(* keep, dont_touch *)`.
* **Physics & Window Calculation:** An oscillator's frequency ($f_{RO} \approx \frac{1}{2 \cdot N \cdot t_{pd}(V_{dd}, T)}$) shifts with temperature and substrate voltage. Cycle counters evaluate frequencies over a parameterizable gate window (`RO_WINDOW` set to 256-512 cycles, estimasi 2.13 µs to 4.27 µs at 120 MHz). Relative frequency resolution is approximately $1/(f_{RO} \times T_{window})$: for $f_{RO} \approx 250$ MHz and $T_{window} \approx 2.13$ µs the counter accumulates about 533 counts, giving about 0.19% (estimasi). Latency is in microseconds (**estimasi 2 to 4 µs**), serving as a slow-drift thermal and supply monitor.

### Optional Off-Chip Board Monitor (LTC2308 ADC)
* **Classification:** The Terasic DE10-Nano features a Linear Technology LTC2308 (8-channel, 12-bit, 500 ksps) ADC accessed via a dedicated 2x5 header.
* **Role:** Serves as a slow, off-chip board-level power monitor for HPS Linux telemetry. It is not part of the internal silicon sensor fabric and cannot detect nanosecond glitches due to its 500 ksps bandwidth limit.

---

## 3. Neuromorphic Edge AI Core Microarchitecture

Daripada menerapkan arsitektur 2D CNN konvensional yang membutuhkan puluhan blok DSP multiplier dan latensi komputasi tinggi, Peruri-Sentinel mengimplementasikan filter spatio-temporal Spiking Neural Network (SNN) berbasis dinamika Leaky Integrate-and-Fire (LIF) neuron.

```
       [ 12-Channel Digitized In-Silicon Telemetry Vector ]
       (8-ch RO Delta Freq + 4-ch TDL Canary Fast Glitch)
                          │
                          ▼
┌────────────────────────────────────────────────────────┐
│      PHASE-TO-SPIKE DELTA ENCODER (P2SE)               │
│      Mengonversi rate-of-change (Δf/Δt) menjadi spike  │
└────────────────────────┬───────────────────────────────┘
                         │ 12 Jalur Spike Paralel
                         ▼
┌────────────────────────────────────────────────────────┐
│      12x8 LEAKY INTEGRATE-AND-FIRE (LIF) NEURONS       │
│                                                        │
│   V[t] = β · V[t-1] + Σ (W_ij · S_j[t])                │
│                                                        │
│   • Datapath Multiplier-Free (Shift-and-Add)           │
│   • Bobot offline terkonfigurasi pada M10K ROM         │
└────────────────────────┬───────────────────────────────┘
                         │ Layer 1 Anomaly Spikes
                         ▼
┌────────────────────────────────────────────────────────┐
│      TEMPORAL COINCIDENCE DETECTOR (OUTPUT LAYER)      │
│      Mengevaluasi korelasi anomali multi-node          │
└────────────────────────┬───────────────────────────────┘
                         │
        ┌────────────────┴────────────────┐
        ▼                                 ▼
[ Output Release Gate Abort ]     [ Graduated Tamper Counter ]
```

### Formulasi Matematis: LIF Leaky Integrator Tanpa Multiplier
Secara matematis, satu neuron LIF dengan input biner beroperasi sebagai leaky integrator (IIR filter orde-satu dengan ambang batas diskrit). Potensial membran setiap neuron $i$ dihitung pada setiap siklus clock:

$$V_i[t] = \left(V_i[t-1] - (V_i[t-1] \gg \text{LEAK\_SHIFT})\right) + \sum_{j=1}^{12} W_{ij} \cdot S_j[t]$$

Keterangan variabel:
* $S_j[t] \in \{0, 1\}$ merepresentasikan keberadaan spike anomali dari kanal telemetri $j$ (8 kanal RO rate-of-change + 4 kanal TDL glitch alert).
* $W_{ij}$ adalah bobot integer bertanda 8-bit.
* Perkalian disederhanakan sepenuhnya menjadi operasi bitwise shift-and-add (multiplier-free datapath), sehingga tidak memerlukan blok DSP hard multiplier.

### Ambang Batas dan Pelepasan Spike
Jika $V_i[t] \ge V_{threshold}$:
1. Neuron menghasilkan spike output: $S_{out, i}[t] = 1$.
2. Potensial membran di-reset secara diskrit: $V_i[t] \leftarrow 0$.

### Latensi Reaksi Sensor Berdasarkan Jalur
* **TDL Canary (Fast Path):** Latensi deteksi 1 sampai 2 siklus clock (target, ~8,3 sampai 16,6 ns pada 120 MHz). Jalur ini mendeteksi glitch clock dan transient voltage droop seketika sebelum setup time register terlanggar.
* **RO Mesh Counters (Slow Path):** Frekuensi dievaluasi melalui jendela pencacah `RO_WINDOW` (256-512 siklus clock, estimasi 2,13 µs sampai 4,27 µs pada 120 MHz). Latensi berada pada skala mikrodetik (estimasi 2 sampai 4 µs) untuk mendeteksi drift termal dan manipulasi substrat lokal.

### Kalibrasi Bobot Offline dan Rencana Uji Ablasi
* **Sumber Bobot:** Bobot $W_{ij}$ tidak dilatih secara online di dalam silikon, melainkan dituning secara offline menggunakan rekaman jejak telemetri sensor RO/TDL pada board DE10-Nano di bawah variasi thermal sweep (25 °C hingga 60 °C) dan transient voltage droop.
* **Rencana Uji Ablasi:** Evaluasi komparatif akan dijalankan pada dataset jejak fisik yang identik:
  1. *Fixed Threshold:* Batas ambang frekuensi statis.
  2. *EWMA Filter:* Exponentially Weighted Moving Average linier tanpa deteksi spasial.
  3. *SNN-LIF dengan Spatial Coincidence:* Arsitektur usulan Peruri-Sentinel.
  * *Metrik Uji:* Detection rate terhadap fault injeksi nyata vs false-trigger rate pada variasi lingkungan wajar.

---

## 4. Arsitektur Pertahanan Berlapis, Output Release Gate, dan Graduated Response

Peruri-Sentinel menerapkan prinsip defense-in-depth dengan tiga lapisan proteksi perangkat keras:

```
                                  [ EVALUASI SENSOR & SNN ]
                                              │
         ┌────────────────────────────────────┼────────────────────────────────────┐
         ▼                                    ▼                                    ▼
[ ALWAYS-ON DPA HIDING ]           [ DETEKSI TRANSIENT ANOMALI ]       [ SERANGAN PERSISTEN TERKONFIRMASI ]
├─ Desinkronisasi trace             ├─ TDL Glitch / RO Frequency Alert  ├─ Tamper Counter >= N (Ambang Bahaya)
├─ Dummy cycle insertion (LFSR)     ├─ Supresi Output Release Gate      ├─ Asynchronous Key Zeroize (<8,3 ns)
└─ Clock phase dithering acak       └─ Increment Tamper Counter (+1)    └─ Permanent Lockdown Mode
```

### Lapisan 1: Always-On DPA Hiding (Bukan Deteksi Pasif)
Pengukuran osiloskop eksternal pada resistor shunt bersifat pasif dan tidak meninggalkan jejak elektrik di dalam silikon. Oleh karena itu, Peruri-Sentinel tidak mengklaim deteksi sesi DPA, melainkan menerapkan mitigasi aktif terus-menerus (always-on DPA hiding):
* Modul LFSR membangkitkan siklus dummy acak dan variasi delay untuk memutus sinkronisasi kurva konsumsi daya (trace desynchronization).
* Mereduksi korelasi statistik konsumsi daya terhadap data rahasia tanpa membebani logika klasifikasi anomali.

### Lapisan 2: Output Release Gate (`output_release_gate`)
Modul ini merupakan benteng utama pencegahan Differential Fault Analysis (DFA):
* Ciphertext hasil komputasi AES ditahan di dalam register output internal dan tidak langsung dirilis ke bus eksternal. Selama operasi, keluaran tertahan dengan `CT_OUT = 0` dan `ct_valid = 0`.
* Sinyal pemblokir `gate_block` menggabungkan tiga sumber: `tdl_alert_any` (langsung dari TDL pada `CLK_sys`, tanpa CDC), `env_alarm_sync` (alarm lambat yang bersifat sticky, melalui synchronizer 2-FF), dan `harness_alarm` (hanya pada build demo, bernilai 0 pada produksi).
* Setelah ronde AES terakhir selesai, gate menahan ciphertext selama H = 4 siklus clock (estimasi): 2 siklus latensi TDL ditambah 2 siklus margin. Ciphertext hanya dirilis jika `gate_block` bernilai 0 selama operasi dan selama H.
* Jalur lambat tidak memutuskan satu operasi AES sendiri. Satu jendela RO lebih panjang daripada satu operasi AES, sehingga jaminan per operasi berasal dari jalur TDL, sedangkan jalur lambat menahan rilis selama alarm aktif.
* **Biaya latensi dan throughput:** AES-128 iteratif membutuhkan sekitar 11 hingga 15 siklus (estimasi). H menambah 4 siklus, dan dummy cycle DPA menambah rata-rata 1,5 siklus (estimasi). Latensi total per operasi menjadi sekitar 16,5 hingga 20,5 siklus, atau 137 hingga 171 ns pada 120 MHz (estimasi). Throughput satu blok 128-bit turun dari sekitar 1,02 hingga 1,40 Gbit/s menjadi 0,75 hingga 0,93 Gbit/s (estimasi), penurunan sekitar 27 hingga 33% (estimasi).

### Lapisan 3: Graduated Response (Respon Bertingkat)
Alih-alih langsung menghapus kunci pada alarm pertama (yang berisiko mematikan paspor warga negara di bandara akibat false positive, atau menjadi celah Denial-of-Service):
1. **Alarm Tunggal:** Operasi kriptografi yang sedang berjalan dibatalkan (abort), output ditahan oleh Output Release Gate, dan register `tamper_counter` bertambah 1 per tepi naik sinyal alarm. Satu kejadian dihitung sekali, di dalam maupun di luar operasi, bukan per siklus.
2. **Ambang Batas Serangan ($N$ Kejadian):** Jika `tamper_counter` mencapai nilai batas $N$ (parameter; demo menggunakan $N = 4$, nilai produksi ditetapkan oleh penerbit dokumen keamanan), sistem menyimpulkan adanya serangan injeksi terencana.
3. **Zeroization & Permanent Lockdown:** Jalur asynchronous clear terpicu, menghapus master key dan register status dalam waktu di bawah 8,3 ns (estimasi, dari analisis TimeQuest STA), mengunci chip secara permanen. Penyerang yang sengaja menginjeksi N kejadian tetap dapat mengunci kartu; trade-off ini dipilih karena kebocoran kunci lebih merusak daripada kartu yang terkunci.

**Persistensi penghitung.** Pada demo DE10-Nano, `tamper_counter` berada di register fabric yang tidak tahan daya mati dan dicerminkan ke kartu microSD oleh HPS. Ini hanya simulasi: FPGA bukan secure element. Pada ASIC, counter harus disimpan di OTP, eFuse, atau NVM host.

### Isolasi Domain Clock dan Clock Domain Crossing (CDC)
* **Sampling Clock Serangan:** Sensor TDL canary beroperasi pada clock sistem yang diserang (`CLK_sys`) untuk menangkap distorsi clock secara langsung (Zick et al., FPGA 2013).
* **Domain Keputusan Terisolasi:** Logika akumulasi SNN, tamper counter, dan modul tripwire beroperasi pada domain clock terisolasi atau dieksekusi secara asinkron.
* **Mitigasi CDC:** Setiap lintasan sinyal alarm dari domain sensor ke domain keputusan dilengkapi synchronizer 2-FF dengan penambahan latensi sinkronisasi ~2 siklus clock untuk mencegah metastabilitas.

### Verifikasi Waktu Zeroization
Waktu propagasi jalur clear asinkron diukur dan diverifikasi melalui timing report Quartus Prime TimeQuest Static Timing Analysis (STA), yang menghasilkan estimasi <8,3 ns pada kecepatan 120 MHz. SignalTap Logic Analyzer tidak dapat mengukur delay fisik sub-siklus karena resolusinya dibatasi oleh periode sample clock; SignalTap digunakan khusus untuk memverifikasi urutan kejadian level siklus.

### Perbandingan dengan Redundansi Temporal (Encrypt Twice and Compare)
Teknik konvensional enkripsi ganda memiliki kelemahan: menggandakan latensi eksekusi (overhead 100%), tidak mampu menangkap fault identik yang menyerang kedua eksekusi, serta tidak melindungi instruksi non-kriptografi (seperti percabangan verifikasi `auth_ok`). Sensor fisik Peruri-Sentinel bersama Output Release Gate memberikan proteksi independen dengan overhead waktu minimal, dan dapat diposisikan sebagai lapisan komplementer.

---

## 5. Estimasi Implementasi Hardware: DE10-Nano & Sky130 ASIC

Desain Peruri-Sentinel menyeimbangkan densitas logika pada FPGA Cyclone V dan kelayakan fabrikasi silikon pada PDK SkyWater 130nm.

```
+-----------------------------------------------------------------------------------------+
|                                    DE10-Nano SoC Overview                               |
|                                                                                         |
|  +--------------------------------+           Lightweight HPS-to-FPGA AXI Bridge        |
|  |       ARM Cortex-A9 HPS        | <================================================>  |
|  |   (Linux Telemetry / API)      |                                                     |
|  +--------------------------------+                                                     |
|                                                                 FPGA Fabric (Cyclone V) |
|  +-----------------------------------------------------------------------------------+  |
|  |  +---------------------+   +----------------------+   +------------------------+  |  |
|  |  | Cryptographic Core  |   | Hardware Tripwire &  |   | Peruri-Sentinel        |  |  |
|  |  | (AES-128/256)       |   | Output Release Gate  |   | SNN Anomaly Core       |  |  |
|  |  +----------▲----------+   +----------▲-----------+   +-----------▲------------+  |  |
|  |             │                         │                           │               |  |
|  |             └─────────────────────────┴───────────────────────────┘               |  |
|  |                                       │                                           |  |
|  |                         Isolated Secure Enclave Bus                               |  |
|  |                                       │                                           |  |
|  |         +─────────────────────────────┴─────────────────────────────+             |  |
|  |         │      Distributed Sensor Mesh (RO Arrays + TDL Registers)  │             |  |
|  |         +───────────────────────────────────────────────────────────+             |  |
|  |                                                                                   |  |
|  |  [Off-Chip Monitor Header] ──► LTC2308 ADC (SPI, 500 ksps, telemetry board level) |  |
|  +-----------------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------------+
```

### Estimasi Anggaran Resource DE10-Nano

| Elemen Resource | Tersedia pada DE10-Nano | Digunakan oleh Peruri-Sentinel | Utilisasi | Peruntukan Arsitektur |
| :--- | :--- | :--- | :--- | :--- |
| **Logic Elements (LE)** | 110.000 | ~14.300 (estimasi) | 13,0% | Sensor counters, datapath SNN-LIF, FSM, Output Gate |
| **DSP Blocks (18x18)** | 112 | 0 | 0,0% | Arsitektur multiplier-free shift-and-add |
| **M10K BRAM Bits** | 5.570 Kbits | ~460 Kbits (estimasi) | 8,2% | SNN Weight ROM & Secure Key Vault |
| **Output Release Gate** | - | ~80 LE (estimasi) | <0,1% | Register penahan ciphertext & supresi output |
| **On-Board ADC** | LTC2308 (8-Ch, 12-bit) | 1 SPI Core Interface | Aktif | Monitor tegangan level board off-chip (bukan sensor silikon) |
| **Target Clock ($F_{\max}$)** | Batas Fisik Silikon | 120 MHz (target) | Aman | Margin timing closure pada speed grade -7 |

### Jalur Implementasi ASIC SkyWater 130nm (LibreLane / OpenROAD)
* **Sintesis Standard Cell:** Karena bebas dari blok hard DSP, seluruh modul SNN-LIF dan sensor disintesis murni menggunakan gerbang logika digital standar (NAND, NOR, DFF) pada PDK terbuka `sky130A`.
* **Rincian Estimasi Luas Area Silikon:**
  * Modul Sensor Mesh + SNN-LIF Anomaly Core + Output Gate + Tripwire: 0,08 sampai 0,12 mm² (estimasi).
  * Modul Baseline Kriptografi AES-128/256: 0,15 sampai 0,22 mm² (estimasi).
  * Total estimasi luas die: <0,35 mm² (target, akan diverifikasi melalui alur LibreLane).
* **Isolasi Tata Letak (Layout Isolation):** Core pengaman dan register kunci dikelompokkan dalam blok fisik terisolasi dengan guard ring untuk mencegah intervensi elektrikal antar substrat.

---

## Struktur repositori

- `diagrams/`: gambar PNG yang ditampilkan di README ini.
- `rtl/`: sumber Verilog (belum ditambahkan).
- `verify/`: testbench Icarus Verilog dan cocotb (belum ditambahkan).
- `librelane/`: konfigurasi alur ASIC sky130A (belum ditambahkan).

## Status

Spesifikasi dan gambar disusun sebelum implementasi RTL. Nilai yang ditandai (target) atau (estimasi) belum diukur pada perangkat keras.
