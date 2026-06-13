# msort.sdc — timing constraints for the alignment-register merge-sorter.
# Single synchronous clock. Target 200 MHz (5.0 ns) as a starting point; tighten
# after the first fit to find true Fmax.

create_clock -name clk -period 5.000 [get_ports clk]

# Async, host-driven control/data; relax I/O timing (registered handshake).
set_input_delay  -clock clk 1.0 [remove_from_collection [all_inputs]  [get_ports clk]]
set_output_delay -clock clk 1.0 [all_outputs]

# The reset is applied for many cycles before use; treat as a false path.
set_false_path -from [get_ports rst_n]
