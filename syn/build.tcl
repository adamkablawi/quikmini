# QuikMini: Vivado synthesis, place & route, and timing (non-project batch mode)
#
# Run from the repo root:  make synth
#   (or: vivado -mode batch -source syn/build.tcl)
#
# Builds out-of-context, so the bus ports aren't assigned to pins and the
# reports describe the core itself. Reports land in build/syn/.

set part   xc7s50csga324-1
set top    quikmini
set outdir build/syn

file mkdir $outdir

read_verilog -sv [glob rtl/*.sv]
read_xdc syn/quikmini.xdc

synth_design -top $top -part $part -mode out_of_context
report_utilization -file $outdir/post_synth_utilization.rpt

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 10 -file $outdir/timing_summary.rpt
report_utilization -file $outdir/utilization.rpt
report_utilization -hierarchical -file $outdir/utilization_hier.rpt

# One-line summary for the terminal
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / (10.0 - $wns)}]
puts [format "QuikMini @ 100 MHz: WNS = %.3f ns, Fmax ~ %.1f MHz" $wns $fmax]
