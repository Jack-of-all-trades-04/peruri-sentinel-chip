#!/usr/bin/env python3
"""Tier 1 board-level waveform panels from tb_de10_nano_top (RTL freeze, PASS)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wave_render import VCD, render

OUT = sys.argv[1]
VCDF = 'sim_build/tb_de10_nano_top.vcd'
TB = 'tb_de10_nano_top.'
T = TB + 'dut.'
U = T + 'u_core.'
SRC = 'Sumber: tb_de10_nano_top (PASS), RTL freeze 19 Okt 2026, build demo, clock 50 MHz; parameter waktu tombol diperkecil untuk simulasi. (terukur, simulasi)'

def R(label, sig, **kw):
    d = dict(label=label, sig=sig); d.update(kw); return d

clk = R('clk', T + 'clk', kind='clk', period=20.0, ftext='50 MHz', fill=False, note='50 MHz')
op_req = R('op_req', U + 'op_req', note='permintaan enkripsi')
mark = R('nvm_wr_en', U + 'nvm_wr_en', note='tulis NVM (MARK / COMMIT)', color='amber')
grant = R('op_grant', U + 'op_grant', note='izin dari FSM persisten')
aes = R('aes_busy', U + 'aes_busy', note='AES-128 berjalan (11 siklus)')
done = R('aes_done', U + 'aes_done', note='AES selesai')
fault = R('fault_en', U + 'fault_en', note='fault ronde 9 disuntikkan', color='red')
alarm = R('alarm', U + 'alarm', note='alarm sensor/harness', color='red')
blk = R('blkA (latch gate)', U + 'u_gate.blkA', note='gate menahan rilis', color='red')
gblk = R('gate_blocked', U + 'gate_blocked', note='operasi diblokir', color='red')
cfin = R('commit_fin', U + 'commit_fin', note='COMMIT NVM selesai', color='amber')
ccln = R('commit_clean', U + 'commit_clean', note='COMMIT bersih', color='green')
ctv = R('ct_valid', U + 'ct_valid', note='ciphertext dirilis', color='green')
cto = R('ct_out', U + 'ct_out', kind='bus', fmt='ct', note='port ciphertext', color='green')
cnt = R('alarm_count', U + 'tamper_counter', kind='bus', fmt='dec', note='counter alarm (NVM)', color='red')
tear = R('tear_count', U + 'tear_count', kind='bus', fmt='dec', note='counter tear (NVM)', color='amber')
lock = R('lockdown', U + 'lockdown', note='chip terkunci permanen', color='red')
kz = R('key_is_zero', U + 'key_is_zero', note='kunci master = 0', color='red')
zreq = R('zeroize_req', U + 'zeroize_req', note='perintah hapus kunci', color='red')
azn = R('async_zeroize_n', U + 'async_zeroize_n', note='clear asinkron vault (aktif 0)', color='red')
rstn = R('rst_n (KEY0)', U + 'rst_n', note='reset pengguna', color='amber')
porn = R('por_n core', U + 'por_n', note='reset daya core', color='amber')
cut = R('cutting', T + 'cutting', note='emulasi daya diputus', color='amber')
rdv = R('nvm_rd_valid', U + 'nvm_rd_valid', note='baca rekaman NVM saat boot', color='amber')
pw = R('power_warn', U + 'power_warn', note='peringatan droop catu', color='amber')
key = R('KEY[1:0]', TB + 'KEY', kind='bus', fmt='bin', width=2, note='tombol (aktif 0)')
sw = R('SW[3:0]', TB + 'SW', kind='bus', fmt='bin', width=4, note='saklar')
led7 = R('LED7', TB + 'LED', bitidx=7, note='lockdown', color='red')
led4 = R('LED4', TB + 'LED', bitidx=4, note='enkripsi benar', color='green')
bad = R('released_bad', T + 'released_bad', note='ciphertext SALAH keluar', color='red')

names = sorted({r['sig'] for r in [clk, op_req, mark, grant, aes, done, fault, alarm, blk, gblk, cfin, ccln, ctv, cto, cnt,
                                   tear, lock, kz, zreq, azn, rstn, porn, cut, rdv, pw, key, sw, led7, led4, bad]})
v = VCD(VCDF, names)

P = []
P.append(('T1_00_ikhtisar_seluruh_skenario', dict(
    title='Tier 1: ikhtisar seluruh skenario uji board (simulasi tingkat board)',
    subtitle='Urutan sama dengan demo: bersih, Sentinel OFF, 3 serangan, serangan ke-4 (lockdown), reset, unlock, kartu dicabut, power cut, power_warn',
    t0=0, t1=112000,
    rows=[sw, key, ctv, bad, gblk, cnt, tear, lock, kz, porn, led7, led4],
    regions=[dict(t0=8000, t1=13700, text='Sentinel OFF', color='redsoft', tcolor='red'),
             dict(t0=37010, t1=53330, text='LOCKDOWN', color='redsoft', tcolor='red'),
             dict(t0=73500, t1=100000, text='skenario daya', color='ambersoft', tcolor='amber')],
    markers=[dict(t=9410, text='ciphertext salah bocor (SW0=0)', lane=1),
             dict(t=36790, text='serangan ke-4', lane=0),
             dict(t=47710, text='KEY0', color='amber', lane=1),
             dict(t=53330, text='debug unlock', color='amber', lane=0)],
    caption=['Setiap ct_valid adalah satu ciphertext FIPS-197 C.1 yang dirilis. Dengan Sentinel ON tidak ada ciphertext salah yang keluar (released_bad hanya saat SW0 = 0).',
             'Counter alarm naik 1 per serangan; di serangan ke-4 (N = 4, demo) kunci dihapus dan chip terkunci; KEY0 tidak membukanya. ' , SRC])))
P.append(('T1_01_operasi_bersih', dict(
    title='Tier 1: operasi bersih, ciphertext dirilis setelah COMMIT NVM bersih',
    subtitle='op_req -> MARK ke NVM -> izin FSM -> 0-3 siklus dummy DPA -> AES 11 siklus -> tahan H = 4 -> COMMIT -> ct_valid',
    t0=1250, t1=2400, rows=[clk, op_req, mark, grant, aes, done, blk, cfin, ccln, ctv, cto],
    markers=[dict(t=1350, text='op_req', color='bit'), dict(t=1850, text='aes_done', color='bit', lane=1), dict(t=2230, text='ct_valid (880 ns), ct_out = 69c4e0d8...c55a', color='green', anchor='end')],
    caption=['ct_out bernilai nol sampai ct_valid; nilai yang dirilis 69c4e0d8...c55a = vektor FIPS-197 C.1.',
             'Total op_req ke ct_valid 880 ns (44 siklus @ 50 MHz) pada operasi ini; rentang 43-46 siklus tergantung siklus dummy DPA.', SRC])))
P.append(('T1_02_sentinel_off_ciphertext_salah_bocor', dict(
    title='Tier 1, Sentinel OFF: fault ronde 9 menghasilkan ciphertext salah yang keluar (kondisi rawan DFA)',
    subtitle='SW0 = 0 lalu KEY1: fault disuntikkan, tidak ada alarm, gate tidak memblokir, ciphertext salah dirilis',
    t0=8450, t1=9550, rows=[clk, sw, op_req, fault, aes, done, alarm, gblk, ctv, cto, bad, cnt],
    markers=[dict(t=9410, text='ciphertext salah keluar (ct_out bukan vektor FIPS)', color='red', anchor='end')],
    caption=['Ini pembanding: tanpa Sentinel, satu ciphertext salah sudah cukup untuk analisis DFA. Counter tidak bergerak.', SRC])))
P.append(('T1_03_sentinel_on_serangan_diblokir', dict(
    title='Tier 1, Sentinel ON: serangan yang sama diblokir, counter naik di NVM',
    subtitle='SW0 = 1 lalu KEY1: alarm saat AES berjalan, gate menahan, COMMIT tidak bersih, ct_valid tetap 0',
    t0=14450, t1=15600, rows=[clk, op_req, fault, aes, done, alarm, blk, mark, cfin, ccln, gblk, ctv, cto, cnt],
    markers=[dict(t=15050, text='alarm', color='red'), dict(t=15450, text='gate_blocked', color='red', lane=1)],
    caption=['ct_valid tidak pernah naik dan ct_out tetap 0: ciphertext salah tidak keluar. Counter alarm 0 -> 1 ditulis ke NVM (nvm_wr_en).', SRC])))
P.append(('T1_04_serangan_ke4_lockdown_zeroize', dict(
    title='Tier 1: serangan ke-4 mencapai ambang N = 4, kunci dihapus, chip terkunci',
    subtitle='counter 3 -> 4, zeroize_req, clear asinkron vault, key_is_zero, lockdown',
    t0=36100, t1=37400, rows=[clk, op_req, fault, aes, alarm, blk, mark, cnt, zreq, azn, kz, lock, ctv],
    markers=[dict(t=36610, text='alarm ke-4', color='red'), dict(t=37010, text='lockdown', color='red', lane=1),
             dict(t=37030, text='key_is_zero', color='red', lane=2)],
    caption=['Di skenario ini alarm datang di tengah operasi: alarm 36.610 ns -> key_is_zero 37.030 ns (420 ns), karena FSM menutup operasi dan menulis EVENT ke NVM dulu.',
             'Angka 280 ns di dokumen diukur saat alarm ke-4 datang ketika FSM idle (tb_latency_metrics). Kunci tidak pernah dirilis: ct_valid tetap 0.', SRC])))
P.append(('T1_05_reset_pengguna_tidak_membuka_lockdown', dict(
    title='Tier 1: reset pengguna (KEY0) tidak membuka lockdown',
    subtitle='rst_n ditarik rendah; lockdown dan kunci nol tetap, tidak ada ciphertext dirilis',
    t0=47300, t1=48900, rows=[key, rstn, lock, kz, cnt, ctv, led7, led4],
    markers=[dict(t=47710, text='KEY0 (rst_n = 0)', color='amber')],
    caption=['Lockdown dan counter hidup di domain power-on reset dan NVM, bukan di reset pengguna.', SRC])))
P.append(('T1_06_kartu_dicabut_counter_bertahan', dict(
    title='Tier 1: kartu dicabut (daya core diputus), counter alarm bertahan di NVM',
    subtitle='SW = 1001 + KEY1: por_n core rendah, register core kembali 0, saat boot rekaman NVM dibaca dan counter kembali 2',
    t0=73500, t1=74600, rows=[key, cut, porn, rdv, cnt, tear, lock],
    markers=[dict(t=73730, text='daya diputus', color='amber'), dict(t=74270, text='counter dibaca ulang dari NVM = 2', color='green', lane=1)],
    caption=['Nilai 0 sesaat pada alarm_count adalah register core saat reset; nilai yang berlaku dibaca ulang dari rekaman NVM dua salinan ber-CRC.',
             'Kartu dicabut di luar operasi tidak menambah tear_count.', SRC])))
P.append(('T1_07_power_cut_di_tengah_enkripsi', dict(
    title='Tier 1: daya diputus di tengah operasi (AES selesai, sebelum COMMIT), dicatat sebagai tear',
    subtitle='SW = 1011 + KEY1: daya diputus tepat setelah AES, sebelum COMMIT NVM; saat boot rekaman MARK tanpa COMMIT terbaca, tear_count +1',
    t0=87350, t1=88400, rows=[clk, grant, aes, cut, porn, rdv, mark, tear, cnt, ctv],
    markers=[dict(t=87630, text='daya diputus (sebelum COMMIT)', color='amber'), dict(t=88190, text='tear_count = 1', color='amber', lane=1)],
    caption=['Operasi yang terputus tidak pernah merilis ciphertext (ct_valid tetap 0) dan dihitung tear (M = 8, demo). Counter alarm tidak berubah (2).', SRC])))
P.append(('T1_08_power_warn_membatalkan_operasi', dict(
    title='Tier 1: power_warn (droop catu) membatalkan operasi yang sedang berjalan',
    subtitle='SW = 1101 + KEY1: power_warn naik saat AES, operasi dibatalkan, gate memblokir, tear_count 1 -> 2',
    t0=96350, t1=97150, rows=[clk, grant, aes, done, pw, mark, cfin, ccln, gblk, ctv, tear, cnt],
    markers=[dict(t=96690, text='power_warn', color='amber'), dict(t=96950, text='gate_blocked', color='red', lane=1)],
    caption=['commit_clean tetap 0 sehingga ciphertext tidak dirilis. Kejadian dicatat sebagai tear, bukan alarm.', SRC])))

os.makedirs(OUT, exist_ok=True)
for name, p in P:
    render(v, p, os.path.join(OUT, name + '.png'))
    print('ok', name)
