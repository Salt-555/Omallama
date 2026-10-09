# gpu-power — efficiency knee + longevity for the RTX PRO 6000 Blackwell

Run the card at the knee of its perf/watt curve, held steady, so it draws the
least power for near-peak LLM throughput and ages as slowly as the silicon
allows.

## The objective, honestly

Max *performance* and max *efficiency* are different points on the same curve.
Above the knee, each extra ~10% of power buys a few percent of throughput. The
knee is the joint optimum — and it is also the longevity optimum. Choosing it
gives up a few percent of peak speed to buy a large cut in heat, power draw and
electrical stress.

## What ages a GPU, and what we can touch

| Wearout mechanism | Driver | Lever on Linux |
| --- | --- | --- |
| Electromigration / TDDB | core voltage | none directly — the PMU owns the V/F curve. A power + clock ceiling makes it settle at a *lower voltage for that clock*. |
| Arrhenius (hotter = faster failure) | temperature | power cap → less heat; physical airflow in the enclosure |
| Thermal cycling (ΔT fatigue) | clock/power churn | a **fixed** clock ceiling stops P-state hopping |
| Current transients | power spikes | power cap |

Steady state is the whole game: a card pinned to one operating point does not
fatigue the way a card that swings between idle and boost thousands of times a
day does.

## For LLM inference specifically

- **Decode** is memory-bandwidth bound. Cutting the **core** clock barely moves
  tokens/sec — capping core is nearly free for generation.
- **Prefill** is compute bound and does care.
- **Memory clock is the decode bottleneck.** Do not lock it down.

So the profile that suits us caps *core* power/clock and leaves memory at full.

## Procedure

1. **Characterize** — find the knee from measurements, not guesses:

   ```bash
   sudo MODEL=~/models/your-model.gguf \
        BENCH=~/CodingProjects/llamacpp-mainline/llama.cpp/build/bin/llama-bench \
        ~/CodingProjects/omallama/gpu-power/efficiency-sweep.sh
   ```

   Writes `~/.local/state/gpu-power/efficiency.csv` with, per power ceiling,
   decode and prefill tokens/sec plus tokens-per-joule. Sweep wider than you
   think you need; the knee is usually lower than expected.

2. **Pick the knee** — the power ceiling past which `tokens_per_joule` stops
   improving (or the last ~5% of throughput costs >20% more power).

3. **Lock it in** — dry-run first, then apply:

   ```bash
   DRY_RUN=1 POWER_LIMIT_W=250 CORE_CLOCK_MAX=1700 \
     ~/CodingProjects/omallama/gpu-power/apply-profile.sh
   sudo POWER_LIMIT_W=250 CORE_CLOCK_MAX=1700 \
     ~/CodingProjects/omallama/gpu-power/apply-profile.sh
   ```

4. **Persist at boot** (system unit, needs root):

   ```bash
   sudo install -Dm755 apply-profile.sh /usr/local/lib/gpu-power/apply-profile.sh
   sudo install -Dm644 README.md         /usr/local/lib/gpu-power/README.md
   printf 'POWER_LIMIT_W=250\nCORE_CLOCK_MAX=1700\n' | sudo tee /etc/gpu-power-profile.conf
   sudo install -Dm644 gpu-power-profile.service /etc/systemd/system/gpu-power-profile.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now gpu-power-profile.service
   ```

5. **Verify** — soak under real load and confirm temp and `clocks.sm` are flat:

   ```bash
   watch -n2 nvidia-smi --query-gpu=power.draw,clocks.sm,temperature.gpu,utilization.gpu --format=csv
   ```

## Kernel-side hygiene (bootloader)

Add to your kernel cmdline and regenerate the boot entry (Arch/Omarchy):

```
pcie_port_pm=off pcie_aspm=off
```

These disable PCIe power management, which is documented as the trigger class
for GSP/GPU-lost faults. Independent of the profile above.

## Files

| File | Purpose |
| --- | --- |
| `efficiency-sweep.sh` | characterize perf/watt; write the CSV |
| `apply-profile.sh` | set the power + core-clock ceiling now (or dry-run) |
| `gpu-power-profile.service` | apply the chosen profile at every boot |

## Caveats

- The sweep needs the card and an installed NVIDIA driver. Without them the
  scripts fail with a clear message rather than guessing.
- The **numbers must come from your card.** Silicon varies per unit; the knee is
  not a constant.
- This is a *static* profile on purpose. Dynamic/per-second NVML polling during
  load is its own stability hazard — don't build a feedback loop on top of it.
