#=============================================================================
# fix_hold_probe.tcl —— 在**已布线的数据库**上跑 TD 的显式 hold 修复（ECO），
#                       并对比修复前后的时序 / 可选地重新出位流。
#
# 为什么要单独做这一步：
#   官方 DefaultFlow.tcl 只在 `arr_filter on`（多种子模式）里才调 `fix_hold`，
#   普通流程（`arr_filter false`，例程与本工程都用它）完全不做显式 hold 修复，
#   只靠 route 命令自带的 hold 修复。本工程 2026-09-26 实测：
#     route 后         HWNS = +3 ps（1 个端点，pixel_clk 域）
#     fix_hold 一遍后  HWNS = +22 ps（setup 不变，仍是 +609 ps）
#     再跑第 2、3 遍    不再变化（已收敛）
#   修完仍能正常 `bitgen` 出流。
#
# 用法（必须在**与 phy_1 同级**的运行目录里跑，脚本要读 ../phy_1/<name>_pr.db）：
#   mkdir build/<proj>/td_project/<proj>_Runs/phy_hf
#   cp build/<proj>/.../phy_1/{<name>.prj,settings.cfg}  .../phy_hf/
#   cd .../phy_hf
#   <TD>/bin/td_commands_prompt.exe tools/fix_hold_probe.tcl
#
# 注意：这是"补救手段"，不是默认构建步骤。默认仍走官方流程（结果可复现、0 违例）。
#       只有当某个 RTL 改动把 hold 压成负值、而你又不想动结构时才用它。
#=============================================================================

set prj_name {hdmi_player}          # ← 改工程名时同步改这里
set route_db ../phy_1/${prj_name}_pr.db

puts "=== import_device / open_project ==="
import_device eagle_s20.db -package EG4S20BG256
open_project ${prj_name}.prj -noanalyze

puts "=== import post-route db: $route_db ==="
if {[catch {import_db $route_db} e]} { puts "IMPORT ERR: $e"; exit }
update_timing -mode final
report_qor -step route -file fixhold_before.qor
report_timing_summary -file fixhold_before.timing

puts "=== fix_hold ==="
if {[catch {fix_hold} e]} { puts "FIXHOLD ERR: $e" } else { puts "FIXHOLD OK" }
update_timing -mode final
report_qor -step route -file fixhold_after.qor
report_timing_summary -file fixhold_after.timing

# 需要的话把修复后的位流也出出来（去掉下面两行的注释）
# export_db ${prj_name}_fixhold_pr.db
# bitgen -bit ${prj_name}_fixhold.bit

puts "=== done：对比 fixhold_before.qor 与 fixhold_after.qor ==="
exit
