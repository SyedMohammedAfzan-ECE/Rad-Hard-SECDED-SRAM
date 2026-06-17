# Radiation-Hardened SEC-DED SRAM Architecture

## Overview
This repository contains the synthesizable SystemVerilog RTL and the Object-Oriented verification testbench for a fault-tolerant 2Kx16 SRAM array. The architecture implements Hamming Code combinational logic for real-time Single Error Correction and Double Error Detection (SEC-DED).

## Verification Methodology
The verification pipeline was built using a coverage-driven, OOP approach:
* **Generator:** Creates constrained-random read/write transactions to avoid address collisions.
* **Monitor:** Utilizes concurrent `fork...join_none` threads to track the parallel hardware pipeline and eliminate race conditions.
* **Scoreboard:** Evaluates hardware responses against a Golden Reference Model.

## Backdoor Error Injection
To mathematically prove the fault tolerance of the RTL, the testbench bypasses physical interfaces to inject targeted bit-flips directly into the memory array (`dut.mem`), simulating radiation strikes (Single-Event Upsets).

## Simulation Results
The testbench successfully executed 200 constrained transactions. The hardware seamlessly corrected 50 injected single-bit errors in real-time and successfully halted and flagged 50 injected double-bit errors, achieving a 100% verification pass rate in Aldec Riviera-PRO.
