# SecureVote — Hardware Architecture

## The Platform Decision

The voting machine hardware must satisfy competing demands: it must be cheap enough to deploy at scale (hundreds of thousands of units), secure enough to withstand nation-state-level attacks, reliable enough to survive a 16-hour election day without failure, and built from components that are commercially available and independently auditable — no custom ASICs, no proprietary black boxes.

### Why Not a Raspberry Pi (Directly)

The Raspberry Pi is tempting. It's cheap ($35-$80), widely understood, has massive community support, and runs Linux. But the retail Pi has critical gaps for election use:

| Requirement | Retail Raspberry Pi 5 | Verdict |
|---|---|---|
| TPM 2.0 (firmware attestation) | Not included | FAIL — this is non-negotiable |
| Secure boot chain | Partial (can be configured, but not hardened) | WEAK |
| eMMC storage (reliable, not SD card) | No — SD card only on retail board | FAIL — SD cards corrupt under heavy write loads |
| Tamper-evident enclosure | No — open board | FAIL |
| Hardware RNG | Yes (built into BCM2712) | PASS |
| Battery backup integration | No | FAIL |
| Industrial temperature range | No (-20°C to 70°C needed) | FAIL |
| Long-term availability (10+ years) | Consumer product, no guarantees | RISKY |

### The Answer: Raspberry Pi Compute Module 5 + Custom Carrier Board

The **Raspberry Pi Compute Module 5 (CM5)** solves most of these problems. The CM5 is a system-on-module (SoM) — it contains the processor, RAM, and eMMC storage on a small board with edge connectors. You design a custom **carrier board** that provides everything else: TPM chip, power management, display interface, USB ports, camera connector, and tamper detection.

This gives us the best of both worlds:

- **CM5 provides**: Quad-core ARM Cortex-A76 @ 2.4GHz, 2/4/8GB RAM, 16/32GB eMMC, hardware RNG, VideoCore VII GPU, PCIe 2.0 x1, dual MIPI CSI camera, dual MIPI DSI display, USB 3.0, Gigabit Ethernet, Wi-Fi/Bluetooth (disabled in our firmware)
- **Custom carrier board provides**: Discrete TPM 2.0 chip, secure boot enforcement, battery management, tamper-detect mesh, industrial connectors, thermal management, all peripheral interfaces

The CM5 costs approximately **$25-$45** depending on RAM/eMMC configuration. The custom carrier board, at volume (100,000+ units), would cost approximately **$40-$60**. Total compute platform: **$65-$105**.

### Why Not x86?

