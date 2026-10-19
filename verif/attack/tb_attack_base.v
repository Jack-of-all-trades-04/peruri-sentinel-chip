// Automated-attacker testbench for the BASELINE Tier 2 core (before the
// jury-feedback changes). Kept so the baseline search can be repeated:
//   verif/attack/run_attack.py --target base --rtl <baseline rtl dir>
//
// One simulation = one attack scenario (a "genome") given as plusargs.
// The testbench models the physics the RTL cannot model:
//   * TDL depth: nominal 40 / 36 taps (rising / falling launch edge) with
//     +-1 jitter. A clock/voltage glitch of strength S at capture edge C
//     lowers the depth of that capture by S taps.
//   * AES data fault: a glitch with S >= S_AES that hits a busy AES flips
//     the bits MASK of state byte BYTE (the longest path fails first).
//   * local fault (laser/EM model): flips state bits without changing the
//     TDL depth.
//   * power cut: the core loses power for D cycles (all resets low).
// The host requ