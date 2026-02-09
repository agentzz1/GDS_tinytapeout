## How it works

### RTX 8090 – 4-Bit ALU mit Moore-FSM Controller

Dieses Design implementiert eine 4-Bit ALU mit separatem Steuerwerk (Moore-FSM) und Datenpfad.
Es läuft auf dem IHP SG13G2 130nm Prozess via Tiny Tapeout.

#### Architektur: Steuerwerk + Datenpfad (Y-Diagramm)

```
                    ┌─────────────────────────────┐
    ui_in[7] ──────►│      CONTROL (Moore FSM)     │
    (start)         │                              │
    ui_in[6:4] ────►│  IDLE → LOAD → EXECUTE → DONE│
    (op_select)     │                              │
                    │  Outputs: load_a, load_b,    │
                    │  alu_op, result_valid, busy   │
                    └──────┬───────────────────┬───┘
                           │ Steuersignale     │ Flags
                           ▼                   ▲
                    ┌──────────────────────────────┐
    ui_in[3:0] ────►│      DATAPATH (ALU)          │
    (operand_a)     │                              │
    uio_in[3:0] ───►│  ┌────────────────────┐      │──► uo_out[7:0]
    (operand_b)     │  │  SHARED ADDER (1x)  │      │    (result)
                    │  │  ADD: A + B          │      │
                    │  │  SUB: A + ~B + 1     │      │──► Flags
                    │  └────────────────────┘      │
                    └──────────────────────────────┘
```

**Prüfungsbezug Y-Diagramm:** Dieses Design befindet sich auf der **Struktur-Achse** des Y-Diagramms auf RT-Ebene. Die Verhaltensebene (was die ALU tun soll) wurde manuell in eine Struktur (FSM + Datenpfad) überführt – genau das, was ein HLS-Tool automatisch macht.

#### Prüfungsthema: Moore vs. Mealy FSM

Die FSM ist ein **Moore-Automat**: Alle Ausgänge (load_a, load_b, alu_op, result_valid, busy) hängen **nur vom aktuellen Zustand** ab, nicht von den Eingängen.

| Zustand | load_a | load_b | result_valid | busy |
|---------|--------|--------|-------------|------|
| IDLE    | 0      | 0      | 0           | 0    |
| LOAD    | 1      | 1      | 0           | 1    |
| EXECUTE | 0      | 0      | 0           | 1    |
| DONE    | 0      | 0      | 1           | 0    |

**Warum Moore statt Mealy?** Moore-Ausgänge sind **glitch-frei** (da sie nur von Registern abhängen). Mealy-Ausgänge können Glitches haben, weil sie direkt von kombinatorischen Eingängen abhängen.

**Prüfungsfrage:** "Warum hat ein Mealy-Automat potenziell Glitches am Ausgang?"
→ Weil die Ausgänge von Eingängen abhängen, die sich asynchron ändern können. Die kombinatorische Logik kann kurzzeitig falsche Werte produzieren.

#### Prüfungsthema: Allokation & Binding (Resource Sharing)

Im Datenpfad gibt es **einen einzigen Addierer**, der für drei Operationen genutzt wird:

- **ADD:** `result = A + B` (carry_in = 0, adder_b = B)
- **SUB:** `result = A + ~B + 1` (carry_in = 1, adder_b = ~B, Zweierkomplement)
- **CMP:** Wie SUB, aber nur Flags werden genutzt

**Allokation:** Es wird nur 1 Addierer-Ressource instanziiert (statt 2 oder 3).
**Binding:** ADD, SUB und CMP sind an dieselbe Hardwareressource gebunden, gesteuert durch Multiplexer.

**Prüfungsfrage:** "Was ist der Unterschied zwischen Allokation und Binding?"
→ Allokation = Wie viele Ressourcen eines Typs? Binding = Welche Operation nutzt welche Ressource zu welcher Zeit?

#### Prüfungsthema: Scheduling

Die FSM implementiert implizit einen **Schedule**: Jede Operation braucht genau 4 Taktzyklen (IDLE→LOAD→EXECUTE→DONE). Das entspricht einem **statischen Schedule** mit fester Latenz.

Bei **List-Scheduling** (Heuristik) werden Operationen priorisiert und in den frühestmöglichen Takt eingeplant.
Bei **Force-Directed Scheduling** wird die "Self-Force" minimiert – das Maß dafür, wie "teuer" es ist, eine Operation in einen bestimmten Takt zu legen.

#### Prüfungsthema: Was passiert nach der Synthese?

Wenn GitHub Actions den GDS-Flow (LibreLane/OpenLane) startet:

1. **Logiksynthese (Yosys):** Die Verilog-Beschreibung wird in eine Netzliste aus IHP SG13G2 Standardzellen umgewandelt. Dabei kommt **Technologieabbildung** (Technology Mapping) zum Einsatz – oft via Dynamischer Programmierung.

2. **Platzierung (Placement):** Die Zellen werden auf dem Die angeordnet. Der Algorithmus nutzt **Simulated Annealing** mit dem **Metropolis-Kriterium**: Schlechtere Lösungen werden mit Wahrscheinlichkeit e^(-ΔC/T) akzeptiert, um lokale Minima zu verlassen. `PL_TARGET_DENSITY_PCT = 70` in unserer config.json zwingt den Algorithmus, dichter zu packen.

3. **Clock Tree Synthesis (CTS):** Ein Taktbaum wird aufgebaut, damit alle Flip-Flops den Takt gleichzeitig erhalten (minimaler Clock Skew).

4. **Routing:** Die Verdrahtung nutzt **Steiner-Baum-Heuristiken** (globales Routing) und den **Lee-Algorithmus** (Detail-Routing per Maze/Wellenfrontausbreitung).

5. **Timing-Analyse (STA):** Prüft, ob alle Pfade die 20ns Clock Period (50 MHz) einhalten. Falls nicht → **Retiming** (Register verschieben) oder Logik-Optimierung.

#### Prüfungsthema: Retiming

Die Retiming-Formel: `w'(e) = w(e) + r(u) - r(v) ≥ 0`

- w(e) = Anzahl Register auf Kante e
- r(v) = Retiming-Wert des Knotens v
- Die Bedingung w'(e) ≥ 0 stellt sicher, dass keine negativen Registerzahlen entstehen

Unser Design bei 50 MHz auf 130nm sollte keine Timing-Probleme haben. Aber: Wenn du `CLOCK_PERIOD` in config.json auf z.B. 5ns (200 MHz) senkst, wird das Tool Retiming und stärkere Optimierung anwenden müssen.

## How to test

1. Reset: `rst_n` auf 0 setzen, dann auf 1
2. Operanden anlegen: `ui_in[3:0]` = A, `uio_in[3:0]` = B
3. Operation wählen: `ui_in[6:4]` = Opcode (000=ADD, 001=SUB, 010=AND, 011=OR, 100=XOR, 101=SHL, 110=SHR, 111=CMP)
4. Start: `ui_in[7]` = 1 für einen Takt, dann 0
5. Warten auf `uio_out[3]` (result_valid) = 1
6. Ergebnis ablesen: `uo_out[7:0]`, Flags: `uio_out[0]`=zero, `uio_out[1]`=carry, `uio_out[2]`=overflow

Beispiel: 3 + 5 = 8
- ui_in = 8'b1_000_0011 (start=1, op=ADD, A=3)
- uio_in = 8'b0000_0101 (B=5)
- Nach 3 Takten: uo_out = 8'b00001000 (=8), result_valid=1

## External hardware

Keine externe Hardware benötigt. Kann direkt über die Tiny Tapeout Demo-Boards getestet werden.