Intel/AMD mini PCs with built-in TPM 2.0 exist (Intel NUC, etc.), but they cost 3-5x more, consume 3-10x more power (critical for battery backup), generate more heat (reliability concern in enclosed kiosks), and have vastly larger firmware attack surfaces (UEFI/BIOS complexity dwarfs ARM boot). The ARM ecosystem is simpler, cheaper, and more auditable.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        VOTING MACHINE UNIT                                  │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                    CUSTOM CARRIER BOARD (SecureVote CB-1)              │ │
│  │                                                                        │ │
│  │  ┌──────────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────────┐  │ │
│  │  │ Raspberry Pi │  │ TPM 2.0  │  │ Coral    │  │ Power Management │  │ │
│  │  │ CM5          │  │ Infineon │  │ Edge TPU │  │ + UPS            │  │ │
│  │  │ (main SoC)   │  │ SLB9672  │  │ (AI      │  │                  │  │ │
│  │  │              │  │          │  │ accel)   │  │ LiFePO4 Battery  │  │ │
│  │  └──────┬───────┘  └────┬─────┘  └────┬─────┘  └────────┬─────────┘  │ │
│  │         │               │              │                  │            │ │
│  │  ┌──────┴───────────────┴──────────────┴──────────────────┴─────────┐  │ │
│  │  │                    CARRIER BOARD BUS / INTERFACES                │  │ │
│  │  └──┬──────────┬──────────┬──────────┬───────────┬────────────┬────┘  │ │
│  │     │          │          │          │           │            │        │ │
│  │     │          │          │          │           │            │        │ │
│  └─────┼──────────┼──────────┼──────────┼───────────┼────────────┼────────┘ │
│        │          │          │          │           │            │          │
│   ┌────┴───┐ ┌────┴───┐ ┌───┴────┐ ┌──┴─────┐ ┌──┴──────┐ ┌──┴───────┐  │
│   │ 10.1"  │ │ ID     │ │ Camera │ │ Thermal│ │ Ethernet│ │ USB-A    │  │
│   │ Touch  │ │ Scanner│ │ Module │ │ Printer│ │ (RJ45)  │ │ Ports    │  │
│   │ Display│ │ (OCR)  │ │ (face) │ │ (VVPAT │ │         │ │ (export) │  │
│   │        │ │        │ │        │ │ receipt│ │         │ │          │  │
│   └────────┘ └────────┘ └────────┘ └────────┘ └─────────┘ └──────────┘  │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                    TAMPER-EVIDENT ENCLOSURE                            │ │
│  │  - Polycarbonate shell with tamper-detect mesh                        │ │
│  │  - Serialized security seals on all access points                     │ │
│  │  - Anti-tamper switches on case (triggers alert + log)                │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Selection & Bill of Materials

### Core Compute

| Component | Part | Purpose | Unit Cost (est.) |
|---|---|---|---|
| System on Module | Raspberry Pi CM5 (4GB RAM, 32GB eMMC) | Main processor, storage, I/O | $45 |
| AI Accelerator | Google Coral Edge TPU (USB or M.2) | Facial recognition inference | $25-$60 |
| TPM 2.0 | Infineon SLB9672 (SPI interface) | Firmware attestation, key storage | $3-$5 |
| Carrier Board | Custom "SecureVote CB-1" (see design below) | Interconnect, power, tamper detect | $45-$60 |

**Why the Coral Edge TPU?**

The dual-model biometric matching requires running two neural networks in real time. The CM5's CPU can handle one model (the lightweight geometric model), but the deep learning model (ArcFace-class) needs hardware acceleration. Options considered:

| Accelerator | Performance | Power | Cost | Availability |
|---|---|---|---|---|
| Google Coral Edge TPU | 4 TOPS | 2W | $25-$60 | Widely available |
| Intel Movidius (NCS2) | 1 TOPS | ~1W | $70 | Discontinued — FAIL |
| NVIDIA Jetson Nano | 472 GFLOPS | 5-10W | $149 | Overkill, power-hungry |
| Hailo-8L | 13 TOPS | 1.5W | $30-$40 | Newer, less proven supply |
| Software only (CM5 CPU) | ~0.5 TOPS | — | $0 | Too slow for real-time |

The Coral Edge TPU hits the sweet spot: cheap, low power, fast enough, and available in both USB and M.2 form factors. The M.2 version connects via the CM5's PCIe lane for lower latency.

### Display

| Component | Part | Purpose | Unit Cost |
|---|---|---|---|
| Touchscreen | 10.1" IPS capacitive, 1280x800, MIPI DSI | Ballot display and voter input | $45-$65 |
| Privacy filter | 3M Gold Privacy Screen, 10.1" | Prevents side-angle viewing | $15-$25 |

The display connects via the CM5's MIPI DSI interface (no USB/HDMI adapter needed — lower latency, fewer attack surfaces). A 10.1" screen is large enough for comfortable ballot navigation, including accessibility requirements (large fonts, high contrast).

### Camera (Biometric)

| Component | Part | Purpose | Unit Cost |
|---|---|---|---|
| Camera module | Raspberry Pi Camera Module 3 (12MP, AF) | Facial capture for biometric matching | $25 |
| IR illuminator | 850nm IR LED ring (custom on carrier board) | Consistent lighting, liveness depth | $3-$5 |

The Pi Camera Module 3 connects via MIPI CSI-2 (native interface on CM5). It provides 12MP resolution with autofocus — far more than needed for facial geometry extraction, but the extra resolution helps with liveness detection (detecting printed photos vs. real faces at the pixel level).

The IR illuminator is critical for consistent biometric performance regardless of ambient lighting. Polling places range from bright gymnasiums to dim church basements. IR provides a consistent, invisible light source for the camera.

### ID Scanner

| Component | Part | Purpose | Unit Cost |
|---|---|---|---|
| ID scanner | Custom USB document scanner module | Scan front/back of ID | $30-$50 |
| Alternative | Slot-feed scanner (credit-card style) | Insert ID, auto-scan both sides | $40-$60 |

There are two approaches here. A **flatbed-style scanner** is simpler but requires the voter to position the ID correctly twice (front and back). A **slot-feed scanner** (like a card reader that pulls the ID through) automatically captures both sides in one motion — better UX, fewer errors, slightly more expensive.

For the slot-feed approach, we'd use an off-the-shelf document scanner module (similar to what's used in self-checkout kiosks) with USB interface. The OCR processing runs on the CM5's CPU — this is a lightweight task that doesn't need the TPU.

