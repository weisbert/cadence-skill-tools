# cadence-skill-tools

Cadence SKILL tools for IC design automation in Virtuoso (developed against
IC6.1.8).

## Tools

- **[dreg_gen](dreg_gen/)** — *(in development)* Driver Register generator.
  Select a DUT in schematic, pick which pins to drive, and a Verilog-A
  "Dreg" cell is auto-generated with one CDF parameter per pin
  (1/0 → DVDD/0). Bus pins collapse to one integer parameter,
  bit-decomposed internally.

## Usage

Each tool is self-contained under its own subdirectory. Load by sourcing
its `.il` files in the CIW:

```skill
load("<path-to-cadence-skill-tools>/<tool>/<file>.il")
```

See each tool's README for load order, entry points, and acceptance tests.
