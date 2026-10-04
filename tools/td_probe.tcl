# 载入已布线的数据库，报告 SDRAM 原语落点与时钟网络情况
import_device eagle_s20.db -package EG4S20BG256
open_project {hdmi_player.prj} -noanalyze
import_db hdmi_player_pr.db

puts "############ SDRAM 原语落点 ############"
if {[catch {report_cells {u_sdram/u_sdram} -pin_loc} m]} { puts "  <失败: $m>" } else { puts $m }

puts "############ 时钟网络 ############"
if {[catch {report_clock_summary -expand_buckets} m]} { puts "  <失败: $m>" } else { puts $m }

puts "############ 顶层时钟网络走线 ############"
foreach n {clk_dup_1 mem_clk mem_clk_sft pixel_clk serial_clk} {
    if {[catch {report_nets $n -connection} m]} { puts "  $n <无法报告>" } else { puts "--- $n ---"; puts $m }
}
puts "=== DONE ==="