### Printer

| Component | Part | Purpose | Unit Cost |
|---|---|---|---|
| Thermal printer | Epson TM-T88VII (or equivalent) | VVPAT printout + voter receipt | $250-$350 |
| Thermal printer (budget) | Custom thermal printer module | Same, lower cost at volume | $40-$80 |

The printer serves two critical functions: the VVPAT paper trail (voter reviews under glass before ballot is final) and the voter receipt (QR code + VoteRecordID).

At retail, thermal printers like the Epson TM-T88 are expensive because they're designed for point-of-sale with fancy features. For a voting machine, we need:
- Reliable paper feed (no jams during a 16-hour day)
- Clear print quality for OCR readback during audits
- Two paper paths (one for VVPAT into sealed box, one for receipt to voter)

At volume, a custom thermal printer module with dual paper paths can be manufactured for $40-$80. This is the biggest area where custom hardware reduces cost.

### Power

| Component | Part | Purpose | Unit Cost |
|---|---|---|---|
| Power supply | 12V/5A DC adapter (UL listed) | Primary power | $8-$12 |
| UPS battery | LiFePO4 cell, 12V 6Ah | 4+ hours backup | $25-$40 |
| Power management IC | Texas Instruments BQ25798 | Charge management, switchover | $5-$8 |

LiFePO4 (lithium iron phosphate) chemistry is chosen over standard Li-ion for safety — it doesn't thermally run away, tolerates wider temperatures, and lasts 2,000+ charge cycles. A 6Ah cell at 12V provides approximately 72Wh, enough for 4-6 hours of operation with the full system drawing ~12-15W.

### Network

| Component | Part | Purpose | Unit Cost |
|---|---|---|---|
| Ethernet | Built into CM5 (Gigabit) | Optional ID verification network | $0 (included) |
| Wi-Fi/Bluetooth | Built into CM5 | **DISABLED IN FIRMWARE** | $0 |

The CM5 includes Wi-Fi and Bluetooth radios. These are **permanently disabled at the firmware level** — not just turned off in software, but disabled in the device tree configuration so no software can enable them. The voting machine uses wired Ethernet only, and only for the optional real-time ID verification network. If that network is unavailable, the machine operates fully offline using its local voter roll cache.

### Storage

| Component | Part | Purpose | Unit Cost |
|---|---|---|---|
| Primary storage | CM5 onboard eMMC (32GB) | OS, application, local databases | $0 (included) |
| Export media | USB flash drive (hardware-encrypted) | Encrypted vote data export | $15-$25 |

The 32GB eMMC is more than sufficient. The OS image is ~500MB. The application binary is ~20MB. The local voter roll cache for a large precinct (50,000 voters) is ~200MB. Vote records for a full day (5,000 voters) occupy ~50MB. This leaves ample headroom.

eMMC storage is soldered to the CM5 module — it cannot be removed or swapped without disassembling the module. This is a security feature: no one can pull an SD card and clone it.

### Enclosure

