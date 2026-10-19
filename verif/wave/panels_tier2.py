#!/usr/bin/env python3
"""Tier 2 waveform panels: board-level tb (glitch, LIF, lockdown, power_warn) and clock monitor tb."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wave_render import VCD, render, ival

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

def R(label, sig, **kw):
    d = dict(label=label, sig=sig); d.update(kw); return d

# ---------------- board-level Tier 2 ----------------
B = 'tb_de10_nano_top_t2.'; T = B + 'dut.'; U = T + 'u_core.'
SRC2 = 'Sumber: tb_de10_nano_top_t2 (PASS), RTL freeze 19 Okt 2026, build demo, CLK_sys 80 MHz, CLK_sentinel 50 MHz; TDL dan RO memakai model simulasi. (terukur, simulasi)'
csys = R('CLK_sys', U + 'clk_sys', kind='clk', period=12.5, ftext='80 MHz', fill=False, note='80 MHz (domain diserang)')
glitch = R('injeksi glitch', B + 'glitch_low', note='glitch clock (stimulus)', color='red')
rnd = R('ronde AES', U + 'u_aes.round', kind='bus', fmt='dec', note='ronde yang sedang dihitung')
tdl = R('tdl_alert', U + 'tdl_alert', note='sensor TDL (jalur cepat)', color='red')
alsys = R('alarm_sys', U + 'alarm_sys', note='alarm ke gate, tanpa CDC', color='red')
blk = R('blkA (latch gate)', U + 'u_gate.blkA', note='gate menahan rilis', color='red')
gblk = R('gate_blocked', T + 'gate_blocked', note='operasi diblokir', color='red')
ctv = R('ct_valid', U + 'ct_valid', note='ciphertext dirilis', color='green')
fsma = R('alarm di CLK_sentinel', U + 'fsm_alarm', note='setelah sinkronisasi CDC', color='amber')
cnt = R('alarm_count', U + 'tamper_counter', kind='bus', fmt='dec', note='counter alarm (NVM)', color='red')
tear = R('tear_count', U + 'tear_count', kind='bus', fmt='dec', note='counter tear (NVM)', color='amber')
armed = R('tdl_armed', U + 'tdl_armed', note='TDL terkalibrasi', color='green')
depth = R('kedalaman minimum TDL', U + 'tdl_min_r', kind='bus', fmt='dec', note='tap terendah terukur (model)')
sel = R('tap kasar', U + 'tdl_sel', kind='bus', fmt='dec', note='tap dipilih kalibrasi')
warm = R('permit_sys', U + 'permit_sys', note='warm-up monitor selesai', color='green')
opreq = R('op_req', U + 'op_req', note='permintaan enkripsi')
lif = R('lif_alarm', T + 'lif_alarm', note='filter LIF (jalur lambat)', color='red')
spk = R('spike_bus', U + 'spike_bus', kind='bus', fmt='hex', note='spike dari 8 RO')
acc = R('akumulator LIF', U + 'u_lif.acc', kind='bus', fmt='dec', note='potensial membran (integrasi)', color='amber')
zreq = R('zeroize_req', U + 'zeroize_req', note='perintah hapus kunci', color='red')
kz = R('key_is_zero', T + 'key_is_zero', note='kunci master = 0', color='red')
lock = R('lockdown', T + 'lockdown_sys', note='chip terkunci', color='red')
pw = R('power_warn', U + 'power_warn', note='peringatan droop catu', color='amber')
aesb = R('aes_busy', U + 'u_aes.busy', note='AES-128 berjalan')
sw = R('SW[3:0]', B + 'SW', kind='bus', fmt='bin', width=4, note='saklar')
key = R('KEY[1:0]', B + 'KEY', kind='bus', fmt='bin', width=2, note='tombol (aktif 0)')

rows_b = [acc, csys, glitch, rnd, tdl, alsys, blk, gblk, ctv, fsma, cnt, tear, armed, depth, sel, warm, opreq, lif, spk, zreq, kz, lock, pw, aesb, sw, key]
vb = VCD('sim_build/tb_de10_nano_top_t2.vcd', sorted({r['sig'] for r in rows_b}))

P = []
P.append(('T2_00_ikhtisar_seluruh_skenario', vb, dict(
    title='Tier 2: ikhtisar seluruh skenario uji board (simulasi tingkat board, dua domain clock)',
    subtitle='Kalibrasi TDL, operasi 80 MHz, fault software, glitch clock fisik, Sentinel OFF, burst TDL, RO turun (LIF), lockdown, reset, unlock, power_warn',
    t0=0, t1=88000, rows=[sw, key, ctv, glitch, tdl, lif, gblk, cnt, tear, lock, kz, armed],
    regions=[dict(t0=46890, t1=60530, text='LOCKDOWN', color='redsoft', tcolor='red')],
    markers=[dict(t=21258, text='glitch fisik', lane=0), dict(t=27495, text='glitch, Sentinel OFF', color='amber', lane=1),
             dict(t=46470, text='LIF: RO lokal turun', lane=2), dict(t=78990, text='power_warn', color='amber', lane=0)],
    caption=['Glitch saat Sentinel ON ditangkap TDL dan diblokir; saat Sentinel OFF tidak dihitung. Burst TDL 5 siklus dihitung satu kali (counter 3).',
             'Kejadian ke-4 berasal dari jalur lambat (RO + LIF): kunci dihapus dan chip terkunci. power_warn dicatat sebagai tear.', SRC2])))
P.append(('T2_01_boot_kalibrasi_tdl_dan_warmup', vb, dict(
    title='Tier 2: saat boot TDL mengkalibrasi diri, monitor clock warm-up, baru operasi diizinkan',
    subtitle='tdl_armed naik setelah sapuan tap kasar; permit_sys naik setelah warm-up clock monitor; operasi pertama dirilis',
    t0=0, t1=5800, rows=[armed, sel, depth, warm, opreq, ctv],
    markers=[dict(t=1331, text='TDL armed', color='green'), dict(t=4481, text='warm-up selesai', color='green', lane=1),
             dict(t=5431, text='ciphertext pertama', color='green', anchor='end')],
    caption=['Pada model simulasi kedalaman sudah di dalam rentang [16, 60], jadi kalibrasi tetap di tap kasar 0. Di board, kalibrasi yang sama memilih tap 11-14 dan kedalaman 48-52 dari 64 tap tergantung build (terukur, board).',
             'Batasan yang diakui: sebelum TDL armed, AES belum ditolak (fail-open singkat saat boot); perbaikan dijadwalkan.', SRC2])))
P.append(('T2_02_glitch_clock_ditangkap_tdl', vb, dict(
    title='Tier 2: glitch clock di ronde akhir AES ditangkap TDL, ciphertext tidak keluar',
    subtitle='glitch pada CLK_sys -> tdl_alert -> alarm_sys langsung ke gate (tanpa CDC) -> latch gate -> counter naik di domain CLK_sentinel',
    t0=21150, t1=21900, rows=[csys, glitch, rnd, tdl, alsys, blk, gblk, ctv, fsma, cnt],
    markers=[dict(t=21258, text='glitch', color='red'), dict(t=21293.8, text='tdl_alert', color='red', lane=1),
             dict(t=21718.8, text='gate_blocked', color='red', anchor='end')],
    caption=['Glitch ke tdl_alert sekitar 36 ns di sini (2-3 siklus 12,5 ns, tergantung posisi glitch); alert ke alarm gate 0 siklus. ct_valid tetap 0.',
             'Counter alarm 1 -> 2 dicatat setelah alarm menyeberang ke CLK_sentinel lewat sinkronisasi.', SRC2])))
P.append(('T2_03_jalur_lambat_lif_lockdown', vb, dict(
    title='Tier 2: anomali RO lokal ditangkap filter LIF, kejadian ke-4, kunci dihapus, lockdown',
    subtitle='spike dari mesh 8 RO -> LIF -> alarm -> counter 3 -> 4 -> zeroize -> key_is_zero -> lockdown',
    t0=37800, t1=47300, rows=[sw, spk, lif, alsys, gblk, cnt, zreq, kz, lock, ctv],
    markers=[dict(t=38343.8, text='stimulus: periode RO ke-3 x1,18', color='amber'), dict(t=46470, text='lif_alarm', color='red', lane=1, anchor='end'), dict(t=46890, text='key_is_zero', color='red', lane=2)],
    caption=['Satu RO (model) diperlambat (periode x1,18); LIF mengintegrasikan spike lokal per jendela 5,12 µs dan beralarm sekitar 8,1 µs kemudian.', 'LIF membedakan anomali lokal dari drift seragam. Operasi tetap berjalan sampai alarm; setelah lockdown tidak ada ciphertext dirilis.', SRC2])))
P.append(('T2_04_power_warn_abort', vb, dict(
    title='Tier 2: power_warn membatalkan operasi, dicatat sebagai tear',
    subtitle='power_warn (domain CLK_sentinel) saat AES berjalan -> operasi dibatalkan, gate memblokir, tear_count 0 -> 1',
    t0=78700, t1=79500, rows=[csys, aesb, pw, gblk, ctv, tear, cnt],
    markers=[dict(t=78990, text='power_warn', color='amber'), dict(t=79318.8, text='gate_blocked', color='red', anchor='end')],
    caption=['Tidak ada ciphertext dari operasi yang dibatalkan. Counter alarm tidak berubah.', SRC2])))

# ---------------- clock monitor ----------------
M = 'tb_core_t2_clockmon.u_main.'
SRC3 = 'Sumber: tb_core_t2_clockmon (PASS), RTL freeze 19 Okt 2026, nominal CLK_sys 80 MHz, CLK_sentinel 50 MHz; clock dihentikan/diubah oleh testbench. (terukur, simulasi)'
cs_ = R('CLK_sys', M + 'clk_sys', note='domain diserang', fill=False)
cn_ = R('CLK_sentinel', M + 'clk_sen', note='domain pengawas', fill=False)
aes2 = R('aes_busy', M + 'dut.u_aes.busy', note='AES-128 berjalan')
msys = R('monitor CLK_sys', M + 'dut.u_mon_sys.alarm', note='frekuensi di luar batas', color='red')
hbs = R('heartbeat CLK_sentinel mati', M + 'dut.u_w_hbsen.dead', note='watchdog heartbeat', color='red')
cf = R('clk_fault', M + 'clk_fault', note='gangguan clock (sticky)', color='red')
sd = R('sen_dead', M + 'sen_dead', note='CLK_sentinel berhenti', color='red')
al2 = R('alarm_sys', M + 'alarm_sys', note='alarm ke gate', color='red')
pm = R('permit_sys', M + 'dut.permit_sys', note='operasi diizinkan', color='green')
blk2 = R('blkA (latch gate)', M + 'dut.u_gate.blkA', note='gate menahan rilis', color='red')
gb2 = R('gate_blocked', M + 'gate_blocked', note='operasi diblokir', color='red')
ctv2 = R('ct_valid', M + 'ct_valid', note='ciphertext dirilis', color='green')
ac2 = R('alarm_count', M + 'ac', kind='bus', fmt='dec', note='counter alarm (NVM)', color='red')
rows_c = [cs_, cn_, aes2, msys, hbs, cf, sd, al2, pm, blk2, gb2, ctv2, ac2]
vc = VCD('sim_build/tb_clockmon_sel.vcd', sorted({r['sig'] for r in rows_c}))
P.append(('T2_05_clk_sentinel_dihentikan', vc, dict(
    title='Tier 2: CLK_sentinel (domain pengawas) dihentikan di tengah operasi',
    subtitle='heartbeat lintas domain berhenti -> clk_fault dan sen_dead -> gate menahan, operasi ditolak; kejadian dihitung saat clock kembali',
    t0=72500, t1=90500, rows=[cs_, cn_, aes2, hbs, cf, sd, al2, pm, gb2, ctv2, ac2],
    regions=[dict(t0=73727, t1=87729, text='CLK_sentinel berhenti', color='ambersoft', tcolor='amber')],
    markers=[dict(t=75082, text='clk_fault', color='red'), dict(t=88069, text='gate_blocked', color='red', lane=1, anchor='end')],
    caption=['Penyerang tidak bisa mematikan pengawas diam-diam: tanpa CLK_sentinel, CLK_sys menolak operasi dan tidak ada ciphertext dirilis.', SRC3])))
P.append(('T2_06_clk_sys_diperlambat', vc, dict(
    title='Tier 2: CLK_sys diperlambat di luar batas, clock monitor beralarm',
    subtitle='periode CLK_sys menjadi 62,5 ns (nominal 12,5 ns) -> monitor RO lokal mendeteksi -> clk_fault, operasi ditolak',
    t0=133000, t1=137500, rows=[cs_, cn_, msys, cf, al2, pm, ac2],
    markers=[dict(t=133925.0, text='CLK_sys mulai diperlambat', color='amber'), dict(t=135498, text='clk_fault (1.57 µs kemudian)'.replace('.', ','), color='red', lane=1)],
    caption=['Di simulasi monitor membedakan clock lambat/cepat; di board batas sengaja dilebarkan sehingga yang andal di board adalah deteksi clock berhenti.', SRC3])))
P.append(('T2_07_clk_sys_dihentikan_di_tengah_operasi', vc, dict(
    title='Tier 2: CLK_sys (domain yang diserang) dihentikan di tengah enkripsi',
    subtitle='CLK_sys berhenti 5 µs saat AES sedang berjalan -> clk_fault, izin operasi dicabut -> saat clock kembali gate memblokir, counter naik',
    t0=524800, t1=532000, rows=[cs_, cn_, aes2, cf, al2, pm, blk2, gb2, ctv2, ac2],
    regions=[dict(t0=525486, t1=530505, text='CLK_sys berhenti', color='ambersoft', tcolor='amber')],
    markers=[dict(t=526666, text='clk_fault (1,18 µs setelah berhenti)', color='red'), dict(t=531005, text='gate_blocked', color='red', lane=1, anchor='end')],
    caption=['Operasi yang terkena penghentian clock tidak merilis ciphertext; kejadian dihitung sekali.', SRC3])))

for name, v, p in P:
    render(v, p, os.path.join(OUT, name + '.png'))
    print('ok', name)