| Component | Part | Purpose | Unit Cost |
|---|---|---|---|
| Enclosure | Custom polycarbonate + aluminum frame | Physical protection, mounting | $30-$50 |
| Tamper mesh | Conductive mesh layer inside enclosure | Detects physical intrusion | $5-$10 |
| Tamper switches | Micro switches on all access panels | Detects case opening | $2-$3 |
| Security seals | Serialized tamper-evident seals (50-pack) | Visual tamper evidence | $0.50 each |
| VVPAT ballot box | Sealed, clear-window paper container | Stores paper audit trail | $10-$15 |

The tamper mesh is a thin conductive grid bonded to the inside of the enclosure. If the enclosure is drilled, cut, or pried open, the mesh breaks, triggering an interrupt on the carrier board that logs a tamper event and can optionally lock the machine.

---

## Custom Carrier Board: SecureVote CB-1

The CB-1 is the custom PCB that the CM5 plugs into. It provides all the interfaces, security hardware, and power management that the CM5 doesn't include.

### Block Diagram

```
                    ┌─────────────────────────────────────────────┐
                    │          SecureVote CB-1 Carrier Board       │
                    │                                             │
CM5 Module ════════╡  ┌──────────────────┐                       │
(200-pin            │  │ CM5 SoM Socket   │                       │
connector)          │  │ (200-pin)        │                       │
                    │  └────┬─────────────┘                       │
                    │       │                                     │
                    │  ┌────┴──── MAIN BUS ─────────────────────┐ │
                    │  │                                         │ │
                    │  │  SPI ──── TPM 2.0 (Infineon SLB9672)   │ │
                    │  │                                         │ │
                    │  │  PCIe ─── Coral Edge TPU (M.2 slot)    │ │
                    │  │                                         │ │
                    │  │  MIPI DSI ── Display connector (FPC)    │ │
                    │  │                                         │ │
                    │  │  MIPI CSI ── Camera connector (FPC)     │ │
                    │  │                                         │ │
                    │  │  USB 3.0 ┬─ ID Scanner port             │ │
                    │  │          ├─ Thermal Printer port         │ │
                    │  │          ├─ Export USB-A port            │ │
                    │  │          └─ Internal hub (2-port)        │ │
                    │  │                                         │ │
                    │  │  USB 2.0 ── Internal: debug (disabled   │ │
                    │  │             in production firmware)      │ │
                    │  │                                         │ │
                    │  │  Ethernet ── RJ45 jack (with isolation  │ │
                    │  │              transformer)                │ │
                    │  │                                         │ │
                    │  │  GPIO ┬── IR illuminator driver          │ │
                    │  │       ├── Tamper mesh monitor            │ │
                    │  │       ├── Tamper switch inputs (x4)      │ │
                    │  │       ├── Status LEDs (power, active,    │ │
                    │  │       │   error, tamper)                 │ │
                    │  │       ├── Buzzer (audio alerts)          │ │
                    │  │       └── Paper-low sensor (printer)     │ │
                    │  │                                         │ │
                    │  │  I2C ──── Power management IC            │ │
                    │  │           (BQ25798 + fuel gauge)         │ │
                    │  │                                         │ │
                    │  └─────────────────────────────────────────┘ │
                    │                                             │
                    │  ┌─── POWER SECTION ───────────────────────┐ │
                    │  │  12V DC input jack                       │ │
                    │  │  LiFePO4 battery connector               │ │
                    │  │  BQ25798 charge controller               │ │
                    │  │  5V/3.3V voltage regulators              │ │
                    │  │  Power sequencing logic                  │ │
                    │  │  Battery fuel gauge (I2C)                │ │
                    │  └─────────────────────────────────────────┘ │
                    │                                             │
                    │  ┌─── SECURITY SECTION ────────────────────┐ │
                    │  │  Tamper mesh monitor circuit             │ │
                    │  │  4x tamper switch inputs (debounced)     │ │
                    │  │  Tamper event latch (persists w/o power) │ │
                    │  │  Optional: battery-backed SRAM for       │ │
                    │  │  tamper-sensitive key storage             │ │
                    │  └─────────────────────────────────────────┘ │
                    │                                             │
                    │  Board dimensions: 170mm x 120mm            │
                    │  Layers: 4-layer PCB                        │
                    │  Temperature: -20°C to 70°C operating       │
                    └─────────────────────────────────────────────┘
```

### Key Design Decisions

**TPM 2.0 via SPI (not I2C).** The Infineon SLB9672 connects over SPI for higher throughput and lower latency than I2C alternatives. SPI is also less susceptible to bus-sniffing attacks because it uses dedicated chip-select lines.

**Coral TPU via PCIe (not USB).** The M.2 form factor Coral Edge TPU uses the CM5's PCIe x1 lane. This provides ~5 Gbps bandwidth (vs. 480 Mbps for USB 2.0 or 5 Gbps shared for USB 3.0) and lower, more predictable latency for biometric inference. The M.2 slot also physically secures the accelerator — it can't be unplugged without opening the enclosure.

**No Wi-Fi antenna trace on carrier board.** Even though the CM5 has Wi-Fi disabled in firmware, the carrier board does not include an antenna trace, U.FL connector, or RF matching network for Wi-Fi. There is physically no antenna for Wi-Fi to use, even if someone managed to re-enable the radio in software.

**Dedicated USB ports.** Each peripheral (scanner, printer, export drive) gets its own USB port via an onboard USB hub. Ports are physically labeled and mechanically keyed where possible (e.g., the export USB-A port is recessed behind a lockable door). No peripheral can be hot-swapped during voting without opening the enclosure.

**Opto-isolated Ethernet.** The RJ45 Ethernet jack includes an isolation transformer and TVS protection. This protects against electrical attacks injected through the network cable and provides galvanic isolation between the machine and the polling-place network.

---

## Total Bill of Materials

### Per-Unit Cost at Volume (100,000+ units)

| Category | Components | Est. Cost |
|---|---|---|
| **Compute** | CM5 (4GB/32GB), Coral TPU, TPM 2.0 | $73-$110 |
| **Carrier Board** | CB-1 PCB, connectors, passives, power ICs | $45-$60 |
| **Display** | 10.1" touchscreen + privacy filter | $60-$90 |
| **Camera** | Pi Camera Module 3 + IR illuminator | $28-$30 |
| **ID Scanner** | Slot-feed document scanner module | $40-$60 |
| **Printer** | Custom dual-path thermal printer module | $40-$80 |
| **Power** | 12V adapter + LiFePO4 battery + management | $38-$60 |
| **Enclosure** | Polycarbonate shell, tamper mesh, switches, seals | $47-$78 |
| **Networking** | Ethernet cable + RJ45 (included on board) | $2-$5 |
| **Miscellaneous** | Cables, mounting hardware, packaging | $15-$25 |
| | | |
| **TOTAL PER UNIT** | | **$388-$598** |
| **Target at volume** | | **~$500** |

### Cost Comparison

| System | Est. Per-Unit Cost | Notes |
|---|---|---|
| **SecureVote** | **~$500** | Custom hardware, all features |
| ES&S ExpressVote | $3,000-$5,000 | Current market leader |
| Dominion ICE | $3,000-$4,000 | Current market |
| Hart InterCivic Verity | $2,500-$4,500 | Current market |
| Budget DRE (touchscreen only) | $1,500-$2,500 | Basic, fewer features |

SecureVote hardware costs roughly **10-15% of current commercial voting machines** while providing superior security features (TPM attestation, biometric auth, Merkle-tree immutability, AI-accelerated ID verification). The savings come from:

1. Using commodity ARM compute (CM5) instead of custom x86 boards
2. Open-source software (no per-unit licensing fees)
3. Commodity peripherals instead of proprietary modules
4. Scale economics of the Raspberry Pi ecosystem

### National Deployment Cost Estimate

The United States has approximately **175,000 polling places** with an average of **4-8 machines each**. Assuming 6 machines per location:

| Scenario | Machines | Hardware Cost | Per-Voter Cost (160M voters) |
|---|---|---|---|
| Minimum (4/location) | 700,000 | $350M | $2.19 |
| Standard (6/location) | 1,050,000 | $525M | $3.28 |
| Maximum (8/location) | 1,400,000 | $700M | $4.38 |

For context, the current annual cost of election administration in the US is estimated at $2-$4 billion. A one-time $525M hardware investment (with a 10-year lifecycle) adds roughly $52.5M per year — a modest increment for a dramatically more secure system.

---

## Firmware & Boot Security

### Secure Boot Chain

```
1. CM5 ROM Bootloader (immutable, burned into silicon)
   │
   ├── Verifies: U-Boot signature (Ed25519, key in OTP fuses)
   │
   ▼
2. U-Boot (signed)
   │
   ├── TPM attestation: measures own hash into PCR[0]
   ├── Measures kernel hash into PCR[1]
   ├── Measures device tree hash into PCR[2]
   ├── Verifies: Linux kernel signature
   │
   ▼
3. Linux Kernel (signed, minimal, custom-built)
   │
   ├── Measures initramfs hash into PCR[3]
   ├── Verifies: initramfs signature
   ├── Mounts root filesystem READ-ONLY (dm-verity)
   │
   ▼
4. Initramfs
   │
   ├── Mounts encrypted data partition (LUKS2, key sealed to TPM PCRs)
   ├── Verifies: sv-machine binary hash against TPM-sealed expected hash
   │
   ▼
5. sv-machine binary
   │
   ├── Step 1: TPM attestation (verify all PCR values match expected)
   ├── Step 2: Hardware self-test
   ├── ... (normal boot sequence)
```

Every link in this chain is verified before the next one loads. If any hash doesn't match — the ROM bootloader won't load U-Boot, U-Boot won't load the kernel, the kernel won't mount the filesystem, and the application won't start. The machine displays "FIRMWARE INTEGRITY FAILURE" and refuses to operate.

### TPM PCR Allocation

| PCR | Measures | Purpose |
|---|---|---|
| PCR[0] | U-Boot hash | Bootloader integrity |
| PCR[1] | Linux kernel hash | Kernel integrity |
| PCR[2] | Device tree hash | Hardware configuration integrity |
| PCR[3] | Initramfs hash | Early userspace integrity |
| PCR[4] | sv-machine binary hash | Application integrity |
| PCR[5] | Configuration file hash | Runtime config integrity |
| PCR[6] | BDF hash | Ballot definition integrity |
| PCR[7] | Reserved for future use | — |

The LUKS2 encryption key for the data partition is **sealed to PCRs 0-5**. This means the data partition can only be decrypted if the entire boot chain (from bootloader through application binary and config) matches the expected state. If anyone modifies any component, the TPM refuses to unseal the key, and the data remains encrypted.

### Operating System

The voting machine runs a **custom-built, minimal Linux** distribution:

- **Kernel**: Latest LTS Linux kernel (e.g., 6.6.x), compiled with only the drivers needed for the specific hardware. No module loading at runtime.
- **Root filesystem**: Read-only, verified by dm-verity. The hash tree for dm-verity is signed and checked at boot.
- **No package manager**: apt, dpkg, snap — none of these exist on the image. Software is updated only by flashing a new firmware image.
- **No shell access**: No bash, no sh, no login prompt. The console outputs kernel logs only. There is no way to "log in" to the machine.
- **No SSH**: The SSH daemon is not included in the image at all — not disabled, not present.
- **No unnecessary services**: No cron, no syslog (replaced by the application's own structured logging), no systemd (replaced by a minimal init that launches sv-machine and nothing else).
- **Minimal userspace**: busybox (for init and emergency recovery only, not accessible during normal operation), the sv-machine binary, and the Coral Edge TPU runtime library. That's it.

### Firmware Update Process

1. A new firmware image is built from published source using the reproducible build process.
2. The image is signed with the firmware signing key (HSM, 3-of-5 threshold).
3. The signed image is published on the transparency log with its hash.
4. During the pre-election provisioning window (>30 days before election), the image is loaded onto encrypted USB drives.
5. An election official inserts the USB into the machine's export port and authenticates with their worker credential.
6. The machine verifies the firmware signature, compares the version (prevents rollback to older versions), and begins the update.
7. The update writes to a secondary boot partition (A/B partitioning). The machine reboots into the new partition.
8. If the new firmware fails to boot successfully (attestation fails, self-test fails), the machine automatically falls back to the previous partition.
9. After successful boot, the machine performs a full LAT (Logic and Accuracy Test) before being cleared for deployment.

No firmware updates are permitted within 30 days of an election, except for critical security patches that require 3-of-5 signing authority approval and mandatory re-LAT of all patched machines.

---

## Peripheral Specifications

### ID Scanner

| Spec | Requirement |
|---|---|
| Resolution | 600 DPI minimum (for OCR accuracy) |
| Color depth | 24-bit color (needed for ID photo extraction) |
| Scan speed | < 3 seconds for both sides |
| Document size | Credit card to passport page |
| Interface | USB 2.0 (adequate bandwidth for images) |
| Illumination | White LED (built into scanner module) |
| Feed mechanism | Slot-feed (insert, auto-capture, auto-eject) |
| Durability | 100,000+ scan cycles |

The scanner module must support "deskew" (auto-straightening tilted scans) in hardware or firmware. The OCR is performed by the CM5's CPU using an open-source OCR engine (Tesseract or equivalent, compiled into sv-machine).

### Camera (Biometric)

| Spec | Requirement |
|---|---|
| Resolution | 8MP minimum (12MP with Pi Camera Module 3) |
| Frame rate | 30fps for liveness detection, 2fps for presence monitoring |
| Focus | Autofocus (fixed focus is insufficient for varying voter heights) |
| Interface | MIPI CSI-2 (native CM5 interface) |
| IR capability | Via external IR illuminator on carrier board |
| Field of view | 66° (Pi Camera Module 3 default) — captures face at 30-60cm |
| Mounting | Fixed position above display, angled 15° down |

The camera mount is critical. It must be positioned so that a seated or standing voter's face is centered in frame at the typical interaction distance (30-60cm from the screen). The 15° downward angle accommodates the range of voter heights without requiring mechanical adjustment.

### Thermal Printer

| Spec | Requirement |
|---|---|
| Print width | 80mm (standard thermal receipt width) |
| Resolution | 203 DPI minimum (for readable text and QR codes) |
| Speed | 150mm/sec minimum |
| Paper paths | **TWO**: one for VVPAT (into sealed box), one for receipt (to voter) |
| Paper roll | 80mm x 80m per roll (enough for ~1,000 VVPAT records) |
| Auto-cutter | Yes (partial cut for VVPAT, full cut for receipt) |
| Interface | USB 2.0 |
| MTBF | 60 million lines |
| Paper-low sensor | Yes (alerts poll worker before paper runs out) |

The dual paper path is the most custom element. The VVPAT paper feeds through a transparent viewing window where the voter can read their selections, then drops into a sealed ballot box beneath the machine. The receipt paper feeds to a slot in the front of the enclosure where the voter collects it.

### Display

| Spec | Requirement |
|---|---|
| Size | 10.1" diagonal |
| Resolution | 1280 x 800 (WXGA) |
| Type | IPS (wide viewing angle for voter; privacy filter limits side view) |
| Touch | 10-point capacitive (responsive, no stylus needed) |
| Interface | MIPI DSI (native CM5, no adapter) |
| Brightness | 350+ nits (readable in bright polling places) |
| Contrast | 800:1 minimum |
| Surface | Anti-glare, anti-fingerprint coating |

ADA compliance note: the touchscreen must support an external accessibility device (sip-and-puff, paddle switch) via the USB port for voters with motor disabilities. The ballot rendering software supports these input methods.

---

## Power Budget

| Component | Typical Draw | Peak Draw |
|---|---|---|
| CM5 (4GB) | 3.5W | 8W |
| Coral Edge TPU | 2W | 4W (during inference) |
| 10.1" Display | 3W | 5W (full brightness) |
| Camera | 0.5W | 1W |
| ID Scanner | 0W (idle) | 5W (scanning) |
| Thermal Printer | 0W (idle) | 30W (printing) |
| Carrier board (TPM, LEDs, etc.) | 1W | 2W |
| **TOTAL** | **~10W (idle/voting)** | **~55W (peak: scanning + printing)** |

Battery life estimate with 72Wh LiFePO4 cell:
- Idle (no voter): 72Wh / 10W = **7.2 hours**
- Active voting (continuous): 72Wh / 15W (avg) = **4.8 hours**
- The 4-hour minimum battery backup requirement is met with margin

Peak draw during printing is handled by the battery's high discharge capability (LiFePO4 can deliver 2C = 12A easily). The 12V/5A (60W) wall adapter covers all components at peak simultaneously.

---

## Environmental Specifications

| Parameter | Requirement |
|---|---|
| Operating temperature | -10°C to 50°C (14°F to 122°F) |
| Storage temperature | -20°C to 70°C (-4°F to 158°F) |
| Humidity | 10-90% non-condensing |
| Altitude | Up to 3,000m (10,000 ft) |
| Vibration | Per IEC 60068-2-6 (transport and in-use) |
| Drop | Survives 0.5m drop onto concrete (in enclosure) |
| EMC | FCC Part 15 Class A, CE marking |
| Safety | UL 62368-1 (IT equipment safety) |

These specs cover the range of real-world polling place conditions, from unheated garages in Minnesota winters to un-air-conditioned gymnasiums in Arizona summers.

---

## Manufacturing & Supply Chain

### Component Sourcing

All components are sourced from **at least two independent suppliers** where possible (dual-sourcing). The CM5 is the single-source risk (only available from Raspberry Pi Ltd), but the Raspberry Pi Foundation has demonstrated long-term commitment to industrial availability of Compute Modules, with the CM4 having a planned production life through 2034.

### Assembly

Board assembly (SMT pick-and-place, reflow soldering, testing) is performed by EMS (Electronics Manufacturing Services) providers. At least two independent EMS partners are qualified to build the CB-1, providing redundancy against supply disruptions.

### Quality Control

- **100% functional test**: Every assembled unit undergoes automated functional testing (all peripherals, TPM communication, boot sequence).
- **Burn-in**: Units are powered on for 48 hours at elevated temperature (40°C) to catch early failures (infant mortality screening).
- **Random sample destructive testing**: 1 in 1,000 units is disassembled and inspected for solder quality, component authenticity, and BOM compliance.
- **Component authentication**: All ICs (especially the TPM and CM5) are verified against manufacturer records to detect counterfeit components.

### Tamper-Evident Packaging

Finished units are sealed in tamper-evident packaging with unique serial numbers. The packaging serial number, machine serial number, TPM public key, and firmware hash are recorded in a database before shipment. Election officials verify these records upon receipt.

---

## Maintenance & Lifecycle

| Activity | Frequency | Performed By |
|---|---|---|
| Battery health check | Annually | Certified technician |
| Battery replacement | Every 5 years | Certified technician |
| Printer mechanism cleaning | Before each election | Poll worker (trained) |
| Paper roll replacement | Before each election | Poll worker |
| Security seal replacement | Each deployment cycle | Bipartisan team |
| Firmware update | As needed (>30 days pre-election) | Election administrator |
| Full diagnostic (LAT) | Before each election | Election official |
| Forensic audit (random sample) | After each election | Independent auditors |

**Expected unit lifespan**: 10 years (2-3 election cycles per year = 20-30 elections per unit).

**End-of-life**: Decommissioned units have their eMMC storage cryptographically wiped (overwrite + key destruction), TPM cleared, and batteries removed for recycling. The enclosure and non-electronic components are recycled.

---

## Open Hardware

The carrier board design (schematic, PCB layout, BOM, Gerber files) will be published under the **CERN Open Hardware Licence v2** (CERN-OHL-S-2.0). Anyone can manufacture the board, audit the design, or propose improvements. This is consistent with the project's transparency principle — security through design, not obscurity.
